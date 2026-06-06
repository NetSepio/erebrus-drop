import 'package:flutter/services.dart';

class HostFolderBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  Future<List<HostFolderItem>> list({
    required String rootUri,
    required String path,
  }) async {
    final result = await _channel.invokeMethod<List<Object?>>(
      'listHostFolder',
      {'rootUri': rootUri, 'path': path},
    );
    return (result ?? <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(HostFolderItem.fromJson)
        .toList();
  }

  Future<HostFolderItem> copyFileInto({
    required String rootUri,
    required String folderPath,
    required String sourcePath,
    required String name,
    required String mimeType,
  }) async {
    final result = await _channel
        .invokeMethod<Map<Object?, Object?>>('copyFileIntoHostFolder', {
          'rootUri': rootUri,
          'folderPath': folderPath,
          'sourcePath': sourcePath,
          'name': name,
          'mimeType': mimeType,
        });
    return HostFolderItem.fromJson(result ?? <Object?, Object?>{});
  }

  Future<void> createFolder({
    required String rootUri,
    required String path,
  }) async {
    await _channel.invokeMethod<Object?>('createHostFolder', {
      'rootUri': rootUri,
      'path': path,
    });
  }

  Future<HostFolderCachedFile> copyFileToCache({
    required String rootUri,
    required String path,
  }) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'copyHostFileToCache',
      {'rootUri': rootUri, 'path': path},
    );
    return HostFolderCachedFile.fromJson(result ?? <Object?, Object?>{});
  }

  Future<void> openFile({required String rootUri, required String path}) async {
    await _channel.invokeMethod<Object?>('openHostFile', {
      'rootUri': rootUri,
      'path': path,
    });
  }

  Future<void> shareFile({
    required String rootUri,
    required String path,
  }) async {
    await _channel.invokeMethod<Object?>('shareHostFile', {
      'rootUri': rootUri,
      'path': path,
    });
  }

  Future<void> deleteFile({
    required String rootUri,
    required String path,
  }) async {
    await _channel.invokeMethod<Object?>('deleteHostFile', {
      'rootUri': rootUri,
      'path': path,
    });
  }

  Future<void> openLocalFile({
    required String path,
    required String name,
    required String mimeType,
  }) async {
    await _channel.invokeMethod<Object?>('openLocalFile', {
      'path': path,
      'name': name,
      'mimeType': mimeType,
    });
  }

  Future<void> shareLocalFile({
    required String path,
    required String name,
    required String mimeType,
  }) async {
    await _channel.invokeMethod<Object?>('shareLocalFile', {
      'path': path,
      'name': name,
      'mimeType': mimeType,
    });
  }
}

class HostFolderItem {
  const HostFolderItem({
    required this.name,
    required this.path,
    required this.type,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.mimeType,
  });

  final String name;
  final String path;
  final String type;
  final int sizeBytes;
  final DateTime modifiedAt;
  final String? mimeType;

  factory HostFolderItem.fromJson(Map<Object?, Object?> json) {
    return HostFolderItem(
      name: json['name']?.toString() ?? 'Item',
      path: json['path']?.toString() ?? '/',
      type: json['type']?.toString() ?? 'file',
      sizeBytes: json['sizeBytes'] is int ? json['sizeBytes'] as int : 0,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        json['modifiedAtMillis'] is int ? json['modifiedAtMillis'] as int : 0,
      ),
      mimeType: json['mimeType']?.toString(),
    );
  }
}

class HostFolderCachedFile {
  const HostFolderCachedFile({
    required this.path,
    required this.name,
    required this.mimeType,
  });

  final String path;
  final String name;
  final String mimeType;

  factory HostFolderCachedFile.fromJson(Map<Object?, Object?> json) {
    return HostFolderCachedFile(
      path: json['path']?.toString() ?? '',
      name: json['name']?.toString() ?? 'download',
      mimeType: json['mimeType']?.toString() ?? 'application/octet-stream',
    );
  }
}
