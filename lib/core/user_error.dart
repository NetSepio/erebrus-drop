import 'package:flutter/services.dart';

import 'storage_guard.dart';

/// Turns an exception into one short sentence for a snackbar, without Dart
/// prefixes like "Bad state:" or raw JSON bodies.
String userErrorText(Object error) {
  if (StorageGuard.isOutOfSpace(error)) {
    return 'This device ran out of storage. Free up space and try again.';
  }
  var text = switch (error) {
    PlatformException(:final message) => message ?? error.code,
    _ => '$error',
  };
  for (final prefix in const [
    'Bad state: ',
    'Exception: ',
    'FileSystemException: ',
    'HttpException: ',
    'SocketException: ',
  ]) {
    if (text.startsWith(prefix)) text = text.substring(prefix.length);
  }
  text = text.trim();
  if (text.isEmpty || text.startsWith('{') || text.length > 220) {
    return 'Something went wrong. Try again.';
  }
  return text;
}
