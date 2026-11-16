import 'package:flutter/foundation.dart';

import 'calendar_event.dart';
import 'recurrence.dart';
import 'time_zones.dart';

/// How a series repeats, as its calendar has it, read for Edit (calendar
/// idea #55): the repeat in New meeting's own terms, where it can be put
/// in them, and the day the series starts on.
///
/// Read from what the calendar sends and nothing else, and never thrown
/// over: a series made elsewhere may repeat in ways New meeting has no
/// words for (the second Tuesday of every other month, a day added by
/// hand), and then [repeat] is null and Edit leaves the repeat as it is.
/// Only what Repeat's menu has an item for is read as a repeat: every day,
/// every week or every 2 weeks, every month, every year. A series every 3
/// weeks shown as Every week would be made every week by one tap.
@immutable
class SeriesRepeat {
  const SeriesRepeat({required this.repeat, required this.firstDay});

  /// How it repeats, or null where New meeting could not have made it so.
  final Recurrence? repeat;

  /// The day of the series' first meeting, a date at midnight, on the
  /// calendar's own clock for it.
  final DateTime firstDay;

  static const _graphDays = [
    'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday',
    'sunday',
  ];
  static const _ruleDays = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
  static const _graphWeeks = {
    'first': 1,
    'second': 2,
    'third': 3,
    'fourth': 4,
    'last': -1,
  };

  /// A date written "2026-09-01", or "20260901", or null.
  static DateTime? _day(Object? text) {
    if (text is! String) return null;
    final m = RegExp(r'^(\d{4})-?(\d{2})-?(\d{2})').firstMatch(text.trim());
    if (m == null) return null;
    final (y, mo, d) = (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    final day = DateTime(y, mo, d);
    // Not a day there is: 31 September comes back as 1 October.
    return day.month == mo ? day : null;
  }

  /// Graph's patternedRecurrence, from a series' master; null for a
  /// meeting on its own, or anything not one.
  static SeriesRepeat? fromGraph(Object? recurrence) {
    if (recurrence is! Map) return null;
    final pattern = recurrence['pattern'];
    final range = recurrence['range'];
    if (pattern is! Map || range is! Map) return null;
    final first = _day(range['startDate']);
    if (first == null) return null;
    final repeat = _graphRepeat(pattern, range, first);
    if (repeat == null) {
      // Said, so that a series offered no Repeat on a device can be told
      // apart from one not read: the pattern's kind, nothing of the meeting.
      debugPrint('[myemail] a series repeats in a way Edit cannot show: '
          '${pattern['type']}, ${range['type']}');
    }
    return SeriesRepeat(repeat: repeat, firstDay: first);
  }

  static Recurrence? _graphRepeat(Map pattern, Map range, DateTime first) {
    // A whole number, as Graph writes it: anything else is not known.
    final given = pattern['interval'];
    if (given is! int || given < 1) return null;
    final interval = given;
    final names = pattern['daysOfWeek'];
    final days = <int>{};
    if (names is List) {
      for (final n in names) {
        final i = _graphDays.indexOf('$n'.toLowerCase());
        if (i < 0) return null;
        days.add(i + 1);
      }
    }
    final Recurrence? how = switch (pattern['type']) {
      'daily' when interval == 1 => const Recurrence(RepeatKind.daily),
      // The week New meeting counts from is Sunday's; every other week
      // counted from another day is not the same meetings.
      'weekly' when days.isNotEmpty &&
              (interval == 1 ||
                  (interval == 2 &&
                      '${pattern['firstDayOfWeek'] ?? 'sunday'}'
                              .toLowerCase() ==
                          'sunday')) =>
        Recurrence(RepeatKind.weekly, interval: interval, days: days),
      'absoluteMonthly' when interval == 1 &&
              pattern['dayOfMonth'] == first.day =>
        const Recurrence(RepeatKind.monthlyOnDate),
      'relativeMonthly' when interval == 1 &&
              days.length == 1 &&
              days.single == first.weekday &&
              _graphWeeks['${pattern['index'] ?? 'first'}'.toLowerCase()] ==
                  Recurrence.weekOfMonth(first) =>
        const Recurrence(RepeatKind.monthlyOnWeekday),
      'absoluteYearly' when interval == 1 &&
              pattern['dayOfMonth'] == first.day &&
              pattern['month'] == first.month =>
        const Recurrence(RepeatKind.yearly),
      _ => null,
    };
    if (how == null) return null;
    switch (range['type']) {
      case 'endDate':
        final last = _day(range['endDate']);
        return last == null ? null : how.ending(day: last);
      case 'numbered':
        final n = range['numberOfOccurrences'];
        return n is int && n > 0 ? how.ending(times: n) : null;
      case 'noEnd':
        return how;
      default:
        return null;
    }
  }

  /// A Google event that is a series: its `recurrence` lines and its
  /// start. Null for one that is not.
  static SeriesRepeat? fromGoogle(Map<Object?, Object?> event) {
    final lines = event['recurrence'];
    if (lines is! List || lines.isEmpty) return null;
    final start = event['start'];
    if (start is! Map) return null;
    // The date as the event writes it, on its own clock: "2026-09-01" or
    // "2026-09-01T09:00:00+03:00".
    final first = _day(start['date'] ?? start['dateTime']);
    if (first == null) return null;
    final rules = [
      for (final l in lines)
        if ('$l'.toUpperCase().startsWith('RRULE:')) '$l'.substring(6),
    ];
    // A day added by hand (RDATE), or a rule taking days out (EXRULE), is
    // more than New meeting shows; a day taken out (EXDATE) is not the
    // repeat's to say.
    final added = lines.any((l) {
      final line = '$l'.toUpperCase();
      return line.startsWith('RDATE') || line.startsWith('EXRULE');
    });
    // Its own zone, to read a timed end on its own clock.
    final named = start['timeZone'];
    final zone = named is String ? ianaZoneOf(named) : null;
    final repeat = rules.length == 1 && !added
        ? _rule(rules.single, first, zone: zone)
        : null;
    if (repeat == null) {
      // As for Graph's: the rules' kinds alone.
      debugPrint('[myemail] a series repeats in a way Edit cannot show: '
          '${[for (final r in rules) r.split(';').first]}'
          '${added ? ', with days added' : ''}');
    }
    return SeriesRepeat(repeat: repeat, firstDay: first);
  }

  static Recurrence? _rule(String rule, DateTime first, {String? zone}) {
    final parts = <String, String>{};
    for (final p in rule.split(';')) {
      final eq = p.indexOf('=');
      if (eq <= 0) return null;
      parts[p.substring(0, eq).toUpperCase()] =
          p.substring(eq + 1).toUpperCase();
    }
    const known = {
      'FREQ', 'INTERVAL', 'BYDAY', 'BYMONTHDAY', 'BYMONTH', 'COUNT', 'UNTIL',
      'WKST',
    };
    if (parts.keys.any((k) => !known.contains(k))) return null;
    // A whole number, one where the rule says none, as the rule has it.
    final interval = int.tryParse(parts['INTERVAL'] ?? '1');
    if (interval == null || interval < 1) return null;
    // Each day, and the week of the month before it where there is one:
    // "TU", "4TU", "-1TU".
    final byDay = <({int? week, int day})>[];
    for (final d in (parts['BYDAY'] ?? '').split(',')) {
      if (d.isEmpty) continue;
      final m = RegExp(r'^([+-]?\d)?([A-Z]{2})$').firstMatch(d);
      final i = m == null ? -1 : _ruleDays.indexOf(m[2]!);
      if (i < 0) return null;
      byDay.add((week: m![1] == null ? null : int.parse(m[1]!), day: i + 1));
    }
    final monthDay = parts['BYMONTHDAY'];
    final month = parts['BYMONTH'];
    final Recurrence? how = switch (parts['FREQ']) {
      'DAILY' when interval == 1 &&
              byDay.isEmpty &&
              monthDay == null &&
              month == null =>
        const Recurrence(RepeatKind.daily),
      // Every other week counted from Monday, as the rule's own default,
      // is what New meeting writes.
      'WEEKLY' when monthDay == null &&
              month == null &&
              byDay.every((d) => d.week == null) &&
              (interval == 1 ||
                  (interval == 2 && (parts['WKST'] ?? 'MO') == 'MO')) =>
        Recurrence(RepeatKind.weekly,
            interval: interval,
            days: byDay.isEmpty
                ? {first.weekday}
                : {for (final d in byDay) d.day}),
      'MONTHLY' when interval == 1 &&
              month == null &&
              byDay.isEmpty &&
              (monthDay == null || monthDay == '${first.day}') =>
        const Recurrence(RepeatKind.monthlyOnDate),
      'MONTHLY' when interval == 1 &&
              month == null &&
              monthDay == null &&
              byDay.length == 1 &&
              byDay.single.day == first.weekday &&
              byDay.single.week == Recurrence.weekOfMonth(first) =>
        const Recurrence(RepeatKind.monthlyOnWeekday),
      'YEARLY' when interval == 1 &&
              byDay.isEmpty &&
              (month == null || month == '${first.month}') &&
              (monthDay == null || monthDay == '${first.day}') =>
        const Recurrence(RepeatKind.yearly),
      _ => null,
    };
    if (how == null) return null;
    final count = parts['COUNT'];
    final until = parts['UNTIL'];
    if (count != null) {
      final n = int.tryParse(count);
      return n == null || n < 1 ? null : how.ending(times: n);
    }
    if (until != null) {
      final day = _untilDay(until, zone);
      return day == null ? null : how.ending(day: day);
    }
    return how;
  }

  /// UNTIL's day: a date as it is, and a time in UTC on the series' own
  /// clock ([zone]), which is how a rule ending at the end of its last day
  /// writes it: a series set in Los Angeles ends at 07:59:59 UTC the next
  /// day. On the phone's clock where the series names no zone.
  static DateTime? _untilDay(String until, String? zone) {
    final m = RegExp(r'^(\d{8})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$')
        .firstMatch(until);
    if (m == null) return null;
    final day = _day(m[1]);
    if (day == null || m[2] == null) return day;
    final at = DateTime.utc(day.year, day.month, day.day, int.parse(m[2]!),
        int.parse(m[3]!), int.parse(m[4]!));
    final here = m[5] == null
        ? DateTime(day.year, day.month, day.day)
        : zone == null
            ? at.toLocal()
            : wallClockIn(at, zone);
    return DateTime(here.year, here.month, here.day);
  }

  @override
  bool operator ==(Object other) =>
      other is SeriesRepeat &&
      other.repeat == repeat &&
      other.firstDay == firstDay;

  @override
  int get hashCode => Object.hash(repeat, firstDay);
}

/// The first day on or after [from] that [repeat] falls on: where a series
/// given [repeat] starts, its first meeting moved there from its own day.
/// The weekly repeats by their days picked, the others from [from] itself.
///
/// Every other week, the first day is looked for inside the week [from]
/// is in, counted from [weekStart] (Sunday for Outlook, Monday for Google,
/// as each counts a series' weeks), so the meetings stay in the weeks they
/// were in: every 2 weeks on Tuesday moved to Monday starts the day before
/// the first Tuesday, not six days after it, in a week that had none.
DateTime firstDayOf(Recurrence repeat, DateTime from,
    {int weekStart = DateTime.sunday}) {
  final day = DateTime(from.year, from.month, from.day);
  final days = switch (repeat.kind) {
    RepeatKind.weekly => repeat.days,
    RepeatKind.workDays => repeat.daysFrom(day),
    _ => const <int>{},
  };
  if (days.isEmpty) return day;
  final week = repeat.kind == RepeatKind.weekly && repeat.interval > 1
      ? _weekOf(day, weekStart)
      : day;
  for (var i = 0; i < 7; i++) {
    final next = DateTime(week.year, week.month, week.day + i);
    if (days.contains(next.weekday)) return next;
  }
  return day;
}

/// The first day of the week [day] is in, the week starting on [weekStart].
DateTime _weekOf(DateTime day, int weekStart) =>
    DateTime(day.year, day.month, day.day - (day.weekday - weekStart) % 7);

/// The days of the meetings [repeat] makes from [first], the first
/// meeting's day, in order, without end: for [lastMeetingOf].
Iterable<DateTime> _meetingDays(
  Recurrence repeat,
  DateTime first,
  int weekStart,
) sync* {
  final from = DateTime(first.year, first.month, first.day);
  final every = repeat.interval < 1 ? 1 : repeat.interval;
  switch (repeat.kind) {
    case RepeatKind.daily:
      for (var i = 0;; i += every) {
        yield DateTime(from.year, from.month, from.day + i);
      }
    case RepeatKind.weekly || RepeatKind.workDays:
      final days = repeat.daysFrom(from);
      final weeks = repeat.kind == RepeatKind.weekly ? every : 1;
      final week = _weekOf(from, weekStart);
      for (var w = 0;; w += weeks) {
        for (var i = 0; i < 7; i++) {
          final d = DateTime(week.year, week.month, week.day + 7 * w + i);
          if (days.contains(d.weekday) && !d.isBefore(from)) yield d;
        }
      }
    case RepeatKind.monthlyOnDate:
      for (var m = 0;; m += every) {
        final d = DateTime(from.year, from.month + m, from.day);
        // A month without the day (the 31st) has no meeting.
        if (d.day == from.day) yield d;
      }
    case RepeatKind.monthlyOnWeekday:
      final n = Recurrence.weekOfMonth(from);
      for (var m = 0;; m += every) {
        final d = _weekdayOfMonth(
            DateTime(from.year, from.month + m), from.weekday, n);
        if (!d.isBefore(from)) yield d;
      }
    case RepeatKind.yearly:
      for (var y = 0;; y++) {
        final d = DateTime(from.year + y, from.month, from.day);
        if (d.day == from.day) yield d;
      }
  }
}

/// The [n]th [weekday] of [month]'s month, or its last for -1.
DateTime _weekdayOfMonth(DateTime month, int weekday, int n) {
  if (n == -1) {
    final last = DateTime(month.year, month.month + 1, 0);
    return DateTime(
        last.year, last.month, last.day - (last.weekday - weekday) % 7);
  }
  final first = DateTime(month.year, month.month);
  return DateTime(first.year, first.month,
      1 + (weekday - first.weekday) % 7 + 7 * (n - 1));
}

/// The day of the last meeting [repeat] makes from [first], the first
/// meeting's day: by its end day or its number of meetings. Null for one
/// that goes on without end.
DateTime? lastMeetingOf(
  Recurrence repeat,
  DateTime first, {
  int weekStart = DateTime.sunday,
}) {
  final until = repeat.until;
  final count = repeat.count;
  if (until == null && count == null) return null;
  DateTime? last;
  var n = 0;
  for (final day in _meetingDays(repeat, first, weekStart)) {
    if (until != null && day.isAfter(until)) break;
    last = day;
    n++;
    // Outlook takes up to 999 meetings; the search is never longer than
    // a long series, and never without end.
    if ((count != null && n >= count) || n >= 100000) break;
  }
  return last;
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];

/// [day] as the screen says a date in a sentence: "3 November 2026".
String dayInWords(DateTime day) =>
    '${day.day} ${_monthNames[day.month - 1]} ${day.year}';

/// The IANA zone [event] was set in, from what its calendar names it (a
/// Windows name from Exchange, Google's own): what a change to it is
/// written in, so a meeting set in Jerusalem stays Jerusalem's whatever
/// the phone's zone. Null where it names none, or one not known.
String? ownZoneOf(CalendarEvent event) {
  final name = event.timeZone?.trim();
  return name == null || name.isEmpty ? null : ianaZoneOf(name);
}
