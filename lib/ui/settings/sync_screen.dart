import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/sync_prefs.dart';
import '../../state/sync_providers.dart';

/// How often MyEmail looks for new mail in the background.
///
/// Only that. Whether it then tells you is the Notifications screen, because
/// the two are separate decisions: keeping the app current so it is ready
/// when you open it, and being interrupted when something arrives.
class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(syncSettingsProvider);
    final stoppedAt = ref.watch(stalledLiveSyncProvider).value;
    final exempt = ref.watch(batteryExemptProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync'), centerTitle: false),
      body: switch (settings) {
        AsyncError(:final error) => Center(child: Text('$error')),
        AsyncData(value: final prefs) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'How often MyEmail checks for new mail when it is closed.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (stoppedAt != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Android stopped this at '
                    '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(stoppedAt))}'
                    '. It allows it about six hours a day unless MyEmail is '
                    'opened, and opening it has started it again.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              if (prefs.syncs &&
                  prefs.mode.needsForegroundService &&
                  exempt == false)
                _LimitedBanner(
                  onAllow: () => ref
                      .read(syncSettingsProvider.notifier)
                      .askToRunInBackground(),
                ),
              RadioGroup<SyncMode>(
                groupValue: prefs.mode,
                onChanged: (mode) =>
                    mode == null ? null : _setMode(context, ref, mode),
                child: Column(
                  children: [
                    for (final mode in SyncMode.values)
                      RadioListTile<SyncMode>(
                        value: mode,
                        title: Text(mode.label),
                        // The cost is on the row with the choice, not in a
                        // footnote. Two of these put a permanent notification
                        // in the shade and cost real battery, and finding that
                        // out afterwards feels like a trick.
                        subtitle: Text(mode.cost),
                        isThreeLine: true,
                      ),
                  ],
                ),
              ),
              if (prefs.mode == SyncMode.periodic) ...[
                const Divider(height: 1),
                _IntervalTile(prefs: prefs),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                child: Text(
                  _footnote(prefs),
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

  static String _footnote(SyncPrefs prefs) {
    if (!prefs.syncs) {
      return 'Nothing runs in the background. Mail arrives when you open '
          'MyEmail, and no notification can reach you before that.';
    }
    if (prefs.showsOngoingNotification) {
      return 'A permanent "MyEmail" notification stays in the shade while '
          'this is on. Android requires it, and there is no way to hide it '
          'and keep checking this often.\n\n'
          'Only your Inbox is watched. Mail that a rule files into another '
          'folder is synced quietly.';
    }
    return 'Android decides when these checks actually run, so they can be '
        'later than the interval you pick, especially overnight.\n\n'
        'Only your Inbox is watched. Mail that a rule files into another '
        'folder is synced quietly.';
  }

  Future<void> _setMode(
    BuildContext context,
    WidgetRef ref,
    SyncMode mode,
  ) async {
    final ok = await ref.read(syncSettingsProvider.notifier).setMode(mode);
    if (ok || !context.mounted) return;
    // Only the foreground modes ask, and only they can be refused.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(duration: kBottomMessage, 
          content: Text(
            'That needs notification permission, because Android requires a '
            'permanent notification for it. Nothing changed.',
          ),
        ),
      );
  }
}

/// Android is optimising MyEmail's battery, which is what refuses push its
/// service whenever it starts again on its own. The way out is Android's
/// own dialog.
class _LimitedBanner extends StatelessWidget {
  const _LimitedBanner({required this.onAllow});

  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onErrorContainer;
    return Container(
      key: const ValueKey('background-limited'),
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.battery_alert_outlined, size: 18, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Android limits MyEmail in the background. When it restarts '
              'MyEmail on its own, this cannot run, and mail is checked only '
              'every ${SyncPrefs.minimumIntervalMinutes} minutes until you '
              'open the app.',
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
          TextButton(
            onPressed: onAllow,
            style: TextButton.styleFrom(foregroundColor: foreground),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
  }
}

class _IntervalTile extends ConsumerWidget {
  const _IntervalTile({required this.prefs});

  final SyncPrefs prefs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: const Text('How often'),
      subtitle: Text('About every ${label(prefs.intervalMinutes)}'),
      trailing: DropdownButton<int>(
        value: prefs.intervalMinutes,
        underline: const SizedBox.shrink(),
        onChanged: (minutes) {
          if (minutes == null) return;
          ref.read(syncSettingsProvider.notifier).setInterval(minutes);
        },
        items: [
          for (final minutes in SyncPrefs.intervalChoices)
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
