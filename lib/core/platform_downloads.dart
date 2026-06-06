import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class PlatformDownloadException implements Exception {
  const PlatformDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PlatformSavedDownload {
  const PlatformSavedDownload({
    required this.name,
    required this.location,
    this.path,
    this.uri,
  });

  final String name;
  final String location;
  final String? path;
  final String? uri;

  factory PlatformSavedDownload.fromJson(Map<Object?, Object?> json) {
    final name = json['name']?.toString() ?? 'download';
    return PlatformSavedDownload(
      name: name,
      location:
          json['location']?.toString() ??
          json['path']?.toString() ??
          json['uri']?.toString() ??
          name,
      path: json['path']?.toString(),
      uri: json['uri']?.toString(),
    );
  }
}

class PlatformDownloads {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  static Future<PlatformSavedDownload> saveFileToDownloads({
    required File source,
    required String name,
    String? mimeType,
  }) async {
    try {
      final result = await _channel
          .invokeMapMethod<Object?, Object?>('saveFileToDownloads', {
            'path': source.path,
            'name': name,
            'mimeType': mimeType ?? 'application/octet-stream',
          });
      if (result != null) {
        return PlatformSavedDownload.fromJson(result);
      }
    } on MissingPluginException {
      return _saveWithDartFallback(source: source, name: name);
    } on PlatformException catch (error) {
      throw PlatformDownloadException(
        error.message ?? 'Could not save this file to Downloads.',
      );
    }

    return _saveWithDartFallback(source: source, name: name);
  }

  static Future<PlatformSavedDownload> _saveWithDartFallback({
    required File source,
    required String name,
  }) async {
    final directory = await _fallbackDirectory();
    await directory.create(recursive: true);
    final target = await _uniqueFile(directory, _safeName(name));
    await source.copy(target.path);
    return PlatformSavedDownload(
      name: target.uri.pathSegments.last,
      location: 'Downloads/${target.uri.pathSegments.last}',
      path: target.path,
    );
  }

  static Future<Directory> _fallbackDirectory() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return downloads;
      }
    } catch (_) {
      // Mobile platforms are handled by native code; this is for tests/desktop.
    }

    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}${Platform.pathSeparator}Downloads');
  }

  static Future<File> _uniqueFile(Directory directory, String name) async {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    var candidate = File('${directory.path}${Platform.pathSeparator}$name');
    var index = 1;
    while (await candidate.exists()) {
      candidate = File(
        '${directory.path}${Platform.pathSeparator}$base-$index$extension',
      );
      index++;
    }
    return candidate;
  }

  static String _safeName(String name) {
    final safe = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return safe.isEmpty ? 'download' : safe;
  }
}
