import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:erebrus_drop/features/gateway/drop_auth_client.dart';
import 'package:erebrus_drop/features/gateway/drop_gateway_client.dart';
import 'package:erebrus_drop/features/gateway/gateway_http.dart';
import 'package:erebrus_drop/features/gateway/gateway_session_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late HttpServer server;
  late Uri base;
  late DropAuthClient client;
  late GatewaySessionRepository repo;
  late MemorySessionStore store;
  late Future<void> Function(HttpRequest) handler;
  late List<String> refreshBodies;
  late List<String?> refreshBearers;
  var refreshes = 0;

  Map<String, dynamic> payload(String token) => {
    'access_token': token,
    'token': 'legacy-alias',
    'refresh_token': 'refresh-$token',
    'token_type': 'Bearer',
    'expires_in': 86400,
    'refresh_expires_in': 2592000,
    'session_id': 'session',
    'user_id': 'user',
    'role': 'user',
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = MemorySessionStore();
    refreshes = 0;
    refreshBodies = [];
    refreshBearers = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    client = DropAuthClient(gatewayUrl: base.toString());
    repo = GatewaySessionRepository(client: client, store: store);
    await repo.install(
      DropAuthSession.fromJson(payload('initial')),
      expectedGeneration: repo.beginLogin(),
      method: 'email',
    );
    client.authorization = repo;
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/v2/auth/refresh') {
        refreshes++;
        refreshBearers.add(
          request.headers.value(HttpHeaders.authorizationHeader),
        );
        refreshBodies.add(await utf8.decoder.bind(request).join());
        request.response.write(jsonEncode(payload('replacement')));
        await request.response.close();
      } else {
        await handler(request);
      }
    });
  });
  tearDown(() async => server.close(force: true));

  Future<void> expired(HttpRequest request) async {
    request.response.statusCode = 401;
    request.response.write('{"code":"ACCESS_TOKEN_EXPIRED"}');
    await request.response.close();
  }

  test(
    '401 renewal retries identical POST and idempotency key exactly once',
    () async {
      final requests = <String>[];
      final tokens = <String?>[];
      handler = (request) async {
        requests.add(await utf8.decoder.bind(request).join());
        final token = request.headers.value(HttpHeaders.authorizationHeader);
        tokens.add(token);
        if (token == 'Bearer initial') return expired(request);
        expect(
          jsonDecode(store.value!)['session']['access_token'],
          'replacement',
        );
        request.response.write('{"upload_id":"upload","node_id":"node"}');
        await request.response.close();
      };
      final gateway = DropGatewayClient(
        gatewayUrl: base.toString(),
        authorization: repo,
      );
      await gateway.reserveUpload(
        nodeId: 'node',
        sizeBytes: 5,
        filename: 'file',
        contentType: 'text/plain',
        visibility: 'private',
        idempotencyKey: 'stable-key',
      );
      expect(requests.length, 2);
      expect(requests[1], requests[0]);
      expect(jsonDecode(requests[0])['idempotency_key'], 'stable-key');
      expect(tokens, ['Bearer initial', 'Bearer replacement']);
      expect(refreshes, 1);
      expect(refreshBodies.map(jsonDecode).single, {
        'refresh_token': 'refresh-initial',
      });
      expect(refreshBearers.single, isNull);
    },
  );

  test('delayed parallel 401s reuse already rotated token', () async {
    final ready = Completer<void>();
    var initialRequests = 0;
    final paths = <String, int>{};
    handler = (request) async {
      paths.update(request.uri.path, (value) => value + 1, ifAbsent: () => 1);
      if (request.headers.value(HttpHeaders.authorizationHeader) ==
          'Bearer initial') {
        initialRequests++;
        if (initialRequests == 10) ready.complete();
        await ready.future;
        if (request.uri.path.endsWith('/9')) {
          // Delay until the first request has durably rotated the credential.
          while (repo.current.value!.session.token == 'initial') {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        }
        return expired(request);
      }
      request.response.write('{}');
      await request.response.close();
    };
    await Future.wait(
      List.generate(
        10,
        (i) => GatewayHttp.getJson(
          base.resolve('/protected/$i'),
          authorization: repo,
        ),
      ),
    );
    expect(refreshes, 1);
    expect(paths.values.every((value) => value == 2), isTrue);
  });

  test(
    'retry is bounded even if replacement access gets another expired 401',
    () async {
      var attempts = 0;
      handler = (request) async {
        attempts++;
        await expired(request);
      };
      await expectLater(
        GatewayHttp.getJson(base.resolve('/protected'), authorization: repo),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.errorCode,
            'code',
            'ACCESS_TOKEN_EXPIRED',
          ),
        ),
      );
      expect(attempts, 2);
      expect(refreshes, 1);
      expect(repo.current.value, isNotNull);
    },
  );

  test('unrelated 401, business errors, and 5xx do not delete auth', () async {
    for (final status in [401, 402, 403, 500, 503]) {
      handler = (request) async {
        request.response.statusCode = status;
        request.response.write('{"code":"BUSINESS_ERROR"}');
        await request.response.close();
      };
      await expectLater(
        GatewayHttp.getJson(
          base.resolve('/error/$status'),
          authorization: repo,
        ),
        throwsA(isA<GatewayException>()),
      );
      expect(repo.current.value!.session.token, 'initial');
    }
    expect(refreshes, 0);
  });

  test('upload bytes are reopened and identical on retry', () async {
    final bodies = <List<int>>[];
    handler = (request) async {
      bodies.add(
        await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
      );
      if (bodies.length == 1) return expired(request);
      request.response.write('{}');
      await request.response.close();
    };
    var opened = 0;
    await GatewayHttp.putBytes(
      base.resolve('/upload'),
      () {
        opened++;
        return Stream.value([1, 2, 3, 4]);
      },
      contentLength: 4,
      contentType: 'application/octet-stream',
      authorization: repo,
    );
    expect(opened, 2);
    expect(bodies, [
      [1, 2, 3, 4],
      [1, 2, 3, 4],
    ]);
  });

  test(
    'server Retry-After throttles repeated attempts and is exposed',
    () async {
      var attempts = 0;
      handler = (request) async {
        attempts++;
        request.response.statusCode = 429;
        request.response.headers.set(HttpHeaders.retryAfterHeader, '120');
        request.response.write('{"error":"slow down"}');
        await request.response.close();
      };
      for (var i = 0; i < 2; i++) {
        await expectLater(
          GatewayHttp.getJson(base.resolve('/limited'), authorization: repo),
          throwsA(
            isA<GatewayException>().having(
              (e) => e.retryAt,
              'retryAt',
              isNotNull,
            ),
          ),
        );
      }
      expect(attempts, 1);
      expect(
        GatewayHttp.parseRetryAfter(
          HttpDate.format(DateTime.utc(2026, 10, 20)),
        ),
        DateTime.utc(2026, 10, 20),
      );
      expect(repo.current.value, isNotNull);
    },
  );

  test(
    'refresh/logout bypass interception and logout accepts empty 204',
    () async {
      final logoutBodies = <String>[];
      handler = (request) async {
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        expect(request.uri.path, '/api/v2/auth/logout');
        logoutBodies.add(await utf8.decoder.bind(request).join());
        request.response.statusCode = 204;
        await request.response.close();
      };
      final replacement = await client.refreshSession('credential');
      expect(replacement.token, 'replacement');
      expect(refreshBearers, [null]);
      await client.logoutSession('refresh-replacement');
      expect(jsonDecode(logoutBodies.single), {
        'refresh_token': 'refresh-replacement',
      });
      expect(refreshes, 1);
    },
  );

  for (final provider in ['wallet', 'email', 'google', 'apple']) {
    test('$provider login preserves complete gateway payload', () async {
      handler = (request) async {
        await request.drain<void>();
        request.response.write(jsonEncode(payload('login')));
        await request.response.close();
      };
      final value = switch (provider) {
        'wallet' => await client.authenticate(
          challengeId: 'flow',
          signature: 'sig',
          publicKey: 'wallet',
        ),
        'email' => await client.emailLoginVerify(
          email: 'a@example.com',
          code: '123456',
        ),
        'google' => await client.googleLogin('id-token'),
        _ => await client.appleLogin(
          idToken: 'id-token',
          authorizationCode: 'code',
          nonce: 'nonce',
          state: 'state',
        ),
      };
      expect(value.token, 'login');
      expect(value.refreshToken, 'refresh-login');
      expect(value.sessionId, 'session');
      expect(value.expiresAt, isNotNull);
      expect(value.refreshExpiresAt, isNotNull);
    });
  }
}
