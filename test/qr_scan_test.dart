import 'dart:convert';

import 'package:erebrus_drop/features/join/qr_scan_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses raw Drop Link QR values', () {
    expect(
      parseDropCodeUrl('http://192.168.1.20:8787'),
      'http://192.168.1.20:8787',
    );
  });

  test('parses spec JSON Drop Code payloads', () {
    final payload = jsonEncode({
      'type': 'erebrus_drop_room',
      'version': 1,
      'roomName': 'Mate 9 Drop',
      'url': 'http://192.168.43.1:8787',
      'authRequired': true,
    });

    expect(parseDropCodeUrl(payload), 'http://192.168.43.1:8787');
  });
}
