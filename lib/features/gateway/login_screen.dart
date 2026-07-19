import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/theme/drop_theme.dart';
import 'auth_config.dart';
import 'desktop_web_auth.dart';
import 'drop_auth_service.dart';

/// Multi-provider sign-in screen for Erebrus Drop.
///
/// Mobile: Reown AppKit (wallet + social/email), native Google/Apple, Erebrus
/// email OTP, and Solana Mobile Wallet Adapter on Seeker/Saga.
/// Desktop: Browser sign-in with erebrusdrop:// callback + paste fallback.
class GatewayLoginScreen extends StatefulWidget {
  const GatewayLoginScreen({super.key, required this.auth});
  final DropAuthService auth;

  @override
  State<GatewayLoginScreen> createState() => _GatewayLoginScreenState();
}

class _GatewayLoginScreenState extends State<GatewayLoginScreen> {
  @override
  void initState() {
    super.initState();
    widget.auth.signedIn.addListener(_onSignedIn);
    if (!isDesktopPlatform && !widget.auth.solanaMobileDevice.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await widget.auth.initReown(context);
      });
    }
  }

  @override
  void dispose() {
    widget.auth.signedIn.removeListener(_onSignedIn);
    super.dispose();
  }

  void _onSignedIn() {
    if (widget.auth.isSignedIn && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DropTheme.black,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.auth.state,
          builder: (context, child) => Stack(
            children: [
              _body(context),
              if (widget.auth.isAuthenticating.value ||
                  widget.auth.awaitingWebCallback.value)
                _loadingOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final isDesktop = isDesktopPlatform;
    final solanaOnly = widget.auth.solanaMobileDevice.value;
    final reownReady = widget.auth.reownReady.value;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: DropTheme.accentGradient,
                borderRadius: BorderRadius.circular(18),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage(DropTheme.logoFlat),
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Welcome to Erebrus Drop',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: DropTheme.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Sign in to send files through Erebrus nodes.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: DropTheme.muted),
          ),
          const SizedBox(height: 36),
          if (isDesktop) ...[
            _PrimaryButton(
              label: 'Sign in with browser',
              icon: Icons.open_in_browser,
              onPressed: () => widget.auth.openWebSignIn(),
            ),
            const SizedBox(height: 16),
            _OutlinedButton(
              label: 'Paste sign-in token',
              icon: Icons.paste,
              onPressed: () => _showPasteSheet(context),
            ),
            const SizedBox(height: 20),
            Text(
              'Opens $kErebrusWebOrigin/auth in your browser.\n'
              'After you sign in, you\'ll return here automatically.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: DropTheme.faint),
            ),
          ] else if (solanaOnly) ...[
            _PrimaryButton(
              label: 'Connect Solana Wallet',
              icon: Icons.account_balance_wallet,
              onPressed: () => widget.auth.signInWithSolanaMobile(context),
            ),
            const SizedBox(height: 16),
            Text(
              'Your Seed Vault wallet signs you in — no passwords.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: DropTheme.faint),
            ),
          ] else ...[
            if (widget.auth.emailLoginAvailable) ...[
              _OutlinedButton(
                label: 'Continue with Email',
                icon: Icons.mail_outline,
                onPressed: () => _showEmailSheet(context),
              ),
              const SizedBox(height: 12),
            ],
            if (widget.auth.googleLoginAvailable) ...[
              _OutlinedButton(
                label: 'Continue with Google',
                icon: Icons.g_mobiledata_rounded,
                onPressed: () => widget.auth.signInWithGoogle(),
              ),
              const SizedBox(height: 12),
            ],
            if (widget.auth.appleLoginAvailable) ...[
              _OutlinedButton(
                label: 'Continue with Apple',
                icon: Icons.apple,
                onPressed: () => widget.auth.signInWithApple(),
              ),
              const SizedBox(height: 12),
            ],
            if (!reownReady &&
                !widget.auth.googleLoginAvailable &&
                !widget.auth.appleLoginAvailable &&
                !widget.auth.emailLoginAvailable)
              _PrimaryButton(
                label: 'Sign in with browser',
                icon: Icons.open_in_browser,
                onPressed: () => widget.auth.openWebSignIn(),
              )
            else ...[
              const SizedBox(height: 8),
              const _DividerLabel(label: 'CONNECT A WALLET'),
              const SizedBox(height: 8),
              _PrimaryButton(
                label: 'Connect Wallet',
                icon: Icons.account_balance_wallet,
                onPressed: () => widget.auth.openReownModal(),
              ),
            ],
          ],
          const SizedBox(height: 20),
          ValueListenableBuilder<String?>(
            valueListenable: widget.auth.error,
            builder: (context, err, _) {
              if (err == null || err.isEmpty) return const SizedBox.shrink();
              return Text(
                err,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: DropTheme.danger),
              );
            },
          ),
          const SizedBox(height: 24),
          Text(
            'By continuing you agree to Erebrus terms.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: DropTheme.faint),
          ),
        ],
      ),
    );
  }

  Widget _loadingOverlay() {
    return Container(
      color: DropTheme.black.withValues(alpha: 0.75),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: DropTheme.orange),
          const SizedBox(height: 16),
          Text(
            'Connecting to Erebrus…',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: DropTheme.white),
          ),
        ],
      ),
    );
  }

  void _showEmailSheet(BuildContext context) {
    widget.auth.error.value = null;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _EmailLoginSheet(auth: widget.auth),
      ),
    );
  }

  void _showPasteSheet(BuildContext context) {
    widget.auth.error.value = null;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _PasteTokenSheet(auth: widget.auth),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, color: DropTheme.onAccent),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: DropTheme.orange,
        foregroundColor: DropTheme.onAccent,
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DropTheme.radiusButton),
        ),
      ),
    );
  }
}

class _OutlinedButton extends StatelessWidget {
  const _OutlinedButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, color: DropTheme.white),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: DropTheme.white,
        minimumSize: const Size(0, 52),
        side: const BorderSide(color: DropTheme.lineStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DropTheme.radiusButton),
        ),
      ),
    );
  }
}

class _DividerLabel extends StatelessWidget {
  const _DividerLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final line = Expanded(
      child: Container(height: 1, color: DropTheme.line),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          line,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: DropTheme.muted,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
          ),
          line,
        ],
      ),
    );
  }
}

class _EmailLoginSheet extends StatefulWidget {
  const _EmailLoginSheet({required this.auth});
  final DropAuthService auth;

  @override
  State<_EmailLoginSheet> createState() => _EmailLoginSheetState();
}

class _EmailLoginSheetState extends State<_EmailLoginSheet> {
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _codeSent ? 'Enter your code' : 'Sign in with email',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: DropTheme.white),
          ),
          const SizedBox(height: 8),
          Text(
            _codeSent
                ? 'We sent a 6-digit code to ${_emailCtrl.text.trim()}'
                : "We'll email you a one-time code.",
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: DropTheme.muted),
          ),
          const SizedBox(height: 18),
          if (!_codeSent) ...[
            _InputField(
              controller: _emailCtrl,
              hint: 'you@example.com',
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
            ),
          ] else ...[
            _InputField(
              controller: _codeCtrl,
              hint: '6-digit code',
              keyboardType: TextInputType.number,
              autofocus: true,
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : (_codeSent ? _verify : _send),
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: DropTheme.onAccent,
                    ),
                  )
                : Text(_codeSent ? 'Verify' : 'Send code'),
          ),
          if (_codeSent) ...[
            const SizedBox(height: 10),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _codeSent = false;
                      _codeCtrl.clear();
                    }),
              child: const Text('Use a different email'),
            ),
          ],
          const SizedBox(height: 12),
          ValueListenableBuilder<String?>(
            valueListenable: widget.auth.error,
            builder: (context, err, _) {
              if (err == null || err.isEmpty) return const SizedBox.shrink();
              return Text(
                err,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: DropTheme.danger),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) return;
    setState(() => _busy = true);
    final ok = await widget.auth.requestEmailLoginCode(email);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _codeSent = true;
    });
  }

  Future<void> _verify() async {
    setState(() => _busy = true);
    await widget.auth.verifyEmailLoginCode(
      email: _emailCtrl.text.trim(),
      code: _codeCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (widget.auth.isSignedIn) Navigator.pop(context);
  }
}

class _PasteTokenSheet extends StatefulWidget {
  const _PasteTokenSheet({required this.auth});
  final DropAuthService auth;

  @override
  State<_PasteTokenSheet> createState() => _PasteTokenSheetState();
}

class _PasteTokenSheetState extends State<_PasteTokenSheet> {
  final _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Paste sign-in token',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: DropTheme.white),
          ),
          const SizedBox(height: 8),
          Text(
            'Paste the full callback URL or PASETO token from the browser.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: DropTheme.muted),
          ),
          const SizedBox(height: 18),
          _InputField(
            controller: _ctrl,
            hint: 'erebrusdrop://auth?token=…',
            autofocus: true,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: DropTheme.onAccent,
                    ),
                  )
                : const Text('Sign in'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _launchWeb,
            child: const Text('Open Erebrus sign-in in browser'),
          ),
          ValueListenableBuilder<String?>(
            valueListenable: widget.auth.error,
            builder: (context, err, _) {
              if (err == null || err.isEmpty) return const SizedBox.shrink();
              return Text(
                err,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: DropTheme.danger),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final input = _ctrl.text.trim();
    if (input.isEmpty) return;
    setState(() => _busy = true);
    await widget.auth.signInWithPastedCredential(input);
    if (!mounted) return;
    setState(() => _busy = false);
    if (widget.auth.isSignedIn) Navigator.pop(context);
  }

  Future<void> _launchWeb() async {
    final url = DesktopWebAuth.buildLoginUrl();
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class _InputField extends StatelessWidget {
  const _InputField({
    required this.controller,
    required this.hint,
    this.keyboardType,
    this.autofocus = false,
  });
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      autofocus: autofocus,
      decoration: InputDecoration(hintText: hint),
    );
  }
}
