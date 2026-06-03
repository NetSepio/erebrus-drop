import '../../core/drop_models.dart';

class DropSettings {
  const DropSettings({
    required this.requirePasswordByDefault,
    required this.burnModeByDefault,
    required this.defaultPermission,
    required this.enableBrowserClients,
    required this.enableMediaStreaming,
    required this.enableMdnsDiscovery,
    required this.defaultPort,
  });

  factory DropSettings.defaults() {
    return const DropSettings(
      requirePasswordByDefault: true,
      burnModeByDefault: false,
      defaultPermission: RoomPermission.dropFolderOnly,
      enableBrowserClients: true,
      enableMediaStreaming: true,
      enableMdnsDiscovery: true,
      defaultPort: 8787,
    );
  }

  final bool requirePasswordByDefault;
  final bool burnModeByDefault;
  final RoomPermission defaultPermission;
  final bool enableBrowserClients;
  final bool enableMediaStreaming;
  final bool enableMdnsDiscovery;
  final int defaultPort;
}
