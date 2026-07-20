import 'package:flutter/material.dart';

import '../../ui/theme/drop_theme.dart';
import '../../ui/widgets/drop_widgets.dart';
import 'drop_auth_service.dart';
import 'gateway_models.dart';

enum GatewayOrgSheetResult { none, changed }

Future<bool> confirmGatewaySignOut(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sign out?'),
          content: const Text(
            'Are you sure you want to sign out of your Erebrus account?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: DropTheme.danger,
                foregroundColor: DropTheme.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ) ??
      false;
}

Future<GatewayOrgSheetResult> showGatewayOrgSheet({
  required BuildContext context,
  required DropAuthService authService,
}) async {
  final result = await showModalBottomSheet<GatewayOrgSheetResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => GatewayOrgSheet(authService: authService),
  );
  return result ?? GatewayOrgSheetResult.none;
}

class GatewayOrgSheet extends StatefulWidget {
  const GatewayOrgSheet({required this.authService, super.key});
  final DropAuthService authService;

  @override
  State<GatewayOrgSheet> createState() => _GatewayOrgSheetState();
}

class _GatewayOrgSheetState extends State<GatewayOrgSheet> {
  bool _creating = false;
  final _nameController = TextEditingController();
  final _slugController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _nameController.dispose();
    _slugController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final orgs = widget.authService.orgs.value;
    final selected = widget.authService.selectedOrg.value;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

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
              'Organization',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              'Select the organization whose plan is used for Drop nodes.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (_creating)
              _createForm()
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final org in orgs)
                        _OrgRow(
                          org: org,
                          selected: selected?.id == org.id,
                          onTap: () async {
                            if (selected?.id == org.id) {
                              Navigator.of(context).pop(GatewayOrgSheetResult.none);
                              return;
                            }
                            final navigator = Navigator.of(context);
                            await widget.authService.selectOrg(org);
                            if (!mounted) return;
                            navigator.pop(GatewayOrgSheetResult.changed);
                          },
                        ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => setState(() => _creating = true),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Create new organization'),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () async {
                          final confirmed = await confirmGatewaySignOut(context);
                          if (!confirmed || !context.mounted) return;
                          final navigator = Navigator.of(context);
                          await widget.authService.signOut();
                          if (!mounted) return;
                          navigator.pop(GatewayOrgSheetResult.changed);
                        },
                        icon: const Icon(Icons.logout_rounded),
                        label: const Text('Sign out'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _createForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: 'Organization name'),
          enabled: !_busy,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _slugController,
          decoration: const InputDecoration(
            labelText: 'Slug (letters, numbers, dashes)',
            hintText: 'my-org',
          ),
          enabled: !_busy,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: PrimaryButton(
                label: _busy ? 'Creating…' : 'Create',
                busy: _busy,
                onPressed: _busy
                    ? null
                    : () async {
                        final name = _nameController.text.trim();
                        final slug = _slugController.text.trim();
                        if (name.isEmpty || slug.isEmpty) return;
                        final navigator = Navigator.of(context);
                        final messenger = ScaffoldMessenger.of(context);
                        setState(() => _busy = true);
                        try {
                          await widget.authService.createOrg(
                            name: name,
                            slug: slug,
                          );
                          if (!mounted) return;
                          navigator.pop(GatewayOrgSheetResult.changed);
                        } catch (e) {
                          if (!mounted) return;
                          messenger.showSnackBar(
                            SnackBar(content: Text('Could not create org: $e')),
                          );
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _creating = false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }
}

class _OrgRow extends StatelessWidget {
  const _OrgRow({
    required this.org,
    required this.selected,
    required this.onTap,
  });

  final DropOrg org;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: DropCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            LeadingTile(
              icon: selected ? Icons.check_circle_rounded : Icons.business_rounded,
              accent: selected ? DropTheme.success : null,
              size: 40,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    org.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${org.plan ?? 'Free'} · ${org.slug}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_rounded, color: DropTheme.success, size: 20),
          ],
        ),
      ),
    );
  }
}
