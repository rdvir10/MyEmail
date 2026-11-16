import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/new_meeting_defaults.dart';
import '../../state/calendar_view_providers.dart' show calendarAccountsProvider;
import '../../state/meeting_providers.dart';
import '../messages/date_format.dart' show formatClock;

/// Settings, Calendar, New meetings: how New meeting starts (calendar idea
/// #61). How long a meeting lasts, whether it ends a few minutes early,
/// and the accounts whose meetings start online. A meeting being edited
/// keeps what it has.
///
/// Online is offered for the accounts whose calendar the app reaches,
/// where Teams or Meet can be: an account set up with an app password has
/// none.
class NewMeetingDefaultsSection extends ConsumerWidget {
  const NewMeetingDefaultsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final defaults = ref.watch(newMeetingDefaultsProvider);
    final set = ref.read(newMeetingDefaultsProvider.notifier).set;
    final accounts = ref.watch(calendarAccountsProvider);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    // What ending early does, said with a time: one at 9:00 ends at 9:25.
    final nine = DateTime(2000, 1, 1, 9);
    String clock(DateTime t) => formatClock(t, use24h: use24h);
    String length(int m) => m == 60 ? '1 hour' : '$m minutes';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
          child: Text(
            'New meetings',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'How New meeting starts. A meeting you edit keeps what it has.',
            style: muted,
          ),
        ),
        ListTile(
          title: const Text('Length'),
          trailing: DropdownButton<int>(
            key: const ValueKey('new-meeting-length'),
            value: defaults.minutes,
            onChanged: (m) {
              if (m != null) set(defaults.copyWith(minutes: m));
            },
            items: [
              for (final m in NewMeetingDefaults.lengthChoices)
                DropdownMenuItem(value: m, child: Text(length(m))),
            ],
          ),
        ),
        ListTile(
          title: const Text('End early'),
          subtitle: Text(defaults.endEarly == 0
              ? 'Off: it ends on the hour or the half hour'
              : 'Time to get to the next one: one at ${clock(nine)} ends at '
                  '${clock(nine.add(defaults.length))}'),
          trailing: DropdownButton<int>(
            key: const ValueKey('new-meeting-end-early'),
            value: defaults.endEarly,
            onChanged: (m) {
              if (m != null) set(defaults.copyWith(endEarly: m));
            },
            items: [
              for (final m in NewMeetingDefaults.endEarlyChoices)
                DropdownMenuItem(
                  value: m,
                  child: Text(m == 0 ? 'Off' : '$m minutes'),
                ),
            ],
          ),
        ),
        if (accounts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Online from the start: New meeting opens with Online on for '
              'the accounts switched on here, its Teams or Meet link made as '
              'it opens. Switch it off on the meeting to go without.',
              style: muted,
            ),
          ),
        for (final a in accounts)
          SwitchListTile(
            key: ValueKey('new-meeting-online:${a.id}'),
            secondary: CircleAvatar(
              radius: 10,
              backgroundColor: Color(a.colorValue),
            ),
            title: Text(a.displayName),
            subtitle: Text(a.emailAddress),
            value: defaults.onlineFor(a.id),
            onChanged: (on) => set(defaults.copyWith(online: {
              for (final id in defaults.online)
                if (id != a.id) id,
              if (on) a.id,
            })),
          ),
      ],
    );
  }
}
