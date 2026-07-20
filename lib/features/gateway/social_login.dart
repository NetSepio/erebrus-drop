import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'auth_config.dart';

/// Whether native Google sign-in can run: a server client id is configured and
/// the platform is supported (Android / iOS).
bool get googleSignInSupported =>
    hasGoogleSignIn && (Platform.isAndroid || Platform.isIOS);

/// Whether Apple sign-in can run: native on iOS (the app targets iOS 13+), or
/// through a configured Services id on non-Apple mobile platforms.
Future<bool> appleSignInSupported() async {
  if (Platform.isIOS) return true;
  if (Platform.isMacOS) {
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
    clientId: Platform.isIOS ? kGoogleIosClientId : null,
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

/// Runs Apple sign-in and returns the values the gateway needs to validate the
/// authorization, or null if the user cancels.
Future<AppleLoginCredential?> appleCredential() async {
  final useWebRelay = !(Platform.isIOS || Platform.isMacOS);
  final nonce = generateNonce();
  final state = 'drop.${generateNonce()}';
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
      nonce: nonce,
      state: state,
    );
    final token = cred.identityToken;
    if (token == null || token.isEmpty) {
      throw const SocialLoginException('Apple did not return an identity token');
    }
    if (cred.state != state) {
      throw const SocialLoginException(
        'Apple sign-in state mismatch — please try again',
      );
    }
    return AppleLoginCredential(
      identityToken: token,
      authorizationCode: cred.authorizationCode,
      nonce: nonce,
      state: state,
    );
  } on SignInWithAppleAuthorizationException catch (e) {
    if (e.code == AuthorizationErrorCode.canceled) return null;
    throw SocialLoginException(
      e.message.isEmpty ? 'Apple sign-in failed' : e.message,
    );
  }
}

class AppleLoginCredential {
  const AppleLoginCredential({
    required this.identityToken,
    required this.authorizationCode,
    required this.nonce,
    required this.state,
  });

  final String identityToken;
  final String authorizationCode;
  final String nonce;
  final String state;
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
