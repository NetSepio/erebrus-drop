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
      'serviceName': session.name,
      'port': session.port,
      'txt': {
        'roomId': session.id,
        'roomName': session.name,
        'deviceName': session.deviceName,
        'auth': session.authRequired ? 'required' : 'open',
        'version': '1.0.0',
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
}
