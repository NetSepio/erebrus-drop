import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/drop_models.dart';

class RoomRuntimeService {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  Future<void> startForegroundRoom({
    required String roomName,
    required String baseUrl,
  }) async {
    await _channel.invokeMethod<Object?>('startRoomForegroundService', {
      'roomName': roomName,
      'baseUrl': baseUrl,
    });
  }

  Future<void> stopForegroundRoom() async {
    await _channel.invokeMethod<Object?>('stopRoomForegroundService');
  }

  Future<void> setKeepAwake({required bool enabled}) async {
    await _channel.invokeMethod<Object?>('setRoomKeepAwake', {
      'enabled': enabled,
    });
  }

  Future<void> publishMdnsRoom(DropRoomSession session) async {
    await _channel.invokeMethod<Object?>('publishMdnsService', {
      'serviceType': '_erebrusdrop._tcp.',
      'serviceName': session.deviceName.trim().isEmpty
          ? session.name
          : session.deviceName,
      'port': session.port,
      'txt': {
        'roomId': session.id,
        'roomName': session.name,
        'deviceName': session.deviceName,
        'devicePlatform': _platformName(),
        'deviceType': _deviceType(),
        'auth': session.authRequired ? 'required' : 'open',
        'version': '1',
        'caps': session.permission.apiValues.join(','),
      },
    });
  }

  Future<void> stopMdnsRoom() async {
    await _channel.invokeMethod<Object?>('stopMdnsService');
  }

  Future<void> moveAppToBackground() async {
    await _channel.invokeMethod<Object?>('moveAppToBackground');
  }

  String _platformName() {
    if (defaultTargetPlatform == TargetPlatform.android) return 'android';
    if (defaultTargetPlatform == TargetPlatform.iOS) return 'ios';
    if (defaultTargetPlatform == TargetPlatform.macOS) return 'macos';
    if (defaultTargetPlatform == TargetPlatform.windows) return 'windows';
    if (defaultTargetPlatform == TargetPlatform.linux) return 'linux';
    return 'unknown';
  }

  String _deviceType() {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return 'phone';
    }
    return 'desktop';
  }
}
