import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:reown_appkit/reown_appkit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/base58.dart' show base58encode;
import 'package:url_launcher/url_launcher.dart';

import '../../core/platform_wallet.dart';
import '../wallet/solana_device_detector.dart';
import '../wallet/solana_wallet_option.dart';
import '../wallet/solana_wallet_picker_sheet.dart';
import '../wallet/solana_wallet_service.dart';
import 'auth_config.dart';
import 'desktop_web_auth.dart';
import 'drop_auth_client.dart';
import 'drop_gateway_client.dart';
import 'gateway_http.dart';
import 'gateway_models.dart';
import 'gateway_session_broker.dart';
import 'gateway_session_repository.dart';
import 'social_login.dart';

/// Auth/session and org state for the Erebrus Drop gateway.
///
/// Supports multiple login paths:
/// - Reown AppKit modal (wallet + social/email) on mobile
/// - Solana Mobile Wallet Adapter on Seeker/Saga
/// - Native Google / Apple sign-in
/// - Gateway email OTP
/// - Desktop browser webauth fallback (erebrusdrop:// callback)
class DropAuthService {
  DropAuthService({
    required this.solana,
    DropAuthClient? authClient,
    DropGatewayClient? gatewayClient,
    GatewaySessionRepository? sessionRepository,
  }) : _authClient = authClient ?? DropAuthClient(),
       _gatewayClient = gatewayClient ?? DropGatewayClient() {
    _sessions = sessionRepository ?? GatewaySessionBroker.owner(_authClient);
    _authClient.authorization = _sessions;
    _gatewayClient.authorization = _sessions;
    _sessions.current.addListener(_syncSession);
    _sessions.message.addListener(_syncSessionMessage);
  }

  final SolanaWalletService solana;
  final DropAuthClient _authClient;
  final DropGatewayClient _gatewayClient;
  late final GatewaySessionRepository _sessions;

  String? _bearerToken;
  String? _walletAddress;
  String? _userId;
  String? _authMethod;
  String? _mwaAuthToken;
  String? _identityGeneration;
  ReownAppKitModal? _appKitModal;
  Future<void>? _reownInitFuture;
  Future<bool>? _revalidationFuture;
  int? _pendingWebGeneration;
  StreamSubscription<Uri>? _deepLinkSubscription;
  bool _disposed = false;

  final ValueNotifier<List<DropOrg>> orgs = ValueNotifier<List<DropOrg>>(
    const [],
  );
  final ValueNotifier<DropOrg?> selectedOrg = ValueNotifier<DropOrg?>(null);
  final ValueNotifier<bool> isAuthenticating = ValueNotifier<bool>(false);
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);
  final ValueNotifier<bool> reownReady = ValueNotifier<bool>(false);
  final ValueNotifier<bool> reownInitializing = ValueNotifier<bool>(false);
  final ValueNotifier<bool> awaitingWebCallback = ValueNotifier<bool>(false);
  final ValueNotifier<bool> solanaMobileDevice = ValueNotifier<bool>(false);
  final ValueNotifier<bool> appleDeviceReady = ValueNotifier<bool>(false);
  final ValueNotifier<DropAuthMethods> authMethods =
      ValueNotifier<DropAuthMethods>(DropAuthMethods.unknown);

  final ValueNotifier<int> loginRevision = ValueNotifier<int>(0);
  final ValueNotifier<bool> signedIn = ValueNotifier<bool>(false);

  String? get bearerToken => _bearerToken;
  String? get walletAddress => _walletAddress;
  String? get userId => _userId;
  String? get authMethod => _authMethod;
  bool get isSignedIn => signedIn.value;
  bool get requiresLogin =>
      _sessions.current.value?.loginRequired == true ||
      _sessions.current.value?.rotationPending == true;
  DropGatewayClient get gatewayClient => _gatewayClient;

  /// Combined [Listenable] for UI state observers.
  Listenable get state => Listenable.merge([
    signedIn,
    loginRevision,
    isAuthenticating,
    error,
    reownReady,
    reownInitializing,
    awaitingWebCallback,
    solanaMobileDevice,
    appleDeviceReady,
    authMethods,
  ]);

  bool get emailLoginAvailable => authMethods.value.email;
  bool get googleLoginAvailable =>
      authMethods.value.google && googleSignInSupported;
  bool get appleLoginAvailable =>
      authMethods.value.apple && appleDeviceReady.value;

  static const String _kSelectedOrgId = 'erebrus_selected_org_id';
  static const String _kSelectedOrgSlug = 'erebrus_selected_org_slug';
  static const String _kSelectedOrgName = 'erebrus_selected_org_name';

  /// Restores session and starts deep-link + auth-method discovery.
  Future<void> loadSession() async {
    try {
      await _sessions.restore();
      _syncSession();
      final prefs = await SharedPreferences.getInstance();
      if (isSignedIn) await _restoreSelectedOrg(prefs);
    } catch (_) {
      error.value =
          'Secure session storage is unavailable. Try again after unlocking your device.';
    }
    await _detectDevice();
    await _loadAuthMethods();
    if (_disposed) return;
    await _listenDeepLinks();
    await revalidateSession();
  }

  /// Checks the current bearer session against an authenticated endpoint.
  /// Renewal failures preserve the session unless explicitly revoked.
  Future<bool> revalidateSession() {
    final active = _revalidationFuture;
    if (active != null) return active;
    late final Future<bool> future;
    future = _runSessionRevalidation().whenComplete(() {
      if (identical(_revalidationFuture, future)) _revalidationFuture = null;
    });
    _revalidationFuture = future;
    return future;
  }

  Future<bool> _runSessionRevalidation() async {
    try {
      await _sessions.restore();
      _syncSession();
      if (!isSignedIn) return false;
      await _sessions.authorize();
      await _loadOrgs();
      error.value = null;
      return true;
    } on GatewayException catch (e) {
      error.value = e.message;
      return isSignedIn;
    } catch (_) {
      error.value = 'Session validation is unavailable. Try again later.';
      return isSignedIn;
    }
  }

  /// Initializes Reown AppKit once a [BuildContext] is available.
  Future<void> initReown(BuildContext context) async {
    while (context.mounted) {
      final active = _reownInitFuture;
      if (active != null) {
        await active;
        if (!context.mounted) return;
        if (_appKitModal?.modalContext == context ||
            !hasReownProjectId ||
            solanaMobileDevice.value ||
            isDesktopPlatform) {
          return;
        }
        // The active initialization belonged to a screen that was replaced.
        // Loop once more so the modal receives this screen's live context.
        continue;
      }

      if (!context.mounted) return;
      late final Future<void> future;
      future = _runReownInitialization(context).whenComplete(() {
        if (identical(_reownInitFuture, future)) _reownInitFuture = null;
      });
      _reownInitFuture = future;
      await future;
      return;
    }
  }

  Future<void> _runReownInitialization(BuildContext context) async {
    try {
      await _initializeReown(context);
    } catch (e) {
      debugPrint('[Reown] init failed: $e');
      error.value = 'Wallet connect failed to start: $e';
      reownReady.value = false;
    } finally {
      reownInitializing.value = false;
    }
  }

  Future<void> _initializeReown(BuildContext context) async {
    if (solanaMobileDevice.value || isDesktopPlatform) return;
    reownInitializing.value = true;
    if (!hasReownProjectId) {
      error.value = kReownProjectIdMissingMessage;
      reownReady.value = false;
      return;
    }

    final previousModal = _appKitModal;
    final wasReady = reownReady.value;
    if (previousModal?.modalContext == context && wasReady) {
      return;
    }

    reownReady.value = false;
    final existingAppKit = wasReady ? previousModal?.appKit : null;
    if (previousModal != null) {
      await previousModal.dispose();
      _appKitModal = null;
    }

    ReownAppKitModalNetworks.removeSupportedNetworks('eip155');
    ReownAppKitModalNetworks.removeTestNetworks();

    final solanaChains = ReownAppKitModalNetworks.getAllSupportedNetworks(
      namespace: 'solana',
    );
    final solanaNamespaces = solanaChains.isEmpty
        ? null
        : {
            'solana': RequiredNamespace(
              chains: solanaChains.map((c) => c.chainId).toList(),
              methods: const ['solana_signMessage', 'solana_signTransaction'],
              events: const [],
            ),
          };

    await PackageInfo.fromPlatform();
    if (!context.mounted) return;

    _appKitModal = ReownAppKitModal(
      context: context,
      appKit: existingAppKit,
      projectId: kReownProjectId,
      logLevel: LogLevel.error,
      metadata: PairingMetadata(
        name: 'Erebrus Drop',
        description: 'Local-first secure Drop Room file transfer',
        url: erebrusSiteUrlFromOrigin(kErebrusWebOrigin),
        icons: [erebrusSiteIconFromOrigin(kErebrusWebOrigin)],
        redirect: const Redirect(
          native: kErebrusNativeRedirect,
          universal: kErebrusUniversalRedirect,
          linkMode: false,
        ),
      ),
      optionalNamespaces: solanaNamespaces,
      featuresConfig: FeaturesConfig(
        showMainWallets: true,
        socials: const [
          AppKitSocialOption.Google,
          AppKitSocialOption.Apple,
          AppKitSocialOption.Email,
          AppKitSocialOption.X,
        ],
      ),
      disconnectOnDispose: false,
    );

    try {
      await _appKitModal!.init();
      _appKitModal!.onModalConnect.subscribe(_onModalConnect);
      _appKitModal!.onModalDisconnect.subscribe(_onModalDisconnect);
      _appKitModal!.onModalError.subscribe(_onModalError);
      reownReady.value = true;

      if (_appKitModal!.isConnected && !isSignedIn) {
        await _authenticateConnectedWallet();
      }
    } catch (e) {
      debugPrint('[Reown] init failed: $e');
      error.value = 'Wallet connect failed to start: $e';
      reownReady.value = false;
    }
  }

  Future<void> openReownModal(BuildContext context) async {
    error.value = null;
    final modal = _appKitModal;
    if (modal == null || !reownReady.value || modal.modalContext != context) {
      await initReown(context);
    }
    if (!context.mounted) return;
    final readyModal = _appKitModal;
    if (readyModal == null ||
        !reownReady.value ||
        readyModal.modalContext != context) {
      error.value = 'Wallet connection is unavailable right now';
      return;
    }
    try {
      await readyModal.openModalView();
    } catch (e) {
      debugPrint('[Reown] open failed: $e');
      error.value = 'Could not open wallet connection: $e';
    }
  }

  /// Cancels an in-flight sign-in attempt and dismisses any open wallet modal.
  void cancelAuthentication() {
    final generation = _sessions.beginLogin();
    _sessions.finishLogin(generation);
    DesktopWebAuth.clearPendingState();
    isAuthenticating.value = false;
    awaitingWebCallback.value = false;
    try {
      if (_appKitModal?.isOpen == true) {
        _appKitModal?.closeModal();
      }
    } catch (_) {}
    error.value = 'Sign-in cancelled';
  }

  /// Opens the browser-based Erebrus sign-in (desktop fallback / mobile generic).
  Future<void> openWebSignIn() async {
    if (isAuthenticating.value || awaitingWebCallback.value) return;
    error.value = null;
    awaitingWebCallback.value = true;
    _pendingWebGeneration = _sessions.generation;
    try {
      final url = DesktopWebAuth.buildLoginUrl();
      final uri = Uri.parse(url);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        awaitingWebCallback.value = false;
        error.value = 'Could not open the browser — check your default browser';
      }
    } catch (e) {
      awaitingWebCallback.value = false;
      error.value = e.toString();
    }
  }

  /// Handles an `erebrusdrop://auth?token=...` callback from the browser.
  Future<void> handleWebAuthCallback(String url) async {
    if (!DesktopWebAuth.isAuthCallback(url)) return;
    if (_pendingWebGeneration != _sessions.generation) return;
    awaitingWebCallback.value = false;
    final generation = _sessions.beginLogin();
    isAuthenticating.value = true;
    error.value = null;
    try {
      final callback = DesktopWebAuth.parseCallback(url);
      if (callback == null || !callback.isValid) {
        error.value = 'Sign-in callback was incomplete — try again';
        return;
      }
      DesktopWebAuth.validateState(callback.state);
      final session = DropAuthSession(
        token: callback.token,
        userId: callback.userId,
        role: callback.role,
        walletAddress: callback.walletAddress,
      );
      await _persistSession(session, generation: generation, method: 'web');
      DesktopWebAuth.clearPendingState();
      await _loadOrgs();
    } on DesktopWebAuthException catch (e) {
      if (generation == _sessions.generation) error.value = e.message;
    } catch (e) {
      if (generation == _sessions.generation) error.value = e.toString();
    } finally {
      _sessions.finishLogin(generation);
      if (generation == _sessions.generation) isAuthenticating.value = false;
    }
  }

  /// Allows pasting a PASETO or full callback URL.
  Future<void> signInFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      error.value = 'Clipboard is empty — copy the sign-in token first';
      return;
    }
    await signInWithPastedCredential(text);
  }

  Future<void> signInWithPastedCredential(String input) async {
    final generation = _sessions.beginLogin();
    isAuthenticating.value = true;
    awaitingWebCallback.value = false;
    error.value = null;
    try {
      final callback = DesktopWebAuth.parseManualAuthInput(input);
      if (callback == null || callback.token.isEmpty) {
        error.value =
            'Could not read a sign-in token — paste the PASETO or full callback URL';
        return;
      }
      final session = DropAuthSession(
        token: callback.token,
        userId: callback.userId.isEmpty ? 'imported' : callback.userId,
        role: callback.role.isEmpty ? 'user' : callback.role,
        walletAddress: callback.walletAddress.isEmpty
            ? 'imported'
            : callback.walletAddress,
      );
      await _persistSession(
        session,
        generation: generation,
        method: 'manual_paste',
      );
      DesktopWebAuth.clearPendingState();
      await _loadOrgs();
    } catch (e) {
      if (generation == _sessions.generation) error.value = e.toString();
    } finally {
      _sessions.finishLogin(generation);
      if (generation == _sessions.generation) isAuthenticating.value = false;
    }
  }

  /// Solana Mobile Wallet Adapter sign-in (Seeker / Saga).
  Future<void> signInWithSolanaMobile(BuildContext context) async {
    if (!Platform.isAndroid || !solanaMobileDevice.value) {
      error.value =
          'Solana Mobile sign-in is only available on Seeker and Saga';
      return;
    }
    if (isAuthenticating.value) return;

    final generation = _sessions.beginLogin();
    isAuthenticating.value = true;
    error.value = null;
    try {
      final wallet = await _pickOrUseConnectedSolanaWallet(context);
      if (wallet == null) {
        error.value = 'No wallet selected';
        return;
      }
      final address = solana.walletAddress;
      if (address == null) {
        error.value = 'Wallet did not return an address';
        return;
      }

      final challenge = await _authClient.fetchAuthChallenge(
        walletAddress: address,
      );
      if (challenge.message.isEmpty) {
        error.value = 'Erebrus returned an empty challenge';
        return;
      }

      final authToken = solana.authToken;
      if (authToken == null || authToken.isEmpty) {
        error.value = 'Wallet is not authorized';
        return;
      }

      final signature = await PlatformWallet.signMessage(
        wallet: wallet,
        authToken: authToken,
        message: challenge.message,
      );

      final session = await _authClient.authenticate(
        challengeId: challenge.challengeId,
        signature: signature,
        publicKey: address,
      );

      await _persistSession(
        session,
        generation: generation,
        method: 'solana_mobile',
        mwaToken: authToken,
      );
      await _loadOrgs();
    } catch (e) {
      if (generation == _sessions.generation) error.value = e.toString();
    } finally {
      _sessions.finishLogin(generation);
      if (generation == _sessions.generation) isAuthenticating.value = false;
    }
  }

  Future<void> signInWithGoogle() async {
    if (isAuthenticating.value || !googleLoginAvailable) return;
    final generation = _sessions.beginLogin();
    isAuthenticating.value = true;
    error.value = null;
    try {
      final idToken = await googleIdToken();
      if (idToken == null) return;
      final session = await _authClient.googleLogin(idToken);
      await _persistSession(session, generation: generation, method: 'google');
      await _loadOrgs();
    } on AuthException catch (e) {
      if (generation == _sessions.generation) error.value = e.message;
    } on SocialLoginException catch (e) {
      if (generation == _sessions.generation) error.value = e.message;
    } catch (e) {
      if (generation == _sessions.generation) error.value = e.toString();
    } finally {
      _sessions.finishLogin(generation);
      if (generation == _sessions.generation) isAuthenticating.value = false;
    }
  }

  Future<void> signInWithApple() async {
    if (isAuthenticating.value || !appleLoginAvailable) return;
    final generation = _sessions.beginLogin();
    isAuthenticating.value = true;
    error.value = null;
    try {
      final credential = await appleCredential();
      if (credential == null) return;
      final session = await _authClient.appleLogin(
        idToken: credential.identityToken,
        authorizationCode: credential.authorizationCode,
        nonce: credential.nonce,
        state: credential.state,
      );
      await _persistSession(session, generation: generation, method: 'apple');
      await _loadOrgs();
    } on AuthException catch (e) {
      if (generation == _sessions.generation) error.value = e.message;
    } on SocialLoginException catch (e) {
      if (generation == _sessions.generation) error.value = e.message;
    } catch (e) {
      if (generation == _sessions.generation) error.value = e.toString();
    } finally {
      _sessions.finishLogin(generation);
      if (generation == _sessions.generation) isAuthenticating.value = false;
    }
  }

  Future<bool> requestEmailLoginCode(String email) async {
    error.value = null;
    try {
      await _authClient.emailLoginStart(email.trim().toLowerCase());
      return true;
    } on AuthException catch (e) {
      error.value = e.message;
    } catch (e) {
      error.value = e.toString();
    }
    return false;
  }

  Future<void> verifyEmailLoginCode({
    required String email,
    required String code,
  }) async {
    final normalized = code.replaceAll(RegExp(r'\D'), '');
    if (normalized.length < 4) {
      error.value = 'Enter the full code from your email';
      return;
    }
    final generation = _sessions.beginLogin();
    isAuthenticating.value = true;
    error.value = null;
    try {
      final session = await _authClient.emailLoginVerify(
        email: email.trim().toLowerCase(),
        code: normalized,
      );
      if (session.token.isEmpty) {
        error.value = 'Sign-in succeeded but no session token was returned';
        return;
      }
      await _persistSession(session, generation: generation, method: 'email');
      await _loadOrgs();
    } on AuthException catch (e) {
      if (generation == _sessions.generation) error.value = e.message;
    } on TimeoutException {
      if (generation == _sessions.generation) {
        error.value = 'Sign-in timed out — check your connection and try again';
      }
    } catch (e) {
      if (generation == _sessions.generation) error.value = e.toString();
    } finally {
      _sessions.finishLogin(generation);
      if (generation == _sessions.generation) isAuthenticating.value = false;
    }
  }

  /// Creates a new organization and refreshes the org list.
  Future<DropOrg> createOrg({
    required String name,
    required String slug,
  }) async {
    if (!isSignedIn) throw const AuthException('Sign in first');
    final org = await _authClient.createOrg(
      bearerToken: _bearerToken!,
      name: name,
      slug: slug,
    );
    await _loadOrgs();
    if (selectedOrg.value == null) {
      await selectOrg(org);
    }
    return org;
  }

  /// Binds an invite code to the signed-in user so the gateway can credit the
  /// referral (XP is awarded to both parties later, once the referee qualifies).
  /// Returns a short success message; throws [AuthException] on an empty code,
  /// an unauthenticated caller, or a gateway rejection.
  Future<String> redeemReferralCode(String code) async {
    if (!isSignedIn || _bearerToken == null || _bearerToken!.isEmpty) {
      throw const AuthException('Sign in first');
    }
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      throw const AuthException('Enter an invite code');
    }
    try {
      final result = await _authClient.redeemReferral(
        bearerToken: _bearerToken!,
        code: trimmed,
      );
      // The gateway returns the referral summary (or `{bound: true}`) — there is
      // no message/xp field, and XP is credited server-side only after the
      // referee qualifies, so confirm the binding rather than promise points.
      final applied =
          result['referral_bound'] == true || result['bound'] == true;
      return applied ? 'Invite code applied' : 'Invite code received';
    } on GatewayException catch (e) {
      throw AuthException(e.message);
    }
  }

  /// Selects the active organization used for Drop discovery and uploads.
  Future<void> selectOrg(DropOrg org) async {
    selectedOrg.value = org;
    _gatewayClient.token = _bearerToken;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSelectedOrgId, org.id);
    await prefs.setString(_kSelectedOrgSlug, org.slug);
    await prefs.setString(_kSelectedOrgName, org.name);
  }

  /// Local logout always clears auth; false means remote revoke is unconfirmed.
  Future<bool> signOut() async {
    final mwaToken = _mwaAuthToken;
    DesktopWebAuth.clearPendingState();
    _pendingWebGeneration = null;
    awaitingWebCallback.value = false;
    isAuthenticating.value = false;
    final logout = _sessions.logout();
    _syncSession();
    unawaited(googleSignOut());
    if (mwaToken != null) unawaited(_disconnectSolanaMobile(mwaToken));
    try {
      await _appKitModal?.disconnect();
    } catch (_) {}
    return logout;
  }

  void _syncSession() {
    final record = _sessions.current.value;
    _bearerToken = record?.session.token;
    _walletAddress = record?.session.walletAddress;
    _userId = record?.session.userId;
    _authMethod = record?.method;
    _mwaAuthToken = record?.mwaToken;
    _gatewayClient.token = _bearerToken;
    if (record == null || record.generation != _identityGeneration) {
      orgs.value = const [];
      selectedOrg.value = null;
    }
    _identityGeneration = record?.generation;
    signedIn.value = record != null;
  }

  void _syncSessionMessage() => error.value = _sessions.message.value;

  void dispose() {
    _disposed = true;
    _sessions.current.removeListener(_syncSession);
    _sessions.message.removeListener(_syncSessionMessage);
    unawaited(_deepLinkSubscription?.cancel());
  }

  Future<void> _loadAuthMethods() async {
    try {
      authMethods.value = await _authClient.fetchAuthMethods();
    } catch (e) {
      debugPrint('[Auth] auth methods unavailable, using defaults: $e');
    }
    try {
      appleDeviceReady.value = await appleSignInSupported();
    } catch (_) {
      appleDeviceReady.value = false;
    }
  }

  Future<void> _detectDevice() async {
    try {
      solanaMobileDevice.value = await isSolanaMobileDevice();
    } catch (_) {
      solanaMobileDevice.value = false;
    }
  }

  Future<void> _listenDeepLinks() async {
    if (_disposed) return;
    try {
      final appLinks = AppLinks();
      await _deepLinkSubscription?.cancel();
      if (_disposed) return;
      _deepLinkSubscription = appLinks.uriLinkStream.listen((uri) {
        final url = uri.toString();
        if (DesktopWebAuth.isAuthCallback(url)) {
          unawaited(handleWebAuthCallback(url));
        } else if (!isDesktopPlatform) {
          _appKitModal?.dispatchEnvelope(url);
        }
      });
      final initial = await appLinks.getInitialLink();
      if (initial != null) {
        final url = initial.toString();
        if (DesktopWebAuth.isAuthCallback(url)) {
          unawaited(handleWebAuthCallback(url));
        }
      }
    } catch (e) {
      debugPrint('[Auth] deep link listener not available: $e');
    }
  }

  Future<void> _onModalConnect(ModalConnect? event) async {
    if (event != null) await _authenticateConnectedWallet();
  }

  Future<void> _onModalDisconnect(ModalDisconnect? event) async {}

  Future<void> _onModalError(ModalError? event) async {
    final message = event?.message;
    if (message == null || message.isEmpty) return;
    if (message.toLowerCase().contains('origin not allowed')) {
      final packageInfo = await PackageInfo.fromPlatform();
      error.value = reownOriginNotAllowedMessage(packageInfo.packageName);
      return;
    }
    error.value = message;
  }

  Future<void> _authenticateConnectedWallet() async {
    final modal = _appKitModal;
    if (modal == null || !modal.isConnected) return;

    final address = await _solanaAddressFromModal(modal);
    if (address == null || address.isEmpty) {
      error.value =
          'Connect a Solana wallet (Phantom, Solflare, etc.). For email sign-in, use Continue with Email — the wallet modal email option does not sign you into Erebrus.';
      return;
    }

    final generation = _sessions.beginLogin();
    isAuthenticating.value = true;
    error.value = null;
    try {
      final challenge = await _authClient.fetchAuthChallenge(
        walletAddress: address,
      );
      final signature = await _signChallengeWithModal(
        modal,
        address,
        challenge.message,
      );
      final session = await _authClient.authenticate(
        challengeId: challenge.challengeId,
        signature: signature,
        publicKey: address,
      );
      await _persistSession(session, generation: generation, method: 'reown');
      await _loadOrgs();
      if (modal.isOpen) modal.closeModal();
    } on AuthException catch (e) {
      if (generation == _sessions.generation) error.value = e.message;
    } catch (e) {
      if (generation == _sessions.generation) error.value = e.toString();
    } finally {
      _sessions.finishLogin(generation);
      if (generation == _sessions.generation) isAuthenticating.value = false;
    }
  }

  Future<String?> _solanaAddressFromModal(ReownAppKitModal modal) async {
    var chainId = modal.selectedChain?.chainId ?? '';
    if (!chainId.startsWith('solana:')) {
      final solChains = ReownAppKitModalNetworks.getAllSupportedNetworks(
        namespace: 'solana',
      );
      if (solChains.isNotEmpty) {
        await modal.selectChain(solChains.first);
      }
    }
    final selected = modal.selectedChain?.chainId ?? '';
    if (!selected.startsWith('solana:')) return null;
    return modal.session?.getAddress('solana');
  }

  Future<String> _signChallengeWithModal(
    ReownAppKitModal modal,
    String address,
    String message,
  ) async {
    final chainId = modal.selectedChain!.chainId;
    final messageBase58 = base58encode(
      Uint8List.fromList(utf8.encode(message)),
    );

    final response = await modal
        .request(
          topic: modal.session!.topic,
          chainId: chainId,
          request: SessionRequestParams(
            method: 'solana_signMessage',
            params: {'pubkey': address, 'message': messageBase58},
          ),
        )
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () =>
              throw const AuthException('Wallet signature timed out'),
        );

    return _signatureToTransmittable(response);
  }

  String _signatureToTransmittable(dynamic response) {
    if (response is String) return response;
    if (response is Map) {
      final sig = _recursiveSearchForMapKey(
        Map<String, dynamic>.from(response),
        'signature',
      );
      if (sig is String) return sig;
    }
    if (response is List && response.isNotEmpty) {
      return _signatureToTransmittable(response.first);
    }
    throw const AuthException('Wallet returned an unreadable signature');
  }

  dynamic _recursiveSearchForMapKey(Map<String, dynamic> map, String key) {
    if (map.containsKey(key)) return map[key];
    for (final value in map.values) {
      if (value is Map<String, dynamic>) {
        final found = _recursiveSearchForMapKey(value, key);
        if (found != null) return found;
      }
    }
    return null;
  }

  Future<SolanaWalletOption?> _pickOrUseConnectedSolanaWallet(
    BuildContext context,
  ) async {
    if (solana.isConnected && solana.connectedWallet != null) {
      return solana.connectedWallet;
    }
    final wallet = await showSolanaWalletPickerSheet(
      context: context,
      walletService: solana,
    );
    if (wallet != null) await solana.connect(wallet: wallet);
    return wallet;
  }

  Future<void> _disconnectSolanaMobile(String? mwaToken) async {
    if (mwaToken == null || mwaToken.isEmpty || !Platform.isAndroid) return;
    try {
      final wallet = solana.connectedWallet;
      if (wallet != null) {
        await PlatformWallet.deauthorizeWallet(
          wallet: wallet,
          authToken: mwaToken,
        );
      }
    } catch (e) {
      debugPrint('[Auth] MWA deauthorize: $e');
    }
  }

  Future<void> _persistSession(
    DropAuthSession session, {
    required int generation,
    required String method,
    String? mwaToken,
  }) async {
    await _sessions.install(
      session,
      expectedGeneration: generation,
      method: method,
      mwaToken: mwaToken,
    );
    if (generation != _sessions.generation) {
      throw const AuthException('Sign-in cancelled');
    }
    DesktopWebAuth.clearPendingState();
    _pendingWebGeneration = null;
    // Notify navigation about successful reauthentication without discarding
    // the recoverable account state during an ordinary refresh failure.
    loginRevision.value++;
  }

  Future<void> _loadOrgs() async {
    if (!isSignedIn) {
      orgs.value = const [];
      return;
    }
    final generation = _sessions.generation;
    await _sessions.authorize();
    final list = await _authClient.fetchOrgs(_bearerToken!);
    if (generation != _sessions.generation || !isSignedIn) return;
    orgs.value = list;
    if (list.isNotEmpty) {
      final selectedId = selectedOrg.value?.id;
      await selectOrg(
        list.firstWhere(
          (org) => org.id == selectedId,
          orElse: () => list.first,
        ),
      );
    } else {
      selectedOrg.value = null;
    }
  }

  Future<void> _restoreSelectedOrg(SharedPreferences prefs) async {
    final id = prefs.getString(_kSelectedOrgId);
    if (id == null || id.isEmpty) {
      if (orgs.value.isNotEmpty) {
        await selectOrg(orgs.value.first);
      }
      return;
    }
    if (orgs.value.isEmpty) {
      selectedOrg.value = DropOrg(
        id: id,
        name: prefs.getString(_kSelectedOrgName) ?? '',
        slug: prefs.getString(_kSelectedOrgSlug) ?? '',
      );
      return;
    }
    final match = orgs.value.firstWhere(
      (o) => o.id == id,
      orElse: () => orgs.value.isNotEmpty
          ? orgs.value.first
          : const DropOrg(id: '', name: '', slug: ''),
    );
    if (match.id.isNotEmpty) {
      await selectOrg(match);
    }
  }
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
