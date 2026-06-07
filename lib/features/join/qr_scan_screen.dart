import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  late final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    facing: CameraFacing.back,
    lensType: CameraLensType.normal,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  bool _scannerRunning = false;
  String? _scannerError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_startScanner());
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Drop Code'),
        actions: [
          IconButton(
            onPressed: _scannerRunning ? () => unawaited(_toggleTorch()) : null,
            icon: const Icon(Icons.flashlight_on_outlined),
            tooltip: 'Toggle flashlight',
          ),
          IconButton(
            onPressed: _scannerRunning
                ? () => unawaited(_switchCamera())
                : null,
            icon: const Icon(Icons.cameraswitch_outlined),
            tooltip: 'Switch camera',
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _handleDetect,
            errorBuilder: (context, error) =>
                _scannerErrorPanel(context, _scannerMessage(error)),
            placeholderBuilder: _scannerPlaceholder,
          ),
          if (_scannerError != null)
            _scannerErrorPanel(context, _scannerError!),
          Align(
            alignment: Alignment.center,
            child: Container(
              width: 246,
              height: 246,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(
                          Icons.qr_code_scanner,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Point the camera at the host device Drop Code.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      final url = value == null ? null : parseDropCodeUrl(value);
      if (url != null) {
        _handled = true;
        Navigator.of(context).pop(url);
        return;
      }
    }
  }

  Future<void> _startScanner() async {
    setState(() => _scannerError = null);
    try {
      await _controller.start();
      if (!mounted) return;
      setState(() => _scannerRunning = true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _scannerRunning = false;
        _scannerError = _scannerMessage(error);
      });
    }
  }

  Future<void> _restartScanner() async {
    try {
      await _controller.stop();
    } catch (_) {
      // Ignore stop errors while recovering from native scanner failures.
    }
    if (mounted) {
      setState(() => _scannerRunning = false);
      await _startScanner();
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } catch (error) {
      if (mounted) setState(() => _scannerError = _scannerMessage(error));
    }
  }

  Future<void> _switchCamera() async {
    try {
      await _controller.switchCamera();
    } catch (error) {
      if (mounted) setState(() => _scannerError = _scannerMessage(error));
    }
  }

  Widget _scannerPlaceholder(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(child: CircularProgressIndicator()),
    );
  }

  Widget _scannerErrorPanel(BuildContext context, String message) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.camera_alt_outlined,
                      color: Theme.of(context).colorScheme.primary,
                      size: 34,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Camera scanner is unavailable',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: () => unawaited(_restartScanner()),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                        FilledButton.icon(
                          onPressed: () => unawaited(_pasteDropCode()),
                          icon: const Icon(Icons.link_outlined),
                          label: const Text('Paste Link'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pasteDropCode() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Paste Drop Link'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Drop Link or Drop Code',
              hintText: 'http://192.168.1.23:8787',
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Use Link'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (!mounted || value == null || value.trim().isEmpty) return;
    final url = parseDropCodeUrl(value);
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That is not a valid Drop Link.')),
      );
      return;
    }
    Navigator.of(context).pop(url);
  }

  String _scannerMessage(Object error) {
    if (error is MobileScannerException) {
      final details = error.errorDetails?.message;
      if (details != null && details.trim().isNotEmpty) return details;
      return switch (error.errorCode) {
        MobileScannerErrorCode.permissionDenied =>
          'Camera permission is required to scan a Drop Code.',
        MobileScannerErrorCode.unsupported =>
          'This device does not support the camera scanner.',
        _ => 'The camera scanner could not start on this device.',
      };
    }
    final text = error.toString();
    if (text.trim().isEmpty) {
      return 'The camera scanner could not start on this device.';
    }
    return text;
  }
}

String? parseDropCodeUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, Object?> &&
        decoded['type'] == 'erebrus_drop_room') {
      return decoded['url']?.toString();
    }
  } catch (_) {
    return null;
  }
  return null;
}
