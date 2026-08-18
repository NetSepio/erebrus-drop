import 'dart:io';

import 'package:erebrus_drop/features/gateway/drop_auth_client.dart';
import 'package:erebrus_drop/features/gateway/drop_auth_service.dart';
import 'package:erebrus_drop/features/gateway/gateway_http.dart';
import 'package:erebrus_drop/features/gateway/gateway_models.dart';
import 'package:erebrus_drop/features/wallet/solana_wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GatewayException', () {
    test('preserves HTTP status and API error code', () {
      final exception = GatewayHttp.responseException(
        HttpStatus.forbidden,
        '{"error":"Not allowed","code":"ORG_FORBIDDEN"}',
      );

      expect(exception.message, 'Not allowed');
      expect(exception.statusCode, 403);
      expect(exception.errorCode, 'ORG_FORBIDDEN');
    });
  });

  group('DropAuthService session validation', () {
    const tokenKey = 'erebrus_gateway_token';

    setUp(() {
      SharedPreferences.setMockInitialValues({tokenKey: 'stored-token'});
    });

    test('expires a restored session on bearer 401', () async {
      final authClient = _ValidationAuthClient(statusCode: 401);
      final service = DropAuthService(
        solana: SolanaWalletService(),
        authClient: authClient,
      );

      await service.loadSession();

      expect(service.isSignedIn, isFalse);
      expect(service.bearerToken, isNull);
      expect(
        service.error.value,
        'Your session expired. Please sign in again.',
      );
      expect(
        (await SharedPreferences.getInstance()).containsKey(tokenKey),
        isFalse,
      );
    });

    test('keeps a restored session on 403', () async {
      final service = DropAuthService(
        solana: SolanaWalletService(),
        authClient: _ValidationAuthClient(statusCode: 403),
      );

      await service.loadSession();

      expect(service.isSignedIn, isTrue);
      expect(service.bearerToken, 'stored-token');
      expect(service.error.value, 'Forbidden');
      expect(
        (await SharedPreferences.getInstance()).getString(tokenKey),
        'stored-token',
      );
    });

    test('keeps a restored session on a recoverable network failure', () async {
      final service = DropAuthService(
        solana: SolanaWalletService(),
        authClient: _ValidationAuthClient(networkFailure: true),
      );

      await service.loadSession();

      expect(service.isSignedIn, isTrue);
      expect(service.bearerToken, 'stored-token');
      expect(service.error.value, contains('Cannot reach Erebrus'));
      expect(
        (await SharedPreferences.getInstance()).getString(tokenKey),
        'stored-token',
      );
    });

    test('keeps a restored session on a server failure', () async {
      final service = DropAuthService(
        solana: SolanaWalletService(),
        authClient: _ValidationAuthClient(statusCode: 503),
      );

      await service.loadSession();

      expect(service.isSignedIn, isTrue);
      expect(service.bearerToken, 'stored-token');
      expect(service.error.value, 'Service unavailable');
      expect(
        (await SharedPreferences.getInstance()).getString(tokenKey),
        'stored-token',
      );
    });
  });
}

class _ValidationAuthClient extends DropAuthClient {
  _ValidationAuthClient({this.statusCode, this.networkFailure = false});

  final int? statusCode;
  final bool networkFailure;

  @override
  Future<DropAuthMethods> fetchAuthMethods() async => DropAuthMethods.unknown;

  @override
  Future<List<DropOrg>> fetchOrgs(String bearerToken) async {
    if (networkFailure) {
      throw GatewayException('Cannot reach Erebrus: offline');
    }
    if (statusCode == HttpStatus.unauthorized) {
      await Future.wait([
        onUnauthorized!(bearerToken),
        onUnauthorized!(bearerToken),
      ]);
    }
    throw GatewayException(
      switch (statusCode) {
        HttpStatus.forbidden => 'Forbidden',
        HttpStatus.serviceUnavailable => 'Service unavailable',
        _ => 'Unauthorized',
      },
      statusCode: statusCode,
      errorCode: statusCode == HttpStatus.unauthorized
          ? 'TOKEN_EXPIRED'
          : 'ORG_FORBIDDEN',
    );
  }
}
