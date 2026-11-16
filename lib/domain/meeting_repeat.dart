import 'package:flutter/foundation.dart';

/// What a series of meetings repeats by: days, weeks, months or years.
enum RepeatUnit { day, week, month, year }

/// How a series of meetings repeats, as its calendar keeps it, for the
/// meeting's sheet to say (calendar idea #44): read from Graph's
/// patternedRecurrence on a Microsoft series, and from the RRULE on a
/// Google one.
///
/// Only what can be said exactly is read. A series that repeats in a way
/// this does not name (by its place in a set, every hour, on any of
/// several days of a month's week, with days added) is not read at all,
/// and the sheet says only that it repeats: nothing rather than something
/// wrong. What the series is read from is written by whoever made it, so
/// nothing here throws.
@immutable
class MeetingRepeat {
  const MeetingRepeat(
    this.every, {
    this.interval = 1,
    this.weekdays = const {},
    this.dayOfMonth,
    this.week,
    this.month,
    this.until,
    this.count,
  });

  final RepeatUnit every;

  /// Every this many days, weeks, months or years.
  final int interval;

  /// The days, as `DateTime.weekday` numbers: a week's, or the one day of
  /// the month's [week] a month's or a year's meeting falls on.
  final Set<int> weekdays;

  /// The day of the month a month's or a year's meeting falls on, 1 to 31;
  /// null for one that falls on a day of the week instead.
  final int? dayOfMonth;

  /// Which of the month's weeks, 1 to 4, or -1 for the last: with one of
  /// [weekdays].
  final int? week;

  /// A year's month, 1 to 12.
  final int? month;

  /// The last day a meeting may fall on, a date at midnight; or [count]
  /// meetings in all; or neither, for good.
  final DateTime? until;
  final int? count;

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

  /// What it does, in a sentence for the sheet: "Every week on Tuesday,
  /// until 30 June 2027", "Every month on the last Friday", "Every week,
  /// Monday to Friday". In the words New meeting's Repeat uses.
  String describe() {
    String every(String unit) =>
        interval == 1 ? 'Every $unit' : 'Every $interval ${unit}s';
    String day(int weekday) => _weekdayNames[weekday - 1];
    final how = switch (this.every) {
      RepeatUnit.day => every('day'),
      RepeatUnit.week when interval == 1 && weekdays.length == 7 =>
        'Every day',
      RepeatUnit.week => '${every('week')}${_days()}',
      RepeatUnit.month when dayOfMonth != null =>
        '${every('month')} on day $dayOfMonth',
      RepeatUnit.month =>
        '${every('month')} on the ${_ordinals[week]} ${day(weekdays.first)}',
      RepeatUnit.year when dayOfMonth != null =>
        '${every('year')} on $dayOfMonth ${_monthNames[month! - 1]}',
      RepeatUnit.year => '${every('year')} on the ${_ordinals[week]} '
          '${day(weekdays.first)} of ${_monthNames[month! - 1]}',
    };
    final last = until;
    final end = last != null
        ? ', until ${last.day} ${_monthNames[last.month - 1]} ${last.year}'
        : count != null
            ? ', $count times'
            : '';
    return '$how$end';
  }

  /// A week's days, in the order of Ron's week, which starts on Sunday as
  /// his Outlook does: " on Tuesday and Thursday", or a run of three or
  /// more as ", Monday to Friday".
  String _days() {
    int place(int weekday) => weekday % 7; // Sunday first.
    final days = weekdays.toList()
      ..sort((a, b) => place(a).compareTo(place(b)));
    final names = [for (final d in days) _weekdayNames[d - 1]];
    if (days.length >= 3 &&
        place(days.last) - place(days.first) == days.length - 1) {
      return ', ${names.first} to ${names.last}';
    }
    final list = names.length == 1
        ? names.single
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    return ' on $list';
  }

  /// Graph's names for the days of the week, in `DateTime.weekday` order.
  static const _graphDays = [
    'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday',
    'sunday',
  ];
  static const _graphWeeks = {
    'first': 1,
    'second': 2,
    'third': 3,
    'fourth': 4,
    'last': -1,
  };

  /// A Microsoft series' `recurrence`, as Graph gives it: a pattern and a
  /// range. Null for none, and for one this cannot say exactly.
  static MeetingRepeat? fromGraph(Object? recurrence) {
    try {
      return _fromGraph(recurrence);
    } catch (_) {
      return null;
    }
  }

  static MeetingRepeat? _fromGraph(Object? recurrence) {
    if (recurrence is! Map) return null;
    final pattern = recurrence['pattern'];
    if (pattern is! Map) return null;
    final interval = switch (pattern['interval']) {
      final int n when n >= 1 => n,
      null => 1,
      _ => null,
    };
    if (interval == null) return null;
    final days = <int>{};
    final names = pattern['daysOfWeek'];
    for (final name in names is List ? names : const []) {
      final at = _graphDays.indexOf('$name'.toLowerCase());
      if (at < 0) return null;
      days.add(at + 1);
    }
    final dayOfMonth = switch (pattern['dayOfMonth']) {
      final int d when d >= 1 && d <= 31 => d,
      _ => null,
    };
    final month = switch (pattern['month']) {
      final int m when m >= 1 && m <= 12 => m,
      _ => null,
    };
    final week = _graphWeeks['${pattern['index']}'.toLowerCase()];
    final end = _graphRange(recurrence['range']);
    if (end == null) return null;
    MeetingRepeat make(
      RepeatUnit every, {
      Set<int> weekdays = const {},
      int? dayOfMonth,
      int? week,
      int? month,
    }) =>
        MeetingRepeat(
          every,
          interval: interval,
          weekdays: weekdays,
          dayOfMonth: dayOfMonth,
          week: week,
          month: month,
          until: end.until,
          count: end.count,
        );
    return switch ('${pattern['type']}') {
      'daily' => make(RepeatUnit.day),
      'weekly' when days.isNotEmpty => make(RepeatUnit.week, weekdays: days),
      'absoluteMonthly' when dayOfMonth != null =>
        make(RepeatUnit.month, dayOfMonth: dayOfMonth),
      'relativeMonthly' when days.length == 1 && week != null =>
        make(RepeatUnit.month, weekdays: days, week: week),
      'absoluteYearly' when dayOfMonth != null && month != null =>
        make(RepeatUnit.year, dayOfMonth: dayOfMonth, month: month),
      'relativeYearly' when days.length == 1 && week != null && month != null =>
        make(RepeatUnit.year, weekdays: days, week: week, month: month),
      _ => null,
    };
  }

  /// A Graph range's end: its last day, its number of meetings, or none.
  /// Null for one that says it ends and cannot be read: left out, the
  /// sheet would say the series goes on for good.
  static ({DateTime? until, int? count})? _graphRange(Object? range) {
    if (range is! Map) return (until: null, count: null);
    switch ('${range['type']}') {
      case 'endDate':
        final day = _date('${range['endDate']}');
        return day == null ? null : (until: day, count: null);
      case 'numbered':
        final n = range['numberOfOccurrences'];
        return n is int && n >= 1 ? (until: null, count: n) : null;
      default:
        return (until: null, count: null);
    }
  }

  /// "2027-06-30" as that day at midnight; null for anything else.
  static DateTime? _date(String text) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(text);
    if (m == null) return null;
    final day = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    return day.month == int.parse(m[2]!) ? day : null;
  }

  /// The RRULE's names for the days of the week, in `DateTime.weekday`
  /// order.
  static const _ruleDays = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

  /// The parts of a rule read here. One with any other (BYSETPOS, BYHOUR,
  /// BYWEEKNO and the rest) repeats in a way this does not say.
  static const _ruleParts = {
    'FREQ', 'INTERVAL', 'COUNT', 'UNTIL', 'BYDAY', 'BYMONTHDAY', 'BYMONTH',
    'WKST',
  };

  /// A Google series' `recurrence` lines: its RRULE, read, beside any days
  /// left out of it (EXDATE), which do not change how it repeats. [start]
  /// is the series' first day, on its own clock, for what the rule leaves
  /// to it: a week's day, a month's date. Null for a rule this cannot say
  /// exactly, two rules, or days added (RDATE).
  static MeetingRepeat? fromRule(Iterable<Object?> lines, {DateTime? start}) {
    try {
      return _fromRule(lines, start);
    } catch (_) {
      return null;
    }
  }

  static MeetingRepeat? _fromRule(Iterable<Object?> lines, DateTime? start) {
    String? rule;
    for (final line in lines) {
      final text = '$line'.trim();
      final name = text.split(RegExp('[:;]')).first.toUpperCase();
      if (name == 'RRULE') {
        final at = text.indexOf(':');
        if (rule != null || at < 0) return null;
        rule = text.substring(at + 1);
      } else if (name != 'EXDATE') {
        return null;
      }
    }
    if (rule == null) return null;
    final parts = <String, String>{};
    for (final part in rule.split(';')) {
      if (part.trim().isEmpty) continue;
      final at = part.indexOf('=');
      if (at <= 0) return null;
      final key = part.substring(0, at).trim().toUpperCase();
      if (!_ruleParts.contains(key) || parts.containsKey(key)) return null;
      parts[key] = part.substring(at + 1).trim().toUpperCase();
    }
    int? number(String? text, int min, int max) {
      if (text == null) return null;
      final n = int.tryParse(text);
      return n != null && n >= min && n <= max ? n : null;
    }

    final interval = parts['INTERVAL'] == null
        ? 1
        : number(parts['INTERVAL'], 1, 1000);
    if (interval == null) return null;
    final count =
        parts['COUNT'] == null ? null : number(parts['COUNT'], 1, 100000);
    if (parts['COUNT'] != null && count == null) return null;
    final until = parts['UNTIL'] == null ? null : _ruleDate(parts['UNTIL']!);
    if (parts['UNTIL'] != null && until == null) return null;
    if (count != null && until != null) return null;
    final dayOfMonth = parts['BYMONTHDAY'] == null
        ? null
        : number(parts['BYMONTHDAY'], 1, 31);
    if (parts['BYMONTHDAY'] != null && dayOfMonth == null) return null;
    final month =
        parts['BYMONTH'] == null ? null : number(parts['BYMONTH'], 1, 12);
    if (parts['BYMONTH'] != null && month == null) return null;
    // Each of BYDAY's days, with the week of the month it may name:
    // "TU", "-1FR", "+2TU".
    final byDay = <({int weekday, int? week})>[];
    for (final item in (parts['BYDAY'] ?? '').split(',')) {
      if (item.isEmpty) continue;
      final m = RegExp(r'^([+-]?\d{1,2})?([A-Z]{2})$').firstMatch(item);
      if (m == null) return null;
      final weekday = _ruleDays.indexOf(m[2]!) + 1;
      if (weekday == 0) return null;
      final week = m[1] == null ? null : int.parse(m[1]!.replaceAll('+', ''));
      if (week != null && !_ordinals.containsKey(week)) return null;
      byDay.add((weekday: weekday, week: week));
    }
    if (parts['BYDAY'] != null && byDay.isEmpty) return null;
    MeetingRepeat make(
      RepeatUnit every, {
      Set<int> weekdays = const {},
      int? dayOfMonth,
      int? week,
      int? month,
    }) =>
        MeetingRepeat(
          every,
          interval: interval,
          weekdays: weekdays,
          dayOfMonth: dayOfMonth,
          week: week,
          month: month,
          until: until,
          count: count,
        );
    final numbered = byDay.length == 1 && byDay.single.week != null;
    switch (parts['FREQ']) {
      case 'DAILY':
        if (byDay.isNotEmpty || dayOfMonth != null || month != null) {
          return null;
        }
        return make(RepeatUnit.day);
      case 'WEEKLY':
        if (dayOfMonth != null || month != null) return null;
        if (byDay.any((d) => d.week != null)) return null;
        final days = {
          for (final d in byDay) d.weekday,
          if (byDay.isEmpty && start != null) start.weekday,
        };
        return days.isEmpty ? null : make(RepeatUnit.week, weekdays: days);
      case 'MONTHLY':
        if (month != null) return null;
        if (byDay.isNotEmpty) {
          if (!numbered || dayOfMonth != null) return null;
          return make(RepeatUnit.month,
              weekdays: {byDay.single.weekday}, week: byDay.single.week);
        }
        final day = dayOfMonth ?? start?.day;
        return day == null ? null : make(RepeatUnit.month, dayOfMonth: day);
      case 'YEARLY':
        final inMonth = month ?? start?.month;
        if (inMonth == null) return null;
        if (byDay.isNotEmpty) {
          if (!numbered || dayOfMonth != null || month == null) return null;
          return make(RepeatUnit.year,
              weekdays: {byDay.single.weekday},
              week: byDay.single.week,
              month: month);
        }
        // A year's date, or the first meeting's, in the month named.
        final day = dayOfMonth ?? start?.day;
        return day == null
            ? null
            : make(RepeatUnit.year, dayOfMonth: day, month: inMonth);
      default:
        return null;
    }
  }

  /// A rule's UNTIL as the last day a meeting may fall on: a date as it is,
  /// a time in UTC on the phone's own clock, as the rule writes the end of
  /// a timed series' last day.
  static DateTime? _ruleDate(String text) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$')
        .firstMatch(text);
    if (m == null) return null;
    final n = [for (var i = 1; i <= 6; i++) int.tryParse(m[i] ?? '') ?? 0];
    if (n[1] < 1 || n[1] > 12 || n[2] < 1 || n[2] > 31) return null;
    final at = m[4] == null
        ? DateTime(n[0], n[1], n[2])
        : m[7] == 'Z'
            ? DateTime.utc(n[0], n[1], n[2], n[3], n[4], n[5]).toLocal()
            : DateTime(n[0], n[1], n[2], n[3], n[4], n[5]);
    return DateTime(at.year, at.month, at.day);
  }

  /// A Google series as Google gives it: its `recurrence`, and its first
  /// day as its own `start` writes it, on the clock it was set on. Null
  /// where it has no rule this can say.
  static MeetingRepeat? fromGoogle(Map<String, Object?> event) {
    final lines = event['recurrence'];
    if (lines is! List) return null;
    final start = event['start'];
    final written = start is Map ? start['date'] ?? start['dateTime'] : null;
    return fromRule(lines, start: written is String ? _date(written) : null);
  }

  @override
  bool operator ==(Object other) =>
      other is MeetingRepeat &&
      other.every == every &&
      other.interval == interval &&
      setEquals(other.weekdays, weekdays) &&
      other.dayOfMonth == dayOfMonth &&
      other.week == week &&
      other.month == month &&
      other.until == until &&
      other.count == count;

  @override
  int get hashCode => Object.hash(every, interval,
      Object.hashAllUnordered(weekdays), dayOfMonth, week, month, until, count);

  @override
  String toString() => 'MeetingRepeat(${describe()})';
}
