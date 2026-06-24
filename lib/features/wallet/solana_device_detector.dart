import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// Returns true only on Solana Mobile hardware (Saga, Seeker, etc.).
Future<bool> isSolanaMobileDevice({DeviceInfoPlugin? deviceInfo}) async {
  if (!Platform.isAndroid) {
    return false;
  }

  final plugin = deviceInfo ?? DeviceInfoPlugin();
  final android = await plugin.androidInfo;
  return isSolanaAndroidInfo(android);
}

/// Pure check for tests — pass mocked [AndroidDeviceInfo].
bool isSolanaAndroidInfo(AndroidDeviceInfo info) {
  final manufacturer = info.manufacturer.toLowerCase();
  final brand = info.brand.toLowerCase();
  final model = info.model.toLowerCase();

  if (manufacturer.contains('solana mobile') || brand == 'solanamobile') {
    return true;
  }

  return model == 'seeker' || model == 'saga';
}