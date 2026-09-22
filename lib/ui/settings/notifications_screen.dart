import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../state/sync_providers.dart';
import 'sync_screen.dart';

/// Whether new mail interrupts you, and which accounts are allowed to.
///
/// Only that. How often MyEmail looks is the Sync screen. The two were one
/// switch and that was wrong: turning notifications off also stopped the app
/// keeping itself current, which is not what anyone means by "be quiet".
///
/// Two things this screen is careful about. The switch here is the user's
/// intent and Android's permission is whether that intent is allowed, so when
/// they disagree it says so. And notifications cannot arrive without a
/// background pass to find them, so if sync is off it says that too rather
/// than showing a switch that is on above a phone that will stay silent.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(syncSettingsProvider);
    final permitted = ref.watch(notificationPermissionProvider).value;
    final accounts = ref.watch(accountsProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications'), centerTitle: false),
      body: switch (settings) {
        AsyncError(:final error) => Center(child: Text('$error')),
        AsyncData(value: final prefs) => ListView(
            children: [
              SwitchListTile(
                title: const Text('Tell me when mail arrives'),
                subtitle: const Text(
                  'Off still syncs in the background, so the app is up to '
                  'date when you open it. It just does it quietly.',
                ),
                isThreeLine: true,
                value: prefs.notify,
                onChanged: (want) => _setNotify(context, ref, want),
              ),
              if (prefs.notifyIsIdle)
                _Banner(
                  icon: Icons.sync_disabled,
                  text: 'Nothing is checking for mail in the background, so '
                      'nothing can announce it.',
                  action: 'Set up sync',
                  onAction: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const SyncScreen()),
                  ),
                  theme: theme,
                  isWarning: true,
                ),
              if (prefs.notify && prefs.syncs && permitted == false)
                _Banner(
                  icon: Icons.warning_amber_outlined,
                  text: 'Android is blocking notifications for MyEmail. '
                      'Turn them on in Settings, Apps, MyEmail.',
                  theme: theme,
                  isWarning: true,
                ),
              const Divider(height: 1),
              _Heading('Accounts', theme: theme),
              if (accounts.isEmpty)
                const ListTile(dense: true, title: Text('No accounts yet.'))
              else
                for (final account in accounts)
                  SwitchListTile(
                    title: Text(account.displayName),
                    subtitle: Text(account.emailAddress),
                    secondary: CircleAvatar(
                      radius: 12,
                      backgroundColor: Color(account.colorValue),
                    ),
                    value: !prefs.mutedAccountIds.contains(account.id),
                    onChanged: prefs.notify
                        ? (on) => ref
                            .read(syncSettingsProvider.notifier)
                            .setAccountMuted(account.id, !on)
                        : null,
                  ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                child: Text(
                  'A muted account still syncs. Its mail is on the device and '
                  'waiting when you open the app; it just does not interrupt '
                  'you to say so.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Future<void> _setNotify(
    BuildContext context,
    WidgetRef ref,
    bool want,
  ) async {
    final ok = await ref.read(syncSettingsProvider.notifier).setNotify(want);
    if (ok || !want || !context.mounted) return;
    // Permission was refused, so the switch stayed off. Say why, or it looks
    // like the switch is broken.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(duration: kBottomMessage, 
          content: Text('Android refused permission, so notifications stay off.'),
        ),
      );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          text,
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.primary),
        ),
      );
}

/// A band that explains a setting that will not do what it looks like it does,
/// with a way out where there is one.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.theme,
    this.action,
    this.onAction,
    this.isWarning = false,
  });

  final IconData icon;
  final String text;
  final ThemeData theme;
  final String? action;
  final VoidCallback? onAction;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final background = isWarning
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHigh;
    final foreground = isWarning
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(foregroundColor: foreground),
              child: Text(action!),
            ),
        ],
      ),
    );
  }
}
