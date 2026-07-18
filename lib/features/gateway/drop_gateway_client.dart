import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'gateway_config.dart';
import 'gateway_http.dart';
import 'gateway_models.dart';

/// Client for the Erebrus gateway Drop endpoints.
class DropGatewayClient {
  DropGatewayClient({String? gatewayUrl, this.bearerToken})
      : _base = GatewayHttp.normalizeBase(gatewayUrl ?? resolveGatewayUrl());

  final Uri _base;
  String? bearerToken;

  set token(String? value) => bearerToken = value;

  /// `GET /api/v2/drop/nodes` — public or private-org Drop-capable nodes.
  Future<List<DropNode>> fetchDropNodes({
    String scope = 'public',
    String? orgId,
  }) async {
    final query = <String, String>{'scope': scope};
    if (orgId != null && orgId.isNotEmpty && scope == 'private') {
      query['org_id'] = orgId;
    }
    final map = await GatewayHttp.getJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/drop/nodes', query: query),
      bearerToken: bearerToken,
    );
    final nodes = (map['nodes'] as List?) ?? [];
    return nodes
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => DropNode.fromJson(Map<String, dynamic>.from(e)))
        .where((n) => n.nodeId.isNotEmpty)
        .toList();
  }

  /// `POST /api/v2/drop/uploads` — reserve an upload slot on a node.
  Future<DropUploadReservation> reserveUpload({
    required String nodeId,
    required int sizeBytes,
    required String filename,
    required String contentType,
    required String visibility,
    String scope = 'public',
    String? orgId,
    String? sha256,
    bool encrypted = false,
    Map<String, dynamic>? encryptionMetadata,
    String? idempotencyKey,
  }) async {
    final body = <String, dynamic>{
      'node_id': nodeId,
      'scope': scope,
      'visibility': visibility,
      'filename': filename,
      'content_type': contentType,
      'size_bytes': sizeBytes,
      'encrypted': encrypted,
      'idempotency_key': idempotencyKey ?? _randomIdempotencyKey(),
      if (orgId != null && orgId.isNotEmpty && scope == 'private')
        'org_id': orgId,
      if (sha256 != null && sha256.isNotEmpty) 'sha256': sha256,
      if (encryptionMetadata != null && encryptionMetadata.isNotEmpty)
        'encryption_metadata': encryptionMetadata,
    };
    final map = await GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/drop/uploads'),
      body,
      bearerToken: bearerToken,
    );
    return DropUploadReservation.fromJson(map);
  }

  /// `PUT /api/v2/drop/uploads/{upload_id}/content` — stream [file] bytes.
  /// Returns the committed file record.
  Future<DropGatewayFile> uploadContent(
    DropUploadReservation reservation,
    File file, {
    String? contentType,
  }) async {
    final uri = GatewayHttp.apiUri(
      _base,
      path: '/api/v2/drop/uploads/${reservation.uploadId}/content',
    );
    final map = await GatewayHttp.putBytes(
      uri,
      file.openRead().cast<List<int>>(),
      contentLength: await file.length(),
      contentType: contentType ?? 'application/octet-stream',
      bearerToken: bearerToken,
    );
    return DropGatewayFile.fromJson(map);
  }

  /// Convenience: reserve + upload a local file to a node.
  /// Returns the committed file (with `cid`).
  Future<DropGatewayFile> uploadFile({
    required String nodeId,
    required File file,
    required String filename,
    required String visibility,
    String scope = 'public',
    String? orgId,
    String? contentType,
  }) async {
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    final sha = digest.toString();
    final reservation = await reserveUpload(
      nodeId: nodeId,
      sizeBytes: bytes.length,
      filename: filename,
      contentType: contentType ?? 'application/octet-stream',
      visibility: visibility,
      scope: scope,
      orgId: orgId,
      sha256: sha,
    );
    return uploadContent(reservation, file, contentType: contentType);
  }

  /// `GET /api/v2/drop/files` — caller's own Drop files.
  Future<List<DropGatewayFile>> fetchMyFiles() async {
    final map = await GatewayHttp.getJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/drop/files'),
      bearerToken: bearerToken,
    );
    final files = (map['files'] as List?) ?? [];
    return files
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => DropGatewayFile.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// `GET /api/v2/orgs/{org_id}/drop/files` — org Drop files.
  Future<List<DropGatewayFile>> fetchOrgFiles(String orgId) async {
    final map = await GatewayHttp.getJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/orgs/$orgId/drop/files'),
      bearerToken: bearerToken,
    );
    final files = (map['files'] as List?) ?? [];
    return files
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => DropGatewayFile.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  String _randomIdempotencyKey() {
    final bytes = List<int>.generate(16, (_) => 0);
    return base64Encode(bytes).replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  }
}
