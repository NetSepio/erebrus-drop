import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'app.dart';

void main() {
  final binding = WidgetsFlutterBinding.ensureInitialized();
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
