import 'dart:io';

import 'package:flutter/services.dart';

import 'desktop_host_folder.dart';
import 'platform_capabilities.dart';

class HostFolderBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  Future<List<HostFolderItem>> list({
    required String rootUri,
    required String path,
  }) async {
    if (isDesktopPlatform) {
      return DesktopHostFolder.list(rootUri: rootUri, path: path);
    }
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
    if (isDesktopPlatform) {
      return DesktopHostFolder.copyFileInto(
        rootUri: rootUri,
        folderPath: folderPath,
        sourcePath: sourcePath,
        name: name,
        mimeType: mimeType,
      );
    }
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
    if (isDesktopPlatform) {
      return DesktopHostFolder.createFolder(rootUri: rootUri, path: path);
    }
    await _channel.invokeMethod<Object?>('createHostFolder', {
      'rootUri': rootUri,
      'path': path,
    });
  }

  Future<HostFolderCachedFile> copyFileToCache({
    required String rootUri,
    required String path,
  }) async {
    if (isDesktopPlatform) {
      return DesktopHostFolder.copyFileToCache(rootUri: rootUri, path: path);
    }
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'copyHostFileToCache',
      {'rootUri': rootUri, 'path': path},
    );
    return HostFolderCachedFile.fromJson(result ?? <Object?, Object?>{});
  }

  /// On desktop, the selected folder is a plain directory: the file itself.
  Future<File?> localFile({required String rootUri, required String path}) {
    if (!isDesktopPlatform) return Future.value();
    return DesktopHostFolder.localFile(rootUri: rootUri, path: path);
  }

  /// Opens a file in the selected folder for ranged reads in place (Android),
  /// or null where only [copyFileToCache] is available.
  Future<HostFileReader?> openFileReader({
    required String rootUri,
    required String path,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await HostFileReader._channel
          .invokeMapMethod<String, Object?>('open', {
            'rootUri': rootUri,
            'path': path,
          });
      if (result == null) return null;
      return HostFileReader._(
        result['id'] as int,
        size: (result['size'] as num?)?.toInt() ?? 0,
        name: result['name']?.toString() ?? 'download',
        mimeType: result['mimeType']?.toString() ?? 'application/octet-stream',
      );
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> openFile({required String rootUri, required String path}) async {
    if (isDesktopPlatform) {
      return DesktopHostFolder.openFile(rootUri: rootUri, path: path);
    }
    await _channel.invokeMethod<Object?>('openHostFile', {
      'rootUri': rootUri,
      'path': path,
    });
  }

  Future<void> shareFile({
    required String rootUri,
    required String path,
  }) async {
    if (isDesktopPlatform) {
      return DesktopHostFolder.shareFile(rootUri: rootUri, path: path);
    }
    await _channel.invokeMethod<Object?>('shareHostFile', {
      'rootUri': rootUri,
      'path': path,
    });
  }

  Future<void> deleteFile({
    required String rootUri,
    required String path,
  }) async {
    if (isDesktopPlatform) {
      return DesktopHostFolder.deleteFile(rootUri: rootUri, path: path);
    }
    await _channel.invokeMethod<Object?>('deleteHostFile', {
      'rootUri': rootUri,
      'path': path,
    });
  }

  Future<void> renameItem({
    required String rootUri,
    required String path,
    required String newName,
  }) async {
    if (isDesktopPlatform) {
      return DesktopHostFolder.renameItem(
        rootUri: rootUri,
        path: path,
        newName: newName,
      );
    }
    await _channel.invokeMethod<Object?>('renameHostItem', {
      'rootUri': rootUri,
      'path': path,
      'newName': newName,
    });
  }

  Future<void> moveItem({
    required String rootUri,
    required String path,
    required String destinationPath,
  }) async {
    if (isDesktopPlatform) {
      return DesktopHostFolder.moveItem(
        rootUri: rootUri,
        path: path,
        destinationPath: destinationPath,
      );
    }
    await _channel.invokeMethod<Object?>('moveHostItem', {
      'rootUri': rootUri,
      'path': path,
      'destinationPath': destinationPath,
    });
  }

  Future<void> openLocalFile({
    required String path,
    required String name,
    required String mimeType,
  }) async {
    if (isDesktopPlatform) {
      return DesktopHostFolder.openLocalFile(
        path: path,
        name: name,
        mimeType: mimeType,
      );
    }
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
    if (isDesktopPlatform) {
      return DesktopHostFolder.shareLocalFile(
        path: path,
        name: name,
        mimeType: mimeType,
      );
    }
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

/// A Drop-folder file held open natively, read in chunks without copying it.
class HostFileReader {
  HostFileReader._(
    this._id, {
    required this.size,
    required this.name,
    required this.mimeType,
  });

  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/host_reader',
  );
  static const int _chunkBytes = 1024 * 1024;

  final int _id;
  final int size;
  final String name;
  final String mimeType;
  bool _closed = false;

  /// Bytes in [start, end). Stops early if the listener cancels, so a video
  /// player seeking away does not keep reading the rest of the file.
  Stream<List<int>> read(int start, int end) async* {
    var offset = start;
    while (offset < end && !_closed) {
      final chunk = await _channel.invokeMethod<Uint8List>('read', {
        'id': _id,
        'offset': offset,
        'length': (end - offset).clamp(0, _chunkBytes),
      });
      if (chunk == null || chunk.isEmpty) break;
      offset += chunk.length;
      yield chunk;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.invokeMethod<void>('close', {'id': _id});
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
