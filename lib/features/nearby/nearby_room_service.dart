import 'package:flutter/services.dart';

import '../../core/desktop_mdns_service.dart';
import '../../core/platform_capabilities.dart';
import '../../features/join/join_room_service.dart';

class NearbyRoomService {
  NearbyRoomService({JoinRoomService? joinRoomService})
    : _joinRoomService = joinRoomService ?? JoinRoomService();

  static const serviceType = '_erebrusdrop._tcp.';
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  final JoinRoomService _joinRoomService;

  Future<List<JoinRoomPreview>> discoverRooms({
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    try {
      final discoveryMaps = isDesktopPlatform
          ? await DesktopMdnsService.instance.discover(timeout: timeout)
          : await _discoverFromNative(timeout: timeout);
      final urls = discoveryMaps
          .map((map) => _urlFromDiscoveryMap(map.cast<Object?, Object?>()))
          .whereType<String>()
          .toSet();
      final previews = <JoinRoomPreview>[];
      for (final url in urls) {
        try {
          previews.add(await _joinRoomService.preview(url));
        } catch (_) {
          // Stale or unreachable mDNS records are ignored.
        }
      }
      previews.sort((left, right) {
        return left.roomName.toLowerCase().compareTo(
          right.roomName.toLowerCase(),
        );
      });
      return previews;
    } on PlatformException {
      return const <JoinRoomPreview>[];
    } on MissingPluginException {
      return const <JoinRoomPreview>[];
    }
  }

  Future<List<Map<Object?, Object?>>> _discoverFromNative({
    required Duration timeout,
  }) async {
    final result = await _channel.invokeMethod<List<Object?>>(
      'discoverMdnsRooms',
      {'serviceType': serviceType, 'timeoutMillis': timeout.inMilliseconds},
    );
    return (result ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .toList();
  }

  Stream<List<JoinRoomPreview>> watchRooms() {
    return Stream<void>.periodic(
      const Duration(seconds: 5),
      (_) {},
    ).asyncMap((_) => discoverRooms());
  }

  String? _urlFromDiscoveryMap(Map<Object?, Object?> map) {
    final url = map['url']?.toString().trim();
    if (url != null && url.isNotEmpty) {
      return url;
    }
    final host = map['host']?.toString().trim();
    final port = map['port'];
    if (host == null || host.isEmpty || port == null) {
      return null;
    }
    return 'http://$host:$port';
  }
}