import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'gateway_config.dart';
import 'gateway_session.dart';

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

  static String? errorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final code = decoded['error_code'] ?? decoded['code'];
        if (code != null && code.toString().isNotEmpty) {
          return code.toString();
        }
        final error = decoded['error'];
        if (error is String && RegExp(r'^[A-Z][A-Z_]+$').hasMatch(error)) {
          return error;
        }
        if (error is Map) {
          final nestedCode = error['code'];
          if (nestedCode != null && nestedCode.toString().isNotEmpty) {
            return nestedCode.toString();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static DateTime? parseRetryAfter(String? value, {DateTime? now}) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return (now ?? DateTime.now()).toUtc().add(
        Duration(seconds: seconds < 0 ? 0 : seconds),
      );
    }
    try {
      return HttpDate.parse(value).toUtc();
    } catch (_) {
      return null;
    }
  }

  static GatewayException responseException(
    int status,
    String body, {
    String? retryAfter,
  }) => GatewayException(
    errorMessage(status, body),
    statusCode: status,
    errorCode: errorCode(body),
    retryAt: parseRetryAfter(retryAfter),
    outcomeUncertain: status >= 500,
  );

  /// Exactly one retry for an explicitly expired access token. The same closure
  /// retains encoded bodies, idempotency keys and reopenable upload streams.
  static Future<T> protectedRequest<T>({
    GatewaySessionAuthorization? authorization,
    String? bearerToken,
    required Future<T> Function(String? token) send,
  }) async {
    final credential = await authorization?.authorize();
    try {
      final result = await send(credential?.token ?? bearerToken);
      if (credential != null) await authorization!.validate(credential);
      return result;
    } on GatewayException catch (e) {
      if (authorization == null || credential == null) rethrow;
      await authorization.handleFailure(credential, e.errorCode);
      if (e.statusCode != 401 || e.errorCode != 'ACCESS_TOKEN_EXPIRED') rethrow;
      final replacement = await authorization.authorize(rejected: credential);
      try {
        final result = await send(replacement.token);
        await authorization.validate(replacement);
        return result;
      } on GatewayException catch (retryError) {
        await authorization.handleFailure(replacement, retryError.errorCode);
        rethrow;
      }
    }
  }

  // Request-specific cooldowns are advisory to callers too (via retryAt).
  static final _cooldowns = <String, DateTime>{};

  static void checkRetryAfter(Uri uri) {
    final retryAt = _cooldowns[uri.toString()];
    if (retryAt == null) return;
    if (!DateTime.now().isBefore(retryAt)) {
      _cooldowns.remove(uri.toString());
      return;
    }
    throw GatewayException(
      'Try again after the server retry interval',
      statusCode: 429,
      retryAt: retryAt,
    );
  }

  static void recordRetryAfter(Uri uri, GatewayException failure) {
    if (failure.retryAt != null) _cooldowns[uri.toString()] = failure.retryAt!;
  }

  static Future<dynamic> _send(
    String method,
    Uri uri, {
    String? bearerToken,
    String? encodedBody,
    Stream<List<int>> Function()? bytes,
    int? contentLength,
    String? contentType,
  }) async {
    checkRetryAfter(uri);
    final client = createClient();
    var transmissionStarted = false;
    try {
      final req = await client.openUrl(method, uri).timeout(_requestTimeout);
      // Credentials must not follow redirects to another origin.
      req.followRedirects = false;
      applyHeaders(
        req,
        bearerToken: bearerToken,
        jsonBody: encodedBody != null,
        contentLength: contentLength,
        contentType: contentType,
      );
      if (encodedBody != null) {
        transmissionStarted = true;
        req.contentLength = utf8.encode(encodedBody).length;
        req.write(encodedBody);
      } else if (bytes != null) {
        transmissionStarted = true;
        await req.addStream(bytes()).timeout(_requestTimeout);
      }
      transmissionStarted = true;
      final res = await req.close().timeout(_requestTimeout);
      final text = await utf8.decodeStream(res).timeout(_requestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final failure = responseException(
          res.statusCode,
          text,
          retryAfter: res.headers.value(HttpHeaders.retryAfterHeader),
        );
        recordRetryAfter(uri, failure);
        throw failure;
      }
      if (text.isEmpty) return null;
      return jsonDecode(text);
    } on SocketException {
      throw GatewayException(
        'Cannot reach Erebrus. Check your connection.',
        outcomeUncertain: transmissionStarted,
      );
    } on TimeoutException {
      throw GatewayException(
        'Erebrus request timed out',
        outcomeUncertain: transmissionStarted,
      );
    } on FormatException {
      throw GatewayException(
        'Invalid Erebrus response',
        outcomeUncertain: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> getJson(
    Uri uri, {
    String? bearerToken,
    GatewaySessionAuthorization? authorization,
  }) async => _map(
    await protectedRequest(
      authorization: authorization,
      bearerToken: bearerToken,
      send: (token) => _send('GET', uri, bearerToken: token),
    ),
  );

  static Future<List<dynamic>> getJsonList(
    Uri uri, {
    String? bearerToken,
    GatewaySessionAuthorization? authorization,
  }) async {
    final decoded = await protectedRequest(
      authorization: authorization,
      bearerToken: bearerToken,
      send: (token) => _send('GET', uri, bearerToken: token),
    );
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
    GatewaySessionAuthorization? authorization,
  }) => _jsonRequest('POST', uri, body, bearerToken, authorization);

  static Future<Map<String, dynamic>> putJson(
    Uri uri,
    Map<String, dynamic> body, {
    String? bearerToken,
    GatewaySessionAuthorization? authorization,
  }) => _jsonRequest('PUT', uri, body, bearerToken, authorization);

  static Future<Map<String, dynamic>> _jsonRequest(
    String method,
    Uri uri,
    Map<String, dynamic> body,
    String? bearerToken,
    GatewaySessionAuthorization? authorization,
  ) {
    final encoded = jsonEncode(body);
    return protectedRequest(
      authorization: authorization,
      bearerToken: bearerToken,
      send: (token) async => _map(
        await _send(method, uri, bearerToken: token, encodedBody: encoded),
      ),
    );
  }

  static Future<Map<String, dynamic>> putBytes(
    Uri uri,
    Stream<List<int>> Function() bytes, {
    required int contentLength,
    required String contentType,
    String? bearerToken,
    GatewaySessionAuthorization? authorization,
  }) => protectedRequest(
    authorization: authorization,
    bearerToken: bearerToken,
    send: (token) async => _map(
      await _send(
        'PUT',
        uri,
        bearerToken: token,
        bytes: bytes,
        contentLength: contentLength,
        contentType: contentType,
      ),
    ),
  );

  static Map<String, dynamic> _map(dynamic decoded) =>
      decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
}

class GatewayException implements Exception {
  GatewayException(
    this.message, {
    this.statusCode,
    this.errorCode,
    this.retryAt,
    this.outcomeUncertain = false,
  });
  final String message;
  final int? statusCode;
  final String? errorCode;
  final DateTime? retryAt;
  final bool outcomeUncertain;
  @override
  String toString() => message;
}
