import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/drop_models.dart';
import '../core/host_folder_bridge.dart';
import '../core/platform_network.dart';

class DropServer {
  static final DropServer _instance = DropServer._internal();
  factory DropServer() => _instance;
  DropServer._internal();

  static const int defaultPort = 8787;
  static const int lastFallbackPort = 8799;
  static const int defaultMaxUploadBytes = 2 * 1024 * 1024 * 1024;
  static const Duration _folderUsageScanTtl = Duration(minutes: 5);
  static const Duration _folderUsageScanYield = Duration(milliseconds: 8);
  static const int _folderUsageScanBatchSize = 25;
  static const int _folderUsageScanMaxEntries = 20000;

  HttpServer? _server;
  DropRoomSession? _session;
  Directory? _dropDirectory;
  final HostFolderBridge _hostFolderBridge = HostFolderBridge();
  _PasswordRecord? _passwordRecord;
  StorageSnapshot? _lastStorageSnapshot;
  DateTime? _lastStorageSnapshotAt;
  Future<StorageSnapshot>? _storageSnapshotInFlight;
  final Map<String, DateTime> _tokens = <String, DateTime>{};
  _FolderUsageCache? _folderUsageCache;
  Future<void>? _folderUsageScanInFlight;
  bool _folderUsageRescanRequested = false;
  int _folderUsageScanGeneration = 0;

  DropRoomSession? get session => _session;

  bool get isRunning => _server != null;

  Future<DropRoomSession> startForTesting({
    required Directory rootDirectory,
  }) async {
    if (_server != null) {
      return _session!;
    }
    await rootDirectory.create(recursive: true);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    final createdAt = DateTime.now();
    _dropDirectory = rootDirectory;
    _passwordRecord = null;
    _session = DropRoomSession(
      id: _randomToken(16),
      name: 'Test Drop Room',
      deviceName: 'Test Host',
      baseUrl: 'http://${server.address.address}:${server.port}',
      localIp: server.address.address,
      port: server.port,
      authRequired: false,
      permission: RoomPermission.fullAccess,
      createdAt: createdAt,
      expiresAt: null,
      roomDirectory: rootDirectory,
      defaultUploadPath: '/',
    );
    unawaited(_serve(server));
    return _session!;
  }

  Future<DropRoomSession> start(DropRoomConfig config) async {
    if (_server != null) {
      return _session!;
    }
    if ((config.hostFolderUri ?? '').trim().isEmpty) {
      throw StateError(
        'Select a Drop folder from phone storage before starting a room.',
      );
    }

    final tempDirectory = await getTemporaryDirectory();
    final roomDirectory = Directory('${tempDirectory.path}/ErebrusDropRuntime');
    await roomDirectory.create(recursive: true);

    final localIp = await PlatformNetwork.bestLocalIp();
    final server = await _bindServer();
    final port = server.port;
    final createdAt = DateTime.now();
    final expiresAt = config.expiry == null
        ? null
        : createdAt.add(config.expiry!);

    _dropDirectory = null;
    _passwordRecord = config.authRequired
        ? _PasswordRecord.create(config.password)
        : null;
    _session = DropRoomSession(
      id: _randomToken(16),
      name: config.name.trim().isEmpty
          ? 'Erebrus Drop Room'
          : config.name.trim(),
      deviceName: config.deviceName.trim().isEmpty
          ? Platform.localHostname
          : config.deviceName.trim(),
      baseUrl: 'http://$localIp:$port',
      localIp: localIp,
      port: port,
      authRequired: config.authRequired,
      permission: config.permission,
      createdAt: createdAt,
      expiresAt: expiresAt,
      roomDirectory: roomDirectory,
      defaultUploadPath: _normalizeRoomPath(config.defaultUploadPath),
      hostFolderUri: config.hostFolderUri,
      hostFolderName: config.hostFolderName,
      hostFolderPlatform: config.hostFolderPlatform,
    );

    _scheduleFolderUsageScan(force: true);
    unawaited(_serve(server));
    return _session!;
  }

  Future<void> stop() async {
    _tokens.clear();
    final server = _server;
    _server = null;
    _session = null;
    _passwordRecord = null;
    _lastStorageSnapshot = null;
    _lastStorageSnapshotAt = null;
    _storageSnapshotInFlight = null;
    _folderUsageScanGeneration++;
    _folderUsageCache = null;
    _folderUsageRescanRequested = false;
    await server?.close(force: true);
  }

  Future<void> updateHostFolder({
    required String? hostFolderUri,
    required String? hostFolderName,
    required String? hostFolderPlatform,
  }) async {
    final session = _requireSession();
    _session = DropRoomSession(
      id: session.id,
      name: session.name,
      deviceName: session.deviceName,
      baseUrl: session.baseUrl,
      localIp: session.localIp,
      port: session.port,
      authRequired: session.authRequired,
      permission: session.permission,
      createdAt: session.createdAt,
      expiresAt: session.expiresAt,
      roomDirectory: session.roomDirectory,
      defaultUploadPath: '/',
      hostFolderUri: hostFolderUri,
      hostFolderName: hostFolderName,
      hostFolderPlatform: hostFolderPlatform,
    );
    _folderUsageScanGeneration++;
    _folderUsageCache = null;
    _folderUsageRescanRequested = false;
    _invalidateStorageSnapshot();
    _scheduleFolderUsageScan(force: true);
  }

  Future<void> openFile(DropFileItem item) async {
    final session = _requireSession();
    if (session.usesExternalHostFolder) {
      await _hostFolderBridge.openFile(
        rootUri: session.hostFolderUri!,
        path: item.path,
      );
      return;
    }
    final entity = _entityFromId(item.id);
    if (entity is! File || !await entity.exists()) {
      throw const FileSystemException('File was not found.');
    }
    await _hostFolderBridge.openLocalFile(
      path: entity.path,
      name: item.name,
      mimeType: item.mimeType ?? _mimeType(entity.path),
    );
  }

  Future<void> shareFile(DropFileItem item) async {
    final session = _requireSession();
    if (item.type == 'folder') {
      throw const FileSystemException('Share a file, not a folder.');
    }
    if (session.usesExternalHostFolder) {
      await _hostFolderBridge.shareFile(
        rootUri: session.hostFolderUri!,
        path: item.path,
      );
      return;
    }
    final entity = _entityFromId(item.id);
    if (entity is! File || !await entity.exists()) {
      throw const FileSystemException('File was not found.');
    }
    await _hostFolderBridge.shareLocalFile(
      path: entity.path,
      name: item.name,
      mimeType: item.mimeType ?? _mimeType(entity.path),
    );
  }

  Future<void> deleteFile(DropFileItem item) async {
    final session = _requireSession();
    if (item.type == 'folder') {
      throw const FileSystemException('Delete a file, not a folder.');
    }
    if (session.usesExternalHostFolder) {
      await _hostFolderBridge.deleteFile(
        rootUri: session.hostFolderUri!,
        path: item.path,
      );
      _folderUsageScanGeneration++;
      _folderUsageCache = null;
      _folderUsageRescanRequested = false;
      _invalidateStorageSnapshot();
      _scheduleFolderUsageScan(force: true);
      return;
    }
    final entity = _entityFromId(item.id);
    if (entity is! File || !await entity.exists()) {
      throw const FileSystemException('File was not found.');
    }
    await entity.delete();
    _invalidateStorageSnapshot();
  }

  Future<DropFileItem> importLocalFile({
    required File file,
    required String name,
    String folderPath = '/',
    String? mimeType,
  }) async {
    final session = _requireSession();
    final safeName = _sanitizeName(name);
    if (safeName.isEmpty) {
      throw const FileSystemException('Choose a file name.');
    }
    if (session.usesExternalHostFolder) {
      final item = await _hostFolderBridge.copyFileInto(
        rootUri: session.hostFolderUri!,
        folderPath: _guestPathForRequest(folderPath),
        sourcePath: file.path,
        name: safeName,
        mimeType: mimeType ?? _mimeType(safeName),
      );
      _requestFolderUsageRescan();
      return _itemFromHostFolderItem(item);
    }
    final directory = Directory(_resolveGuestRoomPath(folderPath).path);
    await directory.create(recursive: true);
    final target = await _uniqueFile(directory, safeName);
    await file.copy(target.path);
    _invalidateStorageSnapshot();
    return _itemFromEntity(target);
  }

  Future<void> pullFileFromRoom({
    required String sourceBaseUrl,
    required String sourceToken,
    required DropFileItem item,
    String destinationPath = '/',
    void Function(int received, int total)? onProgress,
  }) async {
    if (item.type == 'folder') {
      throw const FileSystemException('Pull a file, not a folder.');
    }
    final tempDirectory = await getTemporaryDirectory();
    final transferDirectory = Directory(
      '${tempDirectory.path}/ErebrusDropServerTransfers',
    );
    await transferDirectory.create(recursive: true);
    final temp = await _uniqueFile(transferDirectory, '.${item.name}.part');
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('$sourceBaseUrl/api/files/${item.id}/download'),
      );
      if (sourceToken.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $sourceToken',
        );
      }
      final response = await request.close();
      if (response.statusCode >= 400) {
        final body = await utf8.decoder.bind(response).join();
        throw FileSystemException(
          body.isEmpty ? 'Could not pull remote file.' : body,
        );
      }
      final sink = temp.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, response.contentLength);
        }
      } finally {
        await sink.close();
      }
      await importLocalFile(
        file: temp,
        name: item.name,
        folderPath: destinationPath,
        mimeType: item.mimeType,
      );
    } finally {
      client.close(force: true);
      if (await temp.exists()) {
        await temp.delete();
      }
    }
  }

  Future<void> pushFileToRoom({
    required DropFileItem item,
    required String targetBaseUrl,
    required String targetToken,
    String destinationPath = '/',
    void Function(int sent, int total)? onProgress,
  }) async {
    if (item.type == 'folder') {
      throw const FileSystemException('Push a file, not a folder.');
    }
    final session = _requireSession();
    HostFolderCachedFile? cached;
    File file;
    String mimeType;
    if (session.usesExternalHostFolder) {
      cached = await _hostFolderBridge.copyFileToCache(
        rootUri: session.hostFolderUri!,
        path: item.path,
      );
      file = File(cached.path);
      mimeType = cached.mimeType;
    } else {
      final entity = _entityFromId(item.id, enforceGuestScope: true);
      if (entity is! File || !await entity.exists()) {
        throw const FileSystemException('File was not found.');
      }
      file = entity;
      mimeType = item.mimeType ?? _mimeType(item.name);
    }

    final client = HttpClient();
    try {
      final uri = Uri.parse(
        '$targetBaseUrl/api/files/upload',
      ).replace(queryParameters: {'path': destinationPath, 'name': item.name});
      final request = await client.postUrl(uri);
      request.headers
        ..contentType = ContentType.parse(mimeType)
        ..set(HttpHeaders.authorizationHeader, 'Bearer $targetToken');
      final total = await file.length();
      request.contentLength = total;
      var sent = 0;
      await for (final chunk in file.openRead()) {
        sent += chunk.length;
        request.add(chunk);
        onProgress?.call(sent, total);
      }
      final response = await request.close();
      if (response.statusCode >= 400) {
        final body = await utf8.decoder.bind(response).join();
        throw FileSystemException(body.isEmpty ? 'Could not push file.' : body);
      }
      await response.drain<void>();
    } finally {
      client.close(force: true);
      final cachedPath = cached?.path;
      if (cachedPath != null) {
        final cachedFile = File(cachedPath);
        if (await cachedFile.exists()) {
          await cachedFile.delete();
        }
      }
    }
  }

  Future<StorageSnapshot> storageSnapshot() async {
    final cached = _lastStorageSnapshot;
    final cachedAt = _lastStorageSnapshotAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(seconds: 2)) {
      return cached;
    }
    final inFlight = _storageSnapshotInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _buildStorageSnapshot();
    _storageSnapshotInFlight = future;
    try {
      final snapshot = await future;
      _lastStorageSnapshot = snapshot;
      _lastStorageSnapshotAt = DateTime.now();
      return snapshot;
    } finally {
      if (identical(_storageSnapshotInFlight, future)) {
        _storageSnapshotInFlight = null;
      }
    }
  }

  Future<StorageSnapshot> _buildStorageSnapshot() async {
    final dropDirectory = _dropDirectory;
    final session = _session;
    final roomDirectory = session?.roomDirectory;
    final storageStats = await PlatformNetwork.getStorageStats();
    final external = session?.usesExternalHostFolder == true;
    final folderUsage = external ? _folderUsageCacheFor(session!) : null;
    if (external) {
      _scheduleFolderUsageScan();
    }
    final externalUsedBytes = folderUsage?.usedBytes;
    return StorageSnapshot(
      dropUsedBytes: external
          ? externalUsedBytes ?? 0
          : dropDirectory == null
          ? 0
          : await _directorySize(dropDirectory),
      roomUsedBytes: external
          ? externalUsedBytes ?? 0
          : roomDirectory == null
          ? 0
          : await _directorySize(roomDirectory),
      availableBytes: storageStats['availableBytes'],
      totalBytes: storageStats['totalBytes'],
      maxUploadBytes: defaultMaxUploadBytes,
      folderUsedBytes: externalUsedBytes,
      folderScanStatus: external
          ? folderUsage?.status ?? 'queued'
          : 'unavailable',
      folderScannedAt: folderUsage?.scannedAt,
      folderScanMessage: folderUsage?.message,
      folderScannedFileCount: folderUsage?.fileCount,
      folderScannedFolderCount: folderUsage?.folderCount,
    );
  }

  _FolderUsageCache? _folderUsageCacheFor(DropRoomSession session) {
    final cache = _folderUsageCache;
    if (cache == null || cache.rootUri != session.hostFolderUri) {
      return null;
    }
    return cache;
  }

  void _scheduleFolderUsageScan({bool force = false}) {
    final session = _session;
    if (session?.usesExternalHostFolder != true) {
      return;
    }
    final rootUri = session!.hostFolderUri!;
    final cache = _folderUsageCacheFor(session);
    final now = DateTime.now();
    if (!force && cache != null) {
      final active = cache.status == 'queued' || cache.status == 'scanning';
      final fresh =
          cache.scannedAt != null &&
          now.difference(cache.scannedAt!) < _folderUsageScanTtl;
      if (active || fresh) {
        return;
      }
    }

    if (_folderUsageScanInFlight != null) {
      _folderUsageRescanRequested = _folderUsageRescanRequested || force;
      if (cache != null && cache.status != 'scanning') {
        _folderUsageCache = cache.copyWith(
          status: 'queued',
          updatedAt: now,
          message: 'Folder usage scan queued.',
        );
        _invalidateStorageSnapshot();
      }
      return;
    }

    final generation = ++_folderUsageScanGeneration;
    _folderUsageCache = _FolderUsageCache(
      rootUri: rootUri,
      usedBytes: cache?.usedBytes,
      fileCount: cache?.fileCount ?? 0,
      folderCount: cache?.folderCount ?? 0,
      status: 'queued',
      scannedAt: cache?.scannedAt,
      updatedAt: now,
      message: cache?.usedBytes == null
          ? 'Folder usage scan queued.'
          : 'Updating cached folder usage.',
    );
    _invalidateStorageSnapshot();

    late final Future<void> scan;
    scan = _runFolderUsageScan(rootUri: rootUri, generation: generation)
        .whenComplete(() {
          if (identical(_folderUsageScanInFlight, scan)) {
            _folderUsageScanInFlight = null;
          }
          if (_folderUsageRescanRequested) {
            _folderUsageRescanRequested = false;
            _scheduleFolderUsageScan(force: true);
          }
        });
    _folderUsageScanInFlight = scan;
  }

  Future<void> _runFolderUsageScan({
    required String rootUri,
    required int generation,
  }) async {
    final previous = _folderUsageCache?.usedBytes;
    final startedAt = DateTime.now();
    _folderUsageCache = _FolderUsageCache(
      rootUri: rootUri,
      usedBytes: previous,
      fileCount: 0,
      folderCount: 0,
      status: 'scanning',
      updatedAt: startedAt,
      message: previous == null
          ? 'Scanning selected folder.'
          : 'Refreshing folder usage.',
    );
    _invalidateStorageSnapshot();

    var bytes = 0;
    var fileCount = 0;
    var folderCount = 0;
    var visited = 0;
    var skippedFolders = 0;
    final pending = Queue<String>()..add('/');

    while (pending.isNotEmpty) {
      if (!_isFolderUsageScanCurrent(rootUri, generation)) {
        return;
      }
      final path = pending.removeFirst();
      List<HostFolderItem> items;
      try {
        items = await _hostFolderBridge.list(rootUri: rootUri, path: path);
      } catch (_) {
        skippedFolders++;
        continue;
      }

      for (final item in items) {
        if (!_isFolderUsageScanCurrent(rootUri, generation)) {
          return;
        }
        visited++;
        if (item.type == 'folder') {
          folderCount++;
          pending.add(_normalizeRoomPath(item.path));
        } else {
          fileCount++;
          bytes += max(0, item.sizeBytes);
        }

        if (visited >= _folderUsageScanMaxEntries) {
          _folderUsageCache = _FolderUsageCache(
            rootUri: rootUri,
            usedBytes: bytes,
            fileCount: fileCount,
            folderCount: folderCount,
            status: 'partial',
            scannedAt: DateTime.now(),
            updatedAt: DateTime.now(),
            message:
                'Scanned the first $_folderUsageScanMaxEntries items. Folder may be larger.',
          );
          _invalidateStorageSnapshot();
          return;
        }

        if (visited % _folderUsageScanBatchSize == 0) {
          _folderUsageCache = _FolderUsageCache(
            rootUri: rootUri,
            usedBytes: previous,
            fileCount: fileCount,
            folderCount: folderCount,
            status: 'scanning',
            scannedAt: _folderUsageCache?.scannedAt,
            updatedAt: DateTime.now(),
            message: 'Scanned $fileCount files in $folderCount folders...',
          );
          _invalidateStorageSnapshot();
          await Future<void>.delayed(_folderUsageScanYield);
        }
      }
    }

    if (!_isFolderUsageScanCurrent(rootUri, generation)) {
      return;
    }
    final completeAt = DateTime.now();
    _folderUsageCache = _FolderUsageCache(
      rootUri: rootUri,
      usedBytes: bytes,
      fileCount: fileCount,
      folderCount: folderCount,
      status: skippedFolders == 0 ? 'ready' : 'partial',
      scannedAt: completeAt,
      updatedAt: completeAt,
      message: skippedFolders == 0
          ? 'Scanned $fileCount files in $folderCount folders.'
          : 'Scanned $fileCount files. $skippedFolders folders could not be read.',
    );
    _invalidateStorageSnapshot();
  }

  bool _isFolderUsageScanCurrent(String rootUri, int generation) {
    return _folderUsageScanGeneration == generation &&
        _session?.hostFolderUri == rootUri &&
        _session?.usesExternalHostFolder == true;
  }

  void _requestFolderUsageRescan() {
    _invalidateStorageSnapshot();
    _scheduleFolderUsageScan(force: true);
  }

  Future<File> saveTextSnippet({
    required String title,
    required String body,
    String source = 'manual',
    String folderPath = '/',
  }) async {
    final session = _requireSession();
    if (session.usesExternalHostFolder) {
      final temp = await _writeTempTextFile(title: title, body: body);
      try {
        final item = await _hostFolderBridge.copyFileInto(
          rootUri: session.hostFolderUri!,
          folderPath: _guestPathForRequest(folderPath),
          sourcePath: temp.path,
          name: _entityName(temp),
          mimeType: 'text/plain',
        );
        _requestFolderUsageRescan();
        return File(item.path);
      } finally {
        if (await temp.exists()) {
          await temp.delete();
        }
      }
    }
    final textDirectory = Directory(_resolveGuestRoomPath(folderPath).path);
    await textDirectory.create(recursive: true);
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final safeTitle = _sanitizeName(title.isEmpty ? 'Text snippet' : title);
    final file = File('${textDirectory.path}/$timestamp-$safeTitle.txt');
    await file.writeAsString(body);
    _invalidateStorageSnapshot();
    return file;
  }

  Future<List<DropFileItem>> listFiles(String roomPath) async {
    final session = _requireSession();
    if (session.usesExternalHostFolder) {
      final items = await _hostFolderBridge.list(
        rootUri: session.hostFolderUri!,
        path: _normalizeRoomPath(roomPath),
      );
      return items.map(_itemFromHostFolderItem).toList();
    }
    final directory = Directory(_resolveRoomPath(roomPath).path);
    if (!await directory.exists()) {
      return <DropFileItem>[];
    }
    final children = await directory.list().toList();
    children.sort((a, b) {
      final aIsDir = a is Directory;
      final bIsDir = b is Directory;
      if (aIsDir != bIsDir) {
        return aIsDir ? -1 : 1;
      }
      return _entityName(
        a,
      ).toLowerCase().compareTo(_entityName(b).toLowerCase());
    });
    final items = <DropFileItem>[];
    for (final entity in children) {
      if (_entityName(entity).startsWith('.')) {
        continue;
      }
      try {
        items.add(await _itemFromEntity(entity));
      } on FileSystemException {
        continue;
      }
    }
    return items;
  }

  Future<HttpServer> _bindServer() async {
    Object? lastError;
    for (var port = defaultPort; port <= lastFallbackPort; port++) {
      try {
        final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
        _server = server;
        return server;
      } on SocketException catch (error) {
        lastError = error;
      }
    }
    throw StateError('No Drop Room ports are available: $lastError');
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handleRequest(request));
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/' || path == '/index.html') {
        await _serveIndex(request);
        return;
      }
      if (path == '/dav' || path.startsWith('/dav/')) {
        await _handleWebDav(request);
        return;
      }
      if (path == '/logo.png' && request.method == 'GET') {
        await _serveClientAsset(request, 'logo.png');
        return;
      }
      if (path == '/api/room' && request.method == 'GET') {
        await _json(request, _roomJson());
        return;
      }
      if (path == '/api/auth/login' && request.method == 'POST') {
        await _login(request);
        return;
      }
      if (path == '/api/storage' && request.method == 'GET') {
        if (!_isAuthorized(request)) {
          await _unauthorized(request);
          return;
        }
        await _json(request, (await storageSnapshot()).toJson());
        return;
      }
      if (path == '/api/files' && request.method == 'GET') {
        if (!_isAuthorized(request)) {
          await _unauthorized(request);
          return;
        }
        final roomPath = request.uri.queryParameters['path'] ?? '/';
        final guestPath = _guestPathForRequest(roomPath);
        await _json(request, {
          'path': guestPath,
          'items': (await listFiles(
            guestPath,
          )).map((item) => item.toJson()).toList(),
        });
        return;
      }
      if (path == '/api/folders' && request.method == 'POST') {
        if (!_isAuthorized(request)) {
          await _unauthorized(request);
          return;
        }
        final body = await _readJson(request);
        final folderPath = body['path']?.toString() ?? '/New Folder';
        final session = _requireSession();
        if (session.usesExternalHostFolder) {
          await _hostFolderBridge.createFolder(
            rootUri: session.hostFolderUri!,
            path: _guestPathForRequest(folderPath),
          );
          _requestFolderUsageRescan();
        } else {
          await Directory(
            _resolveGuestRoomPath(folderPath).path,
          ).create(recursive: true);
          _invalidateStorageSnapshot();
        }
        await _json(request, {'ok': true}, statusCode: HttpStatus.created);
        return;
      }
      if (path == '/api/text' && request.method == 'POST') {
        if (!_isAuthorized(request)) {
          await _unauthorized(request);
          return;
        }
        final body = await _readJson(request);
        final session = _requireSession();
        final file = await saveTextSnippet(
          title: body['title']?.toString() ?? 'Text snippet',
          body: body['body']?.toString() ?? '',
          source: body['source']?.toString() ?? 'browser',
          folderPath: session.defaultUploadPath,
        );
        await _json(request, {
          'ok': true,
          'id': session.usesExternalHostFolder
              ? _encodeId(file.path)
              : _idForFile(file),
        });
        return;
      }
      if (path == '/api/files/upload' && request.method == 'POST') {
        if (!_isAuthorized(request)) {
          await _unauthorized(request);
          return;
        }
        await _uploadFile(request);
        return;
      }
      if (path == '/api/files/bundle' && request.method == 'GET') {
        if (!_isAuthorized(request)) {
          await _unauthorized(request);
          return;
        }
        await _downloadBundle(request);
        return;
      }
      if (path == '/api/server/pull' && request.method == 'POST') {
        if (!_isAuthorized(request)) {
          await _unauthorized(request);
          return;
        }
        await _serverPull(request);
        return;
      }
      if (path == '/api/server/push' && request.method == 'POST') {
        if (!_isAuthorized(request)) {
          await _unauthorized(request);
          return;
        }
        await _serverPush(request);
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length == 4 &&
          segments[0] == 'api' &&
          segments[1] == 'files') {
        final id = segments[2];
        final action = segments[3];
        if (action == 'download' && request.method == 'GET') {
          if (!_isAuthorized(request)) {
            await _unauthorized(request);
            return;
          }
          await _downloadFile(request, id, asAttachment: true);
          return;
        }
        if (action == 'stream' &&
            (request.method == 'GET' || request.method == 'HEAD')) {
          if (!_isAuthorized(request)) {
            await _unauthorized(request);
            return;
          }
          await _downloadFile(request, id, asAttachment: false);
          return;
        }
        if (action == 'bundle' && request.method == 'GET') {
          if (!_isAuthorized(request)) {
            await _unauthorized(request);
            return;
          }
          await _downloadBundle(request, ids: <String>[id]);
          return;
        }
      }
      if (segments.length == 3 &&
          segments[0] == 'api' &&
          segments[1] == 'files') {
        final id = segments[2];
        if (request.method == 'DELETE') {
          if (!_isAuthorized(request)) {
            await _unauthorized(request);
            return;
          }
          if (_requireSession().usesExternalHostFolder) {
            await _json(request, {
              'error':
                  'Delete for OS-selected folders is not enabled in this build.',
            }, statusCode: HttpStatus.notImplemented);
            return;
          }
          final entity = _entityFromId(id, enforceGuestScope: true);
          if (entity is File && await entity.exists()) {
            await entity.delete();
          } else if (entity is Directory && await entity.exists()) {
            await entity.delete(recursive: true);
          }
          await _json(request, {'ok': true});
          return;
        }
        if (request.method == 'PATCH') {
          if (!_isAuthorized(request)) {
            await _unauthorized(request);
            return;
          }
          if (_requireSession().usesExternalHostFolder) {
            await _json(request, {
              'error':
                  'Rename for OS-selected folders is not enabled in this build.',
            }, statusCode: HttpStatus.notImplemented);
            return;
          }
          await _renameEntity(request, id);
          return;
        }
      }
      await _notFound(request);
    } on FileSystemException catch (error) {
      await _json(request, {
        'error': 'That path is outside the allowed Drop Room folder.',
        'detail': error.message,
      }, statusCode: HttpStatus.forbidden);
    } catch (error) {
      await _json(request, {
        'error': 'Something went wrong in this Drop Room.',
        'detail': '$error',
      }, statusCode: HttpStatus.internalServerError);
    }
  }

  Future<void> _serveIndex(HttpRequest request) async {
    final html = await rootBundle.loadString(
      'assets/web/drop_client/index.html',
    );
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(html);
    await request.response.close();
  }

  Future<void> _serveClientAsset(HttpRequest request, String name) async {
    final bytes = await rootBundle.load('assets/web/drop_client/$name');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.parse(_mimeType(name))
      ..headers.set(HttpHeaders.cacheControlHeader, 'public, max-age=3600')
      ..add(bytes.buffer.asUint8List());
    await request.response.close();
  }

  Future<void> _login(HttpRequest request) async {
    final passwordRecord = _passwordRecord;
    if (passwordRecord == null) {
      final token = _issueToken();
      await _json(request, _authJson(token));
      return;
    }
    final body = await _readJson(request);
    final password = body['password']?.toString() ?? '';
    if (!passwordRecord.matches(password)) {
      await _json(request, {
        'error': 'Wrong password. Ask the host for the current room password.',
      }, statusCode: HttpStatus.unauthorized);
      return;
    }
    final token = _issueToken();
    await _json(request, _authJson(token));
  }

  Future<void> _uploadFile(HttpRequest request) async {
    final destinationPath =
        request.uri.queryParameters['path'] ??
        _requireSession().defaultUploadPath;
    final contentType = request.headers.contentType;
    if (contentType?.mimeType == 'multipart/form-data') {
      await _uploadMultipart(request, destinationPath);
      return;
    }
    final name = _sanitizeName(
      request.uri.queryParameters['name'] ??
          'upload-${DateTime.now().millisecondsSinceEpoch}',
    );
    final contentLength = request.contentLength;
    if (contentLength > defaultMaxUploadBytes) {
      await _json(request, {
        'error': 'This file is larger than the room upload limit.',
      }, statusCode: HttpStatus.requestEntityTooLarge);
      return;
    }
    final temp = await _tempUploadFile(name);
    try {
      await _writeRequestToFile(request, temp);
      final item = await importLocalFile(
        file: temp,
        name: name,
        folderPath: destinationPath,
        mimeType: contentType?.mimeType ?? _mimeType(name),
      );
      await _json(request, {
        'ok': true,
        'item': item.toJson(),
      }, statusCode: HttpStatus.created);
    } finally {
      if (await temp.exists()) {
        await temp.delete();
      }
    }
  }

  Future<void> _uploadMultipart(
    HttpRequest request,
    String fallbackDestinationPath,
  ) async {
    final contentType = request.headers.contentType;
    final boundary = contentType?.parameters['boundary'];
    if (boundary == null || boundary.isEmpty) {
      await _json(request, {
        'error': 'Multipart upload is missing a boundary.',
      }, statusCode: HttpStatus.badRequest);
      return;
    }

    var received = 0;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      received += chunk.length;
      if (received > defaultMaxUploadBytes) {
        await _json(request, {
          'error': 'Multipart upload exceeds the room upload limit.',
        }, statusCode: HttpStatus.requestEntityTooLarge);
        return;
      }
      builder.add(chunk);
    }

    final items = <Map<String, Object?>>[];
    final parts = _parseMultipartBody(builder.takeBytes(), boundary);
    for (final part in parts) {
      final disposition = _multipartHeader(part.headers, 'content-disposition');
      final parameters = _headerParameters(disposition);
      final partName = parameters['name'];
      if (partName != 'file' && partName != 'files' && partName != 'upload') {
        continue;
      }
      final rawName =
          parameters['filename'] ??
          'upload-${DateTime.now().millisecondsSinceEpoch}';
      final name = _sanitizeName(rawName);
      final temp = await _tempUploadFile(name);
      try {
        await temp.writeAsBytes(part.body, flush: true);
        final item = await importLocalFile(
          file: temp,
          name: name,
          folderPath:
              request.uri.queryParameters['path'] ?? fallbackDestinationPath,
          mimeType:
              _multipartHeader(part.headers, HttpHeaders.contentTypeHeader) ??
              _mimeType(name),
        );
        items.add(item.toJson());
      } finally {
        if (await temp.exists()) {
          await temp.delete();
        }
      }
    }
    if (items.isEmpty) {
      await _json(request, {
        'error': 'Multipart upload did not include any file parts.',
      }, statusCode: HttpStatus.badRequest);
      return;
    }
    await _json(request, {
      'ok': true,
      'items': items,
    }, statusCode: HttpStatus.created);
  }

  Future<void> _downloadFile(
    HttpRequest request,
    String id, {
    required bool asAttachment,
  }) async {
    final session = _requireSession();
    if (session.usesExternalHostFolder) {
      final path = _decodeId(id);
      _guestPathForRequest(path);
      final cached = await _hostFolderBridge.copyFileToCache(
        rootUri: session.hostFolderUri!,
        path: path,
      );
      final file = File(cached.path);
      try {
        await _downloadLocalFile(
          request,
          file,
          mimeType: cached.mimeType,
          fileName: cached.name,
          asAttachment: asAttachment,
        );
      } finally {
        if (await file.exists()) {
          await file.delete();
        }
      }
      return;
    }
    final entity = _entityFromId(id, enforceGuestScope: true);
    if (entity is! File || !await entity.exists()) {
      await _notFound(request);
      return;
    }
    await _downloadLocalFile(
      request,
      entity,
      mimeType: _mimeType(entity.path),
      fileName: _entityName(entity),
      asAttachment: asAttachment,
    );
  }

  Future<void> _downloadBundle(HttpRequest request, {List<String>? ids}) async {
    final requestedIds =
        ids ??
        (request.uri.queryParametersAll['id'] ??
            request.uri.queryParameters['ids']?.split(',') ??
            const <String>[]);
    final safeIds = requestedIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    final bundleName = _sanitizeName(
      request.uri.queryParameters['name'] ?? 'erebrus-drop-bundle',
    );
    final tempDirectory = await getTemporaryDirectory();
    final bundleDirectory = Directory('${tempDirectory.path}/ErebrusDropZips');
    await bundleDirectory.create(recursive: true);
    final zipFile = await _uniqueFile(bundleDirectory, '$bundleName.zip');
    final cachedFiles = <File>[];
    try {
      final entries = await _zipEntriesForIds(safeIds, cachedFiles);
      if (entries.isEmpty) {
        await _json(request, {
          'error': 'Choose at least one file or folder to bundle.',
        }, statusCode: HttpStatus.badRequest);
        return;
      }
      await _writeZipFile(zipFile, entries);
      await _downloadLocalFile(
        request,
        zipFile,
        mimeType: 'application/zip',
        fileName: zipFile.uri.pathSegments.last,
        asAttachment: true,
      );
    } finally {
      for (final file in cachedFiles) {
        if (await file.exists()) {
          await file.delete();
        }
      }
      if (await zipFile.exists()) {
        await zipFile.delete();
      }
    }
  }

  Future<void> _handleWebDav(HttpRequest request) async {
    try {
      if (!_isWebDavAuthorized(request)) {
        request.response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Basic realm="Erebrus Drop"',
        );
        await _webDavError(request, HttpStatus.unauthorized);
        return;
      }
      switch (request.method) {
        case 'OPTIONS':
          await _webDavOptions(request);
        case 'PROPFIND':
          await _webDavPropfind(request);
        case 'GET':
        case 'HEAD':
          await _webDavDownload(request);
        case 'PUT':
          await _webDavPut(request);
        case 'MKCOL':
          await _webDavMkcol(request);
        case 'DELETE':
          await _webDavDelete(request);
        case 'MOVE':
          await _webDavMove(request);
        case 'LOCK':
          await _webDavLock(request);
        case 'UNLOCK':
          request.response.statusCode = HttpStatus.noContent;
          await request.response.close();
        default:
          await _webDavError(request, HttpStatus.methodNotAllowed);
      }
    } on FileSystemException {
      await _webDavError(request, HttpStatus.forbidden);
    } on FormatException {
      await _webDavError(request, HttpStatus.forbidden);
    }
  }

  Future<void> _webDavOptions(HttpRequest request) async {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.set('DAV', '1')
      ..headers.set(
        HttpHeaders.allowHeader,
        'OPTIONS, PROPFIND, GET, HEAD, PUT, MKCOL, DELETE, MOVE',
      )
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    await request.response.close();
  }

  Future<void> _webDavPropfind(HttpRequest request) async {
    final path = _webDavRoomPath(request.uri);
    final depth = request.headers.value('Depth') ?? 'infinity';
    final item = await _webDavItem(path);
    if (item == null) {
      await _webDavError(request, HttpStatus.notFound);
      return;
    }
    final items = <DropFileItem>[item];
    if (item.type == 'folder' && depth != '0') {
      items.addAll(await listFiles(path));
    }
    final xml = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write('<D:multistatus xmlns:D="DAV:">');
    for (final entry in items) {
      xml.write(_webDavResponseXml(entry));
    }
    xml.write('</D:multistatus>');
    request.response
      ..statusCode = 207
      ..headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      )
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(xml.toString());
    await request.response.close();
  }

  Future<void> _webDavDownload(HttpRequest request) async {
    final path = _webDavRoomPath(request.uri);
    final item = await _webDavItem(path);
    if (item == null) {
      await _webDavError(request, HttpStatus.notFound);
      return;
    }
    if (item.type == 'folder') {
      await _webDavError(request, HttpStatus.methodNotAllowed);
      return;
    }
    await _downloadPath(request, item.path, asAttachment: false);
  }

  Future<void> _webDavPut(HttpRequest request) async {
    final path = _webDavRoomPath(request.uri);
    if (path == '/') {
      await _webDavError(request, HttpStatus.conflict);
      return;
    }
    final existing = await _webDavItem(path);
    final parent = _parentRoomPath(path);
    final name = path.split('/').where((part) => part.isNotEmpty).last;
    final temp = await _tempUploadFile(name);
    try {
      await _writeRequestToFile(request, temp);
      await importLocalFile(
        file: temp,
        name: name,
        folderPath: parent,
        mimeType: request.headers.contentType?.mimeType ?? _mimeType(name),
      );
    } finally {
      if (await temp.exists()) {
        await temp.delete();
      }
    }
    request.response.statusCode = existing == null
        ? HttpStatus.created
        : HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _webDavMkcol(HttpRequest request) async {
    final path = _webDavRoomPath(request.uri);
    if (path == '/' || await _webDavItem(path) != null) {
      await _webDavError(request, HttpStatus.methodNotAllowed);
      return;
    }
    final session = _requireSession();
    if (session.usesExternalHostFolder) {
      await _hostFolderBridge.createFolder(
        rootUri: session.hostFolderUri!,
        path: _guestPathForRequest(path),
      );
      _requestFolderUsageRescan();
    } else {
      await Directory(_resolveGuestRoomPath(path).path).create(recursive: true);
      _invalidateStorageSnapshot();
    }
    request.response.statusCode = HttpStatus.created;
    await request.response.close();
  }

  Future<void> _webDavDelete(HttpRequest request) async {
    final path = _webDavRoomPath(request.uri);
    final item = await _webDavItem(path);
    if (item == null || path == '/') {
      await _webDavError(request, HttpStatus.notFound);
      return;
    }
    final session = _requireSession();
    if (session.usesExternalHostFolder) {
      if (item.type == 'folder') {
        await _webDavError(request, HttpStatus.methodNotAllowed);
        return;
      }
      await _hostFolderBridge.deleteFile(
        rootUri: session.hostFolderUri!,
        path: item.path,
      );
      _requestFolderUsageRescan();
    } else {
      final entity = _entityFromId(item.id, enforceGuestScope: true);
      if (entity is Directory) {
        await entity.delete(recursive: true);
      } else if (entity is File) {
        await entity.delete();
      }
      _invalidateStorageSnapshot();
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _webDavMove(HttpRequest request) async {
    final session = _requireSession();
    final destination = request.headers.value('Destination');
    if (destination == null) {
      await _webDavError(request, HttpStatus.badRequest);
      return;
    }
    final sourcePath = _webDavRoomPath(request.uri);
    final destinationPath = _webDavRoomPath(Uri.parse(destination));
    if (sourcePath == '/' || destinationPath == '/') {
      await _webDavError(request, HttpStatus.forbidden);
      return;
    }
    final sourceItem = await _webDavItem(sourcePath);
    if (sourceItem == null) {
      await _webDavError(request, HttpStatus.notFound);
      return;
    }
    final destinationParent = _parentRoomPath(destinationPath);
    final destinationParentItem = await _webDavItem(destinationParent);
    if (destinationParentItem?.type != 'folder') {
      await _webDavError(request, HttpStatus.conflict);
      return;
    }
    final destinationItem = await _webDavItem(destinationPath);
    final destinationExists = destinationItem != null;
    final overwrite = _webDavOverwrite(request);
    if (destinationExists && !overwrite) {
      await _webDavError(request, HttpStatus.preconditionFailed);
      return;
    }
    if (_isPathWithin(destinationPath, sourcePath)) {
      await _webDavError(request, HttpStatus.forbidden);
      return;
    }
    if (sourcePath == destinationPath) {
      request.response.statusCode = destinationExists
          ? HttpStatus.noContent
          : HttpStatus.created;
      await request.response.close();
      return;
    }
    if (session.usesExternalHostFolder) {
      await _moveExternalWebDavEntity(
        session: session,
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        destinationExists: destinationExists,
      );
      _requestFolderUsageRescan();
      request.response.statusCode = destinationExists
          ? HttpStatus.noContent
          : HttpStatus.created;
      await request.response.close();
      return;
    }
    await _moveLocalWebDavEntity(
      sourcePath: sourcePath,
      destinationPath: destinationPath,
      destinationExists: destinationExists,
    );
    _invalidateStorageSnapshot();
    request.response.statusCode = destinationExists
        ? HttpStatus.noContent
        : HttpStatus.created;
    await request.response.close();
  }

  Future<void> _moveExternalWebDavEntity({
    required DropRoomSession session,
    required String sourcePath,
    required String destinationPath,
    required bool destinationExists,
  }) async {
    final rootUri = session.hostFolderUri!;
    String? backupPath;
    if (destinationExists) {
      backupPath = await _webDavOverwriteBackupPath(destinationPath);
      await _hostFolderBridge.moveItem(
        rootUri: rootUri,
        path: _guestPathForRequest(destinationPath),
        destinationPath: _guestPathForRequest(backupPath),
      );
    }
    try {
      await _hostFolderBridge.moveItem(
        rootUri: rootUri,
        path: _guestPathForRequest(sourcePath),
        destinationPath: _guestPathForRequest(destinationPath),
      );
      if (backupPath != null) {
        try {
          await _hostFolderBridge.deleteFile(
            rootUri: rootUri,
            path: _guestPathForRequest(backupPath),
          );
        } catch (_) {
          // The requested MOVE has already succeeded. A leftover hidden backup
          // is better than turning a successful client operation into a failure.
        }
      }
    } catch (_) {
      if (backupPath != null && await _webDavItem(destinationPath) == null) {
        try {
          await _hostFolderBridge.moveItem(
            rootUri: rootUri,
            path: _guestPathForRequest(backupPath),
            destinationPath: _guestPathForRequest(destinationPath),
          );
        } catch (_) {
          // Preserve the original platform error for the WebDAV response.
        }
      }
      rethrow;
    }
  }

  Future<void> _moveLocalWebDavEntity({
    required String sourcePath,
    required String destinationPath,
    required bool destinationExists,
  }) async {
    final source = _entityFromId(
      _encodeId(sourcePath),
      enforceGuestScope: true,
    );
    if (!await source.exists()) {
      throw const FileSystemException('Source does not exist.');
    }
    final target = _resolveGuestRoomPath(destinationPath);
    FileSystemEntity? backup;
    if (destinationExists) {
      final existing = _entityFromId(
        _encodeId(destinationPath),
        enforceGuestScope: true,
      );
      backup = await _moveExistingDestinationAside(existing);
    }
    try {
      if (source is Directory) {
        await source.rename(target.path);
      } else if (source is File) {
        await source.rename(target.path);
      }
      if (backup != null && await backup.exists()) {
        if (backup is Directory) {
          await backup.delete(recursive: true);
        } else {
          await backup.delete();
        }
      }
    } catch (_) {
      if (backup != null && await backup.exists() && !await target.exists()) {
        if (backup is Directory) {
          await backup.rename(target.path);
        } else if (backup is File) {
          await backup.rename(target.path);
        }
      }
      rethrow;
    }
  }

  Future<String> _webDavOverwriteBackupPath(String destinationPath) async {
    final parent = _parentRoomPath(destinationPath);
    final name = _normalizeRoomPath(
      destinationPath,
    ).split('/').where((part) => part.isNotEmpty).last;
    var index = 0;
    while (true) {
      final candidateName =
          '.erebrus-move-overwrite-${DateTime.now().microsecondsSinceEpoch}-$index-$name';
      final candidatePath = parent == '/'
          ? '/$candidateName'
          : '$parent/$candidateName';
      if (await _webDavItem(candidatePath) == null) {
        return candidatePath;
      }
      index++;
    }
  }

  Future<FileSystemEntity> _moveExistingDestinationAside(
    FileSystemEntity existing,
  ) async {
    final parent = existing.parent;
    final name = _entityName(existing);
    var index = 0;
    while (true) {
      final candidatePath =
          '${parent.path}/.erebrus-move-overwrite-${DateTime.now().microsecondsSinceEpoch}-$index-$name';
      final candidateFile = File(candidatePath);
      final candidateDirectory = Directory(candidatePath);
      if (!await candidateFile.exists() && !await candidateDirectory.exists()) {
        if (existing is Directory) {
          return existing.rename(candidatePath);
        }
        return (existing as File).rename(candidatePath);
      }
      index++;
    }
  }

  Future<void> _webDavLock(HttpRequest request) async {
    final token = _randomToken(16);
    final xml =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>'
        '<D:locktype><D:write/></D:locktype>'
        '<D:lockscope><D:exclusive/></D:lockscope>'
        '<D:depth>0</D:depth><D:timeout>Second-3600</D:timeout>'
        '<D:locktoken><D:href>opaquelocktoken:$token</D:href></D:locktoken>'
        '</D:activelock></D:lockdiscovery></D:prop>';
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.set('Lock-Token', '<opaquelocktoken:$token>')
      ..headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      )
      ..write(xml);
    await request.response.close();
  }

  Future<void> _downloadPath(
    HttpRequest request,
    String path, {
    required bool asAttachment,
  }) async {
    final session = _requireSession();
    final guestPath = _guestPathForRequest(path);
    if (session.usesExternalHostFolder) {
      final cached = await _hostFolderBridge.copyFileToCache(
        rootUri: session.hostFolderUri!,
        path: guestPath,
      );
      final file = File(cached.path);
      try {
        await _downloadLocalFile(
          request,
          file,
          mimeType: cached.mimeType,
          fileName: cached.name,
          asAttachment: asAttachment,
        );
      } finally {
        if (await file.exists()) {
          await file.delete();
        }
      }
      return;
    }
    final entity = _entityFromId(_encodeId(guestPath), enforceGuestScope: true);
    if (entity is! File || !await entity.exists()) {
      await _webDavError(request, HttpStatus.notFound);
      return;
    }
    await _downloadLocalFile(
      request,
      entity,
      mimeType: _mimeType(entity.path),
      fileName: _entityName(entity),
      asAttachment: asAttachment,
    );
  }

  Future<DropFileItem?> _webDavItem(String path) async {
    final guestPath = _guestPathForRequest(path);
    if (guestPath == '/') {
      final session = _requireSession();
      return DropFileItem(
        id: _encodeId('/'),
        name: session.hostFolderName ?? 'Erebrus Drop',
        type: 'folder',
        path: '/',
        sizeBytes: 0,
        createdAt: session.createdAt,
        modifiedAt: DateTime.now(),
        mimeType: null,
        streamable: false,
      );
    }
    final session = _requireSession();
    if (session.usesExternalHostFolder) {
      final children = await listFiles(_parentRoomPath(guestPath));
      for (final item in children) {
        if (item.path == guestPath) return item;
      }
      return null;
    }
    final entity = _entityFromId(_encodeId(guestPath), enforceGuestScope: true);
    if (!await entity.exists()) return null;
    return _itemFromEntity(entity);
  }

  String _webDavResponseXml(DropFileItem item) {
    final isFolder = item.type == 'folder';
    final href = _webDavHref(item.path, isFolder: isFolder);
    final modified = HttpDate.format(item.modifiedAt.toUtc());
    final contentType = item.mimeType ?? 'application/octet-stream';
    return '<D:response>'
        '<D:href>${_xmlEscape(href)}</D:href>'
        '<D:propstat><D:prop>'
        '<D:displayname>${_xmlEscape(item.name)}</D:displayname>'
        '<D:resourcetype>${isFolder ? '<D:collection/>' : ''}</D:resourcetype>'
        '<D:getlastmodified>${_xmlEscape(modified)}</D:getlastmodified>'
        '${isFolder ? '' : '<D:getcontentlength>${item.sizeBytes}</D:getcontentlength>'}'
        '${isFolder ? '' : '<D:getcontenttype>${_xmlEscape(contentType)}</D:getcontenttype>'}'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
        '</D:response>';
  }

  String _webDavHref(String path, {required bool isFolder}) {
    final normalized = _normalizeRoomPath(path);
    final suffix = normalized == '/'
        ? ''
        : normalized
              .split('/')
              .where((part) => part.isNotEmpty)
              .map(Uri.encodeComponent)
              .join('/');
    final href = suffix.isEmpty ? '/dav/' : '/dav/$suffix';
    return isFolder && !href.endsWith('/') ? '$href/' : href;
  }

  String _webDavRoomPath(Uri uri) {
    final segments = uri.pathSegments;
    if (segments.isEmpty || segments.first != 'dav') {
      throw const FileSystemException('WebDAV path is outside /dav.');
    }
    final roomSegments = <String>[];
    for (final segment in segments.skip(1)) {
      if (segment.isEmpty) continue;
      if (segment == '.' ||
          segment == '..' ||
          segment.contains('/') ||
          segment.contains('\\') ||
          segment.contains('\u0000')) {
        throw const FileSystemException('WebDAV path is forbidden.');
      }
      final safe = _sanitizeName(segment);
      if (safe.isEmpty) {
        throw const FileSystemException('WebDAV path is forbidden.');
      }
      roomSegments.add(safe);
    }
    return roomSegments.isEmpty ? '/' : '/${roomSegments.join('/')}';
  }

  String _parentRoomPath(String path) {
    final parts = _normalizeRoomPath(
      path,
    ).split('/').where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) return '/';
    parts.removeLast();
    return parts.isEmpty ? '/' : '/${parts.join('/')}';
  }

  bool _isWebDavAuthorized(HttpRequest request) {
    if (_isAuthorized(request)) return true;
    final passwordRecord = _passwordRecord;
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (passwordRecord == null) return true;
    if (header == null || !header.startsWith('Basic ')) return false;
    try {
      final decoded = utf8.decode(base64.decode(header.substring(6).trim()));
      final separator = decoded.indexOf(':');
      final password = separator < 0
          ? decoded
          : decoded.substring(separator + 1);
      return passwordRecord.matches(password);
    } catch (_) {
      return false;
    }
  }

  bool _webDavOverwrite(HttpRequest request) {
    final value = request.headers.value('Overwrite')?.trim().toUpperCase();
    return value == null || value == 'T';
  }

  bool _isPathWithin(String candidatePath, String parentPath) {
    final candidate = _normalizeRoomPath(candidatePath);
    final parent = _normalizeRoomPath(parentPath);
    return parent != '/' && candidate.startsWith('$parent/');
  }

  Future<void> _webDavError(HttpRequest request, int statusCode) async {
    request.response
      ..statusCode = statusCode
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    await request.response.close();
  }

  String _xmlEscape(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  Future<List<_ZipEntry>> _zipEntriesForIds(
    List<String> ids,
    List<File> cachedFiles,
  ) async {
    final session = _requireSession();
    final entries = <_ZipEntry>[];
    if (session.usesExternalHostFolder) {
      for (final id in ids) {
        final path = _decodeId(id);
        _guestPathForRequest(path);
        await _collectExternalZipEntries(
          path: path,
          zipPrefix: _zipRootName(path),
          entries: entries,
          cachedFiles: cachedFiles,
        );
      }
      return entries;
    }

    for (final id in ids) {
      final entity = _entityFromId(id, enforceGuestScope: true);
      if (entity is File && await entity.exists()) {
        entries.add(_ZipEntry(path: _entityName(entity), file: entity));
      } else if (entity is Directory && await entity.exists()) {
        await _collectLocalZipEntries(
          directory: entity,
          zipPrefix: _entityName(entity),
          entries: entries,
        );
      }
    }
    return entries;
  }

  Future<void> _collectExternalZipEntries({
    required String path,
    required String zipPrefix,
    required List<_ZipEntry> entries,
    required List<File> cachedFiles,
  }) async {
    final session = _requireSession();
    try {
      final children = await _hostFolderBridge.list(
        rootUri: session.hostFolderUri!,
        path: path,
      );
      for (final child in children) {
        final childZipPath = '$zipPrefix/${_sanitizeName(child.name)}';
        if (child.type == 'folder') {
          await _collectExternalZipEntries(
            path: child.path,
            zipPrefix: childZipPath,
            entries: entries,
            cachedFiles: cachedFiles,
          );
        } else {
          final cached = await _hostFolderBridge.copyFileToCache(
            rootUri: session.hostFolderUri!,
            path: child.path,
          );
          final file = File(cached.path);
          cachedFiles.add(file);
          entries.add(_ZipEntry(path: childZipPath, file: file));
        }
      }
    } on PlatformException {
      final cached = await _hostFolderBridge.copyFileToCache(
        rootUri: session.hostFolderUri!,
        path: path,
      );
      final file = File(cached.path);
      cachedFiles.add(file);
      entries.add(_ZipEntry(path: _zipRootName(path), file: file));
    }
  }

  Future<void> _collectLocalZipEntries({
    required Directory directory,
    required String zipPrefix,
    required List<_ZipEntry> entries,
  }) async {
    await for (final entity in directory.list(followLinks: false)) {
      final name = _entityName(entity);
      if (name.startsWith('.') || name.endsWith('.part')) continue;
      final zipPath = '$zipPrefix/$name';
      if (entity is Directory) {
        await _collectLocalZipEntries(
          directory: entity,
          zipPrefix: zipPath,
          entries: entries,
        );
      } else if (entity is File) {
        entries.add(_ZipEntry(path: zipPath, file: entity));
      }
    }
  }

  String _zipRootName(String path) {
    final parts = _normalizeRoomPath(
      path,
    ).split('/').where((part) => part.isNotEmpty);
    return parts.isEmpty ? 'Drop Folder' : _sanitizeName(parts.last);
  }

  Future<void> _writeZipFile(File target, List<_ZipEntry> entries) async {
    final writer = _ZipFileWriter(target);
    await writer.open();
    try {
      for (final entry in entries) {
        await writer.addFile(entry.path, entry.file);
      }
      await writer.close();
    } catch (_) {
      await writer.abort();
      rethrow;
    }
  }

  Future<void> _serverPull(HttpRequest request) async {
    final body = await _readJson(request);
    final sourceBaseUrl = body['sourceBaseUrl']?.toString() ?? '';
    final sourceToken = body['sourceToken']?.toString() ?? '';
    final itemJson = body['item'];
    if (sourceBaseUrl.isEmpty || itemJson is! Map) {
      await _json(request, {
        'error': 'sourceBaseUrl and item are required.',
      }, statusCode: HttpStatus.badRequest);
      return;
    }
    final item = DropFileItem.fromJson(itemJson.cast<String, Object?>());
    await pullFileFromRoom(
      sourceBaseUrl: sourceBaseUrl,
      sourceToken: sourceToken,
      item: item,
      destinationPath: body['destinationPath']?.toString() ?? '/',
    );
    await _json(request, {'ok': true}, statusCode: HttpStatus.created);
  }

  Future<void> _serverPush(HttpRequest request) async {
    final body = await _readJson(request);
    final targetBaseUrl = body['targetBaseUrl']?.toString() ?? '';
    final targetToken = body['targetToken']?.toString() ?? '';
    final itemId = body['itemId']?.toString() ?? '';
    if (targetBaseUrl.isEmpty || itemId.isEmpty) {
      await _json(request, {
        'error': 'targetBaseUrl and itemId are required.',
      }, statusCode: HttpStatus.badRequest);
      return;
    }
    final entity = _entityFromId(itemId, enforceGuestScope: true);
    if (entity is! File || !await entity.exists()) {
      await _notFound(request);
      return;
    }
    final item = await _itemFromEntity(entity);
    await pushFileToRoom(
      item: item,
      targetBaseUrl: targetBaseUrl,
      targetToken: targetToken,
      destinationPath: body['destinationPath']?.toString() ?? '/',
    );
    await _json(request, {'ok': true}, statusCode: HttpStatus.created);
  }

  Future<void> _downloadLocalFile(
    HttpRequest request,
    File entity, {
    required String mimeType,
    required String fileName,
    required bool asAttachment,
  }) async {
    final stat = await entity.stat();
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final response = request.response;
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = ContentType.parse(mimeType)
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    if (asAttachment) {
      response.headers.set(
        HttpHeaders.contentDisposition,
        'attachment; filename="$fileName"',
      );
    }

    var start = 0;
    var end = stat.size - 1;
    if (range != null && range.startsWith('bytes=')) {
      final parts = range.substring(6).split('-');
      start = int.tryParse(parts.first) ?? 0;
      if (parts.length > 1 && parts[1].isNotEmpty) {
        end = int.tryParse(parts[1]) ?? end;
      }
      end = min(end, stat.size - 1);
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${stat.size}',
        );
    } else {
      response.statusCode = HttpStatus.ok;
    }

    final length = max(0, end - start + 1);
    response.contentLength = length;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    final stream = entity.openRead(start, end + 1);
    await response.addStream(stream);
    await response.close();
  }

  Future<void> _renameEntity(HttpRequest request, String id) async {
    final entity = _entityFromId(id, enforceGuestScope: true);
    final body = await _readJson(request);
    final newName = _sanitizeName(body['name']?.toString() ?? '');
    if (newName.isEmpty) {
      await _json(request, {
        'error': 'Choose a file or folder name.',
      }, statusCode: HttpStatus.badRequest);
      return;
    }
    final parent = entity.parent;
    final nextPath = '${parent.path}/$newName';
    if (entity is File) {
      await entity.rename(nextPath);
    } else if (entity is Directory) {
      await entity.rename(nextPath);
    }
    await _json(request, {'ok': true});
  }

  Map<String, Object?> _roomJson() {
    final session = _requireSession();
    return {
      'roomId': session.id,
      'roomName': session.name,
      'deviceName': session.deviceName,
      'devicePlatform': Platform.operatingSystem,
      'deviceType': Platform.isAndroid || Platform.isIOS ? 'phone' : 'desktop',
      'authRequired': session.authRequired,
      'permissions': session.permission.apiValues,
      'serverVersion': '1.0.0',
      'baseUrl': session.baseUrl,
      'defaultUploadPath': session.defaultUploadPath,
      'hostFolderName': session.hostFolderName,
      'hostFolderPlatform': session.hostFolderPlatform,
      'storageSource': session.usesExternalHostFolder
          ? 'external'
          : 'appManaged',
      'scopePath': session.permission == RoomPermission.dropFolderOnly
          ? session.defaultUploadPath
          : '/',
      'scopedToDefaultFolder':
          session.permission == RoomPermission.dropFolderOnly,
      'capabilities': {
        'upload': true,
        'multipartUpload': true,
        'download': true,
        'bundleDownload': true,
        'folders': true,
        'streaming': true,
        'text': true,
        'webdav': true,
        'ocr': false,
        'serverToServer': true,
      },
      'webdavUrl': '${session.baseUrl}/dav',
    };
  }

  Map<String, Object?> _authJson(String token) {
    final session = _requireSession();
    final expiresAt = _tokens[token]!;
    return {
      'token': token,
      'expiresAt': expiresAt.toIso8601String(),
      'permissions': session.permission.apiValues,
      'scopePath': session.permission == RoomPermission.dropFolderOnly
          ? session.defaultUploadPath
          : '/',
    };
  }

  bool _isAuthorized(HttpRequest request) {
    if (_passwordRecord == null) {
      return true;
    }
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    final tokenFromHeader = header != null && header.startsWith('Bearer ')
        ? header.substring(7)
        : null;
    final token =
        tokenFromHeader ??
        request.headers.value('x-drop-token') ??
        request.uri.queryParameters['token'];
    if (token == null) {
      return false;
    }
    final expiresAt = _tokens[token];
    if (expiresAt == null || DateTime.now().isAfter(expiresAt)) {
      _tokens.remove(token);
      return false;
    }
    return true;
  }

  String _issueToken() {
    final token = _randomToken(32);
    _tokens[token] = DateTime.now().add(const Duration(hours: 2));
    return token;
  }

  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    if (body.trim().isEmpty) {
      return <String, Object?>{};
    }
    final decoded = jsonDecode(body);
    return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
  }

  Future<void> _json(
    HttpRequest request,
    Map<String, Object?> body, {
    int statusCode = HttpStatus.ok,
  }) async {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _unauthorized(HttpRequest request) {
    return _json(request, {
      'error': 'This Drop Room needs a valid session. Log in again.',
    }, statusCode: HttpStatus.unauthorized);
  }

  Future<void> _notFound(HttpRequest request) {
    return _json(request, {
      'error': 'That Drop Room item was not found.',
    }, statusCode: HttpStatus.notFound);
  }

  DropRoomSession _requireSession() {
    final session = _session;
    if (session == null) {
      throw StateError('Drop Room is not running');
    }
    return session;
  }

  Future<int> _directorySize(Directory directory) async {
    if (!await directory.exists()) {
      return 0;
    }
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        final name = _entityName(entity);
        if (name.startsWith('.') || name.endsWith('.part')) {
          continue;
        }
        try {
          total += await entity.length();
        } on FileSystemException {
          // Upload temp files can disappear between list() and length().
          continue;
        }
      }
    }
    return total;
  }

  Future<DropFileItem> _itemFromEntity(FileSystemEntity entity) async {
    final stat = await entity.stat();
    final isDirectory = entity is Directory;
    final name = _entityName(entity);
    final id = isDirectory
        ? _idForDirectory(entity)
        : _idForFile(entity as File);
    final mimeType = isDirectory ? null : _mimeType(entity.path);
    return DropFileItem(
      id: id,
      name: name,
      type: isDirectory ? 'folder' : 'file',
      path: _relativeRoomPath(entity),
      sizeBytes: isDirectory ? 0 : stat.size,
      createdAt: stat.changed,
      modifiedAt: stat.modified,
      mimeType: mimeType,
      streamable:
          mimeType?.startsWith('video/') == true ||
          mimeType?.startsWith('audio/') == true,
    );
  }

  DropFileItem _itemFromHostFolderItem(HostFolderItem item) {
    final isDirectory = item.type == 'folder';
    final mimeType = isDirectory ? null : item.mimeType ?? _mimeType(item.name);
    return DropFileItem(
      id: _encodeId(item.path),
      name: item.name,
      type: isDirectory ? 'folder' : 'file',
      path: _normalizeRoomPath(item.path),
      sizeBytes: isDirectory ? 0 : item.sizeBytes,
      createdAt: item.modifiedAt,
      modifiedAt: item.modifiedAt,
      mimeType: mimeType,
      streamable:
          mimeType?.startsWith('video/') == true ||
          mimeType?.startsWith('audio/') == true,
    );
  }

  Future<File> _writeTempTextFile({
    required String title,
    required String body,
  }) async {
    final tempDirectory = await getTemporaryDirectory();
    final textDirectory = Directory('${tempDirectory.path}/ErebrusDropText');
    await textDirectory.create(recursive: true);
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final safeTitle = _sanitizeName(title.isEmpty ? 'Text snippet' : title);
    final file = File('${textDirectory.path}/$timestamp-$safeTitle.txt');
    await file.writeAsString(body);
    return file;
  }

  Future<File> _tempUploadFile(String name) async {
    final tempDirectory = await getTemporaryDirectory();
    final tempUploadDirectory = Directory(
      '${tempDirectory.path}/ErebrusDropUploads',
    );
    await tempUploadDirectory.create(recursive: true);
    return _uniqueFile(
      tempUploadDirectory,
      '.${DateTime.now().microsecondsSinceEpoch}-${_sanitizeName(name)}.part',
    );
  }

  Future<void> _writeRequestToFile(HttpRequest request, File target) async {
    var received = 0;
    final sink = target.openWrite();
    try {
      await for (final chunk in request) {
        received += chunk.length;
        if (received > defaultMaxUploadBytes) {
          throw const FileSystemException('Upload exceeds max room size');
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
  }

  List<_MultipartPart> _parseMultipartBody(Uint8List body, String boundary) {
    final marker = utf8.encode('--$boundary');
    final parts = <_MultipartPart>[];
    var index = _indexOfBytes(body, marker, 0);
    while (index >= 0) {
      var partStart = index + marker.length;
      if (partStart + 1 < body.length &&
          body[partStart] == 45 &&
          body[partStart + 1] == 45) {
        break;
      }
      if (partStart + 1 < body.length &&
          body[partStart] == 13 &&
          body[partStart + 1] == 10) {
        partStart += 2;
      }
      final next = _indexOfBytes(body, marker, partStart);
      if (next < 0) break;
      var partEnd = next;
      if (partEnd >= 2 && body[partEnd - 2] == 13 && body[partEnd - 1] == 10) {
        partEnd -= 2;
      }
      final separator = _indexOfBytes(body, const [13, 10, 13, 10], partStart);
      if (separator >= 0 && separator < partEnd) {
        final headerBytes = body.sublist(partStart, separator);
        final dataStart = separator + 4;
        final headers = _parseMultipartHeaders(latin1.decode(headerBytes));
        parts.add(
          _MultipartPart(
            headers: headers,
            body: body.sublist(dataStart, partEnd),
          ),
        );
      }
      index = next;
    }
    return parts;
  }

  Map<String, String> _parseMultipartHeaders(String rawHeaders) {
    final headers = <String, String>{};
    for (final line in rawHeaders.split('\r\n')) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      headers[line.substring(0, separator).trim().toLowerCase()] = line
          .substring(separator + 1)
          .trim();
    }
    return headers;
  }

  String? _multipartHeader(Map<String, String> headers, String name) {
    return headers[name.toLowerCase()];
  }

  Map<String, String> _headerParameters(String? header) {
    final parameters = <String, String>{};
    if (header == null) return parameters;
    for (final segment in header.split(';').skip(1)) {
      final separator = segment.indexOf('=');
      if (separator <= 0) continue;
      final key = segment.substring(0, separator).trim().toLowerCase();
      var value = segment.substring(separator + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      parameters[key] = value;
    }
    return parameters;
  }

  int _indexOfBytes(List<int> haystack, List<int> needle, int start) {
    if (needle.isEmpty || haystack.length < needle.length) return -1;
    for (var index = start; index <= haystack.length - needle.length; index++) {
      var matched = true;
      for (var offset = 0; offset < needle.length; offset++) {
        if (haystack[index + offset] != needle[offset]) {
          matched = false;
          break;
        }
      }
      if (matched) return index;
    }
    return -1;
  }

  Future<File> _uniqueFile(Directory directory, String requestedName) async {
    final safe = _sanitizeName(requestedName).isEmpty
        ? 'download'
        : _sanitizeName(requestedName);
    final dot = safe.lastIndexOf('.');
    final base = dot > 0 ? safe.substring(0, dot) : safe;
    final extension = dot > 0 ? safe.substring(dot) : '';
    var candidate = File('${directory.path}/$safe');
    var index = 1;
    while (await candidate.exists()) {
      candidate = File('${directory.path}/$base-$index$extension');
      index++;
    }
    return candidate;
  }

  FileSystemEntity _entityFromId(String id, {bool enforceGuestScope = false}) {
    final path = _decodeId(id);
    final resolvedPath = enforceGuestScope
        ? _resolveGuestRoomPath(path).path
        : _resolveRoomPath(path).path;
    final directory = Directory(resolvedPath);
    if (directory.existsSync()) {
      return directory;
    }
    return File(resolvedPath);
  }

  String _idForFile(File file) => _encodeId(_relativeRoomPath(file));

  String _idForDirectory(Directory directory) =>
      _encodeId(_relativeRoomPath(directory));

  String _encodeId(String path) {
    return base64Url.encode(utf8.encode(path)).replaceAll('=', '');
  }

  String _decodeId(String id) {
    final padding = '=' * ((4 - id.length % 4) % 4);
    return utf8.decode(base64Url.decode('$id$padding'));
  }

  File _resolveRoomPath(String requestedPath) {
    final session = _requireSession();
    final normalized = _normalizeRoomPath(requestedPath);
    final withoutLeadingSlash = normalized == '/'
        ? ''
        : normalized.substring(1);
    final target = File('${session.roomDirectory.path}/$withoutLeadingSlash');
    final rootPath = session.roomDirectory.absolute.path;
    final targetPath = target.absolute.path;
    if (requestedPath.contains('..') ||
        targetPath != rootPath && !targetPath.startsWith('$rootPath/')) {
      throw const FileSystemException('Path is outside this Drop Room');
    }
    return target;
  }

  File _resolveGuestRoomPath(String requestedPath) {
    return _resolveRoomPath(_guestPathForRequest(requestedPath));
  }

  String _guestPathForRequest(String requestedPath) {
    final session = _requireSession();
    final normalized = _normalizeRoomPath(requestedPath);
    if (session.permission != RoomPermission.dropFolderOnly) {
      return normalized;
    }
    final scope = session.defaultUploadPath;
    if (scope == '/') {
      return normalized;
    }
    if (normalized == '/') {
      return scope;
    }
    if (normalized == scope || normalized.startsWith('$scope/')) {
      return normalized;
    }
    throw const FileSystemException(
      'Guests can only access the host selected drop folder',
    );
  }

  String _normalizeRoomPath(String input) {
    final clean = input.trim().isEmpty ? '/' : input.trim();
    final parts = clean
        .split('/')
        .where((part) => part.isNotEmpty && part != '.' && part != '..')
        .map(_sanitizeName)
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? '/' : '/${parts.join('/')}';
  }

  String _relativeRoomPath(FileSystemEntity entity) {
    final root = _requireSession().roomDirectory.absolute.path;
    final path = entity.absolute.path;
    if (path == root) {
      return '/';
    }
    return path.substring(root.length).replaceAll('\\', '/');
  }

  String _sanitizeName(String name) {
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _entityName(FileSystemEntity entity) {
    return entity.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
  }

  String _mimeType(String path) {
    final extension = path.split('.').last.toLowerCase();
    switch (extension) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
      case 'log':
      case 'md':
        return 'text/plain';
      case 'html':
        return 'text/html';
      case 'json':
        return 'application/json';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'm4v':
        return 'video/x-m4v';
      case 'webm':
        return 'video/webm';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  String _randomToken(int byteLength) {
    final random = Random.secure();
    final bytes = List<int>.generate(byteLength, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  void _invalidateStorageSnapshot() {
    _lastStorageSnapshot = null;
    _lastStorageSnapshotAt = null;
  }
}

class _ZipEntry {
  const _ZipEntry({required this.path, required this.file});

  final String path;
  final File file;
}

class _MultipartPart {
  const _MultipartPart({required this.headers, required this.body});

  final Map<String, String> headers;
  final Uint8List body;
}

class _ZipCentralRecord {
  const _ZipCentralRecord({
    required this.path,
    required this.crc32,
    required this.size,
    required this.offset,
  });

  final String path;
  final int crc32;
  final int size;
  final int offset;
}

class _ZipFileWriter {
  _ZipFileWriter(this.file);

  final File file;
  final List<_ZipCentralRecord> _records = <_ZipCentralRecord>[];
  RandomAccessFile? _raf;
  int _offset = 0;
  bool _closed = false;

  Future<void> open() async {
    _raf = await file.open(mode: FileMode.write);
  }

  Future<void> addFile(String path, File source) async {
    final normalizedPath = path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.trim().isNotEmpty)
        .join('/');
    if (normalizedPath.isEmpty) return;

    final stat = await source.stat();
    final size = stat.size;
    if (size > 0xffffffff) {
      throw const FileSystemException('ZIP64 bundles are not supported.');
    }
    final crc = await _ZipCrc32.file(source);
    final nameBytes = utf8.encode(normalizedPath);
    final localOffset = _offset;
    await _write(_zipLocalHeader(nameBytes, crc, size));
    await for (final chunk in source.openRead()) {
      await _write(chunk);
    }
    _records.add(
      _ZipCentralRecord(
        path: normalizedPath,
        crc32: crc,
        size: size,
        offset: localOffset,
      ),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    final centralStart = _offset;
    for (final record in _records) {
      await _write(_zipCentralHeader(record));
    }
    final centralSize = _offset - centralStart;
    await _write(_zipEndRecord(_records.length, centralSize, centralStart));
    _closed = true;
    await _raf?.close();
  }

  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    await _raf?.close();
  }

  Future<void> _write(List<int> bytes) async {
    await _raf!.writeFrom(bytes);
    _offset += bytes.length;
  }

  Uint8List _zipLocalHeader(List<int> nameBytes, int crc, int size) {
    final bytes = Uint8List(30 + nameBytes.length);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, 0x04034b50, Endian.little);
    data.setUint16(4, 20, Endian.little);
    data.setUint16(6, 0x0800, Endian.little);
    data.setUint16(8, 0, Endian.little);
    data.setUint16(10, 0, Endian.little);
    data.setUint16(12, 0, Endian.little);
    data.setUint32(14, crc, Endian.little);
    data.setUint32(18, size, Endian.little);
    data.setUint32(22, size, Endian.little);
    data.setUint16(26, nameBytes.length, Endian.little);
    data.setUint16(28, 0, Endian.little);
    bytes.setRange(30, 30 + nameBytes.length, nameBytes);
    return bytes;
  }

  Uint8List _zipCentralHeader(_ZipCentralRecord record) {
    final nameBytes = utf8.encode(record.path);
    final bytes = Uint8List(46 + nameBytes.length);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, 0x02014b50, Endian.little);
    data.setUint16(4, 20, Endian.little);
    data.setUint16(6, 20, Endian.little);
    data.setUint16(8, 0x0800, Endian.little);
    data.setUint16(10, 0, Endian.little);
    data.setUint16(12, 0, Endian.little);
    data.setUint16(14, 0, Endian.little);
    data.setUint32(16, record.crc32, Endian.little);
    data.setUint32(20, record.size, Endian.little);
    data.setUint32(24, record.size, Endian.little);
    data.setUint16(28, nameBytes.length, Endian.little);
    data.setUint16(30, 0, Endian.little);
    data.setUint16(32, 0, Endian.little);
    data.setUint16(34, 0, Endian.little);
    data.setUint16(36, 0, Endian.little);
    data.setUint32(38, 0, Endian.little);
    data.setUint32(42, record.offset, Endian.little);
    bytes.setRange(46, 46 + nameBytes.length, nameBytes);
    return bytes;
  }

  Uint8List _zipEndRecord(int count, int centralSize, int centralOffset) {
    final bytes = Uint8List(22);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, 0x06054b50, Endian.little);
    data.setUint16(4, 0, Endian.little);
    data.setUint16(6, 0, Endian.little);
    data.setUint16(8, count, Endian.little);
    data.setUint16(10, count, Endian.little);
    data.setUint32(12, centralSize, Endian.little);
    data.setUint32(16, centralOffset, Endian.little);
    data.setUint16(20, 0, Endian.little);
    return bytes;
  }
}

class _ZipCrc32 {
  static final List<int> _table = List<int>.generate(256, (index) {
    var value = index;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1;
    }
    return value;
  });

  static Future<int> file(File file) async {
    var crc = 0xffffffff;
    await for (final chunk in file.openRead()) {
      for (final byte in chunk) {
        crc = _table[(crc ^ byte) & 0xff] ^ (crc >> 8);
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }
}

class _FolderUsageCache {
  const _FolderUsageCache({
    required this.rootUri,
    required this.usedBytes,
    required this.fileCount,
    required this.folderCount,
    required this.status,
    required this.updatedAt,
    this.scannedAt,
    this.message,
  });

  final String rootUri;
  final int? usedBytes;
  final int fileCount;
  final int folderCount;
  final String status;
  final DateTime updatedAt;
  final DateTime? scannedAt;
  final String? message;

  _FolderUsageCache copyWith({
    int? usedBytes,
    int? fileCount,
    int? folderCount,
    String? status,
    DateTime? updatedAt,
    DateTime? scannedAt,
    String? message,
  }) {
    return _FolderUsageCache(
      rootUri: rootUri,
      usedBytes: usedBytes ?? this.usedBytes,
      fileCount: fileCount ?? this.fileCount,
      folderCount: folderCount ?? this.folderCount,
      status: status ?? this.status,
      updatedAt: updatedAt ?? this.updatedAt,
      scannedAt: scannedAt ?? this.scannedAt,
      message: message ?? this.message,
    );
  }
}

class _PasswordRecord {
  _PasswordRecord({
    required this.salt,
    required this.hash,
    required this.iterations,
  });

  factory _PasswordRecord.create(String password) {
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    const iterations = 120000;
    return _PasswordRecord(
      salt: salt,
      iterations: iterations,
      hash: _pbkdf2(password, salt, iterations),
    );
  }

  final Uint8List salt;
  final Uint8List hash;
  final int iterations;

  bool matches(String password) {
    final candidate = _pbkdf2(password, salt, iterations);
    if (candidate.length != hash.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < hash.length; i++) {
      diff |= hash[i] ^ candidate[i];
    }
    return diff == 0;
  }

  static Uint8List _pbkdf2(String password, Uint8List salt, int iterations) {
    const keyLength = 32;
    final hmac = Hmac(sha256, utf8.encode(password));
    final block = Uint8List(salt.length + 4)
      ..setAll(0, salt)
      ..buffer.asByteData().setUint32(salt.length, 1, Endian.big);
    var digest = Uint8List.fromList(hmac.convert(block).bytes);
    final result = Uint8List.fromList(digest);
    for (var i = 1; i < iterations; i++) {
      digest = Uint8List.fromList(hmac.convert(digest).bytes);
      for (var j = 0; j < result.length; j++) {
        result[j] ^= digest[j];
      }
    }
    return Uint8List.sublistView(result, 0, keyLength);
  }
}
