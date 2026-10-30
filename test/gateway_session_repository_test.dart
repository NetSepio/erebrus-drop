import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:erebrus_drop/features/gateway/drop_auth_client.dart';
import 'package:erebrus_drop/features/gateway/gateway_http.dart';
import 'package:erebrus_drop/features/gateway/gateway_session_broker.dart';
import 'package:erebrus_drop/features/gateway/gateway_session_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_session_store.dart';

final instant = DateTime.utc(2026, 10, 19);

/// [from] defaults to the fake [instant]; pass the real time for code that
/// reads the wall clock.
DropAuthSession session(
  String token, {
  Duration access = const Duration(hours: 24),
  String user = 'user',
  bool modern = true,
  DateTime? from,
}) => DropAuthSession(
  token: token,
  userId: user,
  role: 'user',
  walletAddress: 'wallet-$user',
  expiresAt: modern ? (from ?? instant).add(access) : null,
  refreshToken: modern ? 'refresh-$token' : null,
  refreshExpiresAt: modern
      ? (from ?? instant).add(const Duration(days: 30))
      : null,
  sessionId: modern ? 'session-$user' : null,
);

class SessionClient extends DropAuthClient {
  SessionClient({super.gatewayUrl});
  final refreshed = <String>[];
  final upgraded = <String>[];
  final revoked = <String>[];
  Future<DropAuthSession> Function()? refresh;
  Future<DropAuthSession> Function()? upgrade;
  bool offlineLogout = false;
  @override
  Future<DropAuthSession> refreshSession(String token) async {
    refreshed.add(token);
    return refresh == null ? session('replacement') : await refresh!();
  }

  @override
  Future<DropAuthSession> upgradeSession(String token) async {
    upgraded.add(token);
    return upgrade == null ? session('upgraded') : await upgrade!();
  }

  @override
  Future<void> logoutSession(String token) async {
    revoked.add(token);
    if (offlineLogout) throw const SocketException('offline');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemorySessionStore store;
  late SessionClient client;
  late GatewaySessionRepository repo;
  late DateTime clock;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clock = instant;
    store = MemorySessionStore();
    client = SessionClient();
    repo = GatewaySessionRepository(
      client: client,
      store: store,
      now: () => clock,
    );
  });
  Future<void> install([DropAuthSession? value]) async {
    await repo.install(
      value ?? session('initial'),
      expectedGeneration: repo.beginLogin(),
      method: 'email',
    );
  }

  test(
    'opaque access token, alias preference and configurable expiry metadata',
    () {
      final value = DropAuthSession.fromJson({
        'access_token': 'v4.public.opaque',
        'token': 'old-alias',
        'expires_in': 321,
        'refresh_expires_in': 9876,
      }, now: instant);
      expect(value.token, 'v4.public.opaque');
      expect(value.expiresAt, instant.add(const Duration(seconds: 321)));
      expect(
        value.refreshExpiresAt,
        instant.add(const Duration(seconds: 9876)),
      );
      final absolute = DropAuthSession.fromJson({
        'token': 'legacy-alias',
        'expires_at': instant.millisecondsSinceEpoch ~/ 1000,
        'expires_in': 999,
      }, now: instant);
      expect(absolute.expiresAt, instant);
      expect(absolute.token, 'legacy-alias');
    },
  );

  test(
    'return after 25 hours, restart and resume use persisted replacement',
    () async {
      await install();
      clock = instant.add(const Duration(hours: 25));
      final restarted = GatewaySessionRepository(
        client: client,
        store: store,
        now: () => clock,
      );
      client.refresh = () async =>
          session('day-two', access: const Duration(hours: 49));
      expect((await restarted.authorize()).token, 'day-two');
      expect(client.refreshed, ['refresh-initial']);
      final again = GatewaySessionRepository(
        client: client,
        store: store,
        now: () => clock,
      );
      expect((await again.authorize()).token, 'day-two');
      expect(client.refreshed.length, 1);
      expect(
        jsonDecode(store.value!)['session']['refresh_token'],
        'refresh-day-two',
      );
    },
  );

  test(
    '60 second margin and concurrent callers wait for durable replacement',
    () async {
      await install(session('initial', access: const Duration(seconds: 60)));
      final response = Completer<DropAuthSession>();
      final commit = Completer<void>();
      final sent = Completer<void>();
      client.refresh = () {
        sent.complete();
        return response.future;
      };
      store.beforeWrite = (text) async {
        if (jsonDecode(text)['session']?['access_token'] == 'replacement') {
          await commit.future;
        }
      };
      var completed = 0;
      final requests = List.generate(
        25,
        (_) => repo.authorize().then((value) {
          completed++;
          return value;
        }),
      );
      await sent.future;
      response.complete(session('replacement'));
      await Future<void>.delayed(Duration.zero);
      expect(completed, 0);
      commit.complete();
      final tokens = await Future.wait(requests);
      expect(tokens.every((value) => value.token == 'replacement'), isTrue);
      expect(client.refreshed, ['refresh-initial']);
      expect(repo.current.value!.session.refreshToken, 'refresh-replacement');
    },
  );

  test(
    'legacy preferences migrate securely and upgrade exactly once',
    () async {
      SharedPreferences.setMockInitialValues({
        'erebrus_gateway_token': 'legacy',
        'erebrus_gateway_user_id': 'user',
        'erebrus_gateway_mwa_token': 'mwa-secret',
      });
      await repo.restore();
      expect(
        (await SharedPreferences.getInstance()).getString(
          'erebrus_gateway_token',
        ),
        isNull,
      );
      expect(repo.current.value!.mwaToken, 'mwa-secret');
      await Future.wait(List.generate(8, (_) => repo.authorize()));
      expect(client.upgraded, ['legacy']);
      await repo.authorize();
      expect(client.upgraded.length, 1);
    },
  );

  for (final failure in [
    GatewayException(
      'expired legacy',
      statusCode: 401,
      errorCode: 'ACCESS_TOKEN_EXPIRED',
    ),
    GatewayException(
      'modern credential missing',
      statusCode: 409,
      errorCode: 'SESSION_ALREADY_REFRESHABLE',
    ),
  ]) {
    test(
      'legacy ${failure.errorCode} requires one new login without deleting data',
      () async {
        await install(session('legacy', modern: false));
        client.upgrade = () async => throw failure;
        await expectLater(repo.authorize(), throwsA(isA<GatewayException>()));
        await expectLater(repo.authorize(), throwsA(isA<GatewayException>()));
        expect(client.upgraded.length, 1);
        expect(repo.current.value!.session.userId, 'user');
        expect(repo.current.value!.loginRequired, isTrue);
      },
    );
  }

  for (final code in GatewaySessionRepository.terminalCodes) {
    test('$code terminates and securely tombstones the session', () async {
      await install(session('initial', access: Duration.zero));
      client.refresh = () async =>
          throw GatewayException('revoked', statusCode: 401, errorCode: code);
      await expectLater(repo.authorize(), throwsA(isA<GatewayException>()));
      expect(repo.current.value, isNull);
      expect(jsonDecode(store.value!)['session'], isNull);
    });
  }

  for (final failure in [
    GatewayException('offline', outcomeUncertain: true),
    GatewayException('timeout', outcomeUncertain: true),
    GatewayException('server failure', statusCode: 503, outcomeUncertain: true),
  ]) {
    test(
      '${failure.message} retains data and prevents replay including after restart',
      () async {
        await install(session('initial', access: Duration.zero));
        client.refresh = () async => throw failure;
        await expectLater(repo.authorize(), throwsA(isA<GatewayException>()));
        expect(repo.current.value!.session.userId, 'user');
        expect(repo.current.value!.rotationPending, isTrue);
        final restarted = GatewaySessionRepository(
          client: client,
          store: store,
          now: () => clock,
        );
        await expectLater(
          restarted.authorize(),
          throwsA(isA<GatewayException>()),
        );
        expect(client.refreshed.length, 1);
      },
    );
  }

  test('429 honors persisted Retry-After without clearing user data', () async {
    await install(session('initial', access: Duration.zero));
    final retryAt = instant.add(const Duration(minutes: 5));
    client.refresh = () async => throw GatewayException(
      'rate limited',
      statusCode: 429,
      retryAt: retryAt,
    );
    await expectLater(repo.authorize(), throwsA(isA<GatewayException>()));
    final restarted = GatewaySessionRepository(
      client: client,
      store: store,
      now: () => clock,
    );
    await expectLater(restarted.authorize(), throwsA(isA<GatewayException>()));
    expect(client.refreshed.length, 1);
    clock = retryAt;
    client.refresh = null;
    expect((await restarted.authorize()).token, 'replacement');
    expect(client.refreshed.length, 2);
  });

  test('business errors and unrelated bearer 401s retain auth', () async {
    await install();
    final credential = await repo.authorize();
    await repo.handleFailure(credential, 'PAYMENT_REQUIRED');
    await repo.handleFailure(credential, 'ORG_FORBIDDEN');
    await repo.handleFailure(credential, null);
    expect(repo.current.value!.session.token, 'initial');
    expect(client.refreshed, isEmpty);
  });

  test(
    'refresh business rejection retains data and can be retried explicitly',
    () async {
      await install(session('initial', access: Duration.zero));
      client.refresh = () async => throw GatewayException(
        'business rejection',
        statusCode: 403,
        errorCode: 'POLICY_REJECTED',
      );
      await expectLater(repo.authorize(), throwsA(isA<GatewayException>()));
      expect(repo.current.value!.rotationPending, isFalse);
      expect(repo.current.value!.session.userId, 'user');
    },
  );

  test('malformed success never replays consumed token', () async {
    await install(session('initial', access: Duration.zero));
    client.refresh = () async => session('broken', modern: false);
    await expectLater(repo.authorize(), throwsA(isA<GatewayException>()));
    await expectLater(repo.authorize(), throwsA(isA<GatewayException>()));
    expect(client.refreshed.length, 1);
  });

  test(
    'secure replacement commit failure retains pending journal across restart',
    () async {
      await install(session('initial', access: Duration.zero));
      store.beforeWrite = (text) async {
        if (jsonDecode(text)['session']?['access_token'] == 'replacement') {
          throw StateError('secure storage temporarily unavailable');
        }
      };
      await expectLater(repo.authorize(), throwsA(isA<StateError>()));
      final restarted = GatewaySessionRepository(
        client: client,
        store: store,
        now: () => clock,
      );
      await expectLater(
        restarted.authorize(),
        throwsA(isA<GatewayException>()),
      );
      expect(client.refreshed.length, 1);
      expect(repo.current.value!.rotationPending, isTrue);
    },
  );

  test(
    'confirmed connection failure before sending allows later recovery',
    () async {
      await install(session('initial', access: Duration.zero));
      client.refresh = () async => throw GatewayException('connection refused');
      await expectLater(repo.authorize(), throwsA(isA<GatewayException>()));
      expect(repo.current.value!.rotationPending, isFalse);
      client.refresh = null;
      expect((await repo.authorize()).token, 'replacement');
    },
  );

  test(
    'logout tombstone survives restart while refresh response is outstanding',
    () async {
      await install(session('initial', access: Duration.zero));
      final response = Completer<DropAuthSession>();
      final sent = Completer<void>();
      final localCleared = Completer<void>();
      client.refresh = () {
        sent.complete();
        return response.future;
      };
      final pending = repo.authorize();
      final rejected = expectLater(pending, throwsA(isA<GatewayException>()));
      await sent.future;
      store.beforeWrite = (text) async {
        if (jsonDecode(text)['session'] == null && !localCleared.isCompleted) {
          localCleared.complete();
        }
      };
      final logout = repo.logout();
      await localCleared.future;
      await Future<void>.delayed(Duration.zero);
      final restarted = GatewaySessionRepository(
        client: client,
        store: store,
        now: () => clock,
      );
      await restarted.restore();
      expect(restarted.current.value, isNull);
      response.complete(session('replacement'));
      await logout;
      await rejected;
      expect(client.revoked, ['refresh-replacement']);
      expect(jsonDecode(store.value!)['session'], isNull);
    },
  );

  test(
    'logout during refresh revokes replacement and rejects waiting requests',
    () async {
      await install(session('initial', access: Duration.zero));
      final response = Completer<DropAuthSession>();
      final sent = Completer<void>();
      client.refresh = () {
        sent.complete();
        return response.future;
      };
      final pending = repo.authorize();
      final rejected = expectLater(pending, throwsA(isA<GatewayException>()));
      await sent.future;
      final loggedOut = repo.logout();
      expect(repo.current.value, isNull);
      response.complete(session('replacement'));
      expect(await loggedOut, isTrue);
      await rejected;
      expect(client.revoked, ['refresh-replacement']);
      expect(repo.current.value, isNull);
      expect(jsonDecode(store.value!)['session'], isNull);
    },
  );

  test(
    'offline logout clears local auth and reports unconfirmed revocation',
    () async {
      await install();
      client.offlineLogout = true;
      expect(await repo.logout(), isFalse);
      expect(repo.current.value, isNull);
      expect(repo.message.value, contains('unconfirmed'));
      expect(jsonDecode(store.value!)['session'], isNull);
    },
  );

  test(
    'account switch during refresh revokes old replacement and guards generations',
    () async {
      await install(session('initial', access: Duration.zero));
      final response = Completer<DropAuthSession>();
      final sent = Completer<void>();
      client.refresh = () {
        sent.complete();
        return response.future;
      };
      final pending = repo.authorize();
      final rejected = expectLater(pending, throwsA(isA<GatewayException>()));
      await sent.future;
      final generation = repo.beginLogin();
      final switched = repo.install(
        session('second', user: 'second'),
        expectedGeneration: generation,
        method: 'google',
      );
      response.complete(session('replacement'));
      await switched;
      await rejected;
      expect(client.revoked, ['refresh-replacement']);
      expect(repo.current.value!.session.userId, 'second');
      expect((await repo.authorize()).token, 'second');
    },
  );

  test(
    'late login response after logout cannot resurrect an account',
    () async {
      final generation = repo.beginLogin();
      await repo.logout();
      await expectLater(
        repo.install(
          session('late'),
          expectedGeneration: generation,
          method: 'email',
        ),
        throwsA(isA<GatewayException>()),
      );
      expect(repo.current.value, isNull);
    },
  );

  test(
    'old request failure or success cannot affect switched account',
    () async {
      await install();
      final old = await repo.authorize();
      await install(session('second', user: 'second'));
      await repo.handleFailure(old, 'SESSION_REVOKED');
      await expectLater(
        repo.authorize(rejected: old),
        throwsA(isA<GatewayException>()),
      );
      await expectLater(repo.validate(old), throwsA(isA<GatewayException>()));
      expect(repo.current.value!.session.userId, 'second');
    },
  );

  test('cross-isolate broker shares the owner refresh operation', () async {
    // Native secure storage is mocked only at its platform channel boundary.
    final secure = <String, String>{};
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = Map<String, dynamic>.from(call.arguments);
          final key = args['key'] as String;
          if (call.method == 'read') return secure[key];
          if (call.method == 'write') secure[key] = args['value'] as String;
          return null;
        });
    final ownerClient = SessionClient(
      gatewayUrl: 'https://isolate-test.example',
    );
    // The broker's repository uses the real clock, so the replacement must
    // still be valid now; otherwise the worker's request refreshes again.
    ownerClient.refresh = () async =>
        session('replacement', from: DateTime.now().toUtc());
    final owner = GatewaySessionBroker.owner(ownerClient);
    await owner.install(
      session('initial', access: Duration.zero),
      expectedGeneration: owner.beginLogin(),
      method: 'email',
    );
    final done = ReceivePort();
    final worker = await Isolate.spawn(_workerAuthorize, done.sendPort);
    final local = owner.authorize();
    final workerToken = await done.first.timeout(const Duration(seconds: 10));
    expect((await local).token, 'replacement');
    expect(workerToken, 'replacement');
    expect(ownerClient.refreshed.length, 1);
    worker.kill();
    done.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}

void _workerAuthorize(SendPort result) async {
  try {
    final broker = GatewaySessionBroker(
      gatewayUrl: 'https://isolate-test.example',
    );
    result.send((await broker.authorize()).token);
  } catch (_) {
    result.send('worker failed');
  }
}
