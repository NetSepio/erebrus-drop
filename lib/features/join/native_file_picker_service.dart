import 'package:flutter/services.dart';

class PickedUploadFile {
  const PickedUploadFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
  });

  final String path;
  final String name;
  final int sizeBytes;

  factory PickedUploadFile.fromJson(Map<Object?, Object?> json) {
    return PickedUploadFile(
      path: json['path']?.toString() ?? '',
      name: json['name']?.toString() ?? 'upload',
      sizeBytes: json['sizeBytes'] is int ? json['sizeBytes'] as int : 0,
    );
  }
}

class NativeFilePickerService {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  Future<PickedUploadFile?> pickFileForUpload() async {
    final files = await pickFilesForUpload();
    return files.isEmpty ? null : files.first;
  }

  Future<List<PickedUploadFile>> pickFilesForUpload() async {
    final result = await _channel.invokeMethod<Object?>('pickFilesForUpload');
    if (result is List) {
      return result
          .whereType<Map<Object?, Object?>>()
          .map(PickedUploadFile.fromJson)
          .where((file) => file.path.isNotEmpty)
          .toList();
    }
    if (result is Map<Object?, Object?> && result['path'] != null) {
      return [PickedUploadFile.fromJson(result)];
    }
    return <PickedUploadFile>[];
  }
}
