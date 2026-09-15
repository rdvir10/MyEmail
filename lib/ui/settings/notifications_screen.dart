import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/notification_prefs.dart';
import '../../state/notification_providers.dart';
import '../../state/providers.dart';

/// Turn new-mail notifications on, choose how often to look, and silence
/// individual accounts.
///
/// The screen is careful about one thing in particular: the switch here is the
/// user's intent, and Android's own permission is whether that intent is
/// allowed. When they disagree, the screen says so rather than showing an "on"
/// switch above a phone that will never make a sound.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(notificationSettingsProvider);
    final permitted = ref.watch(notificationPermissionProvider).value;
    final accounts = ref.watch(accountsProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications'), centerTitle: false),
      body: switch (settings) {
        AsyncError(:final error) => Center(child: Text('$error')),
        AsyncData(value: final prefs) => ListView(
            children: [
              SwitchListTile(
                title: const Text('Notify me about new mail'),
                subtitle: const Text(
                  'MailTree checks your inboxes in the background and tells '
                  'you when something arrives.',
                ),
                value: prefs.enabled,
                onChanged: (want) => _setEnabled(context, ref, want),
              ),
              if (prefs.enabled && permitted == false)
                _Warning(
                  text: 'Android is blocking notifications for MailTree. '
                      'Turn them on in Settings, Apps, MailTree.',
                  theme: theme,
                ),
              const Divider(height: 1),
              _IntervalTile(prefs: prefs),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Accounts', style: theme.textTheme.titleSmall),
              ),
              if (accounts.isEmpty)
                const ListTile(
                  dense: true,
                  title: Text('No accounts yet.'),
                )
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
                    onChanged: prefs.enabled
                        ? (on) => ref
                            .read(notificationSettingsProvider.notifier)
                            .setAccountMuted(account.id, !on)
                        : null,
                  ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                child: Text(
                  'Only your Inbox is watched. Mail that a rule files into '
                  'another folder is synced quietly.\n\n'
                  'Android decides when background checks actually run, so '
                  'they can be later than the interval you pick, especially '
                  'overnight.',
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

  Future<void> _setEnabled(
    BuildContext context,
    WidgetRef ref,
    bool want,
  ) async {
    final ok =
        await ref.read(notificationSettingsProvider.notifier).setEnabled(want);
    if (ok || !want || !context.mounted) return;
    // Permission was refused, so the switch stayed off. Say why, or it looks
    // like the switch is broken.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Android refused permission, so notifications stay off.'),
        ),
      );
  }
}

class _IntervalTile extends ConsumerWidget {
  const _IntervalTile({required this.prefs});

  final NotificationPrefs prefs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      enabled: prefs.enabled,
      title: const Text('Check for mail'),
      subtitle: Text('About every ${label(prefs.intervalMinutes)}'),
      trailing: DropdownButton<int>(
        value: prefs.intervalMinutes,
        underline: const SizedBox.shrink(),
        onChanged: prefs.enabled
            ? (minutes) {
                if (minutes == null) return;
                ref
                    .read(notificationSettingsProvider.notifier)
                    .setInterval(minutes);
              }
            : null,
        items: [
          for (final minutes in NotificationPrefs.intervalChoices)
            DropdownMenuItem(value: minutes, child: Text(label(minutes))),
        ],
      ),
    );
  }

  static String label(int minutes) => switch (minutes) {
        < 60 => '$minutes minutes',
        60 => 'hour',
        _ => '${minutes ~/ 60} hours',
      };
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text, required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined,
              size: 18, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
