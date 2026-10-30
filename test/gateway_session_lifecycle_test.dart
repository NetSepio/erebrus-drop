import 'dart:async';

import 'package:erebrus_drop/features/gateway/drop_auth_client.dart';
import 'package:erebrus_drop/features/gateway/drop_auth_service.dart';
import 'package:erebrus_drop/features/gateway/gateway_http.dart';
import 'package:erebrus_drop/features/gateway/gateway_models.dart';
import 'package:erebrus_drop/features/gateway/gateway_session_repository.dart';
import 'package:erebrus_drop/features/wallet/solana_wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_session_store.dart';

class _Client extends DropAuthClient {
  var refreshes = 0;
  GatewayException? orgError;
  Future<DropAuthSession>? login;
  final now = DateTime.utc(2026, 10, 19);
  DropAuthSession session(String token, int hours) => DropAuthSession(
    token: token,
    userId: 'user',
    role: 'user',
    walletAddress: 'wallet',
    refreshToken: 'refresh-$token',
    sessionId: 'session',
    expiresAt: now.add(Duration(hours: hours)),
    refreshExpiresAt: now.add(const Duration(days: 30)),
  );
  @override
  Future<DropAuthSession> refreshSession(String refreshToken) async {
    refreshes++;
    return session('replacement', 49);
  }

  @override
  Future<DropAuthMethods> fetchAuthMethods() async => DropAuthMethods.unknown;
  @override
  Future<DropAuthSession> emailLoginVerify({
    required String email,
    required String code,
  }) => login!;
  @override
  Future<void> logoutSession(String refreshToken) async {}
  @override
  Future<List<DropOrg>> fetchOrgs(String bearerToken) async {
    if (orgError != null) throw orgError!;
    return [
      DropOrg.fromJson({
        'id': 'org',
        'name': 'Paid org',
        'slug': 'paid',
        'plan': 'pro',
      }),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late MemorySessionStore store;
  late GatewaySessionRepository repo;
  late DropAuthService service;
  late DateTime now;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = _Client();
    store = MemorySessionStore();
    now = client.now;
    repo = GatewaySessionRepository(
      client: client,
      store: store,
      now: () => now,
    );
    await repo.install(
      client.session('initial', 24),
      expectedGeneration: repo.beginLogin(),
      method: 'email',
    );
    service = DropAuthService(
      solana: SolanaWalletService(),
      authClient: client,
      sessionRepository: repo,
    );
  });

  test(
    'startup restores login and resume after 25 hours renews before org requests',
    () async {
      await service.loadSession();
      expect(service.bearerToken, 'initial');
      expect(client.refreshes, 0);
      now = client.now.add(const Duration(hours: 25));
      await service.revalidateSession(); // Same entry point used by app resume.
      expect(service.isSignedIn, isTrue);
      expect(service.bearerToken, 'replacement');
      expect(service.gatewayClient.bearerToken, 'replacement');
      expect(client.refreshes, 1);
      expect(service.loginRevision.value, 0); // Silent renewal never navigates.
    },
  );

  test(
    'temporary revalidation errors retain org, selection, and plan data',
    () async {
      await service.loadSession();
      final org = service.orgs.value.single;
      final selected = service.selectedOrg.value;
      for (final status in [401, 403, 429, 503]) {
        client.orgError = GatewayException(
          'temporary',
          statusCode: status,
          errorCode: 'BUSINESS_ERROR',
        );
        await service.revalidateSession();
        expect(service.isSignedIn, isTrue);
        expect(service.orgs.value.single, same(org));
        expect(service.selectedOrg.value, same(selected));
      }
    },
  );

  test(
    'logout during email verification rejects the late login response',
    () async {
      await service.loadSession();
      final response = Completer<DropAuthSession>();
      client.login = response.future;
      final verifying = service.verifyEmailLoginCode(
        email: 'test@example.com',
        code: '123456',
      );
      await service.signOut();
      response.complete(client.session('late', 24));
      await verifying;
      expect(service.isSignedIn, isFalse);
      expect(service.bearerToken, isNull);
      expect(service.loginRevision.value, 0);
    },
  );

  test('secure storage read failure is retryable on resume', () async {
    final flaky = _FlakyStore(store.value!);
    final repository = GatewaySessionRepository(
      client: client,
      store: flaky,
      now: () => now,
    );
    final auth = DropAuthService(
      solana: SolanaWalletService(),
      authClient: client,
      sessionRepository: repository,
    );
    await auth.loadSession();
    expect(auth.isSignedIn, isFalse);
    flaky.available = true;
    await auth.revalidateSession();
    expect(auth.isSignedIn, isTrue);
    expect(auth.bearerToken, 'initial');
  });
}

class _FlakyStore implements GatewaySessionStore {
  _FlakyStore(this.value);
  bool available = false;
  String value;
  @override
  Future<String?> read() async {
    if (!available) throw StateError('locked');
    return value;
  }

  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}
