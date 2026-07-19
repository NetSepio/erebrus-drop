import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/theme/drop_theme.dart';
import '../../ui/widgets/drop_widgets.dart';
import 'solana_wallet_option.dart';
import 'solana_wallet_picker_sheet.dart';
import 'solana_wallet_service.dart';

String truncateWalletAddress(String address) {
  if (address.length <= 12) {
    return address;
  }
  return '${address.substring(0, 4)}…${address.substring(address.length - 4)}';
}

class SolanaWalletCard extends StatefulWidget {
  const SolanaWalletCard({required this.walletService, super.key});

  final SolanaWalletService walletService;

  @override
  State<SolanaWalletCard> createState() => _SolanaWalletCardState();
}

class _SolanaWalletCardState extends State<SolanaWalletCard> {
  bool _loading = false;
  String? _error;
  SolanaWalletOption? _connectingWallet;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    await widget.walletService.restoreSession();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _connect() async {
    final wallet = await showSolanaWalletPickerSheet(
      context: context,
      walletService: widget.walletService,
    );
    if (!mounted || wallet == null) {
      return;
    }

    setState(() {
      _loading = true;
      _connectingWallet = wallet;
      _error = null;
    });

    try {
      await widget.walletService.connect(wallet: wallet);
      if (mounted) {
        setState(() {
          _loading = false;
          _connectingWallet = null;
        });
      }
    } on SolanaWalletException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _connectingWallet = null;
        if (!error.cancelled) {
          _error = error.message;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _connectingWallet = null;
          _error = 'Could not connect wallet. Try again.';
        });
      }
    }
  }

  Future<void> _cancelConnect() async {
    if (!_loading || _connectingWallet == null) {
      return;
    }
    await widget.walletService.cancelConnect();
  }

  Future<void> _disconnect() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await widget.walletService.disconnect();
    } catch (_) {
      await widget.walletService.clearSession();
    }

    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _copyAddress(String address) async {
    await Clipboard.setData(ClipboardData(text: address));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Wallet address copied'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connecting = _loading && _connectingWallet != null;
    final connected = widget.walletService.isConnected;
    final address = widget.walletService.walletAddress;
    final accent = connected ? DropTheme.success : DropTheme.orange;

    if (connecting) {
      final wallet = _connectingWallet!;
      return DropCard(
        onTap: _cancelConnect,
        child: Row(
          children: [
            const LeadingTile(
              icon: Icons.hourglass_top_rounded,
              accent: DropTheme.amber,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Approve in ${wallet.name}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Tap to cancel',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Text(
              'Cancel',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: DropTheme.muted),
            ),
          ],
        ),
      );
    }

    return DropCard(
      child: connected && address != null
          ? Row(
              children: [
                LeadingTile(
                  icon: Icons.account_balance_wallet_rounded,
                  accent: accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PressableScale(
                    onTap: _loading ? null : () => _copyAddress(address),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: truncateWalletAddress(address),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  fontFamily: DropTheme.monoFont,
                                  color: DropTheme.white,
                                ),
                          ),
                          TextSpan(
                            text: ' connected',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                DropIconButton(
                  icon: Icons.copy_rounded,
                  tooltip: 'Copy address',
                  tonal: true,
                  color: DropTheme.success,
                  size: 40,
                  busy: _loading,
                  onPressed: _loading ? null : () => _copyAddress(address),
                ),
                const SizedBox(width: 4),
                DropIconButton(
                  icon: Icons.link_off_rounded,
                  tooltip: 'Disconnect',
                  tonal: true,
                  color: DropTheme.muted,
                  size: 40,
                  busy: _loading,
                  onPressed: _loading ? null : _disconnect,
                ),
              ],
            )
          : Row(
              children: [
                LeadingTile(
                  icon: Icons.account_balance_wallet_rounded,
                  accent: accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Solana wallet',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _error ?? 'Connect your wallet address.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _error != null ? DropTheme.danger : null,
                        ),
                      ),
                    ],
                  ),
                ),
                DropIconButton(
                  icon: _error == null
                      ? Icons.link_rounded
                      : Icons.refresh_rounded,
                  tooltip: _error == null ? 'Connect wallet' : 'Try again',
                  tonal: true,
                  color: DropTheme.orange,
                  size: 40,
                  busy: _loading,
                  onPressed: _loading ? null : _connect,
                ),
              ],
            ),
    );
  }
}
