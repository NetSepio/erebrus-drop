import 'dart:io';

import 'package:erebrus_drop/app.dart';
import 'package:erebrus_drop/server/drop_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('disposing and recreating the UI preserves a live Drop Room', (
    tester,
  ) async {
    final root =
        await tester.runAsync(
              () => Directory.systemTemp.createTemp('erebrus_drop_lifecycle_'),
            )
            as Directory;
    final server = DropServer();
    final session = await tester.runAsync(
      () => server.startForTesting(rootDirectory: root),
    );
    expect(session, isNotNull);
    try {
      await tester.pumpWidget(const MaterialApp(home: DropHomeScreen()));
      await tester.pump();

      expect(server.isRunning, isTrue);

      // Android share intents and platform view changes may detach/recreate the
      // Flutter UI without representing a user request to stop hosting.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(server.isRunning, isTrue);
      expect(server.session?.id, session!.id);
    } finally {
      await tester.runAsync(() async {
        await server.stop();
        await root.delete(recursive: true);
      });
    }
  });

  test('burn-mode room reports expiry and fires onSessionExpired once', () async {
    final root = await Directory.systemTemp.createTemp('erebrus_drop_expiry_');
    final server = DropServer();
    var expiredCalls = 0;
    server.onSessionExpired = () => expiredCalls++;
    try {
      await server.startForTesting(
        rootDirectory: root,
        expiry: const Duration(milliseconds: 150),
      );

      expect(server.isExpired, isFalse);
      expect(expiredCalls, 0);

      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(server.isExpired, isTrue);
      expect(expiredCalls, 1);
    } finally {
      server.onSessionExpired = null;
      await server.stop();
      await root.delete(recursive: true);
    }
  });

  test('non-expiring room never reports expiry', () async {
    final root = await Directory.systemTemp.createTemp('erebrus_drop_noexp_');
    final server = DropServer();
    try {
      await server.startForTesting(rootDirectory: root);
      expect(server.isExpired, isFalse);
    } finally {
      await server.stop();
      await root.delete(recursive: true);
    }
  });
}
