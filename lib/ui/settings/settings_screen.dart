import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/sync_prefs.dart';
import '../../state/providers.dart';
import '../../state/sync_providers.dart';
import '../quick_steps/quick_steps_screen.dart';
import '../../state/update_providers.dart';
import 'about_screen.dart';
import 'accounts_screen.dart';
import 'backup_screen.dart';
import 'notifications_screen.dart';
import 'signatures_screen.dart';
import 'sync_screen.dart';
import 'view_settings_screen.dart';
import 'home_widgets_screen.dart';

/// Everything that used to be loose entries at the bottom of the folder tree,
/// in one place with a subtitle each saying what is currently set.
///
/// The subtitles are the point. A settings list whose rows say only their own
/// name makes you open every one to find the thing you changed last week.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).value ?? const [];
    final sync = ref.watch(syncSettingsProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), centerTitle: false),
      body: ListView(
        children: [
          const _SectionHeading('Mail'),
          _Row(
            icon: Icons.view_quilt_outlined,
            title: 'View',
            subtitle: const ViewSummary().text(ref),
            onTap: () => _open(context, const ViewSettingsScreen()),
          ),
          _Row(
            icon: Icons.sync,
            title: 'Sync',
            subtitle: switch (sync) {
              null => 'Loading',
              final s when s.mode == SyncMode.periodic =>
                'About every ${_minutes(s.intervalMinutes)}',
              final s => s.mode.label,
            },
            onTap: () => _open(context, const SyncScreen()),
          ),
          _Row(
            icon: Icons.notifications_none,
            title: 'Notifications',
            subtitle: switch (sync) {
              null => 'Loading',
              final s when !s.notify => 'Off',
              final s when !s.syncs => 'On, but nothing is syncing',
              final s when s.mutedAccountIds.isNotEmpty =>
                'On, ${s.mutedAccountIds.length} account muted',
              _ => 'On',
            },
            onTap: () => _open(context, const NotificationsScreen()),
          ),
          _Row(
            icon: Icons.widgets_outlined,
            title: 'Home screen widgets',
            subtitle: 'What each one counts, and what it is called',
            onTap: () => _open(context, const HomeWidgetsScreen()),
          ),
          _Row(
            icon: Icons.bolt_outlined,
            title: 'Quick Steps',
            subtitle: 'One-tap action chains',
            onTap: () => _open(context, const QuickStepsScreen()),
          ),
          const Divider(height: 1),
          const _SectionHeading('Accounts'),
          _Row(
            icon: Icons.alternate_email,
            title: 'Accounts',
            subtitle: switch (accounts.length) {
              0 => 'None yet',
              1 => accounts.single.emailAddress,
              final n => '$n accounts',
            },
            onTap: () => _open(context, const AccountsScreen()),
          ),
          _Row(
            icon: Icons.draw_outlined,
            title: 'Signatures',
            subtitle: 'What is added to the end of a message',
            onTap: () => _open(context, const SignaturesScreen()),
          ),
          const Divider(height: 1),
          const _SectionHeading('This app'),
          _Row(
            icon: Icons.save_alt,
            title: 'Backup',
            subtitle: 'Save your settings to a file, or restore them',
            onTap: () => _open(context, const BackupScreen()),
          ),
          _Row(
            icon: Icons.info_outline,
            title: 'About',
            subtitle: switch (ref.watch(installedVersionValueProvider).value) {
              null => 'Version and updates',
              final v => 'Version ${v.version}, build ${v.build}',
            },
            onTap: () => _open(context, const AboutScreen()),
          ),
        ],
      ),
    );
  }

  static String _minutes(int minutes) => switch (minutes) {
        < 60 => '$minutes minutes',
        60 => 'hour',
        _ => '${minutes ~/ 60} hours',
      };

  static void _open(BuildContext context, Widget screen) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => screen),
      );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        text,
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: false,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    );
  }
}
