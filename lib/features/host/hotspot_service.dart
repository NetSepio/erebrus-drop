import 'package:flutter/services.dart';

class HotspotResult {
  const HotspotResult({
    required this.supported,
    required this.started,
    this.ssid,
    this.passphrase,
    this.gatewayIp,
    this.reason,
  });

  final bool supported;
  final bool started;
  final String? ssid;
  final String? passphrase;
  final String? gatewayIp;
  final String? reason;

  factory HotspotResult.fromJson(Map<Object?, Object?> json) {
    return HotspotResult(
      supported: json['supported'] == true,
      started: json['started'] == true,
      ssid: json['ssid']?.toString(),
      passphrase: json['passphrase']?.toString(),
      gatewayIp: json['gatewayIp']?.toString(),
      reason: json['reason']?.toString(),
    );
  }
}

class HotspotService {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  Future<HotspotResult> startLocalOnlyHotspot() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'startLocalOnlyHotspot',
    );
    return HotspotResult.fromJson(result ?? <Object?, Object?>{});
  }

  Future<void> stopLocalOnlyHotspot() async {
    await _channel.invokeMethod<Object?>('stopLocalOnlyHotspot');
  }

  Future<HotspotResult> localOnlyHotspotSupport() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'isLocalOnlyHotspotSupported',
    );
    return HotspotResult.fromJson(result ?? <Object?, Object?>{});
  }

  Future<bool> isLocalOnlyHotspotSupported() async {
    return (await localOnlyHotspotSupport()).supported;
  }
}
