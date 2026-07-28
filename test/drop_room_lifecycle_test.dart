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
}
