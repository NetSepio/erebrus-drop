import 'dart:io';

import 'package:flutter/services.dart';

import '../features/wallet/solana_wallet_option.dart';

class WalletAuthorization {
  const WalletAuthorization({
    required this.authToken,
    required this.publicKey,
    this.walletUriBase,
    this.accountLabel,
  });

  factory WalletAuthorization.fromMap(Map<dynamic, dynamic> map) {
    return WalletAuthorization(
      authToken: map['authToken'] as String,
      publicKey: (map['publicKey'] as Uint8List?) ?? Uint8List.fromList(
        List<int>.from(map['publicKey'] as List<dynamic>),
      ),
      walletUriBase: map['walletUriBase'] as String?,
      accountLabel: map['accountLabel'] as String?,
    );
  }

  final String authToken;
  final Uint8List publicKey;
  final String? walletUriBase;
  final String? accountLabel;
}

class PlatformWallet {
  PlatformWallet._();

  static const MethodChannel _channel = MethodChannel('com.erebrus.drop/wallet');

  static Future<List<SolanaWalletOption>> listWallets() async {
    if (!Platform.isAndroid) {
      return const [];
    }

    final result = await _channel.invokeMethod<List<dynamic>>('listWallets');
    if (result == null) {
      return const [];
    }

    return result
        .whereType<Map<dynamic, dynamic>>()
        .map(SolanaWalletOption.fromMap)
        .toList(growable: false);
  }

  static Future<WalletAuthorization> authorizeWallet({
    required SolanaWalletOption wallet,
    String? authToken,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'authorizeWallet',
      {
        'packageName': wallet.packageName,
        'authToken': authToken,
      },
    );
    if (result == null) {
      throw PlatformException(
        code: 'WALLET_ERROR',
        message: 'Wallet authorization failed.',
      );
    }
    return WalletAuthorization.fromMap(result);
  }

  static Future<bool> cancelPendingOperation() async {
    if (!Platform.isAndroid) {
      return false;
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'cancelWalletOperation',
    );
    return result?['cancelled'] as bool? ?? false;
  }

  static Future<void> deauthorizeWallet({
    required SolanaWalletOption wallet,
    required String authToken,
  }) async {
    await _channel.invokeMethod<void>(
      'deauthorizeWallet',
      {
        'packageName': wallet.packageName,
        'authToken': authToken,
      },
    );
  }

  static Future<String> signMessage({
    required SolanaWalletOption wallet,
    required String authToken,
    required String message,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'signMessage',
      {
        'packageName': wallet.packageName,
        'authToken': authToken,
        'message': message,
      },
    );
    if (result == null || result['signature'] is! String) {
      throw PlatformException(
        code: 'SIGN_MESSAGE_FAILED',
        message: 'Wallet did not return a signature.',
      );
    }
    return result['signature'] as String;
  }
}