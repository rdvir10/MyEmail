import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/error_report.dart' show ReadableError;
import '../../domain/free_busy.dart';
import '../../state/meeting_providers.dart';
import '../../state/providers.dart';
import '../common/bottom_message.dart';
import 'html_editor.dart';

/// Outlook's Share availability: the times the sending account's calendar
/// is free, over the days asked for, written into the message for the other
/// person to pick one. Working days only: the work week is chosen here and
/// kept.
Future<void> insertFreeTimes(
  BuildContext context,
  WidgetRef ref, {
  required String accountId,
  required HtmlEditorController editor,
}) async {
  final asked = await showDialog<_FreeTimesAsk>(
    context: context,
    builder: (_) => _FreeTimesDialog(workWeek: ref.read(workWeekProvider)),
  );
  if (asked == null || !context.mounted) return;
  ref.read(workWeekProvider.notifier).set(asked.workWeek);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
  final days = workingDays(asked.first, asked.days, workWeek: asked.workWeek);
  if (days.isEmpty) return;
  try {
    final busy = await ref.read(mailEngineProvider).busyTimes(
          accountId,
          days.first,
          days.last.add(const Duration(days: 1)),
        );
    final now = DateTime.now();
    final byDay = {
      for (final day in days)
        day: freeOn(
          day,
          busy,
          from: asked.from,
          to: asked.to,
          shortest: asked.shortest,
          notBefore: now,
        ),
    };
    await editor.insertHtml(freeTimesHtml(
      byDay,
      use24h: use24h,
      zone: now.timeZoneName,
    ));
  } catch (e) {
    messenger?.showSnackBar(SnackBar(
      duration: kBottomMessage,
      content: Text(
        'Could not read your calendar. '
        '${e is ReadableError ? e.message : '$e'}',
      ),
    ));
  }
}

/// [count] working days from [first] on, at midnight: the days not in
/// [workWeek] passed over.
List<DateTime> workingDays(
  DateTime first,
  int count, {
  Set<int> workWeek = defaultWorkWeek,
}) {
  final days = <DateTime>[];
  if (workWeek.isEmpty) return days;
  for (var d = 0; days.length < count; d++) {
    final day = DateTime(first.year, first.month, first.day + d);
    if (workWeek.contains(day.weekday)) days.add(day);
  }
  return days;
}

typedef _FreeTimesAsk = ({
  DateTime first,
  int days,
  int from,
  int to,
  Duration shortest,
  Set<int> workWeek,
});

class _FreeTimesDialog extends StatefulWidget {
  const _FreeTimesDialog({required this.workWeek});

  final Set<int> workWeek;

  @override
  State<_FreeTimesDialog> createState() => _FreeTimesDialogState();
}

class _FreeTimesDialogState extends State<_FreeTimesDialog> {
  DateTime _first = DateTime.now();
  int _days = 5;
  int _from = 9;
  int _to = 17;
  int _shortest = 30;
  late final Set<int> _workWeek = {...widget.workWeek};

  static const _names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  Future<void> _pickFirst() async {
    final day = await showDatePicker(
      context: context,
      initialDate: _first,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (day != null) setState(() => _first = day);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    Widget choice(
      String label,
      int value,
      List<int> values,
      String Function(int) text,
      ValueChanged<int> onChanged,
    ) =>
        Row(
          children: [
            Expanded(child: Text(label)),
            DropdownButton<int>(
              value: value,
              underline: const SizedBox.shrink(),
              items: [
                for (final v in values)
                  DropdownMenuItem(value: v, child: Text(text(v))),
              ],
              onChanged: (v) => v == null ? null : setState(() => onChanged(v)),
            ),
          ],
        );
    String hour(int h) => '${h.toString().padLeft(2, '0')}:00';
    // The week from the day it starts on where the phone is, Sunday or
    // Monday. firstDayOfWeekIndex counts from Sunday, DateTime.weekday from
    // Monday.
    final firstDay = localizations.firstDayOfWeekIndex == 0
        ? DateTime.sunday
        : localizations.firstDayOfWeekIndex;
    return AlertDialog(
      title: const Text('Insert free times'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('From'),
              trailing: Text(localizations.formatMediumDate(_first)),
              onTap: _pickFirst,
            ),
            choice('Working days', _days, const [1, 2, 3, 5, 7, 10],
                (v) => '$v', (v) => _days = v),
            choice('Between', _from, [for (var h = 6; h <= 20; h++) h], hour,
                (v) => _from = v < _to ? v : _from),
            choice('And', _to, [for (var h = 7; h <= 22; h++) h], hour,
                (v) => _to = v > _from ? v : _to),
            choice('At least', _shortest, const [15, 30, 60, 90, 120],
                (v) => '$v minutes', (v) => _shortest = v),
            const SizedBox(height: 8),
            const Text('Work week'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (var i = 0; i < 7; i++)
                  if ((firstDay - 1 + i) % 7 + 1 case final day)
                    FilterChip(
                      key: ValueKey('work-day-$day'),
                      label: Text(_names[day - 1]),
                      selected: _workWeek.contains(day),
                      showCheckmark: false,
                      onSelected: (on) => setState(() =>
                          on ? _workWeek.add(day) : _workWeek.remove(day)),
                    ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('free-times-insert'),
          onPressed: _workWeek.isEmpty
              ? null
              : () => Navigator.of(context).pop((
                    first: _first,
                    days: _days,
                    from: _from,
                    to: _to,
                    shortest: Duration(minutes: _shortest),
                    workWeek: {..._workWeek},
                  )),
          child: const Text('Insert'),
        ),
      ],
    );
  }
}
