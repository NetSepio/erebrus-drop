import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../core/host_folder_bridge.dart';

/// Cache copies of Drop-folder files shared across requests on platforms that
/// cannot read the folder in place. A copy lives while requests use it and
/// for [idle] after, so a video player's run of range requests reuses it.
class HostFileCache {
  HostFileCache({this.idle = const Duration(minutes: 3)});

  /// How long an unused copy is kept for the next request.
  final Duration idle;

  final Map<String, _HostFileCacheEntry> _entries = {};
  Timer? _sweep;

  Future<HostFolderCachedFile> acquire({
    required String key,
    required Future<HostFolderCachedFile> Function() copy,
  }) async {
    final existing = _entries[key];
    if (existing != null) {
      existing.users++;
      try {
        final file = await existing.file;
        if (await File(file.path).exists()) return file;
      } catch (_) {
        // The earlier copy failed; make a fresh one below.
      }
      existing.users--;
      _entries.remove(key);
    }
    final entry = _HostFileCacheEntry(copy())..users = 1;
    _entries[key] = entry;
    _sweep ??= Timer.periodic(const Duration(minutes: 1), (_) => evictIdle());
    try {
      return await entry.file;
    } catch (_) {
      _entries.remove(key);
      rethrow;
    }
  }

  void release(String key) {
    final entry = _entries[key];
    if (entry == null) return;
    entry.users = max(0, entry.users - 1);
    entry.lastUsed = DateTime.now();
  }

  /// Deletes copies nobody has used for [idle]; runs every minute.
  Future<void> evictIdle() async {
    final now = DateTime.now();
    final stale = _entries.entries
        .where(
          (e) => e.value.users == 0 && now.difference(e.value.lastUsed) > idle,
        )
        .map((e) => e.key)
        .toList();
    for (final key in stale) {
      await _entries.remove(key)?.delete();
    }
    if (_entries.isEmpty) {
      _sweep?.cancel();
      _sweep = null;
    }
  }

  Future<void> clear() async {
    _sweep?.cancel();
    _sweep = null;
    final entries = _entries.values.toList();
    _entries.clear();
    for (final entry in entries) {
      await entry.delete();
    }
  }
}

class _HostFileCacheEntry {
  _HostFileCacheEntry(this.file);

  final Future<HostFolderCachedFile> file;
  int users = 0;
  DateTime lastUsed = DateTime.now();

  Future<void> delete() async {
    try {
      final cached = File((await file).path);
      if (await cached.exists()) await cached.delete();
    } catch (_) {
      // Copy failed or already removed.
    }
  }
}
