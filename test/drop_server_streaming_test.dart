import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:erebrus_drop/core/host_folder_bridge.dart';
import 'package:erebrus_drop/server/drop_server.dart';
import 'package:erebrus_drop/server/host_file_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Desktop folder access needs the services binding; the test binding fakes
  // HttpClient, so restore the real one for talking to the local server.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  // 0..255 repeated, so any byte range is easy to check.
  final content = List<int>.generate(4096, (i) => i % 256);

  group('DropServer ranges', () {
    late Directory root;
    late DropServer server;
    late String baseUrl;
    late String id;

    Future<void> start({bool hostFolder = false}) async {
      // A selected folder is read in place on desktop hosts.
      debugDefaultTargetPlatformOverride = hostFolder
          ? TargetPlatform.macOS
          : null;
      root = await Directory.systemTemp.createTemp('erebrus_stream_');
      await File('${root.path}/clip.mp4').writeAsBytes(content);
      server = DropServer();
      final session = await server.startForTesting(
        rootDirectory: root,
        hostFolderUri: hostFolder ? root.uri.toString() : null,
      );
      baseUrl = session.baseUrl;
      final listing = await _get('$baseUrl/api/files?path=%2F');
      id =
          ((jsonDecode(utf8.decode(listing.body)) as Map)['items'] as List)
                  .cast<Map>()
                  .firstWhere((item) => item['name'] == 'clip.mp4')['id']
              as String;
    }

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await server.stop();
      if (await root.exists()) await root.delete(recursive: true);
    });

    for (final hostFolder in [false, true]) {
      final label = hostFolder ? 'selected Drop folder' : 'app folder';

      test('serves byte ranges from the $label', () async {
        await start(hostFolder: hostFolder);
        final url = '$baseUrl/api/files/$id/stream';

        final whole = await _get(url);
        expect(whole.status, 200);
        expect(whole.body, content);

        final middle = await _get(url, range: 'bytes=100-199');
        expect(middle.status, 206);
        expect(middle.headers.value('content-range'), 'bytes 100-199/4096');
        expect(middle.body, content.sublist(100, 200));

        final openEnded = await _get(url, range: 'bytes=4000-');
        expect(openEnded.body, content.sublist(4000));

        final suffix = await _get(url, range: 'bytes=-10');
        expect(suffix.status, 206);
        expect(suffix.body, content.sublist(4086));

        final beyond = await _get(url, range: 'bytes=5000-');
        expect(beyond.status, HttpStatus.requestedRangeNotSatisfiable);
        expect(beyond.headers.value('content-range'), 'bytes */4096');
      });
    }

    test('multipart uploads stream each file part to disk', () async {
      await start();
      const boundary = 'erebrus-test-boundary';
      final body = BytesBuilder()
        ..add(utf8.encode('--$boundary\r\n'))
        ..add(
          utf8.encode('Content-Disposition: form-data; name="note"\r\n\r\n'),
        )
        ..add(utf8.encode('ignored field\r\n'))
        ..add(utf8.encode('--$boundary\r\n'))
        ..add(
          utf8.encode(
            'Content-Disposition: form-data; name="files"; filename="a.bin"\r\n'
            'Content-Type: application/octet-stream\r\n\r\n',
          ),
        )
        ..add(content)
        ..add(utf8.encode('\r\n--$boundary\r\n'))
        ..add(
          utf8.encode(
            'Content-Disposition: form-data; name="files"; filename="b.txt"\r\n'
            'Content-Type: text/plain\r\n\r\n',
          ),
        )
        ..add(utf8.encode('second file'))
        ..add(utf8.encode('\r\n--$boundary--\r\n'));
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('$baseUrl/api/files/upload?path=%2F'),
        );
        request.headers.contentType = ContentType(
          'multipart',
          'form-data',
          parameters: {'boundary': boundary},
        );
        request.add(body.takeBytes());
        final response = await request.close();
        final reply = await utf8.decoder.bind(response).join();
        expect(response.statusCode, HttpStatus.created, reason: reply);
        expect((jsonDecode(reply) as Map)['items'], hasLength(2));
      } finally {
        client.close(force: true);
      }
      expect(await File('${root.path}/a.bin').readAsBytes(), content);
      expect(await File('${root.path}/b.txt').readAsString(), 'second file');
    });
  });

  group('HostFileCache', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('erebrus_cache_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<HostFolderCachedFile> copyNamed(String name) async {
      final file = File('${dir.path}/$name');
      await file.writeAsString('cached');
      return HostFolderCachedFile(
        path: file.path,
        name: name,
        mimeType: 'video/mp4',
      );
    }

    test('range requests for one file share a single copy', () async {
      final cache = HostFileCache();
      var copies = 0;
      Future<HostFolderCachedFile> copy() {
        copies++;
        return copyNamed('movie-$copies.mp4');
      }

      final results = await Future.wait([
        for (var i = 0; i < 5; i++) cache.acquire(key: 'movie', copy: copy),
      ]);
      expect(copies, 1);
      expect(results.map((r) => r.path).toSet(), hasLength(1));
      for (var i = 0; i < 5; i++) {
        cache.release('movie');
      }
      await cache.clear();
      expect(File(results.first.path).existsSync(), isFalse);
    });

    test('idle copies are evicted, busy ones are kept', () async {
      final cache = HostFileCache(idle: Duration.zero);
      final idle = await cache.acquire(
        key: 'idle',
        copy: () => copyNamed('idle.mp4'),
      );
      final busy = await cache.acquire(
        key: 'busy',
        copy: () => copyNamed('busy.mp4'),
      );
      cache.release('idle');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await cache.evictIdle();
      expect(File(idle.path).existsSync(), isFalse);
      expect(File(busy.path).existsSync(), isTrue);
      await cache.clear();
    });

    test('a deleted copy is made again', () async {
      final cache = HostFileCache();
      var copies = 0;
      final first = await cache.acquire(
        key: 'k',
        copy: () => copyNamed('k-${++copies}.mp4'),
      );
      cache.release('k');
      await File(first.path).delete();
      final second = await cache.acquire(
        key: 'k',
        copy: () => copyNamed('k-${++copies}.mp4'),
      );
      expect(copies, 2);
      expect(File(second.path).existsSync(), isTrue);
      await cache.clear();
    });
  });
}

Future<({int status, HttpHeaders headers, List<int> body})> _get(
  String url, {
  String? range,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return (
      status: response.statusCode,
      headers: response.headers,
      body: bytes,
    );
  } finally {
    client.close(force: true);
  }
}
