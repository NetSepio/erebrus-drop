import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'core/drop_models.dart';
import 'core/host_folder_bridge.dart';
import 'core/platform_network.dart';
import 'features/host/host_folder_service.dart';
import 'features/host/room_runtime_service.dart';
import 'features/join/join_room_service.dart';
import 'features/join/native_file_picker_service.dart';
import 'features/join/qr_scan_screen.dart';
import 'features/nearby/nearby_room_service.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/onboarding_store.dart';
import 'server/drop_server.dart';
import 'ui/theme/drop_theme.dart';

const String _appVersion = '1.0.2+3';
const String _supportEmail = 'support@netsepio.com';

class ErebrusDropApp extends StatefulWidget {
  const ErebrusDropApp({this.skipOnboarding = false, super.key});

  final bool skipOnboarding;

  @override
  State<ErebrusDropApp> createState() => _ErebrusDropAppState();
}

class _ErebrusDropAppState extends State<ErebrusDropApp> {
  final OnboardingStore _onboardingStore = OnboardingStore();
  late final Future<bool> _onboardingComplete = _onboardingStore.isComplete();
  bool _completedThisRun = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Erebrus Drop',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: DropTheme.dark(),
      home: widget.skipOnboarding
          ? const DropHomeScreen()
          : FutureBuilder<bool>(
              future: _onboardingComplete,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                final complete = snapshot.data == true || _completedThisRun;
                if (complete) {
                  return const DropHomeScreen();
                }
                return OnboardingScreen(
                  onComplete: () async {
                    await _onboardingStore.markComplete();
                    if (mounted) {
                      setState(() => _completedThisRun = true);
                    }
                  },
                );
              },
            ),
    );
  }
}

class DropHomeScreen extends StatefulWidget {
  const DropHomeScreen({super.key});

  @override
  State<DropHomeScreen> createState() => _DropHomeScreenState();
}

class _DropHomeScreenState extends State<DropHomeScreen>
    with WidgetsBindingObserver {
  final DropServer _server = DropServer();
  final HostFolderService _hostFolderService = HostFolderService();
  final RoomRuntimeService _roomRuntimeService = RoomRuntimeService();
  final JoinRoomService _joinRoomService = JoinRoomService();
  late final NearbyRoomService _nearbyRoomService = NearbyRoomService(
    joinRoomService: _joinRoomService,
  );
  final NativeFilePickerService _nativeFilePickerService =
      NativeFilePickerService();
  final HostFolderBridge _hostFolderBridge = HostFolderBridge();
  final ValueNotifier<int> _networkUiVersion = ValueNotifier<int>(0);
  final ValueNotifier<int> _joinUiVersion = ValueNotifier<int>(0);
  final TextEditingController _roomName = TextEditingController(
    text: _defaultRoomName(),
  );
  final TextEditingController _deviceName = TextEditingController(
    text: Platform.localHostname,
  );
  final TextEditingController _password = TextEditingController();
  final TextEditingController _smartText = TextEditingController();
  final TextEditingController _smartTitle = TextEditingController(
    text: 'Quick text',
  );
  final TextEditingController _joinUrl = TextEditingController();
  final TextEditingController _joinPassword = TextEditingController();
  final TextEditingController _joinFolderName = TextEditingController();
  final TextEditingController _joinTextTitle = TextEditingController(
    text: 'Native text',
  );
  final TextEditingController _joinTextBody = TextEditingController();

  final String _defaultUploadPath = '/';
  int _tab = 0;
  bool _starting = false;
  bool _hostFolderBusy = false;
  bool _loadingHostFolderSelection = true;
  bool _networkLoading = true;
  bool _loadingLibraryFiles = false;
  bool _appInForeground = true;
  bool _refreshingRoomData = false;
  bool _backDialogOpen = false;
  bool _joining = false;
  bool _discoveringRooms = false;
  bool _usePassword = true;
  bool _burnMode = false;
  RoomPermission _permission = RoomPermission.dropFolderOnly;
  StorageSnapshot? _storage;
  DropNetworkStatus _networkStatus = const DropNetworkStatus(
    mode: DropNetworkMode.unavailable,
  );
  HostFolderSelection? _hostFolderSelection;
  JoinRoomPreview? _joinPreview;
  JoinRoomSession? _joinSession;
  List<JoinRoomPreview> _foundJoinRooms = <JoinRoomPreview>[];
  String _libraryPath = '/';
  String _joinPath = '/';
  List<DropFileItem> _joinItems = <DropFileItem>[];
  String? _joinActivity;
  String? _nearbyDiscoveryMessage;
  TransferProgress? _joinTransfer;
  String? _libraryError;
  List<DropFileItem> _files = <DropFileItem>[];
  Timer? _refreshTimer;
  DateTime _lastNearbyDiscovery = DateTime.fromMillisecondsSinceEpoch(0);

  DropRoomSession? get _session => _server.session;

  static String _defaultRoomName() {
    final suffix = 1000 + math.Random.secure().nextInt(9000);
    return 'ErebrusDrop$suffix';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadDeviceName());
    unawaited(_loadHostFolderSelection());
    unawaited(_refreshNetworkStatus());
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_server.isRunning && _appInForeground) {
        unawaited(_refreshRoomData());
      }
      if (_tab == 1 && _appInForeground && !_discoveringRooms) {
        final now = DateTime.now();
        if (now.difference(_lastNearbyDiscovery) >=
            const Duration(seconds: 10)) {
          unawaited(_discoverNearbyRooms(silent: true));
        }
      }
    });
  }

  Future<void> _loadDeviceName() async {
    final fallback = Platform.localHostname;
    final deviceName = await PlatformNetwork.deviceName();
    if (!mounted || deviceName.isEmpty) return;
    if (_deviceName.text.trim().isEmpty || _deviceName.text == fallback) {
      _deviceName.text = deviceName;
    }
  }

  Future<void> _loadHostFolderSelection() async {
    final selection = await _hostFolderService.loadSavedSelection();
    if (!mounted) return;
    setState(() {
      _hostFolderSelection = selection;
      _loadingHostFolderSelection = false;
    });
    if (selection != null) {
      unawaited(_loadLibraryFiles());
    }
  }

  Future<void> _refreshNetworkStatus() async {
    _setNetworkState(() => _networkLoading = true);
    try {
      final status = await PlatformNetwork.currentNetworkStatus();
      if (!mounted) return;
      _setNetworkState(() {
        _networkStatus = status;
        _networkLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      _setNetworkState(() {
        _networkStatus = const DropNetworkStatus(
          mode: DropNetworkMode.unavailable,
        );
        _networkLoading = false;
      });
    }
  }

  void _setNetworkState(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _networkUiVersion.value += 1;
  }

  void _setJoinState(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _joinUiVersion.value += 1;
  }

  void _openInfoScreen(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _roomName.dispose();
    _deviceName.dispose();
    _password.dispose();
    _smartText.dispose();
    _smartTitle.dispose();
    _joinUrl.dispose();
    _joinPassword.dispose();
    _joinFolderName.dispose();
    _joinTextTitle.dispose();
    _joinTextBody.dispose();
    _networkUiVersion.dispose();
    _joinUiVersion.dispose();
    unawaited(
      _roomRuntimeService.setKeepAwake(enabled: false).catchError((_) {}),
    );
    unawaited(_roomRuntimeService.stopMdnsRoom().catchError((_) {}));
    unawaited(_roomRuntimeService.stopForegroundRoom().catchError((_) {}));
    unawaited(_server.stop());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    if (_appInForeground) {
      unawaited(_loadLibraryFiles());
      unawaited(_refreshNetworkStatus());
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_handleBackNavigation());
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: IndexedStack(
            index: _tab,
            children: [
              _homeTab(),
              _roomsTab(),
              _libraryTab(),
              _smartSendTab(),
              _settingsTab(),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (index) {
            setState(() => _tab = index);
            if (index == 1) {
              unawaited(_discoverNearbyRooms());
            }
            if (index == 2) {
              unawaited(_loadLibraryFiles());
            }
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.hub_outlined),
              label: 'Rooms',
            ),
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              label: 'Library',
            ),
            NavigationDestination(
              icon: Icon(Icons.flash_on_outlined),
              label: 'Smart Send',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  Widget _homeTab() {
    final session = _session;
    return _Screen(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _brandHeader(),
          const SizedBox(height: 18),
          _StatusPill(
            icon: session == null ? Icons.wifi_off_outlined : Icons.public,
            label: session == null ? 'Offline' : 'Hosting Drop Room',
            color: session == null ? Colors.white54 : DropTheme.success,
          ),
          const SizedBox(height: 22),
          Text(
            'Start, scan, send.',
            style: Theme.of(
              context,
            ).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Text(
            session == null
                ? 'Drop files, text, and media between nearby devices without a cloud account or forced app install.'
                : 'Share the Drop Code or link with guests on this network.',
          ),
          const SizedBox(height: 22),
          _ActionGrid(
            children: session == null
                ? [
                    _PrimaryAction(
                      icon: Icons.add_circle_outline,
                      title: 'Start Drop Room',
                      subtitle: 'Host a local browser room on this network.',
                      onTap: _showStartRoomSheet,
                    ),
                    _PrimaryAction(
                      icon: Icons.login_outlined,
                      title: 'Join Drop Room',
                      subtitle:
                          'Enter a local Drop Link and browse after auth.',
                      onTap: () => setState(() => _tab = 1),
                    ),
                  ]
                : [
                    _PrimaryAction(
                      icon: Icons.qr_code,
                      title: 'Show Drop Code',
                      subtitle: 'Let nearby guests scan and join this room.',
                      onTap: () => _showQrDialog(session),
                    ),
                    _PrimaryAction(
                      icon: Icons.copy,
                      title: 'Copy Drop Link',
                      subtitle: 'Share the browser link for this live room.',
                      onTap: () => _copy(session.baseUrl, 'Drop Link copied'),
                    ),
                  ],
          ),
          const SizedBox(height: 18),
          _QuickActions(
            onSmartSend: () => setState(() => _tab = 3),
            onLibrary: () => setState(() => _tab = 2),
            onQr: session == null
                ? _scanDropCode
                : () => _showQrDialog(session),
          ),
          const SizedBox(height: 18),
          if (session == null)
            _InfoCard(
              title: 'Ready when your Wi-Fi is',
              subtitle:
                  'Start a room, share the QR code, and browser guests can upload, download, create folders, paste text, and stream local media.',
              icon: Icons.wifi_tethering_outlined,
            )
          else
            _hostDashboard(session),
        ],
      ),
    );
  }

  Widget _roomsTab() {
    final session = _session;
    return _Screen(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: 'Rooms',
            action: session == null
                ? FilledButton.icon(
                    onPressed: _showStartRoomSheet,
                    icon: const Icon(Icons.add),
                    label: const Text('Start'),
                  )
                : FilledButton.tonalIcon(
                    onPressed: () => _showQrDialog(session),
                    icon: const Icon(Icons.qr_code),
                    label: const Text('Drop Code'),
                  ),
          ),
          const SizedBox(height: 12),
          if (session != null) _hostDashboard(session),
          const SizedBox(height: 12),
          _nearbyRoomsCard(),
          const SizedBox(height: 12),
          _manualJoinCard(),
          const SizedBox(height: 12),
          _foundRoomsSection(),
        ],
      ),
    );
  }

  Widget _libraryTab() {
    final hasLibrarySource = _server.isRunning || _hostFolderSelection != null;
    return _Screen(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: 'Library',
            action: IconButton(
              onPressed: hasLibrarySource
                  ? () => unawaited(_loadLibraryFiles())
                  : null,
              icon: _loadingLibraryFiles
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
          ),
          const SizedBox(height: 12),
          if (!hasLibrarySource)
            _InfoCard(
              title: 'Choose a Drop folder',
              subtitle:
                  'Library opens your selected phone storage folder even when no room is running.',
              icon: Icons.folder_special_outlined,
              onTap: () => unawaited(_selectHostFolder()),
            )
          else ...[
            _libraryPathBar(),
            const SizedBox(height: 10),
            if (_libraryError != null)
              _InfoCard(
                title: 'Could not open folder',
                subtitle: _libraryError!,
                icon: Icons.error_outline,
                onTap: () => unawaited(_loadLibraryFiles()),
              )
            else if (_loadingLibraryFiles)
              const _InfoCard(
                title: 'Loading folder',
                subtitle: 'Reading the selected Drop folder.',
                icon: Icons.folder_open_outlined,
              )
            else if (_files.isEmpty)
              const _InfoCard(
                title: 'Folder is empty',
                subtitle: 'Uploads, pasted text, and local files appear here.',
                icon: Icons.folder_open_outlined,
              )
            else
              ..._files.map(_fileTile),
          ],
        ],
      ),
    );
  }

  Widget _smartSendTab() {
    return _Screen(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(title: 'Smart Send'),
          const SizedBox(height: 12),
          _InfoCard(
            title: 'Clipboard is explicit',
            subtitle:
                'Paste or type text here. The app only reads clipboard content after a user action.',
            icon: Icons.content_paste_outlined,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _smartTitle,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _smartText,
            minLines: 7,
            maxLines: 12,
            decoration: const InputDecoration(
              labelText: 'Text, SMS copy, link, or note',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _server.isRunning ? _saveSmartText : null,
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('Send to Room'),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                onPressed: _pasteClipboard,
                icon: const Icon(Icons.paste),
                tooltip: 'Paste clipboard',
              ),
            ],
          ),
          const SizedBox(height: 12),
          _FeatureGrid(
            items: const [
              ('Screenshot OCR', Icons.document_scanner_outlined, 'Planned'),
              ('Share Sheet', Icons.ios_share_outlined, 'Planned'),
              ('Files', Icons.attach_file_outlined, 'Native picker ready'),
              ('Links', Icons.link_outlined, 'Send as text'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _settingsTab() {
    return _Screen(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(title: 'Settings'),
          const SizedBox(height: 12),
          _SettingsTile(
            icon: Icons.security_outlined,
            title: 'Require password by default',
            value: _usePassword,
            onChanged: (value) => setState(() => _usePassword = value),
          ),
          _SettingsTile(
            icon: Icons.local_fire_department_outlined,
            title: 'Burn Mode default',
            value: _burnMode,
            onChanged: (value) => setState(() => _burnMode = value),
          ),
          const SizedBox(height: 8),
          _hostFolderSettingsCard(),
          const SizedBox(height: 28),
          Align(
            alignment: Alignment.centerRight,
            child: _FooterIconButton(
              onTap: () => _openInfoScreen(
                _AboutScreen(
                  networkLoading: _networkLoading,
                  networkStatus: _networkStatus,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hostFolderSettingsCard() {
    final selection = _hostFolderSelection;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: DropTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.folder_special_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Drop folder',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              selection == null
                  ? _loadingHostFolderSelection
                        ? 'Checking saved Drop folder...'
                        : 'No folder selected'
                  : selection.name,
            ),
            const SizedBox(height: 4),
            Text(
              selection == null
                  ? 'Choose the phone storage folder used by Library and Drop Rooms.'
                  : 'Library and rooms use this ${selection.platform} folder.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _hostFolderBusy
                      ? null
                      : () => unawaited(_selectHostFolder()),
                  icon: _hostFolderBusy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.folder_open_outlined),
                  label: Text(
                    selection == null ? 'Select Drop Folder' : 'Change Folder',
                  ),
                ),
                if (selection != null && !_server.isRunning)
                  TextButton.icon(
                    onPressed: _hostFolderBusy
                        ? null
                        : _forgetHostFolderSelection,
                    icon: const Icon(Icons.restart_alt_outlined),
                    label: const Text('Forget Folder'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dropFolderStartCard(StateSetter setSheetState) {
    final selection = _hostFolderSelection;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selection == null
                      ? Icons.folder_special_outlined
                      : Icons.folder_open_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Drop folder',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        selection == null ? 'Required' : selection.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _hostFolderBusy
                      ? null
                      : () async {
                          await _selectHostFolder();
                          setSheetState(() {});
                        },
                  icon: _hostFolderBusy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.folder_open_outlined),
                  label: Text(selection == null ? 'Select' : 'Change'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              selection == null
                  ? 'Used by Library, uploads, text, and browser drops.'
                  : 'Library, uploads, text, and browser drops use this root.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _hostDashboard(DropRoomSession session) {
    final storage = _storage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 430;
                    final qr = Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: QrImageView(
                        data: session.baseUrl,
                        version: QrVersions.auto,
                        size: narrow ? 116 : 132,
                        backgroundColor: Colors.white,
                      ),
                    );
                    final headline = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.name,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 6),
                        SelectableText(session.baseUrl),
                      ],
                    );
                    final statuses = Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _StatusPill(
                          icon: session.authRequired
                              ? Icons.lock_outline
                              : Icons.lock_open_outlined,
                          label: session.authRequired
                              ? 'Password room'
                              : 'Open room',
                          color: session.authRequired
                              ? DropTheme.amber
                              : DropTheme.success,
                        ),
                        _StatusPill(
                          icon: session.usesExternalHostFolder
                              ? Icons.folder_open_outlined
                              : Icons.folder_special_outlined,
                          label: session.usesExternalHostFolder
                              ? 'Drop folder ${session.hostFolderName ?? 'Selected folder'}'
                              : 'Drop folder not selected',
                          color: DropTheme.orange,
                        ),
                        if (Platform.isIOS)
                          const _StatusPill(
                            icon: Icons.visibility_outlined,
                            label: 'Screen stays awake',
                            color: DropTheme.amber,
                          ),
                      ],
                    );
                    if (narrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              qr,
                              const SizedBox(width: 12),
                              Expanded(child: headline),
                            ],
                          ),
                          const SizedBox(height: 10),
                          statuses,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        qr,
                        const SizedBox(width: 14),
                        Expanded(child: headline),
                        const SizedBox(width: 14),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: statuses,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final copy = FilledButton.icon(
                      onPressed: () =>
                          _copy(session.baseUrl, 'Drop Link copied'),
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy Drop Link'),
                    );
                    final qrButton = IconButton.filledTonal(
                      onPressed: () => _showQrDialog(session),
                      icon: const Icon(Icons.qr_code),
                      tooltip: 'Show QR',
                    );
                    final stop = IconButton.filledTonal(
                      onPressed: _stopRoom,
                      icon: const Icon(Icons.stop_circle_outlined),
                      tooltip: 'Stop room',
                    );
                    if (constraints.maxWidth < 360) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          copy,
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              qrButton,
                              const SizedBox(width: 10),
                              stop,
                            ],
                          ),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: copy),
                        const SizedBox(width: 10),
                        qrButton,
                        const SizedBox(width: 10),
                        stop,
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Storage',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: _storageProgress(session, storage),
                ),
                const SizedBox(height: 10),
                Text(
                  storage == null
                      ? 'Loading storage...'
                      : _storageSummary(session, storage),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _fileTile(DropFileItem item) {
    final isFolder = item.type == 'folder';
    return Card(
      child: ListTile(
        leading: Icon(
          isFolder ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
        ),
        title: Text(item.name),
        subtitle: Text(
          isFolder
              ? item.path
              : '${formatBytes(item.sizeBytes)} · ${item.mimeType ?? 'file'}',
        ),
        trailing: isFolder
            ? const Icon(Icons.chevron_right)
            : PopupMenuButton<_LibraryFileAction>(
                tooltip: 'File actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  switch (action) {
                    case _LibraryFileAction.open:
                      unawaited(_openLibraryFile(item));
                    case _LibraryFileAction.share:
                      unawaited(_shareLibraryFile(item));
                    case _LibraryFileAction.delete:
                      unawaited(_confirmDeleteLibraryFile(item));
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _LibraryFileAction.open,
                    child: ListTile(
                      leading: Icon(Icons.open_in_new_outlined),
                      title: Text('Open'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _LibraryFileAction.share,
                    child: ListTile(
                      leading: Icon(Icons.ios_share_outlined),
                      title: Text('Share'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _LibraryFileAction.delete,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Delete'),
                    ),
                  ),
                ],
              ),
        onTap: isFolder
            ? () {
                setState(() => _libraryPath = item.path);
                unawaited(_loadLibraryFiles());
              }
            : () => _openLibraryFile(item),
      ),
    );
  }

  Widget _libraryPathBar() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Browsing ${_dropFolderLabel()} $_libraryPath',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              onPressed: _libraryPath == '/' ? null : _libraryUpFolder,
              icon: const Icon(Icons.drive_folder_upload_outlined),
              tooltip: 'Up folder',
            ),
          ],
        ),
      ),
    );
  }

  Widget _manualJoinCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.link_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Find a Drop Room',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _joinUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Drop Link',
                hintText: 'http://192.168.1.23:8787',
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _joining ? null : _previewJoinRoom,
                  icon: _joining
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.travel_explore),
                  label: const Text('Check Room'),
                ),
                FilledButton.icon(
                  onPressed: _joining ? null : _scanDropCode,
                  icon: const Icon(Icons.qr_code_scanner_outlined),
                  label: const Text('Scan Code'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _nearbyRoomsCard() {
    final message =
        _nearbyDiscoveryMessage ??
        'Browse this Wi-Fi or hotspot network for advertised Drop Rooms.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.radar_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Nearby Rooms',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(message),
                ],
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              onPressed: _discoveringRooms
                  ? null
                  : () => unawaited(_discoverNearbyRooms()),
              icon: _discoveringRooms
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              tooltip: 'Discover nearby rooms',
            ),
          ],
        ),
      ),
    );
  }

  Widget _foundRoomsSection() {
    if (_foundJoinRooms.isEmpty) {
      return const _InfoCard(
        title: 'No rooms found yet',
        subtitle:
            'Scan a Drop Code or paste a local Drop Link to add a room here.',
        icon: Icons.travel_explore_outlined,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Found Rooms'),
        const SizedBox(height: 10),
        ..._foundJoinRooms.map(_foundRoomTile),
      ],
    );
  }

  Widget _foundRoomTile(JoinRoomPreview preview) {
    final active =
        _joinPreview?.baseUrl == preview.baseUrl && _joinSession != null;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => unawaited(_openJoinRoomDetail(preview)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RoomAvatar(icon: _roomIcon(preview), active: active),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preview.roomName,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${preview.deviceName} · ${_roomPlatformLabel(preview)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _StatusPill(
                          icon: preview.authRequired
                              ? Icons.lock_outline
                              : Icons.lock_open_outlined,
                          label: preview.authRequired ? 'Password' : 'Open',
                          color: preview.authRequired
                              ? DropTheme.amber
                              : DropTheme.success,
                        ),
                        _StatusPill(
                          icon: Icons.folder_outlined,
                          label: preview.scopedToDefaultFolder
                              ? 'Scoped'
                              : 'Drop folder',
                          color: DropTheme.orange,
                        ),
                        if (active)
                          const _StatusPill(
                            icon: Icons.check_circle_outline,
                            label: 'Joined',
                            color: DropTheme.success,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  void _rememberFoundRoom(JoinRoomPreview preview) {
    final existingIndex = _foundJoinRooms.indexWhere(
      (room) => room.baseUrl == preview.baseUrl,
    );
    if (existingIndex >= 0) {
      _foundJoinRooms[existingIndex] = preview;
      return;
    }
    _foundJoinRooms = [preview, ..._foundJoinRooms].take(5).toList();
  }

  Future<void> _discoverNearbyRooms({bool silent = false}) async {
    if (_discoveringRooms) return;
    _lastNearbyDiscovery = DateTime.now();
    _setJoinState(() {
      _discoveringRooms = true;
      if (!silent) {
        _nearbyDiscoveryMessage = null;
      }
    });
    try {
      final rooms = await _nearbyRoomService.discoverRooms();
      if (!mounted) return;
      final ownSession = _session;
      final visibleRooms = rooms
          .where(
            (room) =>
                ownSession?.id != room.roomId &&
                ownSession?.baseUrl != room.baseUrl,
          )
          .toList();
      _setJoinState(() {
        _foundJoinRooms = visibleRooms.take(5).toList();
        _nearbyDiscoveryMessage = visibleRooms.isEmpty
            ? 'No other Drop Rooms found on this network.'
            : 'Found ${visibleRooms.length} Drop Room${visibleRooms.length == 1 ? '' : 's'} nearby.';
      });
    } catch (error) {
      if (mounted) {
        _setJoinState(() {
          _nearbyDiscoveryMessage = 'Could not browse nearby rooms: $error';
        });
      }
    } finally {
      if (mounted) {
        _setJoinState(() => _discoveringRooms = false);
      }
    }
  }

  Future<void> _openJoinRoomDetail(JoinRoomPreview preview) async {
    _setJoinState(() {
      if (_joinPreview?.baseUrl != preview.baseUrl) {
        _joinSession = null;
        _joinItems = <DropFileItem>[];
        _joinPath = _initialJoinPath(preview);
        _joinActivity = null;
        _joinTransfer = null;
        _joinPassword.clear();
      }
      _joinPreview = preview;
      _rememberFoundRoom(preview);
    });

    if (preview.authRequired) {
      final password = await _promptJoinPassword(preview);
      if (!mounted || password == null) return;
      _joinPassword.text = password;
    }

    final joined = await _loginJoinRoom();
    if (!mounted || !joined) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ValueListenableBuilder<int>(
          valueListenable: _joinUiVersion,
          builder: (context, _, _) {
            final activePreview = _joinPreview ?? preview;
            return _JoinedRoomDetailScreen(
              preview: activePreview,
              session: _joinSession,
              path: _joinPath,
              items: _joinItems,
              activity: _joinActivity,
              transfer: _joinTransfer,
              joining: _joining,
              passwordController: _joinPassword,
              folderNameController: _joinFolderName,
              textTitleController: _joinTextTitle,
              textBodyController: _joinTextBody,
              onJoin: () async {
                await _loginJoinRoom();
              },
              onRefresh: _loadJoinedFiles,
              onUpFolder: _joinedUpFolder,
              onUploadFiles: _pickAndUploadJoinedFiles,
              onCreateFolder: _createJoinedFolder,
              onSendText: _sendJoinedText,
              onFolderTap: (item) {
                _setJoinState(() => _joinPath = item.path);
                unawaited(_loadJoinedFiles());
              },
              onDownload: _downloadJoinedFile,
              transferBuilder: _transferPanel,
            );
          },
        ),
      ),
    );
    _disconnectJoinedRoom(preview);
  }

  Future<String?> _promptJoinPassword(JoinRoomPreview preview) async {
    _joinPassword.clear();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(preview.roomName),
          content: TextField(
            controller: _joinPassword,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Room password'),
            onSubmitted: (value) {
              final password = value.trim();
              if (password.isNotEmpty) {
                Navigator.of(context).pop(password);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final password = _joinPassword.text.trim();
                if (password.isNotEmpty) {
                  Navigator.of(context).pop(password);
                }
              },
              child: const Text('Join'),
            ),
          ],
        );
      },
    );
  }

  void _disconnectJoinedRoom(JoinRoomPreview preview) {
    if (_joinPreview?.baseUrl != preview.baseUrl) return;
    _setJoinState(() {
      _joinPreview = null;
      _joinSession = null;
      _joinItems = <DropFileItem>[];
      _joinPath = '/';
      _joinActivity = null;
      _joinTransfer = null;
      _joinPassword.clear();
    });
  }

  String _initialJoinPath(JoinRoomPreview preview) {
    return preview.scopedToDefaultFolder
        ? preview.scopePath
        : preview.defaultUploadPath;
  }

  IconData _roomIcon(JoinRoomPreview preview) {
    final platform = preview.devicePlatform.toLowerCase();
    final type = preview.deviceType.toLowerCase();
    if (platform.contains('android')) return Icons.android;
    if (platform.contains('ios')) return Icons.phone_iphone;
    if (type.contains('phone')) return Icons.smartphone_outlined;
    if (platform.contains('mac')) return Icons.laptop_mac_outlined;
    if (platform.contains('windows') || platform.contains('linux')) {
      return Icons.computer_outlined;
    }
    return Icons.devices_other_outlined;
  }

  String _roomPlatformLabel(JoinRoomPreview preview) {
    final platform = preview.devicePlatform.toLowerCase();
    if (platform.contains('android')) return 'Android phone';
    if (platform.contains('ios')) return 'iPhone';
    if (platform.contains('mac')) return 'Mac';
    if (platform.contains('windows')) return 'Windows';
    if (platform.contains('linux')) return 'Linux';
    return preview.deviceType.isEmpty ? 'Local device' : preview.deviceType;
  }

  Widget _transferPanel(TransferProgress transfer) {
    final progress = transfer.progress;
    final speed = transfer.speedBytesPerSecond <= 0
        ? 'Calculating...'
        : '${formatBytes(transfer.speedBytesPerSecond.round())}/s';
    final eta = transfer.completed
        ? 'Done'
        : transfer.eta == null
        ? 'ETA unavailable'
        : _formatEta(transfer.eta!);
    final total = transfer.totalBytes <= 0
        ? formatBytes(transfer.sentBytes)
        : '${formatBytes(transfer.sentBytes)} / ${formatBytes(transfer.totalBytes)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  transfer.direction == TransferDirection.upload
                      ? Icons.upload_outlined
                      : Icons.download_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    transfer.title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                if (progress != null)
                  Text('${(progress * 100).clamp(0, 100).round()}%'),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text('$total · $speed · $eta'),
            if (transfer.detail.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                transfer.detail,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _networkPanel() {
    final status = _networkStatus;
    final isReady = status.isReady;
    final icon = isReady
        ? status.isHotspot
              ? Icons.wifi_tethering
              : Icons.network_wifi_outlined
        : Icons.wifi_tethering_error_outlined;
    final title = _networkLoading
        ? 'Checking network'
        : isReady
        ? 'Creating over ${status.label}'
        : 'Create a hotspot first';
    final description = _networkLoading
        ? 'Looking for Wi-Fi or an active hotspot.'
        : isReady
        ? 'Guests must join the same ${status.label} network.'
        : 'Turn on a phone hotspot, connect guests, then refresh.';
    final guideLabel = Platform.isIOS
        ? 'Personal Hotspot Guide'
        : 'Hotspot Guide';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(description),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _networkLoading
                      ? null
                      : () => unawaited(_refreshNetworkStatus()),
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh network',
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_networkLoading)
              const Row(
                children: [
                  SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('Checking network...'),
                ],
              )
            else if (isReady)
              _StatusPill(
                icon: Icons.check_circle_outline,
                label: 'Mode: ${status.label}',
                color: status.isHotspot ? DropTheme.amber : DropTheme.success,
              )
            else
              FilledButton.tonalIcon(
                onPressed: _showManualHotspotGuide,
                icon: const Icon(Icons.help_outline),
                label: Text(guideLabel),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showStartRoomSheet() async {
    unawaited(_refreshNetworkStatus());
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return ValueListenableBuilder<int>(
              valueListenable: _networkUiVersion,
              builder: (context, _, _) {
                final passwordRequiredButEmpty =
                    _usePassword && _password.text.trim().isEmpty;
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    MediaQuery.of(context).viewInsets.bottom + 14,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Start Drop Room',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Guests on the same network can join from the app or a browser.',
                        ),
                        const SizedBox(height: 16),
                        _networkPanel(),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _roomName,
                          decoration: const InputDecoration(labelText: 'Room'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _deviceName,
                          decoration: const InputDecoration(labelText: 'User'),
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Password Room'),
                          value: _usePassword,
                          onChanged: (value) {
                            setSheetState(() => _usePassword = value);
                            setState(() => _usePassword = value);
                          },
                        ),
                        if (_usePassword)
                          TextField(
                            controller: _password,
                            obscureText: true,
                            onChanged: (_) => setSheetState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Room password',
                              helperText: 'Required for password rooms.',
                            ),
                          ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<RoomPermission>(
                          initialValue: _permission,
                          decoration: const InputDecoration(
                            labelText: 'Permissions',
                            helperText:
                                'Drop folder only keeps guests inside the selected folder.',
                          ),
                          items: RoomPermission.values
                              .map(
                                (permission) => DropdownMenuItem(
                                  value: permission,
                                  child: Text(permission.label),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setSheetState(() => _permission = value);
                            setState(() => _permission = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        _dropFolderStartCard(setSheetState),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Burn Mode'),
                          subtitle: const Text(
                            'Auto-expire this room after 2 hours.',
                          ),
                          value: _burnMode,
                          onChanged: (value) {
                            setSheetState(() => _burnMode = value);
                            setState(() => _burnMode = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed:
                              _starting ||
                                  passwordRequiredButEmpty ||
                                  !_networkStatus.isReady
                              ? null
                              : () async {
                                  final navigator = Navigator.of(context);
                                  final started = await _startRoom();
                                  if (mounted && started) navigator.pop();
                                },
                          icon: _starting
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _networkStatus.isHotspot
                                      ? Icons.wifi_tethering
                                      : Icons.network_wifi_outlined,
                                ),
                          label: const Text('Start Room'),
                        ),
                        if (passwordRequiredButEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Enter a password or turn off Password Room.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ] else if (!_networkStatus.isReady) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Connect to Wi-Fi or create a hotspot first.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<bool> _startRoom() async {
    final password = _password.text.trim();
    if (_usePassword && password.isEmpty) {
      _snack('Enter a room password or turn off Password Room.');
      return false;
    }
    setState(() => _starting = true);
    try {
      await _refreshNetworkStatus();
      if (!_networkStatus.isReady) {
        _snack('Connect to Wi-Fi or create a hotspot first.');
        _showManualHotspotGuide();
        return false;
      }
      final canStart = await _ensureDropFolderChoice();
      if (!canStart) return false;
      final session = await _server.start(
        DropRoomConfig(
          name: _roomName.text,
          deviceName: _deviceName.text,
          password: _usePassword ? password : '',
          permission: _permission,
          burnMode: _burnMode,
          expiry: _burnMode ? const Duration(hours: 2) : null,
          defaultUploadPath: _defaultUploadPath,
          hostFolderUri: _hostFolderSelection?.uri,
          hostFolderName: _hostFolderSelection?.name,
          hostFolderPlatform: _hostFolderSelection?.platform,
        ),
      );
      try {
        await _roomRuntimeService.setKeepAwake(enabled: true);
      } on PlatformException {
        // Keep-awake is a foreground convenience; hosting still works without it.
      }
      try {
        await _roomRuntimeService.startForegroundRoom(
          roomName: session.name,
          baseUrl: session.baseUrl,
        );
      } on PlatformException {
        // Some Android builds deny foreground notifications until the user
        // grants notification permission. The local server can still run.
      }
      try {
        await _roomRuntimeService.publishMdnsRoom(session);
      } on PlatformException {
        // mDNS is best-effort. The direct Drop Link still works.
      }
      await _refreshRoomData();
      if (mounted) {
        _snack('Drop Room is live');
      }
      return true;
    } catch (error) {
      if (mounted) {
        _snack('Could not start room: $error');
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  void _showManualHotspotGuide() {
    final hotspotName = Platform.isIOS
        ? 'Personal Hotspot'
        : 'Portable Hotspot';
    final title = Platform.isIOS ? 'Personal Hotspot Guide' : 'Hotspot Guide';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Open system Settings.'),
            const SizedBox(height: 8),
            Text('2. Enable $hotspotName.'),
            const SizedBox(height: 8),
            const Text('3. Connect guests to that hotspot.'),
            const SizedBox(height: 8),
            const Text('4. Return here and tap Start Room.'),
            const SizedBox(height: 8),
            const Text('5. Keep Erebrus Drop open during transfers.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleBackNavigation() async {
    if (_backDialogOpen || !mounted) return;
    _backDialogOpen = true;
    try {
      final action = await _showBackActionDialog();
      if (!mounted || action == null) return;
      switch (action) {
        case _BackAction.background:
          await _moveAppToBackground();
        case _BackAction.close:
          await _closeAppFromBack();
      }
    } finally {
      _backDialogOpen = false;
    }
  }

  Future<_BackAction?> _showBackActionDialog() {
    final hosting = _server.isRunning;
    final canBackground = !Platform.isIOS;
    return showDialog<_BackAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          hosting
              ? Platform.isIOS
                    ? 'Keep Drop Room open?'
                    : 'Keep Drop Room running?'
              : 'Close Erebrus Drop?',
        ),
        content: Text(
          hosting
              ? Platform.isIOS
                    ? 'The screen stays awake while this room is active. Keep Erebrus Drop open while guests transfer; iOS pauses local hosting if the app is backgrounded. Closing the app will stop the room.'
                    : 'A Drop Room is active. You can keep Erebrus Drop running in the background so guests can continue transfers. Closing the app will stop the room and disconnect guests.'
              : Platform.isIOS
              ? 'Close Erebrus Drop?'
              : 'You can keep Erebrus Drop in the background or close the app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_BackAction.close),
            child: Text(hosting ? 'Stop Room & Close' : 'Close App'),
          ),
          if (canBackground)
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_BackAction.background),
              child: Text(hosting ? 'Keep Hosting' : 'Background'),
            )
          else
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Keep Open'),
            ),
        ],
      ),
    );
  }

  Future<void> _moveAppToBackground() async {
    try {
      await _roomRuntimeService.moveAppToBackground();
    } on PlatformException {
      await SystemNavigator.pop();
    }
  }

  Future<void> _closeAppFromBack() async {
    if (_server.isRunning) {
      await _stopRoom();
    }
    await SystemNavigator.pop();
  }

  Future<void> _stopRoom() async {
    try {
      await _roomRuntimeService.setKeepAwake(enabled: false);
    } on PlatformException {
      // Keep-awake reset is best-effort.
    }
    try {
      await _roomRuntimeService.stopMdnsRoom();
    } on PlatformException {
      // Local discovery publishing is best-effort.
    }
    try {
      await _roomRuntimeService.stopForegroundRoom();
    } on PlatformException {
      // The foreground service is Android-only and best-effort.
    }
    await _server.stop();
    if (!mounted) return;
    setState(() {
      _storage = null;
      _files = <DropFileItem>[];
      _libraryPath = '/';
    });
    unawaited(_loadLibraryFiles());
    _snack('Drop Room stopped');
  }

  Future<void> _refreshRoomData() async {
    if (!_server.isRunning || _refreshingRoomData) return;
    _refreshingRoomData = true;
    try {
      final storage = await _server.storageSnapshot();
      final files = await _server.listFiles(_libraryPath);
      if (!mounted) return;
      setState(() {
        _storage = storage;
        _files = files;
        _libraryError = null;
      });
    } catch (_) {
      // Upload temp files can move while storage is being measured.
      // The next periodic refresh will pick up the settled state.
    } finally {
      _refreshingRoomData = false;
    }
  }

  Future<void> _loadLibraryFiles() async {
    if (_loadingLibraryFiles) return;
    if (mounted) {
      setState(() {
        _loadingLibraryFiles = true;
        _libraryError = null;
      });
    }
    try {
      if (_server.isRunning) {
        await _refreshRoomData();
        return;
      }
      final selection = _hostFolderSelection;
      if (selection == null) {
        if (!mounted) return;
        setState(() {
          _files = <DropFileItem>[];
          _libraryError = null;
        });
        return;
      }
      final items = await _hostFolderBridge.list(
        rootUri: selection.uri,
        path: _libraryPath,
      );
      if (!mounted) return;
      setState(() {
        _files = items.map(_dropFileItemFromHostFolderItem).toList();
        _libraryError = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _files = <DropFileItem>[];
        _libraryError = error.message ?? 'Could not read the selected folder.';
      });
    } on MissingPluginException {
      if (!mounted) return;
      setState(() {
        _files = <DropFileItem>[];
        _libraryError =
            'Folder browsing needs the latest native build. Stop the app and run a fresh build, then try again.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _files = <DropFileItem>[];
        _libraryError = 'Could not read the selected folder: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _loadingLibraryFiles = false);
      }
    }
  }

  void _libraryUpFolder() {
    if (_libraryPath == '/') return;
    final parts = _libraryPath
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    parts.removeLast();
    setState(() => _libraryPath = parts.isEmpty ? '/' : '/${parts.join('/')}');
    unawaited(_loadLibraryFiles());
  }

  Future<void> _saveSmartText() async {
    if (_smartText.text.trim().isEmpty) {
      _snack('Paste or type text first');
      return;
    }
    await _server.saveTextSnippet(
      title: _smartTitle.text,
      body: _smartText.text,
    );
    _smartText.clear();
    await _refreshRoomData();
    _snack('Text saved to the room');
  }

  String _dropFolderLabel() {
    final session = _session;
    if (session?.usesExternalHostFolder == true) {
      return session!.hostFolderName ?? 'selected folder';
    }
    final selection = _hostFolderSelection;
    if (selection != null) {
      return selection.name;
    }
    return 'No Drop folder selected';
  }

  double? _storageProgress(DropRoomSession session, StorageSnapshot? storage) {
    final total = storage?.totalBytes;
    if (storage == null || total == null || total <= 0) {
      return null;
    }
    final used = session.usesExternalHostFolder
        ? storage.folderUsedBytes
        : storage.roomUsedBytes;
    if (used == null) {
      return null;
    }
    return (used / total).clamp(0.0, 1.0).toDouble();
  }

  String _storageSummary(DropRoomSession session, StorageSnapshot storage) {
    if (session.usesExternalHostFolder) {
      return '${session.hostFolderName ?? 'Selected folder'} · ${_folderUsageSummary(storage)} · Transfer capacity ${formatBytes(storage.availableBytes)} · Upload cap ${formatBytes(storage.maxUploadBytes)}';
    }
    return 'Room ${formatBytes(storage.roomUsedBytes)} · Drop ${formatBytes(storage.dropUsedBytes)} · Transfer capacity ${formatBytes(storage.availableBytes)}';
  }

  String _folderUsageSummary(StorageSnapshot storage) {
    final used = storage.folderUsedBytes;
    if (used != null) {
      final scannedAt = storage.folderScannedAt;
      final age = scannedAt == null
          ? ''
          : ' · scanned ${_shortAge(scannedAt)} ago';
      return 'Folder ${formatBytes(used)}$age';
    }
    if (storage.folderScanStatus == 'queued' ||
        storage.folderScanStatus == 'scanning') {
      return 'Folder scanning...';
    }
    return 'Folder size unavailable';
  }

  String _shortAge(DateTime time) {
    final seconds = DateTime.now().difference(time).inSeconds;
    if (seconds < 60) {
      return '${math.max(0, seconds)}s';
    }
    final minutes = (seconds / 60).round();
    if (minutes < 60) {
      return '${minutes}m';
    }
    return '${(minutes / 60).round()}h';
  }

  Future<void> _openLibraryFile(DropFileItem item) async {
    try {
      final selection = _hostFolderSelection;
      if (_server.isRunning) {
        await _server.openFile(item);
      } else if (selection != null) {
        await _hostFolderBridge.openFile(
          rootUri: selection.uri,
          path: item.path,
        );
      } else {
        _snack('Select a Drop folder first.');
      }
    } on FileSystemException catch (error) {
      _snack(error.message);
    } on PlatformException catch (error) {
      _snack(error.message ?? 'Could not open ${item.name}');
    } on MissingPluginException {
      _snack(
        'File opening needs the latest native build. Stop the app and run a fresh build, then try again.',
      );
    } catch (error) {
      _snack('Could not open ${item.name}: $error');
    }
  }

  Future<void> _shareLibraryFile(DropFileItem item) async {
    try {
      final selection = _hostFolderSelection;
      if (item.type == 'folder') {
        _snack('Share a file, not a folder.');
      } else if (_server.isRunning) {
        await _server.shareFile(item);
      } else if (selection != null) {
        await _hostFolderBridge.shareFile(
          rootUri: selection.uri,
          path: item.path,
        );
      } else {
        _snack('Select a Drop folder first.');
      }
    } on FileSystemException catch (error) {
      _snack(error.message);
    } on PlatformException catch (error) {
      _snack(error.message ?? 'Could not share ${item.name}');
    } on MissingPluginException {
      _snack(
        'File sharing needs the latest native build. Stop the app and run a fresh build, then try again.',
      );
    } catch (error) {
      _snack('Could not share ${item.name}: $error');
    }
  }

  Future<void> _confirmDeleteLibraryFile(DropFileItem item) async {
    if (item.type == 'folder') {
      _snack('Delete a file, not a folder.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text('Delete ${item.name}? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _deleteLibraryFile(item);
    }
  }

  Future<void> _deleteLibraryFile(DropFileItem item) async {
    try {
      final selection = _hostFolderSelection;
      if (_server.isRunning) {
        await _server.deleteFile(item);
        await _refreshRoomData();
      } else if (selection != null) {
        await _hostFolderBridge.deleteFile(
          rootUri: selection.uri,
          path: item.path,
        );
        await _loadLibraryFiles();
      } else {
        _snack('Select a Drop folder first.');
        return;
      }
      if (mounted) {
        _snack('${item.name} deleted');
      }
    } on FileSystemException catch (error) {
      _snack(error.message);
    } on PlatformException catch (error) {
      _snack(error.message ?? 'Could not delete ${item.name}');
    } on MissingPluginException {
      _snack(
        'File deletion needs the latest native build. Stop the app and run a fresh build, then try again.',
      );
    } catch (error) {
      _snack('Could not delete ${item.name}: $error');
    }
  }

  DropFileItem _dropFileItemFromHostFolderItem(HostFolderItem item) {
    final isDirectory = item.type == 'folder';
    final mimeType = isDirectory
        ? null
        : item.mimeType ?? _mimeTypeForName(item.name);
    return DropFileItem(
      id: item.path,
      name: item.name,
      type: isDirectory ? 'folder' : 'file',
      path: _normalizeLibraryPath(item.path),
      sizeBytes: isDirectory ? 0 : item.sizeBytes,
      createdAt: item.modifiedAt,
      modifiedAt: item.modifiedAt,
      mimeType: mimeType,
      streamable: _isStreamableMime(mimeType),
    );
  }

  bool _isStreamableMime(String? mimeType) {
    return mimeType?.startsWith('video/') == true ||
        mimeType?.startsWith('audio/') == true;
  }

  String _normalizeLibraryPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty || trimmed == '/') {
      return '/';
    }
    final withSlash = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return withSlash.length > 1 && withSlash.endsWith('/')
        ? withSlash.substring(0, withSlash.length - 1)
        : withSlash;
  }

  String _mimeTypeForName(String name) {
    final extension = name.split('.').last.toLowerCase();
    switch (extension) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
      case 'log':
      case 'md':
        return 'text/plain';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'm4v':
        return 'video/x-m4v';
      case 'webm':
        return 'video/webm';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _previewJoinRoom() async {
    _setJoinState(() => _joining = true);
    try {
      final preview = await _joinRoomService.preview(_joinUrl.text);
      if (!mounted) return;
      _setJoinState(() {
        _joinPreview = preview;
        _joinSession = null;
        _joinItems = <DropFileItem>[];
        _joinPath = _initialJoinPath(preview);
        _joinActivity = null;
        _joinTransfer = null;
        _rememberFoundRoom(preview);
      });
      _snack('Found ${preview.roomName}');
    } catch (error) {
      if (mounted) _snack('Could not find room: $error');
    } finally {
      if (mounted) _setJoinState(() => _joining = false);
    }
  }

  Future<bool> _loginJoinRoom() async {
    final preview = _joinPreview;
    if (preview == null) {
      await _previewJoinRoom();
      return false;
    }
    _setJoinState(() => _joining = true);
    try {
      final joinSession = await _joinRoomService.login(
        baseUrl: preview.baseUrl,
        password: preview.authRequired ? _joinPassword.text : '',
      );
      if (!mounted) return false;
      _setJoinState(() {
        _joinSession = joinSession;
        _joinPath = _initialJoinPath(preview);
      });
      _snack('Joined ${preview.roomName}');
      await _loadJoinedFiles();
      return true;
    } catch (error) {
      if (mounted) _snack('Could not join room: $error');
      return false;
    } finally {
      if (mounted) _setJoinState(() => _joining = false);
    }
  }

  Future<void> _scanDropCode() async {
    final scannedUrl = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (scannedUrl == null || scannedUrl.trim().isEmpty) return;
    _setJoinState(() {
      _tab = 1;
      _joinUrl.text = scannedUrl;
      _joinPreview = null;
      _joinSession = null;
      _joinItems = <DropFileItem>[];
      _joinPath = '/';
    });
    await _previewJoinRoom();
  }

  Future<void> _loadJoinedFiles() async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    if (preview == null || joinSession == null) return;
    _setJoinState(() => _joinActivity = 'Loading remote files...');
    try {
      final items = await _joinRoomService.listFiles(
        baseUrl: preview.baseUrl,
        token: joinSession.token,
        path: _joinPath,
      );
      if (!mounted) return;
      _setJoinState(() {
        _joinItems = items;
        _joinActivity = null;
      });
    } catch (error) {
      if (mounted) {
        _setJoinState(() => _joinActivity = 'Could not load files: $error');
      }
    }
  }

  Future<void> _createJoinedFolder() async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    final folderName = _joinFolderName.text.trim();
    if (preview == null || joinSession == null || folderName.isEmpty) return;
    try {
      await _joinRoomService.createFolder(
        baseUrl: preview.baseUrl,
        token: joinSession.token,
        path: _joinPath == '/' ? '/$folderName' : '$_joinPath/$folderName',
      );
      _joinFolderName.clear();
      await _loadJoinedFiles();
      _snack('Folder created');
    } catch (error) {
      if (mounted) _snack('Could not create folder: $error');
    }
  }

  Future<void> _sendJoinedText() async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    if (preview == null ||
        joinSession == null ||
        _joinTextBody.text.trim().isEmpty) {
      return;
    }
    try {
      await _joinRoomService.sendText(
        baseUrl: preview.baseUrl,
        token: joinSession.token,
        title: _joinTextTitle.text,
        body: _joinTextBody.text,
      );
      _joinTextBody.clear();
      await _loadJoinedFiles();
      _snack('Text sent to joined room');
    } catch (error) {
      if (mounted) _snack('Could not send text: $error');
    }
  }

  Future<void> _downloadJoinedFile(DropFileItem item) async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    if (preview == null || joinSession == null) return;
    final stopwatch = Stopwatch()..start();
    var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final saved = await _joinRoomService.downloadFile(
        baseUrl: preview.baseUrl,
        token: joinSession.token,
        item: item,
        onProgress: (received, total) {
          if (!mounted) return;
          final now = DateTime.now();
          if (now.difference(lastUpdate).inMilliseconds < 250 &&
              received != total) {
            return;
          }
          lastUpdate = now;
          final elapsed = math.max(stopwatch.elapsedMilliseconds / 1000, 0.001);
          final speed = received / elapsed;
          _setJoinState(
            () => _joinTransfer = TransferProgress(
              direction: TransferDirection.download,
              title: 'Downloading ${item.name}',
              detail: 'Saving to this device',
              sentBytes: received,
              totalBytes: total < 0 ? 0 : total,
              speedBytesPerSecond: speed,
            ),
          );
        },
      );
      if (!mounted) return;
      _setJoinState(() {
        _joinTransfer = TransferProgress.complete(
          direction: TransferDirection.download,
          title: 'Downloaded ${saved.name}',
          detail: 'Saved to ${saved.location}',
          totalBytes: item.sizeBytes,
        );
        _joinActivity = null;
      });
      _snack('Saved to ${saved.location}');
    } catch (error) {
      if (mounted) {
        _setJoinState(() => _joinTransfer = null);
        _snack('Could not download file: $error');
      }
    }
  }

  Future<void> _pickAndUploadJoinedFiles() async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    if (preview == null || joinSession == null) return;
    final pickedFiles = await _nativeFilePickerService.pickFilesForUpload();
    if (pickedFiles.isEmpty) return;
    final totalBytes = pickedFiles.fold<int>(
      0,
      (sum, file) => sum + file.sizeBytes,
    );
    final stopwatch = Stopwatch()..start();
    var uploadedBeforeCurrent = 0;
    var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      for (var index = 0; index < pickedFiles.length; index++) {
        final picked = pickedFiles[index];
        final fileName = picked.name;
        await _joinRoomService.uploadFile(
          baseUrl: preview.baseUrl,
          token: joinSession.token,
          path: _joinPath,
          file: File(picked.path),
          fileName: fileName,
          onProgress: (sent, total) {
            if (!mounted) return;
            final overallSent = uploadedBeforeCurrent + sent;
            final now = DateTime.now();
            if (now.difference(lastUpdate).inMilliseconds < 250 &&
                sent != total) {
              return;
            }
            lastUpdate = now;
            final elapsed = math.max(
              stopwatch.elapsedMilliseconds / 1000,
              0.001,
            );
            final speed = overallSent / elapsed;
            _setJoinState(
              () => _joinTransfer = TransferProgress(
                direction: TransferDirection.upload,
                title: 'Uploading ${index + 1}/${pickedFiles.length} $fileName',
                detail: 'Target $_joinPath',
                sentBytes: overallSent,
                totalBytes: totalBytes,
                speedBytesPerSecond: speed,
              ),
            );
          },
        );
        uploadedBeforeCurrent += picked.sizeBytes;
      }
      if (!mounted) return;
      _setJoinState(() {
        _joinTransfer = TransferProgress.complete(
          direction: TransferDirection.upload,
          title: 'Uploaded ${pickedFiles.length} file(s)',
          detail: 'Saved to $_joinPath',
          totalBytes: totalBytes,
        );
        _joinActivity = null;
      });
      await _loadJoinedFiles();
    } catch (error) {
      if (mounted) {
        _setJoinState(() => _joinTransfer = null);
        _snack('Could not upload files: $error');
      }
    }
  }

  void _joinedUpFolder() {
    if (_joinPath == '/') return;
    final preview = _joinPreview;
    final scopedRoot = preview?.scopedToDefaultFolder == true
        ? preview!.scopePath
        : '/';
    if (_joinPath == scopedRoot) return;
    final parts = _joinPath
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    parts.removeLast();
    final nextPath = parts.isEmpty ? '/' : '/${parts.join('/')}';
    _setJoinState(
      () => _joinPath =
          preview?.scopedToDefaultFolder == true &&
              (nextPath == '/' || !nextPath.startsWith(scopedRoot))
          ? scopedRoot
          : nextPath,
    );
    unawaited(_loadJoinedFiles());
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null || data!.text!.isEmpty) {
      _snack('Clipboard is empty');
      return;
    }
    _smartText.text = data.text!;
  }

  Future<bool> _selectHostFolder() async {
    setState(() => _hostFolderBusy = true);
    try {
      final selection = await _hostFolderService.selectHostFolder();
      if (!mounted) return false;
      if (selection == null) {
        _snack('No Drop folder selected.');
        return false;
      }
      setState(() {
        _hostFolderSelection = selection;
        _libraryPath = '/';
        _libraryError = null;
      });
      try {
        await _hostFolderService.saveSelection(selection);
      } on Object {
        if (mounted) {
          _snack(
            'Selected for this session. Could not save folder permission.',
          );
        }
      }
      if (_server.isRunning) {
        await _server.updateHostFolder(
          hostFolderUri: selection.uri,
          hostFolderName: selection.name,
          hostFolderPlatform: selection.platform,
        );
      }
      await _loadLibraryFiles();
      if (mounted) {
        _snack('Selected ${selection.name}');
      }
      return true;
    } on PlatformException catch (error) {
      if (mounted) {
        if (Platform.isIOS && error.code == 'PICK_FOLDER_UNAVAILABLE') {
          _snack(
            'The iOS Files picker is not active in this installed build. Stop the app and run a fresh iOS build, then try again.',
          );
        } else {
          _snack(error.message ?? 'Could not select a host folder');
        }
      }
      return false;
    } on MissingPluginException {
      if (mounted) {
        _snack(
          'Folder selection needs the latest native build. Stop the app and run a fresh build, then try again.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _hostFolderBusy = false);
    }
  }

  Future<void> _forgetHostFolderSelection() async {
    if (_server.isRunning) {
      _snack('Stop the active room before forgetting the Drop folder.');
      return;
    }
    await _hostFolderService.clearSelection();
    setState(() {
      _hostFolderSelection = null;
      _libraryPath = '/';
      _files = <DropFileItem>[];
      _libraryError = null;
    });
    if (mounted) {
      _snack('Drop folder permission forgotten');
    }
  }

  Future<bool> _ensureDropFolderChoice() async {
    if (_loadingHostFolderSelection) {
      await _loadHostFolderSelection();
    }
    if (!mounted) {
      return false;
    }
    if (_hostFolderSelection != null) {
      return true;
    }
    final shouldSelect = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Drop folder'),
        content: const Text(
          'Erebrus Drop needs a folder selected from Files or phone storage before it can host a room. Create or choose an ErebrusDrop folder in the picker.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('Select Folder'),
          ),
        ],
      ),
    );
    if (shouldSelect == true) {
      return _selectHostFolder();
    }
    _snack('Select a Drop folder to start hosting.');
    return false;
  }

  Future<void> _copy(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    _snack(message);
  }

  void _showQrDialog(DropRoomSession session) {
    showDialog<void>(
      context: context,
      builder: (context) => DropCodeDialog(
        link: session.baseUrl,
        onCopy: () => _copy(session.baseUrl, 'Drop Link copied'),
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatEta(Duration duration) {
    if (duration.inSeconds <= 0) {
      return 'ETA now';
    }
    if (duration.inHours > 0) {
      final minutes = duration.inMinutes.remainder(60);
      return 'ETA ${duration.inHours}h ${minutes}m';
    }
    if (duration.inMinutes > 0) {
      final seconds = duration.inSeconds.remainder(60);
      return 'ETA ${duration.inMinutes}m ${seconds}s';
    }
    return 'ETA ${duration.inSeconds}s';
  }

  Widget _brandHeader() {
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            boxShadow: [
              BoxShadow(
                color: DropTheme.orange.withValues(alpha: 0.28),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset(
            DropTheme.logoAsset,
            fit: BoxFit.cover,
            semanticLabel: 'Erebrus Drop logo',
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Erebrus Drop',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              Text('No cloud. No account. Nearby only.'),
            ],
          ),
        ),
      ],
    );
  }
}

enum _BackAction { background, close }

enum _LibraryFileAction { open, share, delete }

enum TransferDirection { upload, download }

class TransferProgress {
  const TransferProgress({
    required this.direction,
    required this.title,
    required this.detail,
    required this.sentBytes,
    required this.totalBytes,
    required this.speedBytesPerSecond,
    this.completed = false,
  });

  factory TransferProgress.complete({
    required TransferDirection direction,
    required String title,
    required String detail,
    required int totalBytes,
  }) {
    return TransferProgress(
      direction: direction,
      title: title,
      detail: detail,
      sentBytes: totalBytes,
      totalBytes: totalBytes,
      speedBytesPerSecond: 0,
      completed: true,
    );
  }

  final TransferDirection direction;
  final String title;
  final String detail;
  final int sentBytes;
  final int totalBytes;
  final double speedBytesPerSecond;
  final bool completed;

  bool get isActive => !completed;

  double? get progress {
    if (totalBytes <= 0) {
      return null;
    }
    return (sentBytes / totalBytes).clamp(0.0, 1.0);
  }

  Duration? get eta {
    if (completed || totalBytes <= 0 || speedBytesPerSecond <= 0) {
      return null;
    }
    final remaining = math.max(0, totalBytes - sentBytes);
    return Duration(seconds: (remaining / speedBytesPerSecond).ceil());
  }
}

class _JoinedRoomDetailScreen extends StatelessWidget {
  const _JoinedRoomDetailScreen({
    required this.preview,
    required this.session,
    required this.path,
    required this.items,
    required this.activity,
    required this.transfer,
    required this.joining,
    required this.passwordController,
    required this.folderNameController,
    required this.textTitleController,
    required this.textBodyController,
    required this.onJoin,
    required this.onRefresh,
    required this.onUpFolder,
    required this.onUploadFiles,
    required this.onCreateFolder,
    required this.onSendText,
    required this.onFolderTap,
    required this.onDownload,
    required this.transferBuilder,
  });

  final JoinRoomPreview preview;
  final JoinRoomSession? session;
  final String path;
  final List<DropFileItem> items;
  final String? activity;
  final TransferProgress? transfer;
  final bool joining;
  final TextEditingController passwordController;
  final TextEditingController folderNameController;
  final TextEditingController textTitleController;
  final TextEditingController textBodyController;
  final Future<void> Function() onJoin;
  final Future<void> Function() onRefresh;
  final VoidCallback onUpFolder;
  final Future<void> Function() onUploadFiles;
  final Future<void> Function() onCreateFolder;
  final Future<void> Function() onSendText;
  final void Function(DropFileItem item) onFolderTap;
  final void Function(DropFileItem item) onDownload;
  final Widget Function(TransferProgress transfer) transferBuilder;

  @override
  Widget build(BuildContext context) {
    final joined = session != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(preview.roomName),
        actions: [
          if (joined)
            IconButton(
              onPressed: () => unawaited(onRefresh()),
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh room',
            ),
        ],
      ),
      body: _Screen(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _roomHeader(context),
            const SizedBox(height: 12),
            if (!joined) _joinCard(context) else _joinedFilesCard(context),
            if (joined) ...[
              const SizedBox(height: 12),
              _sendToolsCard(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _roomHeader(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RoomAvatar(icon: _roomIcon, active: session != null),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        preview.roomName,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${preview.deviceName} · $_platformLabel',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        preview.baseUrl,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusPill(
                  icon: preview.authRequired
                      ? Icons.lock_outline
                      : Icons.lock_open_outlined,
                  label: preview.authRequired ? 'Password room' : 'Open room',
                  color: preview.authRequired
                      ? DropTheme.amber
                      : DropTheme.success,
                ),
                _StatusPill(
                  icon: Icons.folder_outlined,
                  label: preview.scopedToDefaultFolder
                      ? 'Scoped folder'
                      : 'Drop folder',
                  color: DropTheme.orange,
                ),
                if (session != null)
                  const _StatusPill(
                    icon: Icons.check_circle_outline,
                    label: 'Joined',
                    color: DropTheme.success,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _joinCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              preview.authRequired ? 'Enter room password' : 'Join open room',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            if (preview.authRequired) ...[
              const SizedBox(height: 10),
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Room password'),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: joining ? null : () => unawaited(onJoin()),
              icon: joining
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: Text(joining ? 'Joining...' : 'Join Room'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _joinedFilesCard(BuildContext context) {
    final scopedRoot = preview.scopedToDefaultFolder ? preview.scopePath : '/';
    final canGoUp = path != '/' && path != scopedRoot;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Files',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(path, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => unawaited(onRefresh()),
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh room',
                ),
                IconButton(
                  onPressed: canGoUp ? onUpFolder : null,
                  icon: const Icon(Icons.drive_folder_upload_outlined),
                  tooltip: 'Up folder',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _StatusPill(
                  icon: Icons.folder_outlined,
                  label: 'Upload target $path',
                  color: DropTheme.orange,
                ),
                FilledButton.tonalIcon(
                  onPressed: transfer?.isActive == true
                      ? null
                      : () => unawaited(onUploadFiles()),
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('Upload Files'),
                ),
              ],
            ),
            if (transfer != null) ...[
              const SizedBox(height: 10),
              transferBuilder(transfer!),
            ],
            if (activity != null) ...[
              const SizedBox(height: 10),
              _InlineActivity(message: activity!),
            ],
            const SizedBox(height: 12),
            if (items.isEmpty && activity == null)
              const _EmptyFolderState()
            else
              ...items.map(
                (item) => _JoinedFileTile(
                  item: item,
                  onFolderTap: onFolderTap,
                  onDownload: onDownload,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sendToolsCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Send', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: folderNameController,
                    decoration: const InputDecoration(labelText: 'New folder'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: () => unawaited(onCreateFolder()),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  tooltip: 'Create folder',
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textTitleController,
              decoration: const InputDecoration(labelText: 'Text title'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: textBodyController,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Text to send'),
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () => unawaited(onSendText()),
              icon: const Icon(Icons.send_outlined),
              label: const Text('Send Text'),
            ),
          ],
        ),
      ),
    );
  }

  IconData get _roomIcon {
    final platform = preview.devicePlatform.toLowerCase();
    final type = preview.deviceType.toLowerCase();
    if (platform.contains('android')) return Icons.android;
    if (platform.contains('ios')) return Icons.phone_iphone;
    if (type.contains('phone')) return Icons.smartphone_outlined;
    if (platform.contains('mac')) return Icons.laptop_mac_outlined;
    if (platform.contains('windows') || platform.contains('linux')) {
      return Icons.computer_outlined;
    }
    return Icons.devices_other_outlined;
  }

  String get _platformLabel {
    final platform = preview.devicePlatform.toLowerCase();
    if (platform.contains('android')) return 'Android phone';
    if (platform.contains('ios')) return 'iPhone';
    if (platform.contains('mac')) return 'Mac';
    if (platform.contains('windows')) return 'Windows';
    if (platform.contains('linux')) return 'Linux';
    return preview.deviceType.isEmpty ? 'Local device' : preview.deviceType;
  }
}

class _JoinedFileTile extends StatelessWidget {
  const _JoinedFileTile({
    required this.item,
    required this.onFolderTap,
    required this.onDownload,
  });

  final DropFileItem item;
  final void Function(DropFileItem item) onFolderTap;
  final void Function(DropFileItem item) onDownload;

  @override
  Widget build(BuildContext context) {
    final isFolder = item.type == 'folder';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: DropTheme.surfaceHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: Icon(
            isFolder
                ? Icons.folder_outlined
                : item.streamable
                ? Icons.play_circle_outline
                : Icons.insert_drive_file_outlined,
          ),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            isFolder
                ? item.path
                : '${formatBytes(item.sizeBytes)} · ${item.mimeType ?? 'file'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: isFolder
              ? const Icon(Icons.chevron_right)
              : IconButton(
                  onPressed: () => onDownload(item),
                  icon: const Icon(Icons.download_outlined),
                  tooltip: 'Download',
                ),
          onTap: isFolder ? () => onFolderTap(item) : null,
        ),
      ),
    );
  }
}

class _EmptyFolderState extends StatelessWidget {
  const _EmptyFolderState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      decoration: BoxDecoration(
        color: DropTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          Icon(
            Icons.folder_open_outlined,
            size: 34,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 8),
          const Text(
            'This folder is empty',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _InlineActivity extends StatelessWidget {
  const _InlineActivity({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final isError = message.startsWith('Could not');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: DropTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (isError)
              const Icon(Icons.error_outline, size: 18, color: DropTheme.danger)
            else
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _RoomAvatar extends StatelessWidget {
  const _RoomAvatar({required this.icon, required this.active});

  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? DropTheme.success
        : Theme.of(context).colorScheme.primary;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.48)),
      ),
      child: Icon(icon, color: color),
    );
  }
}

class _Screen extends StatelessWidget {
  const _Screen({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: child,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final titleWidget = Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        );
        if (action == null) {
          return titleWidget;
        }
        if (constraints.maxWidth < 360) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [titleWidget, const SizedBox(height: 8), action!],
          );
        }
        return Row(
          children: [
            Expanded(child: titleWidget),
            action!,
          ],
        );
      },
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({
    required this.icon,
    required this.title,
    required this.status,
    required this.detail,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String status;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      _StatusPill(
                        icon: Icons.circle,
                        label: status,
                        color: color,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(detail),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionGrid extends StatelessWidget {
  const _ActionGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > 640) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: SizedBox(height: 132, child: children[i])),
              ],
            ],
          );
        }
        return Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: children[i]),
            ],
          ],
        );
      },
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                icon,
                size: 34,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DropCodeDialog extends StatelessWidget {
  const DropCodeDialog({required this.link, required this.onCopy, super.key});

  final String link;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(screen.width - 32, 360.0);
    final qrSize = math.min(dialogWidth - 64, 220.0);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 360,
          maxHeight: math.max(280, screen.height - 32),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Drop Code',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SizedBox.square(
                    dimension: qrSize,
                    child: QrImageView(
                      data: link,
                      version: QrVersions.auto,
                      size: qrSize,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(link, textAlign: TextAlign.center),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                  FilledButton(
                    onPressed: onCopy,
                    child: const Text('Copy Link'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.onSmartSend,
    required this.onLibrary,
    required this.onQr,
  });

  final VoidCallback onSmartSend;
  final VoidCallback onLibrary;
  final VoidCallback? onQr;

  @override
  Widget build(BuildContext context) {
    final actions = [
      FilledButton.tonalIcon(
        onPressed: onSmartSend,
        icon: const Icon(Icons.flash_on_outlined),
        label: const Text('Smart Send'),
      ),
      FilledButton.tonalIcon(
        onPressed: onQr,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan QR'),
      ),
      FilledButton.tonalIcon(
        onPressed: onLibrary,
        icon: const Icon(Icons.folder_outlined),
        label: const Text('Library'),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 430) {
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: actions
                .map(
                  (action) => SizedBox(
                    width: (constraints.maxWidth - 8) / 2,
                    child: action,
                  ),
                )
                .toList(),
          );
        }
        return Row(
          children: actions
              .map(
                (action) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: action,
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _AboutScreen extends StatelessWidget {
  const _AboutScreen({
    required this.networkLoading,
    required this.networkStatus,
  });

  final bool networkLoading;
  final DropNetworkStatus networkStatus;

  @override
  Widget build(BuildContext context) {
    return _InfoScaffold(
      title: 'About',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _AppLogoLockup(),
          const SizedBox(height: 22),
          const _SectionHeader(title: 'What it does'),
          const SizedBox(height: 8),
          const _TextCard(
            text:
                'Erebrus Drop lets you create a private local Drop Room for nearby devices. People on the same Wi-Fi or hotspot can join from the app or a browser to move files, folders, text, and streamable media without an account or cloud upload.',
          ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Why it matters'),
          const SizedBox(height: 8),
          const _TextCard(
            text:
                'NetSepio builds for digital sovereignty, privacy, and individual agency in a surveilled internet. Erebrus Drop is one small, practical piece of that ethos: useful sharing that keeps control close to you, your device, and the people you choose.',
          ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Capabilities'),
          const SizedBox(height: 8),
          const _CapabilityCard(
            icon: Icons.wifi_tethering_outlined,
            title: 'Current Wi-Fi hosting',
            status: 'Available',
            detail:
                'Drop Rooms can host on the active local network with browser access.',
            color: DropTheme.success,
          ),
          const _CapabilityCard(
            icon: Icons.link_outlined,
            title: 'Manual Join',
            status: 'Available',
            detail:
                'Join another room by entering its Drop Link, then browse, send text, create folders, and download files.',
            color: DropTheme.success,
          ),
          const _CapabilityCard(
            icon: Icons.qr_code_scanner_outlined,
            title: 'QR scan',
            status: 'Available',
            detail:
                'Scan a host Drop Code with the camera and join from the detected Drop Link.',
            color: DropTheme.success,
          ),
          _CapabilityCard(
            icon: Icons.network_wifi_outlined,
            title: 'Hosting network',
            status: networkLoading
                ? 'Checking'
                : networkStatus.isReady
                ? networkStatus.label
                : 'Hotspot needed',
            detail: networkLoading
                ? 'Checking for Wi-Fi or an active hotspot.'
                : networkStatus.isReady
                ? 'Drops start on the current ${networkStatus.label} network.'
                : 'Connect to Wi-Fi or create a hotspot in system Settings before starting a room.',
            color: networkLoading
                ? Colors.white54
                : networkStatus.isReady
                ? DropTheme.success
                : DropTheme.amber,
          ),
          const _CapabilityCard(
            icon: Icons.radar_outlined,
            title: 'Nearby Rooms',
            status: 'Available',
            detail:
                'Live rooms advertise _erebrusdrop._tcp on Android and iOS. Apps on the same local network can discover and open nearby rooms.',
            color: DropTheme.success,
          ),
          const _CapabilityCard(
            icon: Icons.document_scanner_outlined,
            title: 'Offline OCR and share sheet',
            status: 'Next',
            detail:
                'Smart Send text works now; screenshot OCR and OS share intake are planned native additions.',
            color: DropTheme.amber,
          ),
          const SizedBox(height: 18),
          const _AboutFooterLinks(),
        ],
      ),
    );
  }
}

class _PrivacyScreen extends StatelessWidget {
  const _PrivacyScreen();

  @override
  Widget build(BuildContext context) {
    return const _InfoScaffold(
      title: 'Privacy',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AppLogoLockup(compact: true),
          SizedBox(height: 18),
          _TextCard(
            text:
                'Erebrus Drop does not collect analytics, advertising identifiers, contact lists, location history, or account profiles. NetSepio does not receive your transferred files, pasted text, folder contents, room passwords, or Drop Links.',
          ),
          SizedBox(height: 8),
          _TextCard(
            text:
                'Transfers happen between nearby devices on your local Wi-Fi or hotspot network. Files and text stay on the devices and folders you choose.',
          ),
          SizedBox(height: 8),
          _TextCard(
            text:
                'Permissions are feature-scoped: camera for QR scans, local network access for Drop Rooms, and file or folder access for uploads and downloads. You control when those features are used.',
          ),
          SizedBox(height: 8),
          _TextCard(text: 'For privacy questions, contact $_supportEmail.'),
        ],
      ),
    );
  }
}

class _TermsScreen extends StatelessWidget {
  const _TermsScreen();

  @override
  Widget build(BuildContext context) {
    return const _InfoScaffold(
      title: 'Terms',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AppLogoLockup(compact: true),
          SizedBox(height: 18),
          _TextCard(
            text:
                'Erebrus Drop is provided for private, nearby device-to-device sharing. Use it only for files and content you own or have permission to share.',
          ),
          SizedBox(height: 8),
          _TextCard(
            text:
                'You are responsible for who joins your Drop Room, the network you use, and the files or text you send. Keep room passwords and Drop Links private when sharing sensitive content.',
          ),
          SizedBox(height: 8),
          _TextCard(
            text:
                'The app is provided as-is. Local transfers depend on your device, operating system, browser, storage, permissions, and network conditions.',
          ),
          SizedBox(height: 8),
          _TextCard(
            text:
                'To the fullest extent permitted by law, you agree to indemnify and hold NetSepio harmless from claims, losses, damages, liabilities, and expenses arising from your use of Erebrus Drop, the content you share, or your violation of these terms or applicable law.',
          ),
          SizedBox(height: 8),
          _TextCard(
            text:
                'Erebrus Platform, brand, and apps are products of NetSepio. For support, contact $_supportEmail.',
          ),
        ],
      ),
    );
  }
}

class _InfoScaffold extends StatelessWidget {
  const _InfoScaffold({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _AppLogoLockup extends StatelessWidget {
  const _AppLogoLockup({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final logoSize = compact ? 76.0 : 96.0;
    return Center(
      child: Column(
        children: [
          Container(
            width: logoSize,
            height: logoSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(compact ? 18 : 24),
              boxShadow: [
                BoxShadow(
                  color: DropTheme.orange.withValues(alpha: 0.28),
                  blurRadius: compact ? 24 : 32,
                  offset: Offset(0, compact ? 10 : 14),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              DropTheme.logoAsset,
              fit: BoxFit.cover,
              semanticLabel: 'Erebrus Drop logo',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Erebrus Drop',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            'Version $_appVersion',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _TextCard extends StatelessWidget {
  const _TextCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: Text(text)),
    );
  }
}

class _AboutFooterLinks extends StatelessWidget {
  const _AboutFooterLinks();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const _PrivacyScreen()),
            ),
            child: const Text('Privacy'),
          ),
          Text(
            '|',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const _TermsScreen()),
            ),
            child: const Text('Terms'),
          ),
        ],
      ),
    );
  }
}

class _FooterIconButton extends StatelessWidget {
  const _FooterIconButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'About Erebrus Drop',
      child: Semantics(
        label: 'About Erebrus Drop',
        button: true,
        child: GestureDetector(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: DropTheme.orange.withValues(alpha: 0.34),
              ),
              color: DropTheme.surfaceHigh,
              boxShadow: [
                BoxShadow(
                  color: DropTheme.orange.withValues(alpha: 0.12),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Icon(Icons.info_outline),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid({required this.items});

  final List<(String, IconData, String)> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 520;
        final width = twoColumns
            ? (constraints.maxWidth - 10) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: items
              .map(
                (item) => SizedBox(
                  width: width,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(item.$2),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.$1,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  item.$3,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SwitchListTile(
        secondary: Icon(icon),
        title: Text(title),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
