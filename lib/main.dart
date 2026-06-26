import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'app.dart';
import 'core/desktop_shell.dart';
import 'core/platform_capabilities.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  if (isDesktopPlatform) {
    await DesktopShell.ensureInitialized();
  }
  final useNativeSplash = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  if (useNativeSplash) {
    // Keep the native splash up until Flutter has painted its first
    // (identically-branded) frame, so the handoff has no visible seam.
    FlutterNativeSplash.preserve(widgetsBinding: binding);
  }
  runApp(const ErebrusDropApp());
  if (useNativeSplash) {
    binding.addPostFrameCallback((_) => FlutterNativeSplash.remove());
  }
}