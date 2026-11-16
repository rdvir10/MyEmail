import 'package:flutter/foundation.dart';

import 'recurrence.dart';

/// How a series repeats, as its calendar has it, read for Edit (calendar
/// idea #55): the repeat in New meeting's own terms, where it can be put
/// in them, and the day the series starts on.
///
/// Read from what the calendar sends and nothing else, and never thrown
/// over: a series made elsewhere may repeat in ways New meeting has no
/// words for (the second Tuesday of every other month, a day added by
/// hand), and then [repeat] is null and Edit leaves the repeat as it is.
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
    final given = pattern['interval'];
    final interval = given is int ? given : 1;
    if (interval < 1) return null;
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
      'daily' => Recurrence(RepeatKind.daily, interval: interval),
      // The week New meeting counts from is Sunday's; every other week
      // counted from another day is not the same meetings.
      'weekly' when days.isNotEmpty &&
              (interval == 1 ||
                  '${pattern['firstDayOfWeek'] ?? 'sunday'}'.toLowerCase() ==
                      'sunday') =>
        Recurrence(RepeatKind.weekly, interval: interval, days: days),
      'absoluteMonthly' when pattern['dayOfMonth'] == first.day =>
        Recurrence(RepeatKind.monthlyOnDate, interval: interval),
      'relativeMonthly' when days.length == 1 &&
              days.single == first.weekday &&
              _graphWeeks['${pattern['index'] ?? 'first'}'.toLowerCase()] ==
                  Recurrence.weekOfMonth(first) =>
        Recurrence(RepeatKind.monthlyOnWeekday, interval: interval),
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
    // A day added by hand (RDATE) is more than New meeting shows; a day
    // taken out (EXDATE) is not the repeat's to say.
    final added = lines.any((l) => '$l'.toUpperCase().startsWith('RDATE'));
    final repeat =
        rules.length == 1 && !added ? _rule(rules.single, first) : null;
    if (repeat == null) {
      // As for Graph's: the rules' kinds alone.
      debugPrint('[myemail] a series repeats in a way Edit cannot show: '
          '${[for (final r in rules) r.split(';').first]}'
          '${added ? ', with days added' : ''}');
    }
    return SeriesRepeat(repeat: repeat, firstDay: first);
  }

  static Recurrence? _rule(String rule, DateTime first) {
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
      'DAILY' when byDay.isEmpty && monthDay == null && month == null =>
        Recurrence(RepeatKind.daily, interval: interval),
      // Every other week counted from Monday, as the rule's own default,
      // is what New meeting writes.
      'WEEKLY' when monthDay == null &&
              month == null &&
              byDay.every((d) => d.week == null) &&
              (interval == 1 || (parts['WKST'] ?? 'MO') == 'MO') =>
        Recurrence(RepeatKind.weekly,
            interval: interval,
            days: byDay.isEmpty
                ? {first.weekday}
                : {for (final d in byDay) d.day}),
      'MONTHLY' when month == null &&
              byDay.isEmpty &&
              (monthDay == null || monthDay == '${first.day}') =>
        Recurrence(RepeatKind.monthlyOnDate, interval: interval),
      'MONTHLY' when month == null &&
              monthDay == null &&
              byDay.length == 1 &&
              byDay.single.day == first.weekday &&
              byDay.single.week == Recurrence.weekOfMonth(first) =>
        Recurrence(RepeatKind.monthlyOnWeekday, interval: interval),
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
      final day = _untilDay(until);
      return day == null ? null : how.ending(day: day);
    }
    return how;
  }

  /// UNTIL's day: a date as it is, and a time in UTC on the phone's clock,
  /// which is how a rule ending at the end of a day here writes it.
  static DateTime? _untilDay(String until) {
    final m = RegExp(r'^(\d{8})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$')
        .firstMatch(until);
    if (m == null) return null;
    final day = _day(m[1]);
    if (day == null || m[2] == null) return day;
    final at = DateTime.utc(day.year, day.month, day.day, int.parse(m[2]!),
        int.parse(m[3]!), int.parse(m[4]!));
    final here = m[5] == null
        ? DateTime(day.year, day.month, day.day)
        : at.toLocal();
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
DateTime firstDayOf(Recurrence repeat, DateTime from) {
  final day = DateTime(from.year, from.month, from.day);
  final days = switch (repeat.kind) {
    RepeatKind.weekly => repeat.days,
    RepeatKind.workDays => repeat.daysFrom(day),
    _ => const <int>{},
  };
  if (days.isEmpty) return day;
  for (var i = 0; i < 7; i++) {
    final next = DateTime(day.year, day.month, day.day + i);
    if (days.contains(next.weekday)) return next;
  }
  return day;
}
