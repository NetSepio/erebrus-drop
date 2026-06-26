import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../features/host/host_folder_service.dart';
import 'host_folder_bridge.dart';
import 'platform_capabilities.dart';

class DesktopHostFolder {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  static Future<HostFolderSelection?> selectFolder() async {
    if (!isDesktopPlatform) {
      return null;
    }
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'selectHostFolder',
      );
      if (result == null || (result['uri']?.toString().isEmpty ?? true)) {
        return null;
      }
      return HostFolderSelection.fromJson(result);
    } on MissingPluginException {
      throw PlatformException(
        code: 'PICK_FOLDER_UNAVAILABLE',
        message: 'Folder selection is not available on this desktop build.',
      );
    }
  }

  static Future<List<HostFolderItem>> list({
    required String rootUri,
    required String path,
  }) async {
    final root = await _resolveRootDirectory(rootUri);
    final folder = await _resolveHostDirectory(root: root, path: path);
    if (!await folder.exists()) {
      throw _hostError('HOST_FOLDER_LIST_FAILED', 'Folder not found: $path');
    }
    final folderStat = await folder.stat();
    if (folderStat.type != FileSystemEntityType.directory) {
      throw _hostError('HOST_FOLDER_LIST_FAILED', 'Path is not a folder: $path');
    }

    final entities = await folder.list(followLinks: false).toList();
    final items = <HostFolderItem>[];
    for (final entity in entities) {
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('.')) {
        continue;
      }
      items.add(await _hostItemFromEntity(root: root, entity: entity));
    }

    items.sort((left, right) {
      final leftFolder = left.type == 'folder';
      final rightFolder = right.type == 'folder';
      if (leftFolder != rightFolder) {
        return leftFolder ? -1 : 1;
      }
      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });
    return items;
  }

  static Future<HostFolderItem> copyFileInto({
    required String rootUri,
    required String folderPath,
    required String sourcePath,
    required String name,
    required String mimeType,
  }) async {
    final root = await _resolveRootDirectory(rootUri);
    final folder = await _ensureHostDirectory(root: root, path: folderPath);
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw _hostError('HOST_FOLDER_COPY_FAILED', 'Source file not found.');
    }
    final requestedName = _safeName(name.isEmpty ? source.uri.pathSegments.last : name);
    final destination = await _uniqueChildFile(
      parent: folder,
      name: requestedName,
    );
    await source.copy(destination.path);
    return _hostItemFromFile(root: root, file: destination, mimeType: mimeType);
  }

  static Future<void> createFolder({
    required String rootUri,
    required String path,
  }) async {
    await _ensureHostDirectory(
      root: await _resolveRootDirectory(rootUri),
      path: path,
    );
  }

  static Future<HostFolderCachedFile> copyFileToCache({
    required String rootUri,
    required String path,
  }) async {
    final root = await _resolveRootDirectory(rootUri);
    final source = await _resolveHostFile(root: root, path: path);
    final cacheDir = await _cacheDirectory('host_folder_cache');
    final destination = await _uniqueChildFile(
      parent: cacheDir,
      name: _safeName(source.uri.pathSegments.last),
    );
    await source.copy(destination.path);
    return HostFolderCachedFile(
      path: destination.path,
      name: source.uri.pathSegments.last,
      mimeType: _mimeTypeForPath(source.path),
    );
  }

  static Future<void> openFile({
    required String rootUri,
    required String path,
  }) async {
    final root = await _resolveRootDirectory(rootUri);
    final file = await _resolveHostFile(root: root, path: path);
    await _openPath(file.path);
  }

  static Future<void> shareFile({
    required String rootUri,
    required String path,
  }) async {
    final root = await _resolveRootDirectory(rootUri);
    final file = await _resolveHostFile(root: root, path: path);
    await _revealInFileManager(file.path);
  }

  static Future<void> deleteFile({
    required String rootUri,
    required String path,
  }) async {
    final root = await _resolveRootDirectory(rootUri);
    final target = await _resolveHostEntity(root: root, path: path);
    if (!await target.exists()) {
      throw _hostError('DELETE_FILE_FAILED', 'File not found: $path');
    }
    await target.delete(recursive: true);
  }

  static Future<void> renameItem({
    required String rootUri,
    required String path,
    required String newName,
  }) async {
    final root = await _resolveRootDirectory(rootUri);
    final source = await _resolveHostEntity(root: root, path: path);
    if (!await source.exists()) {
      throw _hostError('RENAME_ITEM_FAILED', 'Item not found: $path');
    }
    final parent = source.parent;
    final destination = File(
      '${parent.path}${Platform.pathSeparator}${_safeName(newName)}',
    );
    await _assertWithinRoot(root: root, target: destination);
    if (await destination.exists()) {
      throw _hostError('RENAME_ITEM_FAILED', 'An item with that name already exists.');
    }
    await source.rename(destination.path);
  }

  static Future<void> moveItem({
    required String rootUri,
    required String path,
    required String destinationPath,
  }) async {
    final root = await _resolveRootDirectory(rootUri);
    final source = await _resolveHostEntity(root: root, path: path);
    final destination = await _resolveHostEntity(root: root, path: destinationPath);
    final destinationParent = destination.parent;
    if (!await destinationParent.exists()) {
      throw _hostError('MOVE_ITEM_FAILED', 'Destination parent not found.');
    }
    final destinationParentStat = await destinationParent.stat();
    if (destinationParentStat.type != FileSystemEntityType.directory) {
      throw _hostError('MOVE_ITEM_FAILED', 'Destination parent is not a folder.');
    }
    if (await destination.exists()) {
      throw _hostError('MOVE_ITEM_FAILED', 'Destination already exists.');
    }
    await source.rename(destination.path);
  }

  static Future<void> openLocalFile({
    required String path,
    required String name,
    required String mimeType,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw _hostError('OPEN_FILE_FAILED', 'File not found: $name');
    }
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.directory) {
      throw _hostError('OPEN_FILE_FAILED', 'Open a file, not a folder.');
    }
    await _openPath(file.path);
  }

  static Future<void> shareLocalFile({
    required String path,
    required String name,
    required String mimeType,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw _hostError('SHARE_FILE_FAILED', 'File not found: $name');
    }
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.directory) {
      throw _hostError('SHARE_FILE_FAILED', 'Share a file, not a folder.');
    }
    await _revealInFileManager(file.path);
  }

  static Future<Directory> _resolveRootDirectory(String rootUri) async {
    final directory = _directoryFromRootUri(rootUri);
    if (!await directory.exists()) {
      throw _hostError(
        'HOST_FOLDER_LIST_FAILED',
        'Selected folder is not available.',
      );
    }
    final stat = await directory.stat();
    if (stat.type != FileSystemEntityType.directory) {
      throw _hostError(
        'HOST_FOLDER_LIST_FAILED',
        'Selected folder is not available.',
      );
    }
    return Directory(await directory.absolute.resolveSymbolicLinks());
  }

  static Directory _directoryFromRootUri(String rootUri) {
    final trimmed = rootUri.trim();
    if (trimmed.isEmpty) {
      throw _hostError('HOST_FOLDER_LIST_FAILED', 'Missing rootUri');
    }
    if (trimmed.startsWith('file://')) {
      return Directory.fromUri(Uri.parse(trimmed));
    }
    return Directory(trimmed);
  }

  static Future<Directory> _resolveHostDirectory({
    required Directory root,
    required String path,
  }) async {
    final target = await _hostDirectory(root: root, path: path);
    await _assertWithinRoot(root: root, target: target);
    return target;
  }

  static Future<File> _resolveHostFile({
    required Directory root,
    required String path,
  }) async {
    final target = File(
      (await _hostDirectory(root: root, path: path)).path,
    );
    await _assertWithinRoot(root: root, target: target);
    if (!await target.exists()) {
      throw _hostError('OPEN_FILE_FAILED', 'File not found: $path');
    }
    final stat = await target.stat();
    if (stat.type == FileSystemEntityType.directory) {
      throw _hostError('OPEN_FILE_FAILED', 'Open a folder by browsing into it.');
    }
    return target;
  }

  static Future<FileSystemEntity> _resolveHostEntity({
    required Directory root,
    required String path,
  }) async {
    final directory = await _hostDirectory(root: root, path: path);
    final file = File(directory.path);
    final entity = await file.exists()
        ? file
        : (await directory.exists() ? directory : file);
    await _assertWithinRoot(root: root, target: entity);
    return entity;
  }

  static Future<Directory> _ensureHostDirectory({
    required Directory root,
    required String path,
  }) async {
    final directory = await _resolveHostDirectory(root: root, path: path);
    await directory.create(recursive: true);
    return directory;
  }

  static Future<Directory> _hostDirectory({
    required Directory root,
    required String path,
  }) async {
    var current = root;
    for (final segment in _hostPathSegments(path)) {
      current = Directory(
        '${current.path}${Platform.pathSeparator}$segment',
      );
    }
    return Directory(await current.absolute.resolveSymbolicLinks());
  }

  static Future<void> _assertWithinRoot({
    required Directory root,
    required FileSystemEntity target,
  }) async {
    final rootPath = await root.absolute.resolveSymbolicLinks();
    final targetPath = await target.absolute.resolveSymbolicLinks();
    final separator = Platform.pathSeparator;
    final normalizedRoot = rootPath.endsWith(separator)
        ? rootPath
        : '$rootPath$separator';
    if (targetPath != rootPath && !targetPath.startsWith(normalizedRoot)) {
      throw _hostError('HOST_FOLDER_LIST_FAILED', 'Path is outside the selected folder.');
    }
  }

  static Future<HostFolderItem> _hostItemFromEntity({
    required Directory root,
    required FileSystemEntity entity,
  }) async {
    final stat = await entity.stat();
    if (stat.type == FileSystemEntityType.directory) {
      return HostFolderItem(
        name: entity.uri.pathSegments.last,
        path: _relativeHostPath(root: root, targetPath: entity.path),
        type: 'folder',
        sizeBytes: 0,
        modifiedAt: stat.modified,
        mimeType: null,
      );
    }
    return _hostItemFromFile(
      root: root,
      file: File(entity.path),
      mimeType: _mimeTypeForPath(entity.path),
      modifiedAt: stat.modified,
    );
  }

  static HostFolderItem _hostItemFromFile({
    required Directory root,
    required File file,
    required String mimeType,
    DateTime? modifiedAt,
  }) {
    final stat = file.statSync();
    return HostFolderItem(
      name: file.uri.pathSegments.last,
      path: _relativeHostPath(root: root, targetPath: file.path),
      type: 'file',
      sizeBytes: stat.size,
      modifiedAt: modifiedAt ?? stat.modified,
      mimeType: mimeType,
    );
  }

  static List<String> _hostPathSegments(String path) {
    return path
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty && segment != '.' && segment != '..')
        .map(_safeName)
        .where((segment) => segment.isNotEmpty)
        .toList();
  }

  static String _relativeHostPath({
    required Directory root,
    required String targetPath,
  }) {
    final rootPath = root.absolute.path;
    final normalizedTarget = Directory(targetPath).absolute.path;
    if (normalizedTarget == rootPath) {
      return '/';
    }
    final prefix = '$rootPath${Platform.pathSeparator}';
    if (normalizedTarget.startsWith(prefix)) {
      final relative = normalizedTarget.substring(prefix.length);
      final segments = relative
          .split(Platform.pathSeparator)
          .where((segment) => segment.isNotEmpty)
          .toList();
      return segments.isEmpty ? '/' : '/${segments.join('/')}';
    }
    return '/${_safeName(normalizedTarget.split(Platform.pathSeparator).last)}';
  }

  static Future<Directory> _cacheDirectory(String name) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}${Platform.pathSeparator}$name');
    await directory.create(recursive: true);
    return directory;
  }

  static Future<File> _uniqueChildFile({
    required Directory parent,
    required String name,
  }) async {
    final safe = _safeName(name);
    final dot = safe.lastIndexOf('.');
    final base = dot > 0 ? safe.substring(0, dot) : safe;
    final extension = dot > 0 ? safe.substring(dot) : '';
    var candidate = File('${parent.path}${Platform.pathSeparator}$safe');
    var index = 1;
    while (await candidate.exists()) {
      final nextName = extension.isEmpty ? '$base-$index' : '$base-$index$extension';
      candidate = File('${parent.path}${Platform.pathSeparator}$nextName');
      index++;
    }
    return candidate;
  }

  static String _safeName(String name) {
    final safe = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return safe.isEmpty ? 'shared-file' : safe;
  }

  static String _mimeTypeForPath(String path) {
    final extension = path.split('.').last.toLowerCase();
    return switch (extension) {
      'txt' => 'text/plain',
      'pdf' => 'application/pdf',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'zip' => 'application/zip',
      'json' => 'application/json',
      'html' => 'text/html',
      'csv' => 'text/csv',
      _ => 'application/octet-stream',
    };
  }

  static Future<void> _openPath(String path) async {
    if (Platform.isMacOS) {
      final result = await Process.run('open', [path]);
      if (result.exitCode != 0) {
        throw _hostError('OPEN_FILE_UNAVAILABLE', 'No app can open this file type.');
      }
      return;
    }
    if (Platform.isLinux) {
      final result = await Process.run('xdg-open', [path]);
      if (result.exitCode != 0) {
        throw _hostError('OPEN_FILE_UNAVAILABLE', 'No app can open this file type.');
      }
      return;
    }
    if (Platform.isWindows) {
      final result = await Process.run('cmd', ['/c', 'start', '', path]);
      if (result.exitCode != 0) {
        throw _hostError('OPEN_FILE_UNAVAILABLE', 'No app can open this file type.');
      }
    }
  }

  static Future<void> _revealInFileManager(String path) async {
    if (Platform.isMacOS) {
      final result = await Process.run('open', ['-R', path]);
      if (result.exitCode != 0) {
        throw _hostError('SHARE_FILE_UNAVAILABLE', 'Could not reveal this file.');
      }
      return;
    }
    if (Platform.isWindows) {
      final result = await Process.run('explorer', ['/select,', path]);
      if (result.exitCode != 0) {
        throw _hostError('SHARE_FILE_UNAVAILABLE', 'Could not reveal this file.');
      }
      return;
    }
    if (Platform.isLinux) {
      final parent = File(path).parent.path;
      final result = await Process.run('xdg-open', [parent]);
      if (result.exitCode != 0) {
        throw _hostError('SHARE_FILE_UNAVAILABLE', 'Could not reveal this file.');
      }
    }
  }

  static PlatformException _hostError(String code, String message) {
    return PlatformException(code: code, message: message);
  }
}