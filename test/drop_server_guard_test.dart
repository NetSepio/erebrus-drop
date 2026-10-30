import 'dart:convert';
import 'dart:io';

import 'package:erebrus_drop/core/drop_models.dart';
import 'package:erebrus_drop/core/platform_network.dart';
import 'package:erebrus_drop/core/storage_guard.dart';
import 'package:erebrus_drop/core/user_error.dart';
import 'package:erebrus_drop/server/drop_server.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StorageGuard', () {
    test('counts the staged copy of the largest file plus a reserve', () {
      expect(
        StorageGuard.requiredBytes([100, 300, 200]),
        600 + 300 + StorageGuard.reserveBytes,
      );
      expect(
        StorageGuard.requiredBytes([100, 300], staged: false),
        400 + StorageGuard.reserveBytes,
      );
    });

    test('reports a shortfall only when space is known and too small', () {
      expect(
        StorageGuard.shortfallMessage(requiredBytes: 10, availableBytes: null),
        isNull,
      );
      expect(
        StorageGuard.shortfallMessage(requiredBytes: 10, availableBytes: 10),
        isNull,
      );
      final message = StorageGuard.shortfallMessage(
        requiredBytes: StorageGuard.reserveBytes + 5 * 1024 * 1024 * 1024,
        availableBytes: StorageGuard.reserveBytes + 1024 * 1024 * 1024,
      );
      expect(message, contains('only 1.0 GB free'));
      expect(message, contains('needs 5.0 GB'));
    });

    test('flags files over the room limit by name', () {
      final message = StorageGuard.oversizeMessage(
        files: [(name: 'small.txt', size: 10), (name: 'movie.mkv', size: 50)],
        maxUploadBytes: 20,
      );
      expect(message, startsWith('movie.mkv'));
    });

    test('recognizes out-of-space errors from the OS and native code', () {
      expect(
        StorageGuard.isOutOfSpace(
          const FileSystemException(
            'write failed',
            '/x',
            OSError('No space left on device', 28),
          ),
        ),
        isTrue,
      );
      expect(
        StorageGuard.isOutOfSpace(
          PlatformException(code: 'X', message: 'ENOSPC (No space left)'),
        ),
        isTrue,
      );
      expect(
        StorageGuard.isOutOfSpace(
          const FileSystemException('File was not found.'),
        ),
        isFalse,
      );
    });
  });

  group('userErrorText', () {
    test('strips Dart prefixes and hides raw JSON', () {
      expect(userErrorText(StateError('Room closed')), 'Room closed');
      expect(
        userErrorText(StateError('{"error":"x"}')),
        'Something went wrong. Try again.',
      );
      expect(
        userErrorText(PlatformException(code: 'E', message: 'Denied')),
        'Denied',
      );
    });
  });

  group('DropServer upload guard', () {
    late Directory root;
    late DropServer server;
    late String baseUrl;
    late String token;

    setUp(() async {
      PlatformNetwork.desktopStatsEnabled = true;
      root = await Directory.systemTemp.createTemp('erebrus_upload_guard_');
      server = DropServer();
      final session = await server.startForTesting(rootDirectory: root);
      baseUrl = session.baseUrl;
      final login = await _post('$baseUrl/api/auth/login', {});
      token = (jsonDecode(login.body) as Map)['token'] as String;
    });

    tearDown(() async {
      await server.stop();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('preflight accepts files that fit', () async {
      final response = await _post('$baseUrl/api/files/upload/check', {
        'files': [
          {'name': 'a.txt', 'size': 1024},
        ],
      }, token: token);
      final json = jsonDecode(response.body) as Map;
      expect(response.status, HttpStatus.ok);
      expect(json['ok'], isTrue);
      expect(json['maxUploadBytes'], DropServer.defaultMaxUploadBytes);
    });

    test('preflight rejects a file over the room limit', () async {
      final response = await _post('$baseUrl/api/files/upload/check', {
        'files': [
          {'name': 'huge.mov', 'size': DropServer.defaultMaxUploadBytes + 1},
        ],
      }, token: token);
      final json = jsonDecode(response.body) as Map;
      expect(json['ok'], isFalse);
      expect(json['error'], startsWith('huge.mov'));
    });

    test(
      'preflight rejects a batch larger than the free space',
      () async {
        // Many files under the per-file cap that together exceed any real disk.
        final response = await _post('$baseUrl/api/files/upload/check', {
          'files': [
            for (var i = 0; i < 4096; i++)
              {'name': 'part-$i.bin', 'size': DropServer.defaultMaxUploadBytes},
          ],
        }, token: token);
        final json = jsonDecode(response.body) as Map;
        expect(
          json['ok'],
          isFalse,
          reason: 'free space: ${json['availableBytes']}',
        );
        expect(json['error'], contains('free'));
      },
      skip: Platform.isWindows
          ? 'free space is not reported on Windows'
          : false,
    );

    test(
      'upload over the room limit is refused before the body is read',
      () async {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          Uri.parse(baseUrl).port,
        );
        socket.write(
          'POST /api/files/upload?path=%2F&name=big.bin HTTP/1.1\r\n'
          'Host: localhost\r\n'
          'Authorization: Bearer $token\r\n'
          'Content-Type: application/octet-stream\r\n'
          'Content-Length: ${DropServer.defaultMaxUploadBytes + 1}\r\n\r\n',
        );
        final reply = await utf8.decoder
            .bind(socket)
            .join()
            .timeout(const Duration(seconds: 10));
        await socket.close();
        expect(reply, startsWith('HTTP/1.1 413'));
        expect(reply, contains('big.bin'));
        expect(root.listSync(), isEmpty);
      },
    );

    test('normal upload still lands in the room', () async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('$baseUrl/api/files/upload?path=%2F&name=hello.txt'),
        );
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.add(utf8.encode('hello'));
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        expect(response.statusCode, HttpStatus.created, reason: body);
      } finally {
        client.close(force: true);
      }
      expect(await File('${root.path}/hello.txt').readAsString(), 'hello');
    });
  });
  group('DropServer permissions', () {
    late Directory root;
    late DropServer server;

    Future<String> start(RoomPermission permission) async {
      root = await Directory.systemTemp.createTemp('erebrus_permissions_');
      await File('${root.path}/song.mp3').writeAsString('id3');
      server = DropServer();
      final session = await server.startForTesting(
        rootDirectory: root,
        permission: permission,
      );
      return session.baseUrl;
    }

    tearDown(() async {
      await server.stop();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<int> statusOf(String method, String url, {List<int>? body}) async {
      final client = HttpClient();
      try {
        final request = await client.openUrl(method, Uri.parse(url));
        if (body != null) request.add(body);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    test('view-only rooms refuse uploads, folders, text and deletes', () async {
      final baseUrl = await start(RoomPermission.viewOnly);
      expect(await statusOf('GET', '$baseUrl/api/files?path=%2F'), 200);
      expect(
        await statusOf(
          'POST',
          '$baseUrl/api/files/upload?path=%2F&name=x.txt',
          body: utf8.encode('x'),
        ),
        HttpStatus.forbidden,
      );
      expect(
        await statusOf('POST', '$baseUrl/api/folders', body: utf8.encode('{}')),
        HttpStatus.forbidden,
      );
      expect(
        await statusOf('POST', '$baseUrl/api/text', body: utf8.encode('{}')),
        HttpStatus.forbidden,
      );
      expect(await statusOf('PUT', '$baseUrl/dav/x.txt', body: [1]), 403);
      expect(File('${root.path}/x.txt').existsSync(), isFalse);
    });

    test('download-only rooms can still stream media', () async {
      final baseUrl = await start(RoomPermission.downloadOnly);
      final listing = await HttpClient()
          .getUrl(Uri.parse('$baseUrl/api/files?path=%2F'))
          .then((request) => request.close())
          .then((response) => utf8.decoder.bind(response).join());
      final id = ((jsonDecode(listing) as Map)['items'] as List).first['id'];
      expect(await statusOf('GET', '$baseUrl/api/files/$id/stream'), 200);
      expect(await statusOf('DELETE', '$baseUrl/api/files/$id'), 403);
    });

    test('upload-only rooms cannot list or download', () async {
      final baseUrl = await start(RoomPermission.uploadOnly);
      expect(await statusOf('GET', '$baseUrl/api/files?path=%2F'), 403);
      expect(await statusOf('GET', '$baseUrl/dav/song.mp3'), 403);
      expect(
        await statusOf(
          'POST',
          '$baseUrl/api/files/upload?path=%2F&name=in.txt',
          body: utf8.encode('in'),
        ),
        HttpStatus.created,
      );
    });

    test('drop-folder rooms keep rename, delete and streaming', () {
      expect(
        RoomPermission.dropFolderOnly.apiValues,
        containsAll(['rename', 'delete', 'streaming', 'upload']),
      );
    });
  });
}

Future<({int status, String body})> _post(
  String url,
  Map<String, Object?> body, {
  String? token,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.json;
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    request.write(jsonEncode(body));
    final response = await request.close();
    return (
      status: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close(force: true);
  }
}
