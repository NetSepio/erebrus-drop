import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/solana.dart';

import '../../core/platform_wallet.dart';
import 'solana_wallet_option.dart';

const String _prefsAuthTokenKey = 'solana_wallet_auth_token';
const String _prefsPublicKeyKey = 'solana_wallet_public_key_b64';
const String _prefsWalletEndpointKey = 'solana_wallet_endpoint_prefix';
const String _prefsWalletPackageKey = 'solana_wallet_package_name';
const String _prefsWalletNameKey = 'solana_wallet_name';

const String _prefsWalletIsSeedVaultKey = 'solana_wallet_is_seed_vault';

/// Optional Solana wallet session for display on Solana Mobile devices.
class SolanaWalletService {
  SolanaWalletService({SharedPreferences? preferences})
    : _preferencesFuture = preferences != null
          ? Future.value(preferences)
          : SharedPreferences.getInstance();

  final Future<SharedPreferences> _preferencesFuture;

  String? authToken;
  Uint8List? publicKey;
  SolanaWalletOption? _connectedWallet;

  bool get isConnected => authToken != null && publicKey != null;

  String? get walletAddress {
    final key = publicKey;
    if (key == null) {
      return null;
    }
    return Ed25519HDPublicKey(key).toBase58();
  }

  Future<List<SolanaWalletOption>> listWallets() => PlatformWallet.listWallets();

  Future<void> restoreSession() async {
    final prefs = await _preferencesFuture;
    final token = prefs.getString(_prefsAuthTokenKey);
    final encodedKey = prefs.getString(_prefsPublicKeyKey);
    final packageName = prefs.getString(_prefsWalletPackageKey);
    if (token == null || encodedKey == null || packageName == null) {
      return;
    }

    try {
      final bytes = base64Decode(encodedKey);
      authToken = token;
      publicKey = Uint8List.fromList(bytes);
      _connectedWallet = SolanaWalletOption(
        id: packageName,
        name: prefs.getString(_prefsWalletNameKey) ?? packageName,
        packageName: packageName,
        isSeedVault: prefs.getBool(_prefsWalletIsSeedVaultKey) ?? false,
      );
    } on FormatException {
      await clearSession(prefs: prefs);
    }
  }

  Future<void> connect({required SolanaWalletOption wallet}) async {
    if (!Platform.isAndroid) {
      throw const SolanaWalletException('Wallet connect is only available on Android.');
    }

    try {
      final reuseAuthToken = _connectedWallet?.packageName == wallet.packageName
          ? authToken
          : null;
      final authorization = await PlatformWallet.authorizeWallet(
        wallet: wallet,
        authToken: reuseAuthToken,
      );
      authToken = authorization.authToken;
      publicKey = authorization.publicKey;
      _connectedWallet = wallet;
      await _persistSession(
        walletUriBase: authorization.walletUriBase,
      );
    } on PlatformException catch (error) {
      if (error.code == 'WALLET_CANCELLED') {
        throw SolanaWalletException(
          error.message ?? 'Wallet connection cancelled.',
          cancelled: true,
        );
      }
      throw SolanaWalletException(
        error.message ?? 'Could not connect wallet. Try again.',
      );
    }
  }

  Future<void> cancelConnect() => PlatformWallet.cancelPendingOperation();

  Future<void> disconnect() async {
    final token = authToken;
    final wallet = _connectedWallet;
    if (token != null && wallet != null) {
      try {
        await PlatformWallet.deauthorizeWallet(
          wallet: wallet,
          authToken: token,
        );
      } catch (_) {
        // Best-effort remote disconnect.
      }
    }
    await clearSession();
  }

  Future<void> clearSession({SharedPreferences? prefs}) async {
    authToken = null;
    publicKey = null;
    _connectedWallet = null;
    final storage = prefs ?? await _preferencesFuture;
    await storage.remove(_prefsAuthTokenKey);
    await storage.remove(_prefsPublicKeyKey);
    await storage.remove(_prefsWalletEndpointKey);
    await storage.remove(_prefsWalletPackageKey);
    await storage.remove(_prefsWalletNameKey);

    await storage.remove(_prefsWalletIsSeedVaultKey);
  }

  Future<void> _persistSession({String? walletUriBase}) async {
    final token = authToken;
    final key = publicKey;
    final wallet = _connectedWallet;
    if (token == null || key == null || wallet == null) {
      return;
    }

    final prefs = await _preferencesFuture;
    await prefs.setString(_prefsAuthTokenKey, token);
    await prefs.setString(_prefsPublicKeyKey, base64Encode(key));
    await prefs.setString(_prefsWalletPackageKey, wallet.packageName);
    await prefs.setString(_prefsWalletNameKey, wallet.name);
    await prefs.setBool(_prefsWalletIsSeedVaultKey, wallet.isSeedVault);
    final endpoint = walletUriBase;
    if (endpoint == null || endpoint.isEmpty) {
      await prefs.remove(_prefsWalletEndpointKey);
    } else {
      await prefs.setString(_prefsWalletEndpointKey, endpoint);
    }
  }
}

class SolanaWalletException implements Exception {
  const SolanaWalletException(this.message, {this.cancelled = false});

  final String message;
  final bool cancelled;

  @override
  String toString() => message;
}