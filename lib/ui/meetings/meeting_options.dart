import 'package:flutter/material.dart';

import '../../domain/calendar_event.dart' show EventShowAs;
import '../../domain/meeting.dart' show Reminder;
import '../../domain/recurrence.dart';
import '../../domain/series_repeat.dart' show firstDayOf;
import '../../domain/time_zones.dart';
import '../calendar/time_zone_picker.dart';
import '../messages/date_format.dart' show formatDay;

/// What a meeting has beyond the when and where, on New meeting's More: how
/// it repeats, the reminder, how it shows, privacy, and the zone its times
/// are on. Each null (or false) is the calendar's own way.
@immutable
class MeetingOptions {
  const MeetingOptions({
    this.repeat,
    this.reminder,
    this.showAs,
    this.isPrivate = false,
    this.zone,
  });

  final Recurrence? repeat;
  final Reminder? reminder;
  final EventShowAs? showAs;
  final bool isPrivate;

  /// The zone the times are set in, by its IANA name: null for the phone's.
  final String? zone;

  MeetingOptions copyWith({
    Recurrence? repeat,
    bool noRepeat = false,
    Reminder? reminder,
    bool noReminderChoice = false,
    EventShowAs? showAs,
    bool noShowAsChoice = false,
    bool? isPrivate,
    String? zone,
    bool ownZone = false,
  }) =>
      MeetingOptions(
        repeat: noRepeat ? null : repeat ?? this.repeat,
        reminder: noReminderChoice ? null : reminder ?? this.reminder,
        showAs: noShowAsChoice ? null : showAs ?? this.showAs,
        isPrivate: isPrivate ?? this.isPrivate,
        zone: ownZone ? null : zone ?? this.zone,
      );

  /// What has been chosen, in a line: "Every week on Tuesday · 15 minutes
  /// before · Free · Private · New York time".
  String summary(DateTime start, {bool editing = false}) => [
        if (repeat case final r?) r.describe(start),
        if (reminder case final r?)
          r.isOn ? r.label : 'No reminder',
        if (showAs case final s? when s != EventShowAs.busy || editing)
          showAsLabel(s),
        if (isPrivate) 'Private',
        if (zone case final z?) '${placeOf(z)} time',
      ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is MeetingOptions &&
      other.repeat == repeat &&
      other.reminder == reminder &&
      other.showAs == showAs &&
      other.isPrivate == isPrivate &&
      other.zone == zone;

  @override
  int get hashCode => Object.hash(repeat, reminder, showAs, isPrivate, zone);
}

String showAsLabel(EventShowAs showAs) => switch (showAs) {
      EventShowAs.busy => 'Busy',
      EventShowAs.free => 'Free',
      EventShowAs.tentative => 'Tentative',
      EventShowAs.outOfOffice => 'Out of office',
      EventShowAs.workingElsewhere => 'Working elsewhere',
    };

/// The repeats New meeting offers, as Outlook for Android lists them.
enum _Repeat {
  never,
  daily,
  workDays,
  weekly,
  fortnightly,
  monthlyOnDate,
  monthlyOnWeekday,
  yearly,
}

const _ordinal = {1: 'first', 2: 'second', 3: 'third', 4: 'fourth', -1: 'last'};
const _weekdayNames = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];
const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];

/// New meeting's More, in a sheet from its bar: the choices, each change
/// handed to [onChanged] as it is made. [editing] leaves out what a meeting
/// already on a calendar keeps (its zone, and its repeat unless [repeats]);
/// [freeOrBusy] is a Google calendar, which keeps only whether the time is
/// taken. [repeats] and [seriesFrom]: see [MeetingOptionsPanel].
Future<void> showMeetingOptions(
  BuildContext context, {
  required MeetingOptions options,
  required DateTime start,
  required bool allDay,
  required Set<int> workWeek,
  required ValueChanged<MeetingOptions> onChanged,
  bool editing = false,
  bool freeOrBusy = false,
  bool? repeats,
  DateTime? seriesFrom,
  int seriesWeekStart = DateTime.sunday,
  int? seriesCount,
  VoidCallback? onShowAsPicked,
}) {
  var shown = options;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => StatefulBuilder(
      builder: (context, setState) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 16),
            child: MeetingOptionsPanel(
              options: shown,
              start: start,
              allDay: allDay,
              workWeek: workWeek,
              editing: editing,
              freeOrBusy: freeOrBusy,
              repeats: repeats,
              seriesFrom: seriesFrom,
              seriesWeekStart: seriesWeekStart,
              seriesCount: seriesCount,
              onShowAsPicked: onShowAsPicked,
              onChanged: (o) {
                setState(() => shown = o);
                onChanged(o);
              },
            ),
          ),
        ),
      ),
    ),
  );
}

/// The choices of [showMeetingOptions].
class MeetingOptionsPanel extends StatefulWidget {
  const MeetingOptionsPanel({
    super.key,
    required this.options,
    required this.start,
    required this.allDay,
    required this.workWeek,
    required this.onChanged,
    this.enabled = true,
    this.editing = false,
    this.freeOrBusy = false,
    this.repeats,
    this.seriesFrom,
    this.seriesWeekStart = DateTime.sunday,
    this.seriesCount,
    this.onShowAsPicked,
  });

  final MeetingOptions options;

  /// The first meeting's day, on the clock its times are set on.
  final DateTime start;
  final bool allDay;
  final Set<int> workWeek;
  final ValueChanged<MeetingOptions> onChanged;

  /// Show as picked, even as what it already was: from then on it is
  /// Ron's choice, which All day leaves alone (New meeting).
  final VoidCallback? onShowAsPicked;
  final bool enabled;
  final bool editing;
  final bool freeOrBusy;

  /// Whether Repeat is offered: on a new meeting unless said, and on a
  /// meeting being changed where it may be (calendar idea #55): a meeting
  /// on its own, to make it a series, or every meeting of a series.
  final bool? repeats;

  /// For every meeting of a series being changed: the series' first day.
  /// Repeat then has no Never (a series stays one), any day of a week may
  /// be unticked but the last, and the days and names go from where the
  /// series will start: the first day on or after its own that the repeat
  /// falls on.
  final DateTime? seriesFrom;

  /// The day a series' weeks are counted from by its calendar: Sunday for
  /// Outlook, Monday for Google. Every other week, a series' new first day
  /// is looked for inside its first week (see `firstDayOf`).
  final int seriesWeekStart;

  /// For a series that ends after a number of meetings: that number, as
  /// read. A series ends on a day or never otherwise: a number of meetings
  /// counts from its first, months ago perhaps, and would end it in the
  /// past.
  final int? seriesCount;

  @override
  State<MeetingOptionsPanel> createState() => _MeetingOptionsPanelState();
}

class _MeetingOptionsPanelState extends State<MeetingOptionsPanel> {
  MeetingOptions get o => widget.options;

  bool get _repeats => widget.repeats ?? !widget.editing;

  /// Every meeting of a series, which starts again where its repeat falls.
  bool get _series => widget.seriesFrom != null;

  /// [day] at the first meeting's time of day.
  DateTime _at(DateTime day) => DateTime(day.year, day.month, day.day,
      widget.start.hour, widget.start.minute);

  /// The first meeting as the repeat now has it: for a series, its first
  /// day on or after the series' own that the repeat falls on.
  DateTime get _start {
    final from = widget.seriesFrom;
    final repeat = o.repeat;
    if (from == null) return widget.start;
    return _at(repeat == null
        ? from
        : firstDayOf(repeat, from, weekStart: widget.seriesWeekStart));
  }

  /// The day a month's or a year's repeat is named from: a series' own
  /// first day, which those keep.
  DateTime get _namedFrom {
    final from = widget.seriesFrom;
    return from == null ? widget.start : _at(from);
  }

  _Repeat get _repeat => switch (o.repeat) {
        null => _Repeat.never,
        Recurrence(kind: RepeatKind.daily) => _Repeat.daily,
        Recurrence(kind: RepeatKind.workDays) => _Repeat.workDays,
        Recurrence(kind: RepeatKind.weekly, interval: 2) => _Repeat.fortnightly,
        Recurrence(kind: RepeatKind.weekly) => _Repeat.weekly,
        Recurrence(kind: RepeatKind.monthlyOnDate) => _Repeat.monthlyOnDate,
        Recurrence(kind: RepeatKind.monthlyOnWeekday) => _Repeat.monthlyOnWeekday,
        Recurrence(kind: RepeatKind.yearly) => _Repeat.yearly,
      };

  String _repeatLabel(_Repeat r) {
    final s = _namedFrom;
    return switch (r) {
      _Repeat.never => 'Never',
      _Repeat.daily => 'Every day',
      _Repeat.workDays => 'Every working day',
      _Repeat.weekly => 'Every week',
      _Repeat.fortnightly => 'Every 2 weeks',
      _Repeat.monthlyOnDate => 'Every month on day ${s.day}',
      _Repeat.monthlyOnWeekday =>
        'Every month on the ${_ordinal[Recurrence.weekOfMonth(s)]} '
            '${_weekdayNames[s.weekday - 1]}',
      _Repeat.yearly => 'Every year on ${s.day} ${_monthNames[s.month - 1]}',
    };
  }

  void _setRepeat(_Repeat r) {
    // A week's other days, as picked: the first meeting's own goes with
    // its date (daysFrom adds it), so a date moved after Every week does
    // not leave the old day behind. Working days are not picked days. A
    // series' days are all picked: its first meeting goes where they are.
    final days = o.repeat?.kind == RepeatKind.weekly
        ? _series
            ? o.repeat!.daysFrom(_start)
            : o.repeat!.days
        : _series
            ? {_namedFrom.weekday}
            : const <int>{};
    final until = o.repeat?.until;
    final count = o.repeat?.count;
    final next = switch (r) {
      _Repeat.never => null,
      _Repeat.daily => const Recurrence(RepeatKind.daily),
      _Repeat.workDays => Recurrence(RepeatKind.workDays, days: widget.workWeek),
      _Repeat.weekly => Recurrence(RepeatKind.weekly, days: days),
      _Repeat.fortnightly =>
        Recurrence(RepeatKind.weekly, interval: 2, days: days),
      _Repeat.monthlyOnDate => const Recurrence(RepeatKind.monthlyOnDate),
      _Repeat.monthlyOnWeekday => const Recurrence(RepeatKind.monthlyOnWeekday),
      _Repeat.yearly => const Recurrence(RepeatKind.yearly),
    };
    widget.onChanged(next == null
        ? o.copyWith(noRepeat: true)
        : o.copyWith(repeat: next.ending(day: until, times: count)));
  }

  Future<void> _pickUntil() async {
    final from = _start;
    final now = DateTime.now();
    final first = DateTime(from.year, from.month, from.day);
    // Ten years on, from the first meeting or from today, whichever is
    // later: a series begun ten years ago can still be given an end ahead.
    final last = DateTime(
        (from.year > now.year ? from.year : now.year) + 10, 12, 31);
    var initial = o.repeat?.until ??
        DateTime(from.year, from.month + 3, from.day);
    // A series begun long ago (#55) is ended from now on, not from three
    // months after it began; and an end read from a calendar, or the first
    // meeting moved past it, is never outside what the picker can show.
    if (o.repeat?.until == null && initial.isBefore(now)) {
      initial = DateTime(now.year, now.month + 3, now.day);
    }
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final day = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (day == null || !mounted) return;
    widget.onChanged(o.copyWith(repeat: o.repeat!.ending(day: day)));
  }

  Future<void> _pickZone() async {
    final chosen = await pickTimeZone(
      context,
      current: o.zone,
      none: "Your own (the phone's)",
    );
    if (chosen == null || !mounted) return;
    widget.onChanged(chosen.zone == null
        ? o.copyWith(ownZone: true)
        : o.copyWith(zone: chosen.zone));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget row(String label, Widget child) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              SizedBox(width: 88, child: Text(label, style: muted)),
              Expanded(child: child),
            ],
          ),
        );
    Widget dropdown<T>({
      required Key key,
      required T value,
      required List<(T, String)> items,
      required ValueChanged<T> onChanged,
    }) =>
        DropdownButton<T>(
          key: key,
          value: value,
          isExpanded: true,
          underline: const SizedBox.shrink(),
          style: theme.textTheme.bodyMedium,
          items: [
            for (final (v, label) in items)
              DropdownMenuItem(
                value: v,
                child: Text(label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: widget.enabled
              ? (v) {
                  if (v is T) onChanged(v);
                }
              : null,
        );
    final repeat = o.repeat;
    final weekly = repeat != null && repeat.kind == RepeatKind.weekly;
    final shownDays = repeat?.daysFrom(_start) ?? const <int>{};
    final ends = repeat == null
        ? 'never'
        : repeat.until != null
            ? 'day'
            : repeat.count != null
                ? 'count'
                : 'never';
    final showAsChoices = widget.freeOrBusy
        ? const [EventShowAs.busy, EventShowAs.free]
        : const [
            EventShowAs.busy,
            EventShowAs.free,
            EventShowAs.tentative,
            EventShowAs.outOfOffice,
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
          if (_repeats) ...[
            row(
              'Repeat',
              dropdown<_Repeat>(
                key: const ValueKey('meeting-repeat'),
                value: _repeat,
                items: [
                  for (final r in _Repeat.values)
                    if (r != _Repeat.never || !_series) (r, _repeatLabel(r)),
                ],
                onChanged: _setRepeat,
              ),
            ),
            if (weekly)
              Padding(
                padding: const EdgeInsets.fromLTRB(104, 0, 8, 4),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        key: ValueKey('meeting-repeat-day:$d'),
                        label: Text(_weekdayNames[d - 1].substring(0, 3)),
                        selected: shownDays.contains(d),
                        // The first meeting's own day is always one of
                        // them; a series' first meeting goes with its days,
                        // the last of which stays.
                        onSelected: !widget.enabled ||
                                (_series
                                    ? shownDays.length == 1 &&
                                        shownDays.contains(d)
                                    : d == _start.weekday)
                            ? null
                            : (on) {
                                final had =
                                    _series ? shownDays : repeat.days;
                                widget.onChanged(o.copyWith(
                                  repeat: repeat.onDays(on
                                      ? {...had, d}
                                      : ({...had}..remove(d))),
                                ));
                              },
                      ),
                  ],
                ),
              ),
            if (repeat != null)
              row(
                'Ends',
                Row(
                  children: [
                    Expanded(
                      child: dropdown<String>(
                        key: const ValueKey('meeting-repeat-ends'),
                        value: ends,
                        items: [
                          ('never', 'Never'),
                          ('day', 'On a day'),
                          // On a series only where it ends so already
                          // (#55): see seriesCount.
                          if (!_series ||
                              widget.seriesCount != null ||
                              ends == 'count')
                            ('count', 'After a number of times'),
                        ],
                        onChanged: (v) => switch (v) {
                          'day' => _pickUntil(),
                          'count' => widget.onChanged(o.copyWith(
                              repeat: repeat.ending(
                                  times: _series
                                      ? widget.seriesCount ?? 10
                                      : 10))),
                          _ => widget.onChanged(
                              o.copyWith(repeat: repeat.ending())),
                        },
                      ),
                    ),
                    if (repeat.until case final until?)
                      TextButton(
                        key: const ValueKey('meeting-repeat-until'),
                        onPressed: widget.enabled ? _pickUntil : null,
                        child: Text(formatDay(until)),
                      ),
                    if (repeat.count case final count?)
                      SizedBox(
                        width: 104,
                        child: dropdown<int>(
                          key: const ValueKey('meeting-repeat-count'),
                          value: count,
                          // 2 to 52, and a series' own number where it is
                          // another, 1 or 60 say: Outlook takes up to 999.
                          items: [
                            for (final n in {
                              for (var n = 2; n <= 52; n++) n,
                              count,
                            }.toList()
                              ..sort())
                              (n, n == 1 ? '1 time' : '$n times'),
                          ],
                          onChanged: (n) => widget.onChanged(
                              o.copyWith(repeat: repeat.ending(times: n))),
                        ),
                      ),
                  ],
                ),
              ),
          ],
          row(
            'Reminder',
            dropdown<Reminder?>(
              key: const ValueKey('meeting-reminder'),
              value: o.reminder,
              items: [
                (
                  null,
                  widget.editing ? 'As it is' : "The calendar's own",
                ),
                for (final r in Reminder.choices) (r, r.label),
              ],
              onChanged: (r) => widget.onChanged(r == null
                  ? o.copyWith(noReminderChoice: true)
                  : o.copyWith(reminder: r)),
            ),
          ),
          row(
            'Show as',
            dropdown<EventShowAs>(
              key: const ValueKey('meeting-show-as'),
              value: showAsChoices.contains(o.showAs ?? EventShowAs.busy)
                  ? o.showAs ?? EventShowAs.busy
                  : EventShowAs.busy,
              items: [for (final s in showAsChoices) (s, showAsLabel(s))],
              onChanged: (s) {
                widget.onShowAsPicked?.call();
                widget.onChanged(o.copyWith(showAs: s));
              },
            ),
          ),
          row(
            'Private',
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Switch(
                key: const ValueKey('meeting-private'),
                value: o.isPrivate,
                onChanged: widget.enabled
                    ? (on) => widget.onChanged(o.copyWith(isPrivate: on))
                    : null,
              ),
            ),
          ),
          if (!widget.editing && !widget.allDay)
            row(
              'Time zone',
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const ValueKey('meeting-zone'),
                  onPressed: widget.enabled ? _pickZone : null,
                  child: Text(o.zone == null
                      ? "Your own (the phone's)"
                      : '${placeOf(o.zone!)} (${offsetOf(o.zone!, widget.start)})'),
                ),
              ),
            ),
      ],
    );
  }
}
