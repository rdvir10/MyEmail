import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/account.dart';
import '../../domain/folder_role.dart';
import '../../domain/follow_up.dart' show shortDay;
import '../../domain/sync_prefs.dart';
import '../../state/folder_tree.dart' show displayPath;
import '../../state/meeting_providers.dart' show workWeekProvider;
import '../../state/providers.dart';
import '../../state/sync_providers.dart';
import '../messages/date_format.dart';

/// What one account's new mail may interrupt you for: everyone's, or VIPs'
/// alone; Outlook for Android's Do Not Disturb; and which folders besides
/// the Inbox are announced too. Its mail syncs whatever is chosen here.
class AccountNotificationsScreen extends ConsumerWidget {
  const AccountNotificationsScreen({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final prefs = ref.watch(syncSettingsProvider).value ?? const SyncPrefs();
    final settings = ref.read(syncSettingsProvider.notifier);
    final rule = prefs.quiet[account.id] ?? const QuietRule();
    final now = DateTime.now();
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String clock(DateTime t) => formatClock(t, use24h: use24h);
    String hour(int h) => clock(DateTime(2000, 1, 1, h));
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final until = rule.until != null && rule.until!.isAfter(now)
        ? rule.until
        : null;
    final folders = [
      for (final f in ref.watch(foldersProvider).value?[account.id] ?? const [])
        if (f.role != FolderRole.inbox &&
            f.role != FolderRole.deleted &&
            f.role != FolderRole.junk &&
            f.role != FolderRole.drafts &&
            f.role != FolderRole.sent &&
            f.role != FolderRole.outbox &&
            !f.isSynthetic)
          f,
    ]..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    Future<void> quiet(QuietRule next) => settings.setQuiet(account.id, next);

    return Scaffold(
      appBar: AppBar(title: Text(account.displayName), centerTitle: false),
      body: ListView(
        children: [
          _Heading('Tell me about', theme: theme),
          RadioGroup<bool>(
            groupValue: prefs.vipOnlyAccountIds.contains(account.id),
            onChanged: (only) => settings.setVipOnly(account.id, only ?? false),
            child: const Column(
              children: [
                RadioListTile<bool>(
                  key: ValueKey('notify-all'),
                  value: false,
                  title: Text('All new mail'),
                ),
                RadioListTile<bool>(
                  key: ValueKey('notify-vips'),
                  value: true,
                  title: Text('Only mail from VIPs'),
                  subtitle: Text('Settings, Notifications, VIPs'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _Heading('Do Not Disturb', theme: theme),
          if (until != null)
            ListTile(
              leading: const Icon(Icons.do_not_disturb_on_outlined),
              title: Text('Quiet until ${shortDay(until)}, ${clock(until)}'),
              trailing: TextButton(
                key: const ValueKey('quiet-end'),
                onPressed: () => quiet(rule.copyWith(until: null)),
                child: const Text('End now'),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    key: const ValueKey('quiet-hour'),
                    onPressed: () => quiet(rule.copyWith(
                        until: DateTime.now().add(const Duration(hours: 1)))),
                    child: const Text('For 1 hour'),
                  ),
                  OutlinedButton(
                    key: const ValueKey('quiet-tomorrow'),
                    onPressed: () => quiet(rule.copyWith(
                        until: DateTime(now.year, now.month, now.day + 1, 8))),
                    child: Text('Until tomorrow, ${hour(8)}'),
                  ),
                ],
              ),
            ),
          SwitchListTile(
            key: const ValueKey('quiet-evenings'),
            title: const Text('Every evening'),
            subtitle: Text('${hour(rule.from)} to ${hour(rule.to)}'),
            value: rule.evenings,
            onChanged: (on) => quiet(rule.copyWith(evenings: on)),
          ),
          if (rule.evenings)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  const Text('From'),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    key: const ValueKey('quiet-from'),
                    value: rule.from,
                    items: [
                      for (var h = 0; h < 24; h++)
                        DropdownMenuItem(value: h, child: Text(hour(h))),
                    ],
                    onChanged: (h) =>
                        h == null ? null : quiet(rule.copyWith(from: h)),
                  ),
                  const SizedBox(width: 16),
                  const Text('to'),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    key: const ValueKey('quiet-to'),
                    value: rule.to,
                    items: [
                      for (var h = 0; h < 24; h++)
                        DropdownMenuItem(value: h, child: Text(hour(h))),
                    ],
                    onChanged: (h) =>
                        h == null ? null : quiet(rule.copyWith(to: h)),
                  ),
                ],
              ),
            ),
          SwitchListTile(
            key: const ValueKey('quiet-weekends'),
            title: const Text('Weekends'),
            subtitle: const Text('All day on the days off in your work week'),
            value: rule.weekends,
            onChanged: (on) => quiet(rule.copyWith(
              weekends: on,
              daysOff: {
                for (var d = DateTime.monday; d <= DateTime.sunday; d++)
                  if (!ref.read(workWeekProvider).contains(d)) d,
              },
            )),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Mail still comes in while it is quiet; it is only not '
              'announced, then or after.',
              style: muted,
            ),
          ),
          const Divider(height: 1),
          _Heading('Folders', theme: theme),
          const SwitchListTile(
            title: Text('Inbox'),
            value: true,
            onChanged: null,
          ),
          for (final f in folders)
            SwitchListTile(
              key: ValueKey('watch:${f.id}'),
              title: Text(f.displayName),
              subtitle: f.path.contains('/') ? Text(displayPath(f)) : null,
              value: prefs.watchedFolderIds.contains(f.id),
              onChanged: (on) => settings.setWatched(f.id, on),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: Text(
              'A folder switched on is checked in the background with the '
              'Inbox, and its new mail announced the same way.',
              style: muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// The people whose mail is always worth hearing about: Outlook's VIPs.
/// An account set to VIPs only announces their mail and no one else's.
class VipsScreen extends ConsumerStatefulWidget {
  const VipsScreen({super.key});

  @override
  ConsumerState<VipsScreen> createState() => _VipsScreenState();
}

class _VipsScreenState extends ConsumerState<VipsScreen> {
  final _field = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _add() {
    final text = _field.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text)) {
      setState(() => _problem = 'An email address');
      return;
    }
    ref.read(syncSettingsProvider.notifier).setVip(text, true);
    _field.clear();
    setState(() => _problem = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = ref.watch(syncSettingsProvider).value ?? const SyncPrefs();
    final vips = prefs.vips.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: const Text('VIPs'), centerTitle: false),
      body: ListView(
        children: [
          if (vips.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Nobody yet. Tap someone on a message and choose Add to '
                'VIPs, or type an address below.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          for (final vip in vips)
            ListTile(
              key: ValueKey('vip:$vip'),
              leading: const Icon(Icons.star_outline),
              title: Text(vip),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close),
                onPressed: () =>
                    ref.read(syncSettingsProvider.notifier).setVip(vip, false),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('vip-field'),
                    controller: _field,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      hintText: 'name@example.com',
                      errorText: _problem,
                      isDense: true,
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                TextButton(onPressed: _add, child: const Text('Add')),
              ],
            ),
          ),
        ],
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
        child: Text(text, style: theme.textTheme.titleSmall),
      );
}

/// One line for an account's row on the Notifications screen: what is
/// quieting it or narrowing it now, or nothing to say.
String? notificationStatus(SyncPrefs prefs, String accountId, DateTime now,
    {required bool use24h}) {
  final rule = prefs.quiet[accountId];
  final parts = <String>[
    if (rule?.until != null && rule!.until!.isAfter(now))
      'Quiet until ${formatClock(rule.until!, use24h: use24h)}'
    else if (rule?.isQuiet(now) ?? false)
      'Quiet now',
    if (rule?.evenings ?? false) 'Quiet evenings',
    if (rule?.weekends ?? false) 'Quiet weekends',
    if (prefs.vipOnlyAccountIds.contains(accountId)) 'VIPs only',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
