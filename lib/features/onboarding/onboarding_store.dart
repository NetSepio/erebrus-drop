import 'dart:io';

import 'package:path_provider/path_provider.dart';

class OnboardingStore {
  static const String _fileName = '.erebrus_drop_onboarded';

  Future<bool> isComplete() async {
    return (await _markerFile()).exists();
  }

  Future<void> markComplete() async {
    final file = await _markerFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(DateTime.now().toIso8601String());
  }

  Future<File> _markerFile() async {
    try {
      final directory = await getApplicationSupportDirectory();
      return File('${directory.path}/$_fileName');
    } catch (_) {
      return File('${Directory.systemTemp.path}/$_fileName');
    }
  }
}
