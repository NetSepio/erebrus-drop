import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/drop_models.dart';
import '../core/platform_network.dart';

class DropServer {
  static const int defaultPort = 8787;
  static const int lastFallbackPort = 8799;
  static const int defaultMaxUploadBytes = 2 * 1024 * 1024 * 1024;

  HttpServer? _server;
  DropRoomSession? _session;
  Directory? _dropDirectory;
  _PasswordRecord? _passwordRecord;
  StorageSnapshot? _lastStorageSnapshot;
  DateTime? _lastStorageSnapshotAt;
  Future<StorageSnapshot>? _storageSnapshotInFlight;
  final Map<String, DateTime> _tokens = <String, DateTime>{};

  DropRoomSession? get session => _session;

  bool get isRunning => _server != null;

  Future<DropRoomSession> start(DropRoomConfig config) async {
    if (_server != null) {
      return _session!;
    }

    final documents = await getApplicationDocumentsDirectory();
    final dropDirectory = Directory('${documents.path}/ErebrusDrop');
    final roomDirectory = Directory('${dropDirectory.path}/CurrentRoom');
    await roomDirectory.create(recursive: true);
    await _ensureDefaultFolders(roomDirectory);

    final localIp = await PlatformNetwork.bestLocalIp();
    final server = await _bindServer();
    final port = server.port;
    final createdAt = DateTime.now();
    final expiresAt = config.expiry == null
        ? null
        : createdAt.add(config.expiry!);

    _dropDirectory = dropDirectory;
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
    );

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
    await server?.close(force: true);
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
    final roomDirectory = _session?.roomDirectory;
    final storageStats = await PlatformNetwork.getStorageStats();
    return StorageSnapshot(
      dropUsedBytes: dropDirectory == null
          ? 0
          : await _directorySize(dropDirectory),
      roomUsedBytes: roomDirectory == null
          ? 0
          : await _directorySize(roomDirectory),
      availableBytes: storageStats['availableBytes'],
      totalBytes: storageStats['totalBytes'],
      maxUploadBytes: defaultMaxUploadBytes,
    );
  }

  Future<File> saveTextSnippet({
    required String title,
    required String body,
    String source = 'manual',
    String folderPath = '/Text',
  }) async {
    final textDirectory = Directory(_resolveRoomPath(folderPath).path);
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
        final folderPath = body['path']?.toString() ?? '/Inbox/New Folder';
        await Directory(
          _resolveGuestRoomPath(folderPath).path,
        ).create(recursive: true);
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
          folderPath: session.permission == RoomPermission.dropFolderOnly
              ? session.defaultUploadPath
              : '/Text',
        );
        await _json(request, {'ok': true, 'id': _idForFile(file)});
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
    final name = _sanitizeName(
      request.uri.queryParameters['name'] ??
          'upload-${DateTime.now().millisecondsSinceEpoch}',
    );
    final directory = Directory(_resolveGuestRoomPath(destinationPath).path);
    await directory.create(recursive: true);
    final target = File('${directory.path}/$name');
    final temp = File('${directory.path}/.$name.part');
    final contentLength = request.contentLength;
    if (contentLength > defaultMaxUploadBytes) {
      await _json(request, {
        'error': 'This file is larger than the room upload limit.',
      }, statusCode: HttpStatus.requestEntityTooLarge);
      return;
    }
    var received = 0;
    final sink = temp.openWrite();
    try {
      await for (final chunk in request) {
        received += chunk.length;
        if (received > defaultMaxUploadBytes) {
          throw const FileSystemException('Upload exceeds max room size');
        }
        sink.add(chunk);
      }
      await sink.close();
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(target.path);
    } catch (_) {
      await sink.close();
      if (await temp.exists()) {
        await temp.delete();
      }
      rethrow;
    }

    _invalidateStorageSnapshot();
    await _json(request, {
      'ok': true,
      'item': (await _itemFromEntity(target)).toJson(),
    }, statusCode: HttpStatus.created);
  }

  Future<void> _downloadFile(
    HttpRequest request,
    String id, {
    required bool asAttachment,
  }) async {
    final entity = _entityFromId(id, enforceGuestScope: true);
    if (entity is! File || !await entity.exists()) {
      await _notFound(request);
      return;
    }
    final stat = await entity.stat();
    final mimeType = _mimeType(entity.path);
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final response = request.response;
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = ContentType.parse(mimeType)
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    if (asAttachment) {
      response.headers.set(
        HttpHeaders.contentDisposition,
        'attachment; filename="${_entityName(entity)}"',
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
      'authRequired': session.authRequired,
      'permissions': session.permission.apiValues,
      'serverVersion': '1.0.0',
      'baseUrl': session.baseUrl,
      'defaultUploadPath': session.defaultUploadPath,
      'scopePath': session.permission == RoomPermission.dropFolderOnly
          ? session.defaultUploadPath
          : '/',
      'scopedToDefaultFolder':
          session.permission == RoomPermission.dropFolderOnly,
      'capabilities': {
        'upload': true,
        'download': true,
        'folders': true,
        'streaming': true,
        'text': true,
        'ocr': false,
        'serverToServer': false,
      },
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

  Future<void> _ensureDefaultFolders(Directory roomDirectory) async {
    const folders = [
      'Inbox',
      'Screenshots',
      'Text',
      'Media',
      'Documents',
      'Shared',
    ];
    for (final folder in folders) {
      await Directory('${roomDirectory.path}/$folder').create(recursive: true);
    }
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

  FileSystemEntity _entityFromId(String id, {bool enforceGuestScope = false}) {
    final path = _decodeId(id);
    return File(
      enforceGuestScope
          ? _resolveGuestRoomPath(path).path
          : _resolveRoomPath(path).path,
    );
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
