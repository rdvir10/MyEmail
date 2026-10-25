import 'package:flutter/foundation.dart';

/// How a meeting repeats: New meeting's Repeat, as Outlook and Google
/// Calendar offer it.
enum RepeatKind {
  /// Every [Recurrence.interval] days.
  daily,

  /// Every working day, as the work week has them (Monday to Friday until
  /// changed): Outlook's "every weekday".
  workDays,

  /// Every [Recurrence.interval] weeks, on [Recurrence.days].
  weekly,

  /// Every [Recurrence.interval] months, on the first meeting's day of the
  /// month.
  monthlyOnDate,

  /// Every [Recurrence.interval] months, on the first meeting's weekday in
  /// the same week of the month: "the fourth Tuesday", or "the last".
  monthlyOnWeekday,

  /// Every year, on the first meeting's date.
  yearly,
}

/// A meeting's repeat: how, how often, and until when. The first meeting is
/// the one being made; the rest follow from its day.
@immutable
class Recurrence {
  const Recurrence(
    this.kind, {
    this.interval = 1,
    this.days = const {},
    this.until,
    this.count,
  });

  final RepeatKind kind;

  /// Every this many days, weeks or months. 1 for a year.
  final int interval;

  /// The days of the week, as `DateTime.weekday` numbers: [RepeatKind.weekly]'s
  /// days, and [RepeatKind.workDays]' working days.
  final Set<int> days;

  /// The last day a meeting may fall on, a date at midnight; or [count]
  /// meetings in all; or neither, for good.
  final DateTime? until;
  final int? count;

  /// The same on [days].
  Recurrence onDays(Set<int> days) =>
      Recurrence(kind, interval: interval, days: days, until: until, count: count);

  /// The same, ending on [day]; after [times] meetings; or never, with
  /// neither.
  Recurrence ending({DateTime? day, int? times}) => Recurrence(
        kind,
        interval: interval,
        days: days,
        until: day == null ? null : DateTime(day.year, day.month, day.day),
        count: day == null ? times : null,
      );

  /// Which of its month's weeks [day] falls in, as Outlook names them: 1 to
  /// 4, or -1 for a fifth, which is the month's last.
  static int weekOfMonth(DateTime day) {
    final n = (day.day - 1) ~/ 7 + 1;
    return n > 4 ? -1 : n;
  }

  /// The days of the week a meeting from [start] falls on: its own always
  /// among them.
  Set<int> daysFrom(DateTime start) => switch (kind) {
        RepeatKind.weekly => {...days, start.weekday},
        RepeatKind.workDays => days.isEmpty ? {1, 2, 3, 4, 5} : days,
        _ => {start.weekday},
      };

  static const _graphDays = [
    'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday',
    'sunday',
  ];
  static const _ruleDays = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
  static const _graphWeeks = {
    1: 'first',
    2: 'second',
    3: 'third',
    4: 'fourth',
    -1: 'last',
  };

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// As Graph's patternedRecurrence for a meeting whose first day is
  /// [start], its times in [timeZone].
  Map<String, Object?> toGraph(DateTime start, {required String timeZone}) {
    List<String> names(Iterable<int> weekdays) => [
          for (final d in (weekdays.toList()..sort())) _graphDays[d - 1],
        ];
    final pattern = switch (kind) {
      RepeatKind.daily => {'type': 'daily', 'interval': interval},
      RepeatKind.workDays => {
          'type': 'weekly',
          'interval': 1,
          'daysOfWeek': names(daysFrom(start)),
          'firstDayOfWeek': 'sunday',
        },
      RepeatKind.weekly => {
          'type': 'weekly',
          'interval': interval,
          'daysOfWeek': names(daysFrom(start)),
          'firstDayOfWeek': 'sunday',
        },
      RepeatKind.monthlyOnDate => {
          'type': 'absoluteMonthly',
          'interval': interval,
          'dayOfMonth': start.day,
        },
      RepeatKind.monthlyOnWeekday => {
          'type': 'relativeMonthly',
          'interval': interval,
          'daysOfWeek': [_graphDays[start.weekday - 1]],
          'index': _graphWeeks[weekOfMonth(start)],
        },
      RepeatKind.yearly => {
          'type': 'absoluteYearly',
          'interval': 1,
          'dayOfMonth': start.day,
          'month': start.month,
        },
    };
    final range = until != null
        ? {'type': 'endDate', 'endDate': _date(until!)}
        : count != null
            ? {'type': 'numbered', 'numberOfOccurrences': count}
            : {'type': 'noEnd'};
    return {
      'pattern': pattern,
      'range': {
        ...range,
        'startDate': _date(start),
        'recurrenceTimeZone': timeZone,
      },
    };
  }

  /// As the RRULE line Google Calendar and the phone's calendar take, for a
  /// meeting whose first day is [start]. A timed meeting's UNTIL is the end
  /// of its last day, in UTC, as the rule requires; a whole day's is the
  /// date.
  String toRule(DateTime start, {required bool allDay}) {
    String days(Iterable<int> weekdays) =>
        [for (final d in (weekdays.toList()..sort())) _ruleDays[d - 1]].join(',');
    final parts = switch (kind) {
      RepeatKind.daily => ['FREQ=DAILY', if (interval > 1) 'INTERVAL=$interval'],
      RepeatKind.workDays => ['FREQ=WEEKLY', 'BYDAY=${days(daysFrom(start))}'],
      RepeatKind.weekly => [
          'FREQ=WEEKLY',
          if (interval > 1) 'INTERVAL=$interval',
          'BYDAY=${days(daysFrom(start))}',
        ],
      RepeatKind.monthlyOnDate => [
          'FREQ=MONTHLY',
          if (interval > 1) 'INTERVAL=$interval',
          'BYMONTHDAY=${start.day}',
        ],
      RepeatKind.monthlyOnWeekday => [
          'FREQ=MONTHLY',
          if (interval > 1) 'INTERVAL=$interval',
          'BYDAY=${weekOfMonth(start)}${_ruleDays[start.weekday - 1]}',
        ],
      RepeatKind.yearly => [
          'FREQ=YEARLY',
          'BYMONTH=${start.month}',
          'BYMONTHDAY=${start.day}',
        ],
    };
    final last = until;
    final end = last == null
        ? (count == null ? null : 'COUNT=$count')
        : allDay
            ? 'UNTIL=${_date(last).replaceAll('-', '')}'
            : 'UNTIL=${_utcStamp(DateTime(last.year, last.month, last.day, 23, 59, 59))}';
    return 'RRULE:${[...parts, ?end].join(';')}';
  }

  static String _utcStamp(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}'
        'T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }

  static const _weekdayNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday',
  ];
  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December',
  ];
  static const _ordinals = {
    1: 'first',
    2: 'second',
    3: 'third',
    4: 'fourth',
    -1: 'last',
  };

  static String _list(List<String> words) => words.length <= 1
      ? words.join()
      : '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';

  /// What it does, in a sentence for the screen: "Every week on Tuesday and
  /// Thursday, until 30 November 2026".
  String describe(DateTime start) {
    String every(String unit) =>
        interval == 1 ? 'Every $unit' : 'Every $interval ${unit}s';
    final weekdays = [
      for (final d in (daysFrom(start).toList()..sort())) _weekdayNames[d - 1],
    ];
    final how = switch (kind) {
      RepeatKind.daily => every('day'),
      RepeatKind.workDays => 'Every working day',
      RepeatKind.weekly => '${every('week')} on ${_list(weekdays)}',
      RepeatKind.monthlyOnDate => '${every('month')} on day ${start.day}',
      RepeatKind.monthlyOnWeekday =>
        '${every('month')} on the ${_ordinals[weekOfMonth(start)]} '
            '${_weekdayNames[start.weekday - 1]}',
      RepeatKind.yearly =>
        'Every year on ${start.day} ${_monthNames[start.month - 1]}',
    };
    final last = until;
    final end = last != null
        ? ', until ${last.day} ${_monthNames[last.month - 1]} ${last.year}'
        : count != null
            ? ', $count times'
            : '';
    return '$how$end';
  }

  @override
  bool operator ==(Object other) =>
      other is Recurrence &&
      other.kind == kind &&
      other.interval == interval &&
      setEquals(other.days, days) &&
      other.until == until &&
      other.count == count;

  @override
  int get hashCode =>
      Object.hash(kind, interval, Object.hashAllUnordered(days), until, count);
}
