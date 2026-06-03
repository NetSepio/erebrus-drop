import 'dart:io';

import 'package:flutter/services.dart';

class PlatformNetwork {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  static Future<List<String>> getLocalIpAddresses() async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>(
        'getLocalIpAddresses',
      );
      final nativeIps = result?.whereType<String>().toList() ?? <String>[];
      if (nativeIps.isNotEmpty) {
        return nativeIps;
      }
    } on PlatformException {
      // Fall through to Dart network interfaces.
    } on MissingPluginException {
      // Tests and unsupported platforms use the Dart fallback.
    }

    final interfaces = await NetworkInterface.list(
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    final addresses = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) {
          addresses.add(address.address);
        }
      }
    }
    return addresses;
  }

  static Future<String> bestLocalIp() async {
    final addresses = await getLocalIpAddresses();
    return addresses.isEmpty ? '127.0.0.1' : addresses.first;
  }

  static Future<String> deviceName() async {
    try {
      final result = await _channel.invokeMethod<String>('getDeviceName');
      if (result != null && result.trim().isNotEmpty) {
        return result.trim();
      }
    } on PlatformException {
      // Use the Dart fallback when native device metadata is unavailable.
    } on MissingPluginException {
      // Widget tests and unsupported platforms use the Dart fallback.
    }
    return Platform.localHostname;
  }

  static Future<Map<String, int?>> getStorageStats() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getStorageStats',
      );
      if (result != null) {
        return {
          'availableBytes': _asInt(result['availableBytes']),
          'totalBytes': _asInt(result['totalBytes']),
        };
      }
    } on PlatformException {
      // Return null values when a native platform does not expose stats.
    } on MissingPluginException {
      // Widget tests and desktop runs land here.
    }
    return {'availableBytes': null, 'totalBytes': null};
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }
}
