import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/follow_up.dart' show shortDay;
import '../../domain/free_busy.dart' show defaultWorkWeek;
import '../../domain/mail_message.dart';
import '../../state/meeting_providers.dart' show workWeekProvider;
import 'date_format.dart';
import 'message_actions.dart';

/// The times Snooze offers from [now], as Outlook's: later today (three
/// hours on, while that is still the day's), tomorrow morning, the weekend
/// (the next day off, from a day worked), and next week (the first day
/// worked after the next days off), each at eight in the morning but the
/// first.
List<({String label, DateTime at})> snoozeChoices(
  DateTime now, {
  Set<int> workWeek = defaultWorkWeek,
}) {
  final today = DateTime(now.year, now.month, now.day);
  DateTime morning(int d) => DateTime(today.year, today.month, today.day + d, 8);
  bool worked(int d) => workWeek.contains(morning(d).weekday);
  final later = DateTime(now.year, now.month, now.day, now.hour + 3);
  final choices = <({String label, DateTime at})>[
    if (later.day == now.day && later.hour < 21)
      (label: 'Later today', at: later),
    (label: 'Tomorrow', at: morning(1)),
  ];
  if (workWeek.isNotEmpty && workWeek.length < 7 && worked(0)) {
    for (var d = 1; d < 7; d++) {
      if (!worked(d)) {
        if (d > 1) choices.add((label: 'This weekend', at: morning(d)));
        break;
      }
    }
  }
  if (workWeek.isNotEmpty && workWeek.length < 7) {
    var d = 0;
    while (d < 7 && worked(d)) {
      d++;
    }
    while (d < 14 && !worked(d)) {
      d++;
    }
    if (d > 1) choices.add((label: 'Next week', at: morning(d)));
  }
  return choices;
}

/// Outlook's Snooze for [messages]: out of the list now, back in its folder,
/// unread, at a time chosen here. Answers whether they went.
Future<bool> showSnoozeSheet(
  BuildContext context,
  WidgetRef ref, {
  required String listId,
  required List<MailMessage> messages,
}) async {
  if (messages.isEmpty) return false;
  final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
  final choices =
      snoozeChoices(DateTime.now(), workWeek: ref.read(workWeekProvider));
  final picked = await showModalBottomSheet<DateTime?>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      final muted = theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Snooze until', style: theme.textTheme.titleMedium),
            ),
            for (final c in choices)
              ListTile(
                key: ValueKey('snooze-${c.label}'),
                leading: const Icon(Icons.snooze_outlined),
                title: Text(c.label),
                trailing: Text(
                  '${shortDay(c.at)}, ${formatClock(c.at, use24h: use24h)}',
                  style: muted,
                ),
                onTap: () => Navigator.of(sheet).pop(c.at),
              ),
            ListTile(
              key: const ValueKey('snooze-custom'),
              leading: const Icon(Icons.calendar_today_outlined),
              title: const Text('Choose a day and time…'),
              onTap: () => Navigator.of(sheet).pop(DateTime(0)),
            ),
          ],
        ),
      );
    },
  );
  if (picked == null || !context.mounted) return false;
  var until = picked;
  if (picked.year == 0) {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year, now.month, now.day + 1),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
    );
    if (day == null || !context.mounted) return false;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
    );
    if (time == null || !context.mounted) return false;
    until = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    if (!until.isAfter(DateTime.now())) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('That time has passed.')));
      return false;
    }
  }
  return MessageActions(ref, listId).snooze(
    context,
    messages,
    until,
    said: '${messages.length == 1 ? 'Snoozed' : '${messages.length} snoozed'}'
        ' until ${shortDay(until)}, ${formatClock(until, use24h: use24h)}',
  );
}
