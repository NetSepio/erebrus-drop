import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform_wallet.dart';
import '../wallet/solana_wallet_picker_sheet.dart';
import '../wallet/solana_wallet_service.dart';
import 'drop_auth_client.dart';
import 'drop_gateway_client.dart';
import 'gateway_models.dart';

/// Auth/session and org state for the Erebrus Drop gateway.
class DropAuthService {
  DropAuthService({
    required this.solana,
    DropAuthClient? authClient,
    DropGatewayClient? gatewayClient,
  })  : _authClient = authClient ?? DropAuthClient(),
        _gatewayClient = gatewayClient ?? DropGatewayClient();

  final SolanaWalletService solana;
  final DropAuthClient _authClient;
  final DropGatewayClient _gatewayClient;

  String? _bearerToken;
  String? _walletAddress;
  String? _userId;

  final ValueNotifier<List<DropOrg>> orgs = ValueNotifier<List<DropOrg>>(const []);
  final ValueNotifier<DropOrg?> selectedOrg = ValueNotifier<DropOrg?>(null);

  String? get bearerToken => _bearerToken;
  String? get walletAddress => _walletAddress;
  String? get userId => _userId;

  bool get isSignedIn => _bearerToken != null && _bearerToken!.isNotEmpty;

  DropGatewayClient get gatewayClient => _gatewayClient;

  static const String _kToken = 'erebrus_gateway_token';
  static const String _kWallet = 'erebrus_gateway_wallet';
  static const String _kUserId = 'erebrus_gateway_user_id';
  static const String _kSelectedOrgId = 'erebrus_selected_org_id';
  static const String _kSelectedOrgSlug = 'erebrus_selected_org_slug';
  static const String _kSelectedOrgName = 'erebrus_selected_org_name';

  /// Restores a persisted session (if any) on startup.
  Future<void> loadSession() async {
    await solana.restoreSession();
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_kToken);
    if (token == null || token.isEmpty) return;

    _bearerToken = token;
    _walletAddress = prefs.getString(_kWallet);
    _userId = prefs.getString(_kUserId);
    _gatewayClient.token = token;

    await _loadOrgs();
    await _restoreSelectedOrg(prefs);
  }

  /// Signs in with the Solana wallet using gateway challenge/response.
  Future<void> signInWithWallet(BuildContext context) async {
    if (!Platform.isAndroid) {
      throw Exception('Gateway wallet login is only available on Android.');
    }

    if (!solana.isConnected) {
      final wallet = await showSolanaWalletPickerSheet(
        context: context,
        walletService: solana,
      );
      if (wallet == null) {
        throw Exception('No wallet selected.');
      }
      await solana.connect(wallet: wallet);
    }

    final address = solana.walletAddress;
    if (address == null) {
      throw Exception('Wallet did not return an address.');
    }

    final challenge = await _authClient.fetchAuthChallenge(
      walletAddress: address,
    );
    final message = challenge.message;
    if (message.isEmpty) {
      throw Exception('Gateway returned an empty challenge.');
    }

    final wallet = solana.connectedWallet;
    final authToken = solana.authToken;
    if (wallet == null || authToken == null || authToken.isEmpty) {
      throw Exception('Wallet is not authorized.');
    }

    final signature = await PlatformWallet.signMessage(
      wallet: wallet,
      authToken: authToken,
      message: message,
    );

    final session = await _authClient.authenticate(
      challengeId: challenge.challengeId,
      signature: signature,
      publicKey: address,
    );

    await _persistSession(session);
    await _loadOrgs();
  }

  /// Creates a new organization and refreshes the org list.
  Future<DropOrg> createOrg({required String name, required String slug}) async {
    if (!isSignedIn) throw Exception('Not signed in');
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

  /// Selects the active organization used for Drop discovery and uploads.
  Future<void> selectOrg(DropOrg org) async {
    selectedOrg.value = org;
    _gatewayClient.token = _bearerToken;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSelectedOrgId, org.id);
    await prefs.setString(_kSelectedOrgSlug, org.slug);
    await prefs.setString(_kSelectedOrgName, org.name);
  }

  /// Clears the signed-in session.
  Future<void> signOut() async {
    _bearerToken = null;
    _walletAddress = null;
    _userId = null;
    orgs.value = const [];
    selectedOrg.value = null;
    _gatewayClient.token = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kWallet);
    await prefs.remove(_kUserId);
    await prefs.remove(_kSelectedOrgId);
    await prefs.remove(_kSelectedOrgSlug);
    await prefs.remove(_kSelectedOrgName);
  }

  Future<void> _persistSession(DropAuthSession session) async {
    _bearerToken = session.token;
    _walletAddress = session.walletAddress;
    _userId = session.userId;
    _gatewayClient.token = session.token;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, session.token);
    await prefs.setString(_kWallet, session.walletAddress);
    await prefs.setString(_kUserId, session.userId);
  }

  Future<void> _loadOrgs() async {
    if (!isSignedIn) {
      orgs.value = const [];
      return;
    }
    try {
      final list = await _authClient.fetchOrgs(_bearerToken!);
      orgs.value = list;
      if (selectedOrg.value == null && list.isNotEmpty) {
        await selectOrg(list.first);
      }
    } catch (e) {
      orgs.value = const [];
      rethrow;
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
