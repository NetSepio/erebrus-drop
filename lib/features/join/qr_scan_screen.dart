import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  static const MethodChannel _scannerChannel = MethodChannel(
    'com.erebrus.drop/qr_scanner',
  );
  bool _handled = false;
  String? _scannerError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_startScanner());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Drop Code')),
      body: Stack(
        children: [
          _scannerError == null
              ? _scannerPlaceholder(context)
              : _scannerErrorPanel(context, _scannerError!),
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

  void _handleCode(String value) {
    if (_handled) return;
    final url = parseDropCodeUrl(value);
    if (url != null) {
      _handled = true;
      Navigator.of(context).pop(url);
      return;
    }
    setState(() {
      _scannerError = 'That QR code is not a valid Drop Link.';
    });
  }

  Future<void> _startScanner() async {
    setState(() => _scannerError = null);
    try {
      final value = await _scannerChannel.invokeMethod<String>('scanQrCode');
      if (!mounted || _handled) return;
      if (value == null || value.trim().isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      _handleCode(value);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _scannerError = _scannerMessage(error));
    } catch (error) {
      if (!mounted) return;
      setState(() => _scannerError = _scannerMessage(error));
    }
  }

  Future<void> _restartScanner() async {
    if (mounted) await _startScanner();
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
    if (error is PlatformException) {
      if (error.message != null && error.message!.trim().isNotEmpty) {
        return error.message!;
      }
      return switch (error.code) {
        'CAMERA_PERMISSION_DENIED' =>
          'Camera permission is required to scan a Drop Code.',
        'CAMERA_UNAVAILABLE' =>
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
