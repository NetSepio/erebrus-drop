import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/drop_models.dart';
import '../../core/platform_downloads.dart';

class JoinRoomException implements Exception {
  const JoinRoomException(this.message);

  final String message;

  @override
  String toString() => message;
}

class JoinRoomPreview {
  const JoinRoomPreview({
    required this.baseUrl,
    required this.roomId,
    required this.roomName,
    required this.deviceName,
    required this.devicePlatform,
    required this.deviceType,
    required this.authRequired,
    required this.defaultUploadPath,
    required this.scopePath,
    required this.scopedToDefaultFolder,
    required this.capabilities,
  });

  final String baseUrl;
  final String roomId;
  final String roomName;
  final String deviceName;
  final String devicePlatform;
  final String deviceType;
  final bool authRequired;
  final String defaultUploadPath;
  final String scopePath;
  final bool scopedToDefaultFolder;
  final Map<String, Object?> capabilities;

  factory JoinRoomPreview.fromJson(String baseUrl, Map<String, Object?> json) {
    return JoinRoomPreview(
      baseUrl: baseUrl,
      roomId: json['roomId']?.toString() ?? '',
      roomName: json['roomName']?.toString() ?? 'Drop Room',
      deviceName: json['deviceName']?.toString() ?? 'Nearby device',
      devicePlatform:
          json['devicePlatform']?.toString() ??
          json['platform']?.toString() ??
          '',
      deviceType: json['deviceType']?.toString() ?? '',
      authRequired: json['authRequired'] == true,
      defaultUploadPath: json['defaultUploadPath']?.toString() ?? '/',
      scopePath: json['scopePath']?.toString() ?? '/',
      scopedToDefaultFolder: json['scopedToDefaultFolder'] == true,
      capabilities:
          (json['capabilities'] as Map?)?.cast<String, Object?>() ??
          <String, Object?>{},
    );
  }
}

class JoinRoomSession {
  const JoinRoomSession({
    required this.token,
    required this.expiresAt,
    required this.permissions,
  });

  final String token;
  final DateTime expiresAt;
  final List<String> permissions;
}

class JoinedDownloadResult {
  const JoinedDownloadResult({required this.name, required this.location});

  final String name;
  final String location;
}

class JoinRoomService {
  static const Duration _connectionTimeout = Duration(seconds: 8);

  Future<JoinRoomPreview> preview(String rawUrl) async {
    final baseUrl = _normalizeBaseUrl(rawUrl);
    final json = await _jsonGet(Uri.parse('$baseUrl/api/room'));
    final preview = JoinRoomPreview.fromJson(baseUrl, json);
    if (preview.roomId.isEmpty) {
      throw const JoinRoomException(
        'This link opened, but it was not a live Drop Room. Ask the host to show the latest Drop Code.',
      );
    }
    return preview;
  }

  Future<JoinRoomSession> login({
    required String baseUrl,
    required String password,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = _connectionTimeout;
    try {
      final request = await client.postUrl(
        Uri.parse('$baseUrl/api/auth/login'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'password': password}));
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      final json = _decodeJsonObject(body);
      if (response.statusCode >= 400) {
        throw StateError(json['error']?.toString() ?? 'Could not join room');
      }
      return JoinRoomSession(
        token: json['token']?.toString() ?? '',
        expiresAt:
            DateTime.tryParse(json['expiresAt']?.toString() ?? '') ??
            DateTime.now(),
        permissions:
            (json['permissions'] as List?)?.whereType<String>().toList() ??
            <String>[],
      );
    } on SocketException {
      throw const JoinRoomException(
        'Could not reach this Drop Room. Confirm both phones are on the same Wi-Fi or hotspot and the host app is still open.',
      );
    } on TimeoutException {
      throw const JoinRoomException(
        'The Drop Room did not respond in time. Check the Wi-Fi connection and try the latest Drop Code again.',
      );
    } on FormatException {
      throw const JoinRoomException(
        'The Drop Room returned an unexpected response. Refresh the room and try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<DropFileItem>> listFiles({
    required String baseUrl,
    required String token,
    required String path,
  }) async {
    final json = await _jsonGet(
      Uri.parse('$baseUrl/api/files?path=${Uri.encodeQueryComponent(path)}'),
      token: token,
    );
    return (json['items'] as List?)
            ?.whereType<Map>()
            .map((item) => DropFileItem.fromJson(item.cast<String, Object?>()))
            .toList() ??
        <DropFileItem>[];
  }

  Future<void> createFolder({
    required String baseUrl,
    required String token,
    required String path,
  }) async {
    await _jsonPost(
      Uri.parse('$baseUrl/api/folders'),
      token: token,
      body: {'path': path},
    );
  }

  Future<void> sendText({
    required String baseUrl,
    required String token,
    required String title,
    required String body,
  }) async {
    await _jsonPost(
      Uri.parse('$baseUrl/api/text'),
      token: token,
      body: {'title': title, 'body': body, 'source': 'native_join'},
    );
  }

  Future<void> uploadFile({
    required String baseUrl,
    required String token,
    required String path,
    required File file,
    String? fileName,
    void Function(int sent, int total)? onProgress,
  }) async {
    final name = Uri.encodeQueryComponent(
      fileName ?? file.uri.pathSegments.last,
    );
    final targetPath = Uri.encodeQueryComponent(path);
    final client = HttpClient();
    client.connectionTimeout = _connectionTimeout;
    try {
      final request = await client.postUrl(
        Uri.parse('$baseUrl/api/files/upload?path=$targetPath&name=$name'),
      );
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..contentType = ContentType.binary;
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
        throw StateError(body.isEmpty ? 'Upload failed' : body);
      }
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  String defaultUploadPath(JoinRoomPreview preview) {
    return preview.defaultUploadPath;
  }

  Future<JoinedDownloadResult> downloadFile({
    required String baseUrl,
    required String token,
    required DropFileItem item,
    void Function(int received, int total)? onProgress,
  }) async {
    final directory = await _downloadStagingDirectory();
    await directory.create(recursive: true);
    final file = await _uniqueFile(directory, _safeName(item.name));
    final client = HttpClient();
    client.connectionTimeout = _connectionTimeout;
    try {
      final request = await client.getUrl(
        Uri.parse('$baseUrl/api/files/${item.id}/download'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      if (response.statusCode >= 400) {
        final body = await utf8.decoder.bind(response).join();
        throw StateError(body.isEmpty ? 'Download failed' : body);
      }
      final sink = file.openWrite();
      var received = 0;
      final total = response.contentLength;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      final saved = await PlatformDownloads.saveFileToDownloads(
        source: file,
        name: item.name,
        mimeType: item.mimeType,
      );
      return JoinedDownloadResult(name: saved.name, location: saved.location);
    } finally {
      client.close(force: true);
      await _deleteIfPresent(file);
    }
  }

  Future<Map<String, Object?>> _jsonGet(Uri uri, {String? token}) async {
    final client = HttpClient();
    client.connectionTimeout = _connectionTimeout;
    try {
      final request = await client.getUrl(uri);
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      final json = _decodeJsonObject(body);
      if (response.statusCode >= 400) {
        throw StateError(json['error']?.toString() ?? 'Request failed');
      }
      return json;
    } on FormatException {
      throw const JoinRoomException(
        'That address responded, but it was not an Erebrus Drop Room. Check the Drop Link shown on the host device.',
      );
    } on SocketException {
      throw const JoinRoomException(
        'Could not reach this Drop Room. Confirm both phones are on the same Wi-Fi or hotspot and the host app is still open.',
      );
    } on TimeoutException {
      throw const JoinRoomException(
        'The Drop Room did not respond in time. Check the Wi-Fi connection and try the latest Drop Code again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _jsonPost(
    Uri uri, {
    required String token,
    required Map<String, Object?> body,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = _connectionTimeout;
    try {
      final request = await client.postUrl(uri);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode(body));
      final response = await request.close();
      final responseBody = await utf8.decoder.bind(response).join();
      final json = responseBody.isEmpty
          ? <String, Object?>{}
          : _decodeJsonObject(responseBody);
      if (response.statusCode >= 400) {
        throw StateError(json['error']?.toString() ?? 'Request failed');
      }
      return json;
    } on FormatException {
      throw const JoinRoomException(
        'The Drop Room returned an unexpected response. Refresh the room and try again.',
      );
    } on SocketException {
      throw const JoinRoomException(
        'Could not reach this Drop Room. Confirm both phones are on the same Wi-Fi or hotspot and the host app is still open.',
      );
    } on TimeoutException {
      throw const JoinRoomException(
        'The Drop Room did not respond in time. Check the Wi-Fi connection and try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Directory> _downloadStagingDirectory() async {
    try {
      final temporary = await getTemporaryDirectory();
      return Directory('${temporary.path}/ErebrusDrop/JoinedDownloads');
    } catch (_) {
      return Directory(
        '${Directory.systemTemp.path}/ErebrusDrop/JoinedDownloads',
      );
    }
  }

  Future<File> _uniqueFile(Directory directory, String name) async {
    final safe = _safeName(name);
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

  Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Temporary staging files are cleaned by the OS if deletion is delayed.
    }
  }

  String _safeName(String name) {
    final safe = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return safe.isEmpty ? 'download' : safe;
  }

  String _normalizeBaseUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw const JoinRoomException('Enter a Drop Link first.');
    }
    final extracted = _extractDropUrl(trimmed);
    if (trimmed.startsWith('{') && extracted == null) {
      throw const JoinRoomException(
        'This QR code is not an Erebrus Drop Code. Scan the host Drop Code or paste its Drop Link.',
      );
    }
    final value = extracted ?? trimmed;
    final withScheme =
        value.startsWith('http://') || value.startsWith('https://')
        ? value
        : 'http://$value';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      throw const JoinRoomException('Enter a valid local Drop Link.');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const JoinRoomException('Drop Links must start with http://.');
    }
    return '${uri.scheme}://${uri.authority}';
  }

  Map<String, Object?> _decodeJsonObject(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('Expected a JSON object.');
    }
    return decoded.cast<String, Object?>();
  }

  String? _extractDropUrl(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, Object?> &&
          decoded['type'] == 'erebrus_drop_room') {
        final url = decoded['url']?.toString().trim();
        return url == null || url.isEmpty ? null : url;
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
