import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform_capabilities.dart';

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

/// Thrown when the phone lacks room to stage the picked files for upload.
class PickStorageException implements Exception {
  const PickStorageException(this.message);

  final String message;

  @override
  String toString() => message;
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
    if (kIsWeb) return <PickedUploadFile>[];

    // On desktop, file_selector uses the native file dialog on all three
    // platforms and avoids the need for per-platform method channel code.
    if (isDesktopPlatform) {
      final picked = await openFiles(
        acceptedTypeGroups: const <XTypeGroup>[XTypeGroup()],
      );
      return Future.wait(
        picked.map((file) async {
          var sizeBytes = 0;
          try {
            sizeBytes = await file.length();
          } catch (_) {
            // The platform may not always report a length; fall back to 0.
          }
          return PickedUploadFile(
            path: file.path,
            name: file.name,
            sizeBytes: sizeBytes,
          );
        }),
      );
    }

    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>('pickFilesForUpload');
    } on PlatformException catch (error) {
      if (error.code == 'INSUFFICIENT_STORAGE') {
        throw PickStorageException(
          error.message ?? 'Not enough free space on this phone.',
        );
      }
      rethrow;
    }
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

  /// Deletes the cache copies Android makes of picked files once they have
  /// been sent. Desktop picks point at the user's own files and are kept.
  Future<void> discard(Iterable<PickedUploadFile> files) async {
    if (kIsWeb || isDesktopPlatform) return;
    for (final file in files) {
      if (!file.path.contains('/picked_uploads/')) continue;
      try {
        await File(file.path).delete();
      } catch (_) {
        // Already gone, or the OS will clear the cache later.
      }
    }
  }
}
