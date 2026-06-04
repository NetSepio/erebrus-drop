import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'core/drop_models.dart';
import 'core/host_folder_bridge.dart';
import 'core/platform_network.dart';
import 'features/host/hotspot_service.dart';
import 'features/host/host_folder_service.dart';
import 'features/host/room_runtime_service.dart';
import 'features/join/join_room_service.dart';
import 'features/join/native_file_picker_service.dart';
import 'features/join/qr_scan_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/onboarding_store.dart';
import 'server/drop_server.dart';
import 'ui/theme/drop_theme.dart';

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
  final HotspotService _hotspotService = HotspotService();
  final HostFolderService _hostFolderService = HostFolderService();
  final RoomRuntimeService _roomRuntimeService = RoomRuntimeService();
  final JoinRoomService _joinRoomService = JoinRoomService();
  final NativeFilePickerService _nativeFilePickerService =
      NativeFilePickerService();
  final HostFolderBridge _hostFolderBridge = HostFolderBridge();
  final ValueNotifier<int> _hotspotUiVersion = ValueNotifier<int>(0);
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
  bool _hotspotBusy = false;
  bool _hostFolderBusy = false;
  bool _loadingHostFolderSelection = true;
  bool _hotspotSupportLoading = true;
  bool _hotspotCanCreate = false;
  bool _loadingLibraryFiles = false;
  bool _appInForeground = true;
  bool _refreshingRoomData = false;
  bool _backDialogOpen = false;
  bool _joining = false;
  bool _usePassword = true;
  bool _burnMode = false;
  RoomPermission _permission = RoomPermission.dropFolderOnly;
  StorageSnapshot? _storage;
  HotspotResult? _hotspotResult;
  String? _hotspotSupportReason;
  HostFolderSelection? _hostFolderSelection;
  JoinRoomPreview? _joinPreview;
  JoinRoomSession? _joinSession;
  String _libraryPath = '/';
  String _joinPath = '/';
  List<DropFileItem> _joinItems = <DropFileItem>[];
  String? _joinActivity;
  TransferProgress? _joinTransfer;
  String? _libraryError;
  List<DropFileItem> _files = <DropFileItem>[];
  Timer? _refreshTimer;

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
    unawaited(_loadHotspotSupport());
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_server.isRunning && _appInForeground) {
        unawaited(_refreshRoomData());
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

  Future<void> _loadHotspotSupport() async {
    try {
      final support = await _hotspotService.localOnlyHotspotSupport();
      _setHotspotState(() {
        _hotspotCanCreate = support.supported;
        _hotspotSupportReason = support.reason;
        _hotspotSupportLoading = false;
      });
    } on PlatformException catch (error) {
      _setHotspotState(() {
        _hotspotCanCreate = false;
        _hotspotSupportReason =
            error.message ?? 'Use system Settings to enable a hotspot.';
        _hotspotSupportLoading = false;
      });
    } on MissingPluginException {
      _setHotspotState(() {
        _hotspotCanCreate = false;
        _hotspotSupportReason =
            'Hotspot setup is handled by system Settings on this device.';
        _hotspotSupportLoading = false;
      });
    } catch (error) {
      _setHotspotState(() {
        _hotspotCanCreate = false;
        _hotspotSupportReason = 'Could not check hotspot support: $error';
        _hotspotSupportLoading = false;
      });
    }
  }

  void _setHotspotState(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _hotspotUiVersion.value += 1;
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
    _hotspotUiVersion.dispose();
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
            color: session == null ? Colors.blueGrey : Colors.green,
          ),
          const SizedBox(height: 22),
          Text(
            'Start, scan, send.',
            style: Theme.of(
              context,
            ).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          const Text(
            'Drop files, text, and media between nearby devices without a cloud account or forced app install.',
          ),
          const SizedBox(height: 22),
          _ActionGrid(
            children: [
              _PrimaryAction(
                icon: Icons.add_circle_outline,
                title: 'Start Drop Room',
                subtitle: 'Host a local browser room on this network.',
                onTap: session == null ? _showStartRoomSheet : null,
              ),
              _PrimaryAction(
                icon: Icons.login_outlined,
                title: 'Join Drop Room',
                subtitle: 'Enter a local Drop Link and browse after auth.',
                onTap: () => setState(() => _tab = 1),
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
          _InfoCard(
            title: 'Nearby Rooms',
            subtitle:
                'Live rooms now publish an mDNS service on the local network; browsing nearby rooms is next.',
            icon: Icons.radar_outlined,
          ),
          const SizedBox(height: 12),
          _InfoCard(
            title: 'Scan Drop Code',
            subtitle:
                'Use the camera to scan a host QR code and fill the Drop Link automatically.',
            icon: Icons.qr_code_scanner_outlined,
            onTap: _scanDropCode,
          ),
          const SizedBox(height: 12),
          _manualJoinCard(),
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
          const SizedBox(height: 8),
          const _SectionHeader(title: 'Platform capabilities'),
          const SizedBox(height: 8),
          const _CapabilityCard(
            icon: Icons.wifi_tethering_outlined,
            title: 'Current Wi-Fi hosting',
            status: 'Available',
            detail:
                'Drop Rooms can host on the active local network with browser access.',
            color: Colors.green,
          ),
          const _CapabilityCard(
            icon: Icons.link_outlined,
            title: 'Manual Join',
            status: 'Available',
            detail:
                'Join another room by entering its Drop Link, then browse, send text, create folders, and download files.',
            color: Colors.green,
          ),
          const _CapabilityCard(
            icon: Icons.qr_code_scanner_outlined,
            title: 'QR scan',
            status: 'Available',
            detail:
                'Scan a host Drop Code with the camera and join from the detected Drop Link.',
            color: Colors.green,
          ),
          _CapabilityCard(
            icon: Icons.network_wifi_outlined,
            title: Platform.isIOS ? 'Personal Hotspot' : 'Hotspot fallback',
            status: _hotspotSupportLoading
                ? 'Checking'
                : Platform.isIOS
                ? 'Guide only'
                : _hotspotCanCreate && !Platform.isIOS
                ? 'App can try'
                : 'Manual setup',
            detail: _hotspotSupportLoading
                ? 'Checking whether this device lets Erebrus Drop create a hotspot.'
                : Platform.isIOS
                ? 'Use shared Wi-Fi for rooms. Enable Personal Hotspot from iPhone Settings only when guests need a private network.'
                : _hotspotCanCreate && !Platform.isIOS
                ? 'Android can attempt local-only hotspot mode. Some OEM policies may still deny it.'
                : _hotspotSupportReason ??
                      'Use system Settings to enable a hotspot, then return to Erebrus Drop.',
            color: _hotspotSupportLoading
                ? Colors.blueGrey
                : _hotspotCanCreate && !Platform.isIOS
                ? Colors.green
                : Colors.amber,
          ),
          const _CapabilityCard(
            icon: Icons.radar_outlined,
            title: 'Nearby Rooms',
            status: 'Publishing',
            detail:
                'Live rooms advertise _erebrusdrop._tcp on Android and iOS. Browsing nearby rooms is the next integration.',
            color: Colors.green,
          ),
          const _CapabilityCard(
            icon: Icons.document_scanner_outlined,
            title: 'Offline OCR and share sheet',
            status: 'Next',
            detail:
                'Smart Send text works now; screenshot OCR and OS share intake are planned native additions.',
            color: Colors.amber,
          ),
        ],
      ),
    );
  }

  Widget _hostFolderSettingsCard() {
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
                              ? Colors.amber
                              : Colors.green,
                        ),
                        _StatusPill(
                          icon: session.usesExternalHostFolder
                              ? Icons.folder_open_outlined
                              : Icons.folder_special_outlined,
                          label: session.usesExternalHostFolder
                              ? 'Drop folder ${session.hostFolderName ?? 'Selected folder'}'
                              : 'Drop folder not selected',
                          color: Colors.lightBlueAccent,
                        ),
                        if (Platform.isIOS)
                          const _StatusPill(
                            icon: Icons.visibility_outlined,
                            label: 'Screen stays awake',
                            color: Colors.amber,
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
    return Card(
      child: ListTile(
        leading: Icon(
          item.type == 'folder'
              ? Icons.folder_outlined
              : Icons.insert_drive_file_outlined,
        ),
        title: Text(item.name),
        subtitle: Text(
          item.type == 'folder'
              ? item.path
              : '${formatBytes(item.sizeBytes)} · ${item.mimeType ?? 'file'}',
        ),
        trailing: item.streamable
            ? const Icon(Icons.play_circle_outline)
            : item.type == 'folder'
            ? const Icon(Icons.chevron_right)
            : const Icon(Icons.open_in_new_outlined),
        onTap: item.type == 'folder'
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
    final preview = _joinPreview;
    final joinSession = _joinSession;
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
                    'Manual Join',
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
            if (preview != null) ...[
              const SizedBox(height: 12),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  preview.authRequired
                      ? Icons.lock_outline
                      : Icons.lock_open_outlined,
                ),
                title: Text(preview.roomName),
                subtitle: Text(
                  preview.scopedToDefaultFolder
                      ? 'Hosted by ${preview.deviceName} · Guests are scoped to ${preview.scopePath}'
                      : 'Hosted by ${preview.deviceName} · Drop folder ${preview.defaultUploadPath}',
                ),
              ),
              if (preview.authRequired) ...[
                TextField(
                  controller: _joinPassword,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Room password'),
                ),
                const SizedBox(height: 10),
              ],
              FilledButton.icon(
                onPressed: _joining ? null : _loginJoinRoom,
                icon: const Icon(Icons.login),
                label: Text(joinSession == null ? 'Join Room' : 'Joined'),
              ),
              if (joinSession != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Session expires ${joinSession.expiresAt.toLocal()} · ${joinSession.permissions.join(', ')}',
                ),
                const SizedBox(height: 12),
                _joinedRoomBrowser(),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _joinedRoomBrowser() {
    final preview = _joinPreview;
    final scopedRoot = preview?.scopedToDefaultFolder == true
        ? preview!.scopePath
        : '/';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Row(
          children: [
            Expanded(
              child: Text(
                'Remote files $_joinPath',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              onPressed: _loadJoinedFiles,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh room',
            ),
            IconButton(
              onPressed: _joinPath == '/' || _joinPath == scopedRoot
                  ? null
                  : _joinedUpFolder,
              icon: const Icon(Icons.drive_folder_upload_outlined),
              tooltip: 'Up folder',
            ),
          ],
        ),
        const SizedBox(height: 6),
        _StatusPill(
          icon: Icons.folder_outlined,
          label: 'Uploads target $_joinPath',
          color: Colors.lightBlueAccent,
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _joinTransfer?.isActive == true
              ? null
              : _pickAndUploadJoinedFiles,
          icon: const Icon(Icons.upload_file_outlined),
          label: const Text('Upload Files to This Folder'),
        ),
        if (_joinTransfer != null) ...[
          const SizedBox(height: 10),
          _transferPanel(_joinTransfer!),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _joinFolderName,
                decoration: const InputDecoration(labelText: 'New folder'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _createJoinedFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: 'Create folder',
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _joinTextTitle,
          decoration: const InputDecoration(labelText: 'Text title'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _joinTextBody,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(labelText: 'Text to send'),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _sendJoinedText,
          icon: const Icon(Icons.send_outlined),
          label: const Text('Send Text to Joined Room'),
        ),
        if (_joinActivity != null) ...[
          const SizedBox(height: 8),
          Text(_joinActivity!),
        ],
        const SizedBox(height: 10),
        if (_joinItems.isEmpty)
          const Text('No remote items loaded yet.')
        else
          ..._joinItems.map(_joinedFileTile),
      ],
    );
  }

  Widget _joinedFileTile(DropFileItem item) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        item.type == 'folder'
            ? Icons.folder_outlined
            : item.streamable
            ? Icons.play_circle_outline
            : Icons.insert_drive_file_outlined,
      ),
      title: Text(item.name),
      subtitle: Text(
        item.type == 'folder'
            ? item.path
            : '${formatBytes(item.sizeBytes)} · ${item.mimeType ?? 'file'}',
      ),
      trailing: item.type == 'folder'
          ? const Icon(Icons.chevron_right)
          : IconButton(
              onPressed: () => _downloadJoinedFile(item),
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Download',
            ),
      onTap: item.type == 'folder'
          ? () {
              setState(() => _joinPath = item.path);
              unawaited(_loadJoinedFiles());
            }
          : null,
    );
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

  Widget _hotspotPanel() {
    final result = _hotspotResult;
    final hotspotActive = result?.started == true;
    final hotspotAttemptFailed = result != null && !result.started;
    final canCreateHotspot =
        _hotspotCanCreate && !Platform.isIOS && !hotspotAttemptFailed;
    final supportReason =
        result?.reason ??
        _hotspotSupportReason ??
        'Use system Settings to enable a hotspot, then return here.';
    final guideLabel = Platform.isIOS
        ? 'Personal Hotspot Guide'
        : 'Hotspot Guide';
    final showManualStatus =
        !Platform.isIOS && !_hotspotSupportLoading && !canCreateHotspot;
    final description = hotspotActive
        ? 'Connect guests to this hotspot, then start the room.'
        : _hotspotSupportLoading
        ? 'Checking whether this device can create a hotspot from the app.'
        : canCreateHotspot
        ? 'Rooms use the current Wi-Fi by default. Create a local hotspot only when guests cannot join that network.'
        : Platform.isIOS
        ? 'Rooms use the current Wi-Fi. Personal Hotspot is only a fallback when guests need a private network.'
        : 'Rooms use the current Wi-Fi. Hotspot setup is handled in system Settings on this device.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.network_wifi_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Network',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(description),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_hotspotSupportLoading)
              const Row(
                children: [
                  SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('Checking hotspot support...'),
                ],
              )
            else if (hotspotActive)
              OutlinedButton.icon(
                onPressed: _hotspotBusy ? null : _stopHotspot,
                icon: _hotspotBusy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_off_outlined),
                label: const Text('Stop Hotspot'),
              )
            else if (canCreateHotspot)
              FilledButton.tonalIcon(
                onPressed: _hotspotBusy ? null : _startHotspot,
                icon: _hotspotBusy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: const Text('Create Local Hotspot'),
              )
            else
              FilledButton.tonalIcon(
                onPressed: _showManualHotspotGuide,
                icon: const Icon(Icons.help_outline),
                label: Text(guideLabel),
              ),
            if (!_hotspotSupportLoading &&
                (hotspotActive ||
                    (!Platform.isIOS && hotspotAttemptFailed) ||
                    showManualStatus)) ...[
              const SizedBox(height: 12),
              _StatusPill(
                icon: hotspotActive
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
                label: hotspotActive
                    ? 'Hotspot active'
                    : 'Manual hotspot setup',
                color: hotspotActive ? Colors.green : Colors.amber,
              ),
              const SizedBox(height: 8),
              if (hotspotActive) ...[
                if (result!.ssid != null)
                  SelectableText('SSID: ${result.ssid}'),
                if (result.passphrase != null)
                  SelectableText('Password: ${result.passphrase}'),
                if (result.gatewayIp != null)
                  SelectableText('Gateway: ${result.gatewayIp}'),
              ] else
                Text(supportReason),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showStartRoomSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
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
                    ValueListenableBuilder<int>(
                      valueListenable: _hotspotUiVersion,
                      builder: (context, _, _) => _hotspotPanel(),
                    ),
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
                      onPressed: _starting || passwordRequiredButEmpty
                          ? null
                          : () async {
                              final navigator = Navigator.of(context);
                              final started = await _startRoom();
                              if (mounted && started) navigator.pop();
                            },
                      icon: _starting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering),
                      label: const Text('Start Room'),
                    ),
                    if (passwordRequiredButEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Enter a password or turn off Password Room.',
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
  }

  Future<bool> _startRoom() async {
    final password = _password.text.trim();
    if (_usePassword && password.isEmpty) {
      _snack('Enter a room password or turn off Password Room.');
      return false;
    }
    setState(() => _starting = true);
    try {
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

  Future<void> _startHotspot() async {
    _setHotspotState(() => _hotspotBusy = true);
    try {
      final result = await _hotspotService.startLocalOnlyHotspot();
      if (!mounted) return;
      _setHotspotState(() {
        _hotspotResult = result;
        if (!result.supported) {
          _hotspotCanCreate = false;
          _hotspotSupportReason = result.reason;
        }
      });
      _snack(
        result.started
            ? 'Hotspot started. Connect nearby devices, then start the room.'
            : result.reason ?? 'Hotspot is unavailable on this device.',
      );
    } on PlatformException catch (error) {
      final message =
          error.message ?? 'This device did not allow hotspot creation.';
      if (!mounted) return;
      _setHotspotState(() {
        _hotspotCanCreate = false;
        _hotspotSupportReason = message;
        _hotspotResult = HotspotResult(
          supported: false,
          started: false,
          reason: message,
        );
      });
      _snack(message);
    } catch (error) {
      final message = 'Could not start hotspot: $error';
      if (!mounted) return;
      _setHotspotState(() {
        _hotspotCanCreate = false;
        _hotspotSupportReason = message;
        _hotspotResult = HotspotResult(
          supported: false,
          started: false,
          reason: message,
        );
      });
      _snack(message);
    } finally {
      _setHotspotState(() => _hotspotBusy = false);
    }
  }

  Future<void> _stopHotspot() async {
    _setHotspotState(() => _hotspotBusy = true);
    try {
      await _hotspotService.stopLocalOnlyHotspot();
      if (!mounted) return;
      _setHotspotState(() => _hotspotResult = null);
      _snack('Hotspot stopped');
    } catch (error) {
      if (mounted) _snack('Could not stop hotspot: $error');
    } finally {
      _setHotspotState(() => _hotspotBusy = false);
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
    setState(() => _joining = true);
    try {
      final preview = await _joinRoomService.preview(_joinUrl.text);
      if (!mounted) return;
      setState(() {
        _joinPreview = preview;
        _joinSession = null;
      });
      _snack('Found ${preview.roomName}');
    } catch (error) {
      if (mounted) _snack('Could not find room: $error');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _loginJoinRoom() async {
    final preview = _joinPreview;
    if (preview == null) {
      await _previewJoinRoom();
      return;
    }
    setState(() => _joining = true);
    try {
      final joinSession = await _joinRoomService.login(
        baseUrl: preview.baseUrl,
        password: preview.authRequired ? _joinPassword.text : '',
      );
      if (!mounted) return;
      setState(() {
        _joinSession = joinSession;
        _joinPath = preview.scopedToDefaultFolder
            ? preview.scopePath
            : preview.defaultUploadPath;
      });
      _snack('Joined ${preview.roomName}');
      await _loadJoinedFiles();
    } catch (error) {
      if (mounted) _snack('Could not join room: $error');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _scanDropCode() async {
    final scannedUrl = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (scannedUrl == null || scannedUrl.trim().isEmpty) return;
    setState(() {
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
    setState(() => _joinActivity = 'Loading remote files...');
    try {
      final items = await _joinRoomService.listFiles(
        baseUrl: preview.baseUrl,
        token: joinSession.token,
        path: _joinPath,
      );
      if (!mounted) return;
      setState(() {
        _joinItems = items;
        _joinActivity = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _joinActivity = 'Could not load files: $error');
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
      final file = await _joinRoomService.downloadFile(
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
          setState(
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
      setState(() {
        _joinTransfer = TransferProgress.complete(
          direction: TransferDirection.download,
          title: 'Downloaded ${item.name}',
          detail: 'Saved to ${file.path}',
          totalBytes: item.sizeBytes,
        );
        _joinActivity = null;
      });
      _snack('Downloaded ${item.name}');
    } catch (error) {
      if (mounted) {
        setState(() => _joinTransfer = null);
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
            setState(
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
      setState(() {
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
        setState(() => _joinTransfer = null);
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
    setState(
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
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
              colors: [Color(0xFF25D7FF), Color(0xFF4C7DFF)],
            ),
          ),
          child: const Center(
            child: Text(
              'ED',
              style: TextStyle(
                color: Color(0xFF07111F),
                fontWeight: FontWeight.w900,
              ),
            ),
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
