import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../ui/theme/drop_theme.dart';
import '../../ui/widgets/drop_widgets.dart';
import 'solana_wallet_option.dart';
import 'solana_wallet_service.dart';

Future<SolanaWalletOption?> showSolanaWalletPickerSheet({
  required BuildContext context,
  required SolanaWalletService walletService,
}) async {
  final wallets = await walletService.listWallets();
  if (!context.mounted) {
    return null;
  }

  if (wallets.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('No Solana wallets found on this device.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return null;
  }

  return showModalBottomSheet<SolanaWalletOption>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      SolanaWalletOption? seedVault;
      for (final wallet in wallets) {
        if (wallet.isSeedVault) {
          seedVault = wallet;
          break;
        }
      }
      final others = wallets.where((wallet) => !wallet.isSeedVault).toList();
      final maxHeight = MediaQuery.sizeOf(context).height * 0.78;

      return Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          MediaQuery.of(context).viewInsets.bottom + 12,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connect wallet',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Choose where to approve your Solana identity.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (seedVault != null) ...[
                        _SeedVaultHeroCard(
                          wallet: seedVault,
                          onTap: () => Navigator.of(context).pop(seedVault),
                        ),
                        if (others.isNotEmpty) ...[
                          const SizedBox(height: 18),
                          const _SectionLabel('Other wallets'),
                          const SizedBox(height: 10),
                        ],
                      ] else ...[
                        const _SectionLabel('Available wallets'),
                        const SizedBox(height: 10),
                      ],
                      ...others.map(
                        (wallet) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _WalletRow(
                            wallet: wallet,
                            onTap: () => Navigator.of(context).pop(wallet),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: DropTheme.faint,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _SeedVaultHeroCard extends StatelessWidget {
  const _SeedVaultHeroCard({required this.wallet, required this.onTap});

  final SolanaWalletOption wallet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: DropCard.tinted(
        accent: DropTheme.success,
        glow: true,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const DropPill(
                  icon: Icons.star_rounded,
                  label: 'Recommended',
                  color: DropTheme.success,
                ),
                const Spacer(),
                Icon(
                  Icons.chevron_right_rounded,
                  color: DropTheme.success.withValues(alpha: 0.8),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _WalletIcon(wallet: wallet, size: 52, accent: DropTheme.success),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        wallet.name,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Built into your Seeker. Fastest way to connect.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WalletRow extends StatelessWidget {
  const _WalletRow({required this.wallet, required this.onTap});

  final SolanaWalletOption wallet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: DropCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            _WalletIcon(wallet: wallet, size: 42, accent: DropTheme.orange),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                wallet.name,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: DropTheme.muted),
          ],
        ),
      ),
    );
  }
}

class _WalletIcon extends StatelessWidget {
  const _WalletIcon({
    required this.wallet,
    required this.size,
    required this.accent,
  });

  final SolanaWalletOption wallet;
  final double size;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final bytes = _decodeIcon(wallet.iconBase64);
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.28),
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallbackIcon(),
        ),
      );
    }
    return _fallbackIcon();
  }

  Widget _fallbackIcon() {
    return LeadingTile(
      icon: wallet.isSeedVault
          ? Icons.shield_rounded
          : Icons.account_balance_wallet_rounded,
      accent: accent,
      size: size,
    );
  }
}

Uint8List? _decodeIcon(String? iconBase64) {
  if (iconBase64 == null || iconBase64.isEmpty) {
    return null;
  }
  try {
    return base64Decode(iconBase64);
  } on FormatException {
    return null;
  }
}