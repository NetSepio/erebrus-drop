import 'dart:convert';
import 'dart:io';

import 'package:erebrus_drop/features/join/join_room_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final servers = <HttpServer>[];

  tearDown(() async {
    for (final server in servers) {
      await server.close(force: true);
    }
    servers.clear();
  });

  test('preview accepts pasted JSON Drop Code payloads', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'roomId': 'room-1',
          'roomName': 'Test Room',
          'deviceName': 'Host Phone',
          'authRequired': false,
          'defaultUploadPath': '/',
          'scopePath': '/',
          'scopedToDefaultFolder': false,
          'capabilities': {'upload': true, 'download': true},
        }),
      );
      await request.response.close();
    });

    final url = 'http://${server.address.address}:${server.port}';
    final payload = jsonEncode({
      'type': 'erebrus_drop_room',
      'version': 1,
      'url': url,
    });

    final preview = await JoinRoomService().preview(payload);

    expect(preview.baseUrl, url);
    expect(preview.roomName, 'Test Room');
  });

  test('preview reports a friendly message for non-Drop responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<html><body>Not a Drop room</body></html>');
      await request.response.close();
    });

    final url = 'http://${server.address.address}:${server.port}';

    await expectLater(
      JoinRoomService().preview(url),
      throwsA(
        isA<JoinRoomException>().having(
          (error) => error.message,
          'message',
          contains('not an Erebrus Drop Room'),
        ),
      ),
    );
  });

  test('preview rejects non-Drop JSON codes without FormatException noise', () {
    expect(
      JoinRoomService().preview('{"type":"other_code"}'),
      throwsA(
        isA<JoinRoomException>().having(
          (error) => error.message,
          'message',
          contains('not an Erebrus Drop Code'),
        ),
      ),
    );
  });
}
