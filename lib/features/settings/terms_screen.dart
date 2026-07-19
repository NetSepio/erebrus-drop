import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../ui/widgets/drop_widgets.dart';

const String _supportEmail = 'support@netsepio.com';

/// Terms of use screen.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terms')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AppLogoLockup(compact: true),
            const SizedBox(height: 18),
            const _TextCard(
              text:
                  'Erebrus Drop is provided for private, nearby device-to-device sharing. Use it only for files and content you own or have permission to share.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'You are responsible for who joins your Drop Room, the network you use, and the files or text you send. Keep room passwords and Drop Links private when sharing sensitive content.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'The app is provided as-is. Local transfers depend on your device, operating system, browser, storage, permissions, and network conditions.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'To the fullest extent permitted by law, you agree to indemnify and hold NetSepio harmless from claims, losses, damages, liabilities, and expenses arising from your use of Erebrus Drop, the content you share, or your violation of these terms or applicable law.',
            ),
            const SizedBox(height: 8),
            _TextCard(
              text:
                  'Erebrus Platform, brand, and apps are products of NetSepio. For support, contact $_supportEmail.',
            ),
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
