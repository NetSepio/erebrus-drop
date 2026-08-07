import 'package:erebrus_drop/ui/layout/desktop_layout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('default desktop window uses side navigation', () {
    expect(DesktopLayout.useSideRail(880), isTrue);
  });

  test('narrow desktop window uses compact navigation', () {
    expect(DesktopLayout.useSideRail(800), isFalse);
  });

  test('large desktop content uses split workspaces', () {
    expect(DesktopLayout.useSplitPane(1100), isTrue);
    expect(DesktopLayout.useSplitPane(900), isFalse);
  });
}
