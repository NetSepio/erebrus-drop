import 'dart:io';

enum RoomPermission {
  dropFolderOnly,
  viewOnly,
  downloadOnly,
  uploadOnly,
  uploadAndDownload,
  fullAccess,
  mediaStreamingOnly,
}

extension RoomPermissionLabel on RoomPermission {
  String get label {
    switch (this) {
      case RoomPermission.dropFolderOnly:
        return 'Drop folder only';
      case RoomPermission.viewOnly:
        return 'View only';
      case RoomPermission.downloadOnly:
        return 'Download only';
      case RoomPermission.uploadOnly:
        return 'Upload only';
      case RoomPermission.uploadAndDownload:
        return 'Upload and download';
      case RoomPermission.fullAccess:
        return 'Full access';
      case RoomPermission.mediaStreamingOnly:
        return 'Media streaming only';
    }
  }

  List<String> get apiValues {
    switch (this) {
      case RoomPermission.dropFolderOnly:
        return [
          'view',
          'upload',
          'download',
          'create_folder',
          'text',
          'drop_folder_only',
        ];
      case RoomPermission.viewOnly:
        return ['view'];
      case RoomPermission.downloadOnly:
        return ['view', 'download'];
      case RoomPermission.uploadOnly:
        return ['upload'];
      case RoomPermission.uploadAndDownload:
        return ['view', 'upload', 'download', 'create_folder', 'text'];
      case RoomPermission.fullAccess:
        return [
          'view',
          'upload',
          'download',
          'create_folder',
          'rename',
          'delete',
          'text',
          'streaming',
        ];
      case RoomPermission.mediaStreamingOnly:
        return ['view', 'streaming'];
    }
  }
}

class DropRoomConfig {
  const DropRoomConfig({
    required this.name,
    required this.deviceName,
    required this.password,
    required this.permission,
    required this.burnMode,
    required this.expiry,
    required this.defaultUploadPath,
  });

  final String name;
  final String deviceName;
  final String password;
  final RoomPermission permission;
  final bool burnMode;
  final Duration? expiry;
  final String defaultUploadPath;

  bool get authRequired => password.trim().isNotEmpty;
}

class DropRoomSession {
  const DropRoomSession({
    required this.id,
    required this.name,
    required this.deviceName,
    required this.baseUrl,
    required this.localIp,
    required this.port,
    required this.authRequired,
    required this.permission,
    required this.createdAt,
    required this.expiresAt,
    required this.roomDirectory,
    required this.defaultUploadPath,
  });

  final String id;
  final String name;
  final String deviceName;
  final String baseUrl;
  final String localIp;
  final int port;
  final bool authRequired;
  final RoomPermission permission;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final Directory roomDirectory;
  final String defaultUploadPath;
}

class StorageSnapshot {
  const StorageSnapshot({
    required this.dropUsedBytes,
    required this.roomUsedBytes,
    required this.availableBytes,
    required this.totalBytes,
    required this.maxUploadBytes,
  });

  final int dropUsedBytes;
  final int roomUsedBytes;
  final int? availableBytes;
  final int? totalBytes;
  final int maxUploadBytes;

  bool get lowStorage {
    final available = availableBytes;
    final total = totalBytes;
    if (available == null || total == null || total <= 0) {
      return false;
    }
    return available / total < 0.15;
  }

  Map<String, Object?> toJson() {
    return {
      'dropUsedBytes': dropUsedBytes,
      'roomUsedBytes': roomUsedBytes,
      'availableBytes': availableBytes,
      'totalBytes': totalBytes,
      'maxUploadBytes': maxUploadBytes,
      'lowStorage': lowStorage,
    };
  }
}

class DropFileItem {
  const DropFileItem({
    required this.id,
    required this.name,
    required this.type,
    required this.path,
    required this.sizeBytes,
    required this.createdAt,
    required this.modifiedAt,
    required this.mimeType,
    required this.streamable,
  });

  final String id;
  final String name;
  final String type;
  final String path;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String? mimeType;
  final bool streamable;

  factory DropFileItem.fromJson(Map<String, Object?> json) {
    return DropFileItem(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Item',
      type: json['type']?.toString() ?? 'file',
      path: json['path']?.toString() ?? '/',
      sizeBytes: json['sizeBytes'] is int ? json['sizeBytes'] as int : 0,
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      modifiedAt:
          DateTime.tryParse(json['modifiedAt']?.toString() ?? '') ??
          DateTime.now(),
      mimeType: json['mimeType']?.toString(),
      streamable: json['streamable'] == true,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'path': path,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'createdAt': createdAt.toIso8601String(),
      'modifiedAt': modifiedAt.toIso8601String(),
      'streamable': streamable,
    };
  }
}

String formatBytes(int? bytes) {
  if (bytes == null) {
    return 'Unavailable';
  }
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final digits = unit == 0 || size >= 10 ? 0 : 1;
  return '${size.toStringAsFixed(digits)} ${units[unit]}';
}
