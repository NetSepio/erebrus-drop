import 'package:erebrus_drop/app.dart';
import 'package:flutter/material.dart';
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
