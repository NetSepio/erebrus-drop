import 'package:flutter/services.dart';

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

  Future<void> moveAppToBackground() async {
    await _channel.invokeMethod<Object?>('moveAppToBackground');
  }
}
