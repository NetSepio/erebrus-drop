import 'package:flutter/foundation.dart';

/// True on macOS, Windows, and Linux Flutter desktop targets.
bool get isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Native camera QR scanning is only available on Android and iOS.
bool get supportsNativeQrScanner =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);