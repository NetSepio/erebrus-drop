import 'dart:io';
import 'dart:math';

import 'drop_models.dart';

/// Free-space checks that run before a transfer starts, so a full disk ends in
/// a clear message instead of a transfer that stalls once storage runs out.
class StorageGuard {
  const StorageGuard._();

  /// Headroom left free for the OS and other apps; filling a phone to the last
  /// byte makes it misbehave long after the transfer ends.
  static const int reserveBytes = 128 * 1024 * 1024;

  /// Bytes needed to receive [sizes] one after another. Uploads are staged in
  /// a temp file and then copied into the Drop folder, so the largest file is
  /// briefly stored twice when [staged] is true.
  static int requiredBytes(Iterable<int> sizes, {bool staged = true}) {
    var total = 0;
    var largest = 0;
    for (final size in sizes) {
      final safe = max(0, size);
      total += safe;
      largest = max(largest, safe);
    }
    return total + (staged ? largest : 0) + reserveBytes;
  }

  /// A user-facing message when [requiredBytes] does not fit in
  /// [availableBytes], or null when it fits or free space is unknown.
  static String? shortfallMessage({
    required int requiredBytes,
    required int? availableBytes,
    String device = 'The host device',
  }) {
    if (availableBytes == null || availableBytes < 0) return null;
    if (requiredBytes <= availableBytes) return null;
    final free = max(0, availableBytes - reserveBytes);
    return '$device has only ${formatBytes(free)} free. '
        'This needs ${formatBytes(requiredBytes - reserveBytes)}. '
        'Free up space or pick fewer files.';
  }

  /// A message when any single file is over [maxUploadBytes], else null.
  static String? oversizeMessage({
    required Iterable<({String name, int size})> files,
    required int maxUploadBytes,
  }) {
    for (final file in files) {
      if (file.size > maxUploadBytes) {
        return '${file.name} is ${formatBytes(file.size)}. '
            'Rooms accept files up to ${formatBytes(maxUploadBytes)}.';
      }
    }
    return null;
  }

  /// Whether [error] means the disk is full, across Android, iOS, macOS,
  /// Linux (ENOSPC = 28) and Windows (ERROR_DISK_FULL = 112,
  /// ERROR_HANDLE_DISK_FULL = 39), including errors relayed from native code.
  static bool isOutOfSpace(Object error) {
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      if (code == 28 && !Platform.isWindows) return true;
      if (Platform.isWindows && (code == 112 || code == 39)) return true;
    }
    final text = '$error'.toLowerCase();
    return text.contains('no space left') ||
        text.contains('enospc') ||
        text.contains('disk full') ||
        text.contains('not enough space') ||
        text.contains('insufficient storage');
  }
}
