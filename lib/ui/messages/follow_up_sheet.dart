import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/follow_up.dart';
import '../../domain/mail_message.dart';
import '../../state/follow_ups.dart';
import '../../state/meeting_providers.dart' show workWeekProvider;
import '../common/bottom_message.dart';
import 'date_format.dart';
import 'message_actions.dart';

/// Outlook's Follow Up for [messages]: a day it is due (today, tomorrow,
/// this week, next week, none, or one chosen), a reminder, Mark complete,
/// or Clear flag. On a Microsoft account the day and the check go to the
/// server, where Outlook on the PC shows them; on Gmail the day is kept
/// here. A reminder is this phone's, for any account.
Future<void> showFollowUpSheet(
  BuildContext context,
  WidgetRef ref, {
  required String listId,
  required List<MailMessage> messages,
}) async {
  if (messages.isEmpty) return;
  final store = ref.read(followUpsProvider.notifier);
  final one = messages.length == 1 ? messages.single : null;
  final record = one == null ? null : store.of(one);
  final choice = await showModalBottomSheet<_Choice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _FollowUpSheet(
      due: one?.flagDue ?? record?.due,
      remindAt: record?.remindAt,
      flagged: messages.any((m) => m.isFlagged),
      workWeek: ref.read(workWeekProvider),
    ),
  );
  if (choice == null || !context.mounted) return;
  final actions = MessageActions(ref, listId);
  switch (choice) {
    case _Due(:final day):
      await actions.followUp(context, messages, due: day);
    case _Custom():
      final now = DateTime.now();
      final day = await showDatePicker(
        context: context,
        initialDate: one?.flagDue ?? record?.due ?? now,
        firstDate: DateTime(now.year - 1),
        lastDate: DateTime(now.year + 5),
      );
      if (day == null || !context.mounted) return;
      await actions.followUp(context, messages, due: day);
    case _Reminder():
      await _remind(context, ref, listId, messages,
          due: one?.flagDue ?? record?.due, was: record?.remindAt);
    case _NoReminder():
      for (final m in messages) {
        await store.setReminder(m, null);
      }
      if (context.mounted) _tell(context, 'Reminder removed');
    case _Complete():
      await actions.followUp(context, messages, complete: true);
    case _Clear():
      await actions.setFlagged(context, messages, false);
  }
}

/// A reminder for [messages], at a day and a time asked for: flagged first
/// where they are not, as Outlook's Add Reminder flags.
Future<void> _remind(
  BuildContext context,
  WidgetRef ref,
  String listId,
  List<MailMessage> messages, {
  DateTime? due,
  DateTime? was,
}) async {
  final now = DateTime.now();
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final start = was ?? due ?? tomorrow;
  final day = await showDatePicker(
    context: context,
    initialDate: start.isBefore(DateTime(now.year, now.month, now.day))
        ? now
        : start,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: DateTime(now.year + 5),
  );
  if (day == null || !context.mounted) return;
  final today = day.year == now.year && day.month == now.month &&
      day.day == now.day;
  final time = await showTimePicker(
    context: context,
    initialTime: was != null
        ? TimeOfDay.fromDateTime(was)
        : today
            ? TimeOfDay(hour: (now.hour + 1) % 24, minute: 0)
            : const TimeOfDay(hour: 9, minute: 0),
  );
  if (time == null || !context.mounted) return;
  final at = DateTime(day.year, day.month, day.day, time.hour, time.minute);
  if (!at.isAfter(DateTime.now())) {
    _tell(context, 'That time has passed.');
    return;
  }
  final unflagged = [
    for (final m in messages)
      if (!m.isFlagged) m,
  ];
  final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
  if (unflagged.isNotEmpty) {
    await MessageActions(ref, listId).followUp(context, unflagged, due: due);
  }
  final store = ref.read(followUpsProvider.notifier);
  var set = true;
  for (final m in messages) {
    set = await store.setReminder(m, at) && set;
  }
  if (!context.mounted) return;
  _tell(
    context,
    set
        ? 'Reminder set for ${shortDay(at)}, ${formatClock(at, use24h: use24h)}'
        : 'The reminder could not be set.',
  );
}

void _tell(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(text)));
}

sealed class _Choice {
  const _Choice();
}

class _Due extends _Choice {
  const _Due(this.day);
  final DateTime? day;
}

class _Custom extends _Choice {
  const _Custom();
}

class _Reminder extends _Choice {
  const _Reminder();
}

class _NoReminder extends _Choice {
  const _NoReminder();
}

class _Complete extends _Choice {
  const _Complete();
}

class _Clear extends _Choice {
  const _Clear();
}

class _FollowUpSheet extends StatelessWidget {
  const _FollowUpSheet({
    required this.due,
    required this.remindAt,
    required this.flagged,
    required this.workWeek,
  });

  final DateTime? due;
  final DateTime? remindAt;
  final bool flagged;
  final Set<int> workWeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final reminder = remindAt == null || remindAt!.isBefore(now)
        ? null
        : '${shortDay(remindAt!)}, ${formatClock(remindAt!, use24h: use24h)}';
    void pick(_Choice c) => Navigator.of(context).pop(c);

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Follow up', style: theme.textTheme.titleMedium),
            ),
            if (flagged && (due != null || reminder != null))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  [
                    if (due != null) dueLabel(due!, now),
                    if (reminder != null) 'Reminder $reminder',
                  ].join(' · '),
                  style: muted,
                ),
              ),
            for (final choice in FollowUpChoice.values)
              ListTile(
                key: ValueKey('follow-up-${choice.name}'),
                leading: const Icon(Icons.flag_outlined),
                title: Text(choice.label),
                trailing: switch (dueFor(choice, now, workWeek: workWeek)) {
                  final day? => Text(shortDay(day), style: muted),
                  null => null,
                },
                onTap: () =>
                    pick(_Due(dueFor(choice, now, workWeek: workWeek))),
              ),
            ListTile(
              key: const ValueKey('follow-up-custom'),
              leading: const Icon(Icons.calendar_today_outlined),
              title: const Text('Choose a day…'),
              onTap: () => pick(const _Custom()),
            ),
            const Divider(height: 1),
            ListTile(
              key: const ValueKey('follow-up-reminder'),
              leading: const Icon(Icons.alarm_add_outlined),
              title: Text(reminder == null
                  ? 'Add reminder…'
                  : 'Change reminder ($reminder)…'),
              onTap: () => pick(const _Reminder()),
            ),
            if (reminder != null)
              ListTile(
                key: const ValueKey('follow-up-no-reminder'),
                leading: const Icon(Icons.alarm_off_outlined),
                title: const Text('Remove reminder'),
                onTap: () => pick(const _NoReminder()),
              ),
            if (flagged) ...[
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('follow-up-complete'),
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Mark complete'),
                onTap: () => pick(const _Complete()),
              ),
              ListTile(
                key: const ValueKey('follow-up-clear'),
                leading: const Icon(Icons.outlined_flag),
                title: const Text('Clear flag'),
                onTap: () => pick(const _Clear()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
