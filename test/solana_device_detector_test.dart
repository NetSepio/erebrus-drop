import 'package:device_info_plus/device_info_plus.dart';
import 'package:erebrus_drop/features/wallet/solana_device_detector.dart';
import 'package:flutter_test/flutter_test.dart';

AndroidDeviceInfo _androidInfo({
  required String manufacturer,
  required String brand,
  required String model,
}) {
  return AndroidDeviceInfo.fromMap({
    'version': {
      'sdkInt': 35,
      'release': '15',
      'codename': 'REL',
      'previewSdkInt': 0,
      'incremental': '1',
      'securityPatch': '2026-01-01',
      'baseOS': '',
    },
    'board': 'board',
    'bootloader': 'bootloader',
    'brand': brand,
    'device': 'device',
    'display': 'display',
    'fingerprint': 'fingerprint',
    'hardware': 'hardware',
    'host': 'host',
    'id': 'id',
    'manufacturer': manufacturer,
    'model': model,
    'product': 'product',
    'supported32BitAbis': <String>[],
    'supported64BitAbis': <String>[],
    'supportedAbis': <String>['arm64-v8a'],
    'tags': 'tags',
    'type': 'type',
    'isPhysicalDevice': true,
    'freeDiskSize': 1000,
    'totalDiskSize': 2000,
    'systemFeatures': <String>[],
    'serialNumber': 'serial',
    'isLowRamDevice': false,
    'physicalRamSize': 8192,
    'availableRamSize': 4096,
  });
}

void main() {
  test('detects Seeker by model', () {
    final info = _androidInfo(
      manufacturer: 'Solana Mobile Inc.',
      brand: 'solanamobile',
      model: 'Seeker',
    );
    expect(isSolanaAndroidInfo(info), isTrue);
  });

  test('detects Saga by model', () {
    final info = _androidInfo(
      manufacturer: 'Solana Mobile Inc.',
      brand: 'solanamobile',
      model: 'Saga',
    );
    expect(isSolanaAndroidInfo(info), isTrue);
  });

  test('detects Solana hardware by manufacturer', () {
    final info = _androidInfo(
      manufacturer: 'Solana Mobile Inc.',
      brand: 'solanamobile',
      model: 'Unknown',
    );
    expect(isSolanaAndroidInfo(info), isTrue);
  });

  test('rejects normal Android phones', () {
    final info = _androidInfo(
      manufacturer: 'Google',
      brand: 'google',
      model: 'Pixel 8',
    );
    expect(isSolanaAndroidInfo(info), isFalse);
  });
}