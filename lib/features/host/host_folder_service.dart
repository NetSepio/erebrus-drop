import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class HostFolderSelection {
  const HostFolderSelection({
    required this.name,
    required this.uri,
    required this.platform,
  });

  final String name;
  final String uri;
  final String platform;

  factory HostFolderSelection.fromJson(Map<Object?, Object?> json) {
    return HostFolderSelection(
      name: json['name']?.toString() ?? 'Selected folder',
      uri: json['uri']?.toString() ?? '',
      platform: json['platform']?.toString() ?? 'unknown',
    );
  }

  Map<String, Object?> toJson() {
    return {'name': name, 'uri': uri, 'platform': platform};
  }
}

class HostFolderService {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  Future<HostFolderSelection?> selectHostFolder() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'selectHostFolder',
    );
    if (result == null || (result['uri']?.toString().isEmpty ?? true)) {
      return null;
    }
    return HostFolderSelection.fromJson(result);
  }

  Future<HostFolderSelection?> loadSavedSelection() async {
    try {
      final file = await _selectionFile();
      if (!await file.exists()) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      final selection = HostFolderSelection.fromJson(decoded);
      unawaited(_syncShareIntakeHostFolder(selection));
      return selection;
    } on Object {
      return null;
    }
  }

  Future<void> saveSelection(HostFolderSelection selection) async {
    final file = await _selectionFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(selection.toJson()));
    await _syncShareIntakeHostFolder(selection);
  }

  Future<void> _syncShareIntakeHostFolder(HostFolderSelection selection) async {
    try {
      await _channel.invokeMethod<Object?>('syncShareIntakeHostFolder', {
        'selection': selection.toJson(),
      });
    } on MissingPluginException {
      // Share-extension folder sync is native-platform specific.
    } on PlatformException {
      // The in-app saved selection remains valid even if extension sync fails.
    }
  }

  Future<void> clearSelection() async {
    try {
      final file = await _selectionFile();
      if (await file.exists()) {
        await file.delete();
      }
    } on Object {
      // Missing saved metadata is harmless.
    }
    try {
      await _channel.invokeMethod<Object?>('clearShareIntakeHostFolder');
    } on MissingPluginException {
      // Share-extension folder sync is native-platform specific.
    } on PlatformException {
      // Clearing the app-side selection is enough to stop in-app hosting.
    }
  }

  Future<File> _selectionFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/host_folder_selection.json');
  }
}
