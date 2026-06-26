import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/desktop_mdns_service.dart';
import '../../core/drop_models.dart';
import '../../core/platform_capabilities.dart';

class RoomRuntimeService {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  Future<void> startForegroundRoom({
    required String roomName,
    required String baseUrl,
  }) async {
    await _invokeMobileOnly('startRoomForegroundService', {
      'roomName': roomName,
      'baseUrl': baseUrl,
    });
  }

  Future<void> stopForegroundRoom() async {
    await _invokeMobileOnly('stopRoomForegroundService');
  }

  Future<void> setKeepAwake({required bool enabled}) async {
    await _invokeMobileOnly('setRoomKeepAwake', {'enabled': enabled});
  }

  Future<void> publishMdnsRoom(DropRoomSession session) async {
    if (isDesktopPlatform) {
      await DesktopMdnsService.instance.publish(
        serviceName: session.deviceName.trim().isEmpty
            ? session.name
            : session.deviceName,
        port: session.port,
        txt: {
          'roomId': session.id,
          'roomName': session.name,
          'deviceName': session.deviceName,
          'devicePlatform': _platformName(),
          'deviceType': _deviceType(),
          'auth': session.authRequired ? 'required' : 'open',
          'version': '1',
          'caps': session.permission.apiValues.join(','),
        },
      );
      return;
    }
    await _invokeBestEffort('publishMdnsService', {
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
    if (isDesktopPlatform) {
      await DesktopMdnsService.instance.stopPublish();
      return;
    }
    await _invokeBestEffort('stopMdnsService');
  }

  Future<void> moveAppToBackground() async {
    await _invokeMobileOnly('moveAppToBackground');
  }

  Future<void> _invokeMobileOnly(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (isDesktopPlatform) {
      return;
    }
    await _invokeBestEffort(method, arguments);
  }

  Future<void> _invokeBestEffort(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      // Unsupported or older native builds.
    } on PlatformException {
      // Permission or platform integration failures are non-fatal.
    }
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