import 'dart:io';

import 'package:flutter/services.dart';

enum DropNetworkMode { wifi, hotspot, unavailable }

class DropNetworkStatus {
  const DropNetworkStatus({
    required this.mode,
    this.address,
    this.interfaceName,
  });

  final DropNetworkMode mode;
  final String? address;
  final String? interfaceName;

  bool get isReady => mode != DropNetworkMode.unavailable;
  bool get isWifi => mode == DropNetworkMode.wifi;
  bool get isHotspot => mode == DropNetworkMode.hotspot;

  String get label {
    return switch (mode) {
      DropNetworkMode.wifi => 'Wi-Fi',
      DropNetworkMode.hotspot => 'Hotspot',
      DropNetworkMode.unavailable => 'No network',
    };
  }

  factory DropNetworkStatus.fromJson(Map<Object?, Object?> json) {
    final modeValue = json['mode']?.toString();
    final mode = switch (modeValue) {
      'wifi' => DropNetworkMode.wifi,
      'hotspot' => DropNetworkMode.hotspot,
      _ => DropNetworkMode.unavailable,
    };
    return DropNetworkStatus(
      mode: mode,
      address: json['address']?.toString(),
      interfaceName: json['interface']?.toString(),
    );
  }
}

class PlatformNetwork {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  static Future<DropNetworkStatus> currentNetworkStatus() async {
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>(
        'getCurrentNetworkStatus',
      );
      if (result != null) {
        return DropNetworkStatus.fromJson(result);
      }
    } on PlatformException {
      // Use interface inspection when native network details are unavailable.
    } on MissingPluginException {
      // Tests and unsupported platforms use interface inspection.
    }

    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      return _statusFromInterfaces(interfaces);
    } on SocketException {
      return const DropNetworkStatus(mode: DropNetworkMode.unavailable);
    }
  }

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
    final status = await currentNetworkStatus();
    final statusAddress = status.address?.trim();
    if (status.isReady &&
        statusAddress != null &&
        _isUsableLocalAddress(statusAddress)) {
      return statusAddress;
    }

    final addresses = await getLocalIpAddresses();
    if (addresses.isEmpty) {
      return '127.0.0.1';
    }
    final sorted = [...addresses]..sort(_compareIpPreference);
    return sorted.first;
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

  static int _compareIpPreference(String left, String right) {
    return _ipPreference(left).compareTo(_ipPreference(right));
  }

  static int _ipPreference(String address) {
    final parts = address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) {
      return 100;
    }
    final a = parts[0]!;
    final b = parts[1]!;
    if (a == 192 && b == 168) return 0;
    if (a == 10) return 1;
    if (a == 172 && b >= 16 && b <= 31) return 2;
    if (a == 169 && b == 254) return 90;
    if (a == 100 && b >= 64 && b <= 127) return 95;
    return 50;
  }

  static DropNetworkStatus _statusFromInterfaces(
    List<NetworkInterface> interfaces,
  ) {
    final candidates = <_NetworkCandidate>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (_isUsableLocalAddress(address.address)) {
          candidates.add(_NetworkCandidate(interface.name, address.address));
        }
      }
    }
    if (candidates.isEmpty) {
      return const DropNetworkStatus(mode: DropNetworkMode.unavailable);
    }

    final wifi = candidates.where(_isWifiCandidate).toList();
    if (wifi.isNotEmpty) {
      final selected = _preferredCandidate(wifi);
      return DropNetworkStatus(
        mode: DropNetworkMode.wifi,
        address: selected.address,
        interfaceName: selected.interfaceName,
      );
    }

    final hotspot = candidates.where(_isHotspotCandidate).toList();
    if (hotspot.isNotEmpty) {
      final selected = _preferredCandidate(hotspot);
      return DropNetworkStatus(
        mode: DropNetworkMode.hotspot,
        address: selected.address,
        interfaceName: selected.interfaceName,
      );
    }

    final local = candidates.where((candidate) {
      final name = candidate.interfaceName.toLowerCase();
      return _isPrivateAddress(candidate.address) &&
          !_isCellularInterface(name) &&
          !_isVirtualInterface(name);
    }).toList();
    if (local.isNotEmpty) {
      final selected = _preferredCandidate(local);
      return DropNetworkStatus(
        mode: DropNetworkMode.wifi,
        address: selected.address,
        interfaceName: selected.interfaceName,
      );
    }

    return const DropNetworkStatus(mode: DropNetworkMode.unavailable);
  }

  static _NetworkCandidate _preferredCandidate(
    List<_NetworkCandidate> candidates,
  ) {
    final sorted = [
      ...candidates,
    ]..sort((left, right) => _compareIpPreference(left.address, right.address));
    return sorted.first;
  }

  static bool _isWifiCandidate(_NetworkCandidate candidate) {
    final name = candidate.interfaceName.toLowerCase();
    if (_isCellularInterface(name) || _isVirtualInterface(name)) {
      return false;
    }
    if (_isHotspotAddress(candidate.address) &&
        candidate.address.endsWith('.1')) {
      return false;
    }
    return name.startsWith('wlan') || name.startsWith('wifi') || name == 'en0';
  }

  static bool _isHotspotCandidate(_NetworkCandidate candidate) {
    final name = candidate.interfaceName.toLowerCase();
    return name.startsWith('ap') ||
        name.startsWith('bridge') ||
        name.contains('tether') ||
        (_isHotspotAddress(candidate.address) &&
            candidate.address.endsWith('.1'));
  }

  static bool _isCellularInterface(String name) {
    return name.startsWith('rmnet') ||
        name.startsWith('ccmni') ||
        name.startsWith('pdp_ip') ||
        name.startsWith('wwan') ||
        name.startsWith('cell');
  }

  static bool _isVirtualInterface(String name) {
    return name.startsWith('tun') ||
        name.startsWith('utun') ||
        name.startsWith('ipsec') ||
        name.startsWith('lo') ||
        name.startsWith('awdl') ||
        name.startsWith('llw');
  }

  static bool _isUsableLocalAddress(String address) {
    final parts = address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) {
      return false;
    }
    final a = parts[0]!;
    final b = parts[1]!;
    if (a == 127 || (a == 169 && b == 254)) {
      return false;
    }
    return true;
  }

  static bool _isPrivateAddress(String address) {
    final parts = address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) {
      return false;
    }
    final a = parts[0]!;
    final b = parts[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  static bool _isHotspotAddress(String address) {
    return address.startsWith('192.168.43.') ||
        address.startsWith('192.168.49.') ||
        address.startsWith('172.20.10.');
  }
}

class _NetworkCandidate {
  const _NetworkCandidate(this.interfaceName, this.address);

  final String interfaceName;
  final String address;
}
