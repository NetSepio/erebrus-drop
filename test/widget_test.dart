import 'package:erebrus_drop/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows Erebrus Drop home actions', (tester) async {
    await tester.pumpWidget(const ErebrusDropApp(skipOnboarding: true));
    await tester.pump();

    expect(find.text('Erebrus Drop'), findsWidgets);
    expect(find.text('Start Drop Room'), findsOneWidget);
    expect(find.text('Join Drop Room'), findsOneWidget);
    expect(find.text('Smart Send'), findsWidgets);
  });

  testWidgets('renders primary tabs across common Android screen sizes', (
    tester,
  ) async {
    final sizes = <Size>[
      const Size(360, 640),
      const Size(360, 780),
      const Size(393, 851),
      const Size(800, 1280),
    ];

    for (final size in sizes) {
      await tester.binding.setSurfaceSize(size);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        return tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const ErebrusDropApp(skipOnboarding: true));
      await tester.pump();
      expect(tester.takeException(), isNull);

      for (final icon in const [
        Icons.hub_outlined,
        Icons.folder_outlined,
        Icons.flash_on_outlined,
        Icons.settings_outlined,
        Icons.home_outlined,
      ]) {
        await tester.tap(find.byIcon(icon).last);
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets(
    'shows one hotspot guide action when app hotspot is unavailable',
    (tester) async {
      const channel = MethodChannel('com.erebrus.drop/network');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'isLocalOnlyHotspotSupported') {
          return {
            'supported': false,
            'started': false,
            'reason': 'Use system Settings to enable a hotspot.',
          };
        }
        if (call.method == 'getDeviceName') {
          return 'Test Phone';
        }
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });

      await tester.pumpWidget(const ErebrusDropApp(skipOnboarding: true));
      await tester.pump();

      await tester.tap(find.text('Start Drop Room'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Network'), findsOneWidget);
      expect(find.text('Hotspot Guide'), findsOneWidget);
      expect(find.text('Create Local Hotspot'), findsNothing);
      expect(find.text('Stop Hotspot'), findsNothing);
    },
  );

  testWidgets('shows drop QR dialog on compact Android screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      return tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DropCodeDialog(
              link: 'http://192.168.1.24:8787',
              onCopy: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Drop Code'), findsOneWidget);
    expect(find.text('http://192.168.1.24:8787'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
