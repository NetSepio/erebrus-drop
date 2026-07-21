import 'package:erebrus_drop/features/host/host_folder_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('host folder selection preserves a macOS security-scoped bookmark', () {
    const selection = HostFolderSelection(
      name: 'Drop',
      uri: 'file:///Users/example/Drop/',
      platform: 'macOS',
      bookmark: 'encoded-bookmark',
    );

    final restored = HostFolderSelection.fromJson(selection.toJson());

    expect(restored.name, selection.name);
    expect(restored.uri, selection.uri);
    expect(restored.platform, selection.platform);
    expect(restored.bookmark, selection.bookmark);
  });

  test('host folder selection remains compatible without a bookmark', () {
    final selection = HostFolderSelection.fromJson(const {
      'name': 'Drop',
      'uri': 'C:\\Drop',
      'platform': 'Windows',
    });

    expect(selection.bookmark, isNull);
    expect(selection.toJson(), isNot(contains('bookmark')));
  });
}
