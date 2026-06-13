import 'dart:convert';
import 'dart:io';

import 'package:erebrus_drop/server/drop_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late DropServer server;
  late String baseUrl;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('erebrus_webdav_move_');
    server = DropServer();
    final session = await server.startForTesting(rootDirectory: root);
    baseUrl = session.baseUrl;
  });

  tearDown(() async {
    await server.stop();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<WebDavResponse> request(
    String method,
    String path, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse('$baseUrl$path'));
      headers.forEach(request.headers.set);
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      return WebDavResponse(response.statusCode, response.headers, body);
    } finally {
      client.close(force: true);
    }
  }

  Future<WebDavResponse> move(
    String sourcePath,
    String destination, {
    String? overwrite,
  }) {
    final headers = <String, String>{'Destination': destination};
    if (overwrite != null) {
      headers['Overwrite'] = overwrite;
    }
    return request('MOVE', sourcePath, headers: headers);
  }

  Future<WebDavResponse> propfind(String path) {
    return request('PROPFIND', path, headers: {'Depth': '1'});
  }

  test('renames a file and updates PROPFIND listing', () async {
    await File('${root.path}/old.txt').writeAsString('hello');

    final response = await move('/dav/old.txt', '$baseUrl/dav/new.txt');

    expect(response.statusCode, HttpStatus.created);
    expect(await File('${root.path}/old.txt').exists(), isFalse);
    expect(await File('${root.path}/new.txt').readAsString(), 'hello');
    final listing = await propfind('/dav/');
    expect(listing.body, contains('new.txt'));
    expect(listing.body, isNot(contains('old.txt')));
  });

  test('renames a folder with children', () async {
    await Directory('${root.path}/old-folder').create();
    await File('${root.path}/old-folder/child.txt').writeAsString('child');

    final response = await move('/dav/old-folder', '$baseUrl/dav/new-folder');

    expect(response.statusCode, HttpStatus.created);
    expect(await Directory('${root.path}/old-folder').exists(), isFalse);
    expect(
      await File('${root.path}/new-folder/child.txt').readAsString(),
      'child',
    );
  });

  test('moves a file into an existing folder', () async {
    await File('${root.path}/note.txt').writeAsString('note');
    await Directory('${root.path}/folder').create();

    final response = await move(
      '/dav/note.txt',
      '$baseUrl/dav/folder/note.txt',
    );

    expect(response.statusCode, HttpStatus.created);
    expect(await File('${root.path}/note.txt').exists(), isFalse);
    expect(await File('${root.path}/folder/note.txt').readAsString(), 'note');
  });

  test('overwrite true replaces existing destination', () async {
    await File('${root.path}/source.txt').writeAsString('source');
    await File('${root.path}/dest.txt').writeAsString('dest');

    final response = await move(
      '/dav/source.txt',
      '$baseUrl/dav/dest.txt',
      overwrite: 'T',
    );

    expect(response.statusCode, HttpStatus.noContent);
    expect(await File('${root.path}/source.txt').exists(), isFalse);
    expect(await File('${root.path}/dest.txt').readAsString(), 'source');
  });

  test('overwrite false rejects existing destination', () async {
    await File('${root.path}/source.txt').writeAsString('source');
    await File('${root.path}/dest.txt').writeAsString('dest');

    final response = await move(
      '/dav/source.txt',
      '$baseUrl/dav/dest.txt',
      overwrite: 'F',
    );

    expect(response.statusCode, HttpStatus.preconditionFailed);
    expect(await File('${root.path}/source.txt').readAsString(), 'source');
    expect(await File('${root.path}/dest.txt').readAsString(), 'dest');
  });

  test('missing source returns 404', () async {
    final response = await move('/dav/missing.txt', '$baseUrl/dav/new.txt');

    expect(response.statusCode, HttpStatus.notFound);
  });

  test('missing destination parent returns 409', () async {
    await File('${root.path}/source.txt').writeAsString('source');

    final response = await move(
      '/dav/source.txt',
      '$baseUrl/dav/missing-parent/source.txt',
    );

    expect(response.statusCode, HttpStatus.conflict);
    expect(await File('${root.path}/source.txt').readAsString(), 'source');
  });

  test('path traversal destination is rejected', () async {
    await File('${root.path}/source.txt').writeAsString('source');

    final response = await move(
      '/dav/source.txt',
      '$baseUrl/dav/%2e%2e/escape.txt',
    );

    expect(response.statusCode, HttpStatus.forbidden);
    expect(await File('${root.path}/source.txt').readAsString(), 'source');
  });

  test('destination outside dav is rejected', () async {
    await File('${root.path}/source.txt').writeAsString('source');

    final response = await move('/dav/source.txt', '$baseUrl/not-dav/file.txt');

    expect(response.statusCode, HttpStatus.forbidden);
    expect(await File('${root.path}/source.txt').readAsString(), 'source');
  });

  test('options advertises move without dav level 2 locks', () async {
    final response = await request('OPTIONS', '/dav/');

    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.value(HttpHeaders.allowHeader), contains('MOVE'));
    expect(
      response.headers.value(HttpHeaders.allowHeader),
      isNot(contains('LOCK')),
    );
    expect(response.headers.value('DAV'), '1');
  });
}

class WebDavResponse {
  const WebDavResponse(this.statusCode, this.headers, this.body);

  final int statusCode;
  final HttpHeaders headers;
  final String body;
}
