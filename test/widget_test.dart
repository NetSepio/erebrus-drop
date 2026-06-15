import 'package:erebrus_drop/app.dart';
import 'package:erebrus_drop/features/onboarding/onboarding_screen.dart';
import 'package:erebrus_drop/ui/theme/drop_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('onboarding adapts to landscape Android screens', (tester) async {
    await tester.binding.setSurfaceSize(const Size(872, 393));
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      return tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: DropTheme.dark(),
        home: OnboardingScreen(onComplete: () async {}),
      ),
    );
    await tester.pump();

    expect(find.text('Create a private Drop Room'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();

    expect(find.text('Guests can join from browser'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows Erebrus Drop home actions', (tester) async {
    await tester.pumpWidget(const ErebrusDropApp(skipOnboarding: true));
    await tester.pump();

    expect(find.text('Erebrus Drop', findRichText: true), findsWidgets);
    expect(find.text('Start Drop Room'), findsOneWidget);
    expect(find.text('Join Drop Room'), findsOneWidget);
    expect(find.text('Send'), findsWidgets);
  });

  testWidgets('renders primary tabs across common Android screen sizes', (
    tester,
  ) async {
    final sizes = <Size>[
      const Size(360, 640),
      const Size(360, 780),
      const Size(393, 851),
      const Size(640, 360),
      const Size(872, 393),
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
        Icons.bolt_outlined,
        Icons.settings_outlined,
        Icons.home_outlined,
      ]) {
        await tester.tap(find.byIcon(icon).last);
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('shows hotspot guide when no Wi-Fi or hotspot is available', (
    tester,
  ) async {
    const channel = MethodChannel('com.erebrus.drop/network');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'getCurrentNetworkStatus') {
        return {'mode': 'unavailable', 'address': null, 'interface': null};
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

    expect(find.text('Create a hotspot first'), findsOneWidget);
    expect(find.text('Hotspot Guide'), findsOneWidget);
    expect(find.text('Create Local Hotspot'), findsNothing);
    expect(find.text('Stop Hotspot'), findsNothing);
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
