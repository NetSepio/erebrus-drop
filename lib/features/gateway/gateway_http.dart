import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'gateway_config.dart';

/// Shared HTTP helpers for the Erebrus gateway Drop and auth APIs.
abstract final class GatewayHttp {
  static const Duration _connectTimeout = Duration(seconds: 12);
  static const Duration _requestTimeout = Duration(seconds: 20);

  static HttpClient createClient() {
    final client = HttpClient();
    client.connectionTimeout = _connectTimeout;
    client.idleTimeout = const Duration(seconds: 15);
    return client;
  }

  static Uri normalizeBase(String url) {
    final trimmed = url.trim();
    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.parse(withScheme);
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (path.isEmpty || path == '/') {
      return uri.replace(path: '', query: null, fragment: null);
    }
    return uri.replace(path: path, query: null, fragment: null);
  }

  static Uri apiUri(
    Uri base, {
    required String path,
    Map<String, String>? query,
  }) {
    final segment = path.startsWith('/') ? path : '/$path';
    final root = base.path.isEmpty || base.path == '/'
        ? ''
        : base.path.replaceAll(RegExp(r'/+$'), '');
    return base.replace(path: '$root$segment', queryParameters: query);
  }

  static void applyHeaders(
    HttpClientRequest req, {
    String? bearerToken,
    bool jsonBody = false,
    int? contentLength,
    String? contentType,
  }) {
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.headers.set('X-Erebrus-Client', gatewayClientHeader());
    if (bearerToken != null && bearerToken.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearerToken');
    }
    if (contentType != null && contentType.isNotEmpty) {
      req.headers.set(HttpHeaders.contentTypeHeader, contentType);
    } else if (jsonBody) {
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    }
    if (contentLength != null) {
      req.contentLength = contentLength;
    }
  }

  static String errorMessage(int status, String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final msg = j['error'] ?? j['message'] ?? j['detail'];
        if (msg != null) return msg.toString();
      }
    } catch (_) {}
    return switch (status) {
      404 => 'Resource not found (404)',
      401 => 'Authentication failed (401)',
      403 => 'Access denied (403)',
      409 => 'Conflict (409)',
      413 => 'Request too large (413)',
      429 => 'Rate limit exceeded — slow down (429)',
      503 => 'Erebrus service unavailable (503)',
      507 => 'Storage capacity exhausted (507)',
      _ => 'Erebrus error ($status)',
    };
  }

  static Future<dynamic> _get(Uri uri, {String? bearerToken}) async {
    final client = createClient();
    try {
      final req = await client.getUrl(uri).timeout(_requestTimeout);
      applyHeaders(req, bearerToken: bearerToken);
      final res = await req.close().timeout(_requestTimeout);
      final text = await utf8.decodeStream(res).timeout(_requestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw GatewayException(errorMessage(res.statusCode, text));
      }
      if (text.isEmpty) return null;
      return jsonDecode(text);
    } on SocketException catch (e) {
      throw GatewayException('Cannot reach Erebrus: ${e.message}');
    } on TimeoutException {
      throw GatewayException('Erebrus request timed out');
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> getJson(
    Uri uri, {
    String? bearerToken,
  }) async {
    final decoded = await _get(uri, bearerToken: bearerToken);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return const {};
  }

  static Future<List<dynamic>> getJsonList(
    Uri uri, {
    String? bearerToken,
  }) async {
    final decoded = await _get(uri, bearerToken: bearerToken);
    if (decoded is List) return decoded;
    if (decoded is Map && decoded['items'] is List) {
      return decoded['items'] as List;
    }
    return const [];
  }

  static Future<Map<String, dynamic>> postJson(
    Uri uri,
    Map<String, dynamic> body, {
    String? bearerToken,
  }) async {
    return _request('POST', uri, body: body, bearerToken: bearerToken);
  }

  static Future<Map<String, dynamic>> putJson(
    Uri uri,
    Map<String, dynamic> body, {
    String? bearerToken,
  }) async {
    return _request('PUT', uri, body: body, bearerToken: bearerToken);
  }

  static Future<Map<String, dynamic>> putBytes(
    Uri uri,
    Stream<List<int>> bytes, {
    required int contentLength,
    required String contentType,
    String? bearerToken,
  }) async {
    final client = createClient();
    try {
      final req = await client.openUrl('PUT', uri).timeout(_requestTimeout);
      applyHeaders(
        req,
        bearerToken: bearerToken,
        contentLength: contentLength,
        contentType: contentType,
      );
      await req.addStream(bytes);
      final res = await req.close().timeout(_requestTimeout);
      final text = await utf8.decodeStream(res).timeout(_requestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw GatewayException(errorMessage(res.statusCode, text));
      }
      if (text.isEmpty) return const {};
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return const {};
    } on SocketException catch (e) {
      throw GatewayException('Cannot reach Erebrus: ${e.message}');
    } on TimeoutException {
      throw GatewayException('Erebrus request timed out');
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> _request(
    String method,
    Uri uri, {
    required Map<String, dynamic> body,
    String? bearerToken,
  }) async {
    final client = createClient();
    try {
      final req = await client.openUrl(method, uri).timeout(_requestTimeout);
      applyHeaders(req, bearerToken: bearerToken, jsonBody: true);
      final encoded = jsonEncode(body);
      req.contentLength = utf8.encode(encoded).length;
      req.write(encoded);
      final res = await req.close().timeout(_requestTimeout);
      final text = await utf8.decodeStream(res).timeout(_requestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw GatewayException(errorMessage(res.statusCode, text));
      }
      if (text.isEmpty) return const {};
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return const {};
    } on SocketException catch (e) {
      throw GatewayException('Cannot reach Erebrus: ${e.message}');
    } on TimeoutException {
      throw GatewayException('Erebrus request timed out');
    } finally {
      client.close(force: true);
    }
  }
}

class GatewayException implements Exception {
  GatewayException(this.message);
  final String message;

  @override
  String toString() => message;
}
