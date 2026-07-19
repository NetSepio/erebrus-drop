/// An organization the signed-in user belongs to.
class DropOrg {
  const DropOrg({
    required this.id,
    required this.name,
    required this.slug,
    this.role,
    this.plan,
    this.verificationStatus,
  });

  final String id;
  final String name;
  final String slug;
  final String? role;
  final String? plan;
  final String? verificationStatus;

  bool get verified => verificationStatus == 'verified';

  factory DropOrg.fromJson(Map<String, dynamic> json) {
    String? str(String key) {
      final value = (json[key] ?? '').toString().trim();
      return value.isEmpty ? null : value;
    }

    return DropOrg(
      id: (json['id'] ?? json['org_id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      slug: (json['slug'] ?? '').toString(),
      role: str('role'),
      plan: str('plan'),
      verificationStatus: str('verification_status'),
    );
  }
}

/// A Drop-capable node returned from the gateway discovery API.
class DropNode {
  const DropNode({
    required this.nodeId,
    required this.name,
    this.orgId,
    this.region = '',
    this.accessMode = 'public',
    this.deploymentProfile = 'standard',
    this.online = true,
    this.acceptingUploads = false,
    this.state = '',
    this.acceptsPublicUploads = false,
    this.webUiAvailable = false,
    this.capacity = 'unknown',
  });

  final String nodeId;
  final String name;
  final String? orgId;
  final String region;
  final String accessMode;
  final String deploymentProfile;
  final bool online;
  final bool acceptingUploads;
  final String state;
  final bool acceptsPublicUploads;
  final bool webUiAvailable;
  final String capacity;

  bool get isPublic => accessMode.toLowerCase() == 'public';

  factory DropNode.fromJson(Map<String, dynamic> json) {
    return DropNode(
      nodeId: (json['node_id'] ?? json['id'] ?? '').toString(),
      name: (json['name'] ?? 'Erebrus node').toString(),
      orgId: (json['org_id'] ?? '').toString().trim().isEmpty
          ? null
          : json['org_id'].toString(),
      region: (json['region'] ?? '').toString(),
      accessMode: (json['access_mode'] ?? 'public').toString(),
      deploymentProfile: (json['deployment_profile'] ?? 'standard').toString(),
      online: json['online'] == true,
      acceptingUploads: json['accepting_uploads'] == true,
      state: (json['state'] ?? '').toString(),
      acceptsPublicUploads: json['accepts_public_uploads'] == true,
      webUiAvailable: json['webui_available'] == true,
      capacity: (json['capacity'] ?? 'unknown').toString(),
    );
  }
}

/// A gateway Drop upload reservation.
class DropUploadReservation {
  const DropUploadReservation({
    required this.id,
    required this.uploadId,
    required this.nodeId,
    required this.scope,
    required this.visibility,
    required this.filename,
    required this.sizeBytes,
    required this.status,
    this.cid,
  });

  final String id;
  final String uploadId;
  final String nodeId;
  final String scope;
  final String visibility;
  final String filename;
  final int sizeBytes;
  final String status;
  final String? cid;

  factory DropUploadReservation.fromJson(Map<String, dynamic> json) {
    return DropUploadReservation(
      id: (json['id'] ?? json['upload_id'] ?? '').toString(),
      uploadId: (json['upload_id'] ?? json['id'] ?? '').toString(),
      nodeId: (json['node_id'] ?? '').toString(),
      scope: (json['scope'] ?? 'public').toString(),
      visibility: (json['visibility'] ?? 'private').toString(),
      filename: (json['filename'] ?? '').toString(),
      sizeBytes: (json['size_bytes'] ?? json['declared_size_bytes'] ?? 0) as int,
      status: (json['status'] ?? '').toString(),
      cid: json['cid']?.toString(),
    );
  }
}

/// A gateway Drop file returned from the files list.
class DropGatewayFile {
  const DropGatewayFile({
    required this.id,
    required this.fileId,
    required this.nodeId,
    this.orgId,
    required this.scope,
    required this.filename,
    this.contentType,
    required this.sizeBytes,
    required this.visibility,
    required this.encrypted,
    required this.status,
    this.cid,
    this.downloadUrl,
    this.gatewayUrl,
    this.encryptionMetadata,
    required this.createdAt,
  });

  final String id;
  final String fileId;
  final String nodeId;
  final String? orgId;
  final String scope;
  final String filename;
  final String? contentType;
  final int sizeBytes;
  final String visibility;
  final bool encrypted;
  final String status;
  final String? cid;
  final String? downloadUrl;
  final String? gatewayUrl;
  final Map<String, dynamic>? encryptionMetadata;
  final DateTime createdAt;

  bool get isPublic => visibility.toLowerCase() == 'public';

  factory DropGatewayFile.fromJson(Map<String, dynamic> json) {
    final created = DateTime.tryParse(
      json['created_at']?.toString() ?? '',
    );
    return DropGatewayFile(
      id: (json['id'] ?? json['file_id'] ?? '').toString(),
      fileId: (json['file_id'] ?? json['id'] ?? '').toString(),
      nodeId: (json['node_id'] ?? '').toString(),
      orgId: (json['org_id'] ?? '').toString().trim().isEmpty
          ? null
          : json['org_id'].toString(),
      scope: (json['scope'] ?? 'public').toString(),
      filename: (json['filename'] ?? 'file').toString(),
      contentType: json['content_type']?.toString(),
      sizeBytes: (json['size_bytes'] ?? 0) as int,
      visibility: (json['visibility'] ?? 'private').toString(),
      encrypted: json['encrypted'] == true,
      status: (json['status'] ?? 'available').toString(),
      cid: json['cid']?.toString(),
      downloadUrl: _pickUrl(json, const [
        'download_url',
        'public_url',
        'url',
      ]),
      gatewayUrl: _pickUrl(json, const ['gateway_url', 'ipfs_url']),
      encryptionMetadata: json['encryption_metadata'] is Map
          ? Map<String, dynamic>.from(json['encryption_metadata'] as Map)
          : null,
      createdAt: created ?? DateTime.now(),
    );
  }
}

String? _pickUrl(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return null;
}
