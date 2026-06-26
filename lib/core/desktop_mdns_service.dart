import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import 'platform_capabilities.dart';

class DesktopMdnsService {
  DesktopMdnsService._();

  static final DesktopMdnsService instance = DesktopMdnsService._();

  static const String serviceType = '_erebrusdrop._tcp';

  BonsoirBroadcast? _broadcast;
  bool _discoveryBusy = false;

  Future<void> publish({
    required String serviceName,
    required int port,
    required Map<String, String> txt,
  }) async {
    if (!isDesktopPlatform || port <= 0) {
      return;
    }
    await stopPublish();
    final service = BonsoirService(
      name: serviceName,
      type: serviceType,
      port: port,
      attributes: txt,
    );
    final broadcast = BonsoirBroadcast(service: service);
    await broadcast.initialize();
    await broadcast.start();
    _broadcast = broadcast;
  }

  Future<void> stopPublish() async {
    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast == null) {
      return;
    }
    try {
      await broadcast.stop();
    } on Object {
      // Stopping an unpublished broadcast is harmless.
    }
  }

  Future<List<Map<String, Object?>>> discover({
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    if (!isDesktopPlatform) {
      return const <Map<String, Object?>>[];
    }
    if (_discoveryBusy) {
      return const <Map<String, Object?>>[];
    }
    _discoveryBusy = true;
    try {
      final discovery = BonsoirDiscovery(type: serviceType);
      await discovery.initialize();
      final rooms = <String, Map<String, Object?>>{};
      final subscription = discovery.eventStream?.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            event.service.resolve(discovery.serviceResolver);
          case BonsoirDiscoveryServiceResolvedEvent():
            final room = _roomMapFromService(event.service);
            if (room != null) {
              rooms['${room['host']}:${room['port']}'] = room;
            }
          case BonsoirDiscoveryServiceUpdatedEvent():
            final room = _roomMapFromService(event.service);
            if (room != null) {
              rooms['${room['host']}:${room['port']}'] = room;
            }
          default:
            break;
        }
      });
      await discovery.start();
      await Future<void>.delayed(timeout);
      await discovery.stop();
      await subscription?.cancel();
      return rooms.values.toList();
    } on Object {
      return const <Map<String, Object?>>[];
    } finally {
      _discoveryBusy = false;
    }
  }

  Map<String, Object?>? _roomMapFromService(BonsoirService service) {
    final host = _preferredHost(service);
    final port = service.port;
    if (host == null || host.isEmpty || port <= 0) {
      return null;
    }
    return {
      'serviceName': service.name,
      'host': host,
      'port': port,
      'url': 'http://$host:$port',
      'txt': Map<String, String>.from(service.attributes),
    };
  }

  String? _preferredHost(BonsoirService service) {
    final addresses = service.hostAddresses
        .map((address) => address.trim())
        .where((address) => address.isNotEmpty)
        .toList();
    if (addresses.isEmpty) {
      return null;
    }
    final private = addresses.where(_isPrivateIpv4).toList();
    final candidates = private.isNotEmpty ? private : addresses;
    candidates.sort(_compareIpPreference);
    return candidates.first;
  }

  int _compareIpPreference(String left, String right) {
    return _ipPreference(left).compareTo(_ipPreference(right));
  }

  int _ipPreference(String address) {
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

  bool _isPrivateIpv4(String address) {
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
}