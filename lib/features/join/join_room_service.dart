import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/drop_models.dart';

class JoinRoomPreview {
  const JoinRoomPreview({
    required this.baseUrl,
    required this.roomId,
    required this.roomName,
    required this.deviceName,
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
      authRequired: json['authRequired'] == true,
      defaultUploadPath: json['defaultUploadPath']?.toString() ?? '/Inbox',
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

class JoinRoomService {
  Future<JoinRoomPreview> preview(String rawUrl) async {
    final baseUrl = _normalizeBaseUrl(rawUrl);
    final json = await _jsonGet(Uri.parse('$baseUrl/api/room'));
    return JoinRoomPreview.fromJson(baseUrl, json);
  }

  Future<JoinRoomSession> login({
    required String baseUrl,
    required String password,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('$baseUrl/api/auth/login'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'password': password}));
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      final json = jsonDecode(body) as Map<String, Object?>;
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

  Future<File> downloadFile({
    required String baseUrl,
    required String token,
    required DropFileItem item,
    void Function(int received, int total)? onProgress,
  }) async {
    final directory = await _joinedDownloadsDirectory();
    await directory.create(recursive: true);
    final file = File('${directory.path}/${_safeName(item.name)}');
    final client = HttpClient();
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
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.close();
      return file;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _jsonGet(Uri uri, {String? token}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      final json = jsonDecode(body) as Map<String, Object?>;
      if (response.statusCode >= 400) {
        throw StateError(json['error']?.toString() ?? 'Request failed');
      }
      return json;
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
          : jsonDecode(responseBody) as Map<String, Object?>;
      if (response.statusCode >= 400) {
        throw StateError(json['error']?.toString() ?? 'Request failed');
      }
      return json;
    } finally {
      client.close(force: true);
    }
  }

  Future<Directory> _joinedDownloadsDirectory() async {
    try {
      final documents = await getApplicationDocumentsDirectory();
      return Directory('${documents.path}/ErebrusDrop/JoinedDownloads');
    } catch (_) {
      return Directory(
        '${Directory.systemTemp.path}/ErebrusDrop/JoinedDownloads',
      );
    }
  }

  String _safeName(String name) {
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _normalizeBaseUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Enter a Drop Link first.');
    }
    final withScheme =
        trimmed.startsWith('http://') || trimmed.startsWith('https://')
        ? trimmed
        : 'http://$trimmed';
    final uri = Uri.parse(withScheme);
    if (uri.host.isEmpty) {
      throw ArgumentError('Enter a valid local Drop Link.');
    }
    return uri
        .replace(path: '', query: '', fragment: '')
        .toString()
        .replaceAll(RegExp(r'/$'), '');
  }
}
