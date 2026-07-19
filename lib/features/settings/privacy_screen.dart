import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../ui/widgets/drop_widgets.dart';

const String _supportEmail = 'support@netsepio.com';

/// Privacy policy screen.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AppLogoLockup(compact: true),
            const SizedBox(height: 18),
            const _TextCard(
              text:
                  'Erebrus Drop does not collect analytics, advertising identifiers, contact lists, location history, or account profiles. NetSepio does not receive your transferred files, pasted text, folder contents, room passwords, or Drop Links.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'Transfers happen between nearby devices on your local Wi-Fi or hotspot network. Files and text stay on the devices and folders you choose.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'Permissions are feature-scoped: camera for QR scans, local network access for Drop Rooms, and file or folder access for uploads and downloads. You control when those features are used.',
            ),
            const SizedBox(height: 8),
            _TextCard(text: 'For privacy questions, contact $_supportEmail.'),
          ],
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
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final version = snapshot.hasData
            ? 'v${snapshot.data!.version} (${snapshot.data!.buildNumber})'
            : '';
        return Center(
          child: BrandLockup(
            centered: true,
            markSize: compact ? 76 : 96,
            wordmarkSize: compact ? 26 : 30,
            subtitle: version,
          ),
        );
      },
    );
  }
}

class _TextCard extends StatelessWidget {
  const _TextCard({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return DropCard(
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
