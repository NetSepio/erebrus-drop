import 'package:flutter/services.dart';

class HostFolderSelection {
  const HostFolderSelection({
    required this.name,
    required this.uri,
    required this.platform,
  });

  final String name;
  final String uri;
  final String platform;

  factory HostFolderSelection.fromJson(Map<Object?, Object?> json) {
    return HostFolderSelection(
      name: json['name']?.toString() ?? 'Selected folder',
      uri: json['uri']?.toString() ?? '',
      platform: json['platform']?.toString() ?? 'unknown',
    );
  }
}

class HostFolderService {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  Future<HostFolderSelection?> selectHostFolder() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'selectHostFolder',
    );
    if (result == null || (result['uri']?.toString().isEmpty ?? true)) {
      return null;
    }
    return HostFolderSelection.fromJson(result);
  }
}
