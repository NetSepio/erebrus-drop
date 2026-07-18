import 'dart:math';

import 'auth_config.dart';

/// Parsed `erebrusdrop://auth` callback from the Erebrus webapp.
class DesktopAuthCallback {
  const DesktopAuthCallback({
    required this.token,
    required this.userId,
    required this.walletAddress,
    required this.role,
    required this.state,
  });

  final String token;
  final String userId;
  final String walletAddress;
  final String role;
  final String state;

  bool get isValid =>
      token.isNotEmpty && userId.isNotEmpty && walletAddress.isNotEmpty && state.isNotEmpty;
}

/// Browser-based sign-in for desktop (and mobile fallback).
///
/// Opens `{EREBRUS_WEB_ORIGIN}/auth` with a redirect back to
/// [kErebrusAuthCallback]. The webapp completes wallet/social/email auth and
/// redirects with a PASETO bearer token in the query string.
class DesktopWebAuth {
  DesktopWebAuth._();

  static String? _pendingState;

  static String? get pendingState => _pendingState;

  static bool isAuthCallback(String url) {
    if (url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.scheme == kErebrusAuthCallbackScheme &&
        (uri.host == kErebrusAuthCallbackHost || uri.path.startsWith('/auth'));
  }

  static String buildLoginUrl() {
    final state = _newState();
    _pendingState = state;
    return Uri.parse('$kErebrusWebOrigin$kErebrusDesktopAuthPath').replace(
      queryParameters: {
        'redirect_uri': kErebrusAuthCallback,
        'state': state,
        'platform': isDesktopPlatform ? 'desktop' : 'mobile',
        'client_id': kErebrusBundleId,
      },
    ).toString();
  }

  /// Parses pasted text: full `erebrusdrop://auth?…` URL, query string, or raw PASETO.
  static DesktopAuthCallback? parseManualAuthInput(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.contains('://') ||
        trimmed.contains('token=') ||
        trimmed.contains('paseto=')) {
      var url = trimmed;
      if (!trimmed.contains('://')) {
        url = '$kErebrusAuthCallback${trimmed.startsWith('?') ? trimmed : '?$trimmed'}';
      }
      final parsed = parseCallback(url);
      if (parsed != null && parsed.token.isNotEmpty) return parsed;
    }

    if (trimmed.startsWith('v4.')) {
      return DesktopAuthCallback(
        token: trimmed,
        userId: '',
        walletAddress: '',
        role: 'user',
        state: '',
      );
    }

    return null;
  }

  static DesktopAuthCallback? parseCallback(String url) {
    if (!isAuthCallback(url)) return null;
    final uri = Uri.parse(url);
    final params = {...uri.queryParameters, ..._fragmentParams(uri)};

    final error = params['error'] ?? params['error_description'];
    if (error != null && error.isNotEmpty) {
      throw DesktopWebAuthException(error);
    }

    final token = params['token'] ?? params['paseto'] ?? '';
    final userId = params['user_id'] ?? params['userId'] ?? '';
    final wallet = params['wallet'] ?? params['wallet_address'] ?? params['public_key'] ?? '';
    final role = params['role'] ?? 'user';
    final state = params['state'] ?? '';

    if (token.isEmpty) return null;

    return DesktopAuthCallback(
      token: token,
      userId: userId,
      walletAddress: wallet,
      role: role,
      state: state,
    );
  }

  static void clearPendingState() => _pendingState = null;

  static void validateState(String state) {
    final expected = _pendingState;
    if (expected == null || expected.isEmpty || state != expected) {
      throw const DesktopWebAuthException('Sign-in state mismatch — try again');
    }
  }

  static Map<String, String> _fragmentParams(Uri uri) {
    if (uri.fragment.isEmpty) return const {};
    return Uri.splitQueryString(uri.fragment);
  }

  static String _newState() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

class DesktopWebAuthException implements Exception {
  const DesktopWebAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}
