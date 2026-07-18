import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'auth_config.dart';

/// Whether native Google sign-in can run: a server client id is configured and
/// the platform is supported (Android / iOS).
bool get googleSignInSupported =>
    hasGoogleSignIn && (Platform.isAndroid || Platform.isIOS);

/// Whether Apple sign-in can run: native on iOS/macOS, or a configured Services
/// id elsewhere.
Future<bool> appleSignInSupported() async {
  if (Platform.isIOS || Platform.isMacOS) {
    try {
      return await SignInWithApple.isAvailable();
    } catch (_) {
      return false;
    }
  }
  return kAppleServiceId.isNotEmpty;
}

/// Runs the Google sign-in sheet and returns an id_token, or null if cancelled.
Future<String?> googleIdToken() async {
  final google = GoogleSignIn(
    serverClientId: hasGoogleSignIn ? kGoogleServerClientId : null,
    scopes: const ['email'],
  );
  final account = await google.signIn();
  if (account == null) return null;
  final auth = await account.authentication;
  final token = auth.idToken;
  if (token == null || token.isEmpty) {
    throw const SocialLoginException('Google did not return an identity token');
  }
  return token;
}

/// Runs the Apple sign-in flow and returns the identity token, or null if
/// cancelled.
Future<String?> appleIdToken() async {
  final useWebRelay = !(Platform.isIOS || Platform.isMacOS);
  try {
    final cred = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      webAuthenticationOptions: useWebRelay && kAppleServiceId.isNotEmpty
          ? WebAuthenticationOptions(
              clientId: kAppleServiceId,
              redirectUri: Uri.parse(kAppleRedirectUri),
            )
          : null,
    );
    final token = cred.identityToken;
    if (token == null || token.isEmpty) {
      throw const SocialLoginException('Apple did not return an identity token');
    }
    return token;
  } on SignInWithAppleAuthorizationException catch (e) {
    if (e.code == AuthorizationErrorCode.canceled) return null;
    throw SocialLoginException(
      e.message.isEmpty ? 'Apple sign-in failed' : e.message,
    );
  }
}

/// Best-effort sign-out from the Google session so the chooser shows next time.
Future<void> googleSignOut() async {
  try {
    await GoogleSignIn().signOut();
  } catch (e) {
    debugPrint('[social] google signOut: $e');
  }
}

class SocialLoginException implements Exception {
  const SocialLoginException(this.message);
  final String message;

  @override
  String toString() => message;
}
