import 'package:flutter/foundation.dart';

import 'calendar_event.dart';
import 'time_zones.dart' show ianaZoneOf, instantIn, wallClockIn;

/// A calendar published as a link: iCalendar text (RFC 5545) holding any
/// number of events, a country's public holidays, a school's terms, a
/// team's fixtures. Read here into its events, and those that repeat laid
/// out over the stretch a view asks for.
///
/// What a published calendar uses is read: whole days, times in UTC, in a
/// named zone or floating, a length as an end or a duration, and repeats
/// by day, week, month or year with the days, dates and months they name,
/// a count or an end, dates left out, and single meetings moved. Rarer
/// parts of a rule (by week number, by day of the year, by position) are
/// left out, the dates they would add with them.
@immutable
class IcsFeed {
  const IcsFeed({this.name, this.events = const []});

  /// What the calendar calls itself (X-WR-CALNAME), where it says.
  final String? name;
  final List<IcsEvent> events;

  /// The text read; never throws, a line it cannot read passed over.
  static IcsFeed parse(String text) {
    String? name;
    final events = <IcsEvent>[];
    _EventBuilder? current;
    var depth = 0;
    for (final raw in _unfold(text)) {
      final line = _IcsLine.parse(raw);
      if (line == null) continue;
      final value = line.value.trim().toUpperCase();
      if (line.name == 'BEGIN') {
        if (value == 'VEVENT' && current == null) {
          current = _EventBuilder();
          depth = 0;
        } else if (current != null) {
          // A reminder (VALARM) inside the event, with lines of its own.
          depth++;
        }
        continue;
      }
      if (line.name == 'END') {
        if (current != null) {
          if (depth > 0) {
            depth--;
          } else if (value == 'VEVENT') {
            if (current.build() case final e?) events.add(e);
            current = null;
          }
        }
        continue;
      }
      if (current == null) {
        if (line.name == 'X-WR-CALNAME') name = _text(line.value).trim();
        continue;
      }
      if (depth == 0) current.read(line);
    }
    return IcsFeed(
      name: name == null || name.isEmpty ? null : name,
      events: events,
    );
  }

  /// Every occurrence of its events that falls between [start] and [end],
  /// as [accountId]'s, read only: a published calendar is read, not
  /// written to.
  List<CalendarEvent> between(
    DateTime start,
    DateTime end, {
    required String accountId,
  }) {
    final moved = <String, Map<int, IcsEvent>>{};
    for (final e in events) {
      final of = e.recurrenceId;
      if (of != null) {
        (moved[e.uid] ??= {})[of.millisecondsSinceEpoch] = e;
      }
    }
    final found = <CalendarEvent>[];
    void add(IcsEvent e, DateTime at, {required bool repeats}) {
      final until = e.allDay
          ? DateTime(at.year, at.month, at.day + e.days)
          : at.add(e.length);
      final ends = until.isBefore(at) ? at : until;
      final overlaps = at.isBefore(end) &&
          (ends.isAfter(start) || (ends == at && !at.isBefore(start)));
      if (!overlaps) return;
      found.add(CalendarEvent(
        id: repeats ? '${e.uid}@${at.millisecondsSinceEpoch}' : e.uid,
        accountId: accountId,
        title: e.summary,
        start: at,
        end: ends,
        allDay: e.allDay,
        location: e.location,
        preview: e.description.length > 300
            ? '${e.description.substring(0, 300)}…'
            : e.description,
        showAs: e.transparent ? EventShowAs.free : EventShowAs.busy,
        readOnly: true,
      ));
    }

    for (final e in events) {
      if (e.cancelled || e.recurrenceId != null) continue;
      final rule = e.rule;
      if (rule == null) {
        add(e, e.start, repeats: false);
        continue;
      }
      final replaced = moved[e.uid] ?? const {};
      for (final at in e.occurrences(end, from: start)) {
        if (e.leftOut(at)) continue;
        final instead = replaced[at.millisecondsSinceEpoch];
        if (instead != null) {
          if (!instead.cancelled) add(instead, instead.start, repeats: true);
          continue;
        }
        add(e, at, repeats: true);
      }
    }
    found.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.end.compareTo(b.end);
    });
    return found;
  }
}

/// One VEVENT, as published.
@immutable
class IcsEvent {
  const IcsEvent({
    required this.uid,
    required this.start,
    this.summary = '',
    this.location = '',
    this.description = '',
    this.allDay = false,
    this.length = Duration.zero,
    this.days = 1,
    this.zone,
    this.floating = false,
    this.rule,
    this.excluded = const {},
    this.recurrenceId,
    this.transparent = false,
    this.cancelled = false,
  });

  final String uid;

  /// The first occurrence: an instant, or for a whole day its date at the
  /// phone's midnight.
  final DateTime start;
  final String summary;
  final String location;
  final String description;
  final bool allDay;

  /// How long a timed one lasts, and how many days a whole-day one spans.
  final Duration length;
  final int days;

  /// The IANA zone its times are on the clock of; null for UTC or floating.
  final String? zone;

  /// On no zone's clock in particular: the phone's.
  final bool floating;

  /// Its RRULE, by part: FREQ, INTERVAL, COUNT, UNTIL, BYDAY and so on.
  final Map<String, String>? rule;

  /// The occurrences left out (EXDATE): instants in milliseconds, or for a
  /// whole day its date's midnight.
  final Set<int> excluded;

  /// For a single meeting of a series moved or changed: which occurrence
  /// it stands for.
  final DateTime? recurrenceId;
  final bool transparent;
  final bool cancelled;

  bool leftOut(DateTime at) => excluded.contains(at.millisecondsSinceEpoch);

  /// The figures of [at] on the clock this event keeps, held in a UTC
  /// DateTime so that adding days never meets a change of the clocks.
  DateTime _wall(DateTime at) {
    if (allDay || floating) {
      return DateTime.utc(at.year, at.month, at.day, at.hour, at.minute,
          at.second);
    }
    final z = zone;
    if (z == null) return at.toUtc();
    final local = wallClockIn(at, z);
    return DateTime.utc(local.year, local.month, local.day, local.hour,
        local.minute, local.second);
  }

  /// The instant [wall]'s figures stand for on this event's clock.
  DateTime _instant(DateTime wall) {
    if (allDay) return DateTime(wall.year, wall.month, wall.day);
    if (floating) {
      return DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute,
          wall.second);
    }
    final z = zone;
    if (z == null) return wall;
    return instantIn(
      DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute,
          wall.second),
      z,
    );
  }

  /// Every start of its series from the first, as instants, until one
  /// falls at or after [until], or the rule's own end. [from] lets a
  /// series with no count start near where it is wanted, rather than walk
  /// up from a first meeting years before.
  Iterable<DateTime> occurrences(DateTime until, {DateTime? from}) sync* {
    final rule = this.rule ?? const {};
    final freq = rule['FREQ'];
    if (!const {'DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'}.contains(freq)) {
      // A rule this does not read: the first meeting alone.
      if (start.isBefore(until)) yield start;
      return;
    }
    final parsed = int.tryParse(rule['INTERVAL'] ?? '') ?? 1;
    final interval = parsed < 1 ? 1 : parsed;
    final count = int.tryParse(rule['COUNT'] ?? '');
    final last = _untilOf(rule['UNTIL']);
    final first = _wall(start);
    final byMonth = _numbers(rule['BYMONTH']);
    final byMonthDay = _numbers(rule['BYMONTHDAY']);
    final byDay = _weekdays(rule['BYDAY']);
    var made = 0;
    var period = 0;
    if (count == null && from != null && from.isAfter(start)) {
      // Whole periods that end before [from], stepped over: at least one
      // short, so a meeting running into [from] is still found.
      final wanted = _wall(from);
      final gap = switch (freq) {
        'DAILY' => wanted.difference(first).inDays,
        'WEEKLY' => wanted.difference(first).inDays ~/ 7,
        'MONTHLY' =>
          (wanted.year - first.year) * 12 + wanted.month - first.month,
        _ => wanted.year - first.year,
      };
      final steps = gap ~/ interval - 1;
      if (steps > 0) period = steps * interval;
    }
    // A rule that never comes round stops here rather than spinning.
    for (var tries = 0; tries < 5000; tries++, period += interval) {
      final candidates = switch (freq) {
        'DAILY' => _daily(first, period, byMonth, byMonthDay, byDay),
        'WEEKLY' => _weekly(first, period, byDay),
        'MONTHLY' => _monthly(first, period, byMonthDay, byDay),
        _ => _yearly(first, period, byMonth, byMonthDay, byDay),
      };
      for (final wall in candidates) {
        if (wall.isBefore(first)) continue;
        final at = _instant(wall);
        if (last != null && at.isAfter(last)) return;
        if (!at.isBefore(until)) return;
        yield at;
        made++;
        if (count != null && made >= count) return;
      }
    }
  }

  DateTime? _untilOf(String? text) {
    if (text == null) return null;
    final value = _IcsDate.parse(text, const {});
    if (value == null) return null;
    // A date alone is to the end of that day.
    if (value.dateOnly) {
      return DateTime(value.at.year, value.at.month, value.at.day, 23, 59, 59);
    }
    return value.utc ? value.at : _instant(value.at);
  }

  static List<int> _numbers(String? text) => [
        for (final part in (text ?? '').split(',')) ?int.tryParse(part.trim()),
      ];

  /// BYDAY's days, each with its ordinal (2MO, -1FR), or 0 for every one.
  static List<({int ordinal, int weekday})> _weekdays(String? text) => [
        for (final part in (text ?? '').split(','))
          if (RegExp(r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$')
                  .firstMatch(part.trim().toUpperCase())
              case final m?)
            (
              ordinal: int.tryParse(m[1] ?? '') ?? 0,
              weekday: _days.indexOf(m[2]!) + 1,
            ),
      ];

  static const _days = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

  static DateTime _at(DateTime first, int year, int month, int day) =>
      DateTime.utc(year, month, day, first.hour, first.minute, first.second);

  static List<DateTime> _daily(
    DateTime first,
    int period,
    List<int> byMonth,
    List<int> byMonthDay,
    List<({int ordinal, int weekday})> byDay,
  ) {
    final day = _at(first, first.year, first.month, first.day + period);
    if (byMonth.isNotEmpty && !byMonth.contains(day.month)) return const [];
    if (byMonthDay.isNotEmpty && !byMonthDay.contains(day.day)) return const [];
    if (byDay.isNotEmpty && !byDay.any((d) => d.weekday == day.weekday)) {
      return const [];
    }
    return [day];
  }

  static List<DateTime> _weekly(
    DateTime first,
    int period,
    List<({int ordinal, int weekday})> byDay,
  ) {
    // The week starts on Monday, iCalendar's own start.
    final monday = _at(first, first.year, first.month,
        first.day - (first.weekday - 1) + period * 7);
    final weekdays = byDay.isEmpty
        ? [first.weekday]
        : ({for (final d in byDay) d.weekday}.toList()..sort());
    return [
      for (final w in weekdays)
        _at(first, monday.year, monday.month, monday.day + w - 1),
    ];
  }

  static List<DateTime> _monthly(
    DateTime first,
    int period,
    List<int> byMonthDay,
    List<({int ordinal, int weekday})> byDay,
  ) {
    final month = DateTime.utc(first.year, first.month + period);
    return _inMonth(first, month.year, month.month,
        byMonthDay.isEmpty && byDay.isEmpty ? [first.day] : byMonthDay, byDay);
  }

  static List<DateTime> _yearly(
    DateTime first,
    int period,
    List<int> byMonth,
    List<int> byMonthDay,
    List<({int ordinal, int weekday})> byDay,
  ) {
    final year = first.year + period;
    final months = byMonth.isEmpty ? [first.month] : (byMonth.toList()..sort());
    return [
      for (final m in months)
        ..._inMonth(first, year, m,
            byMonthDay.isEmpty && byDay.isEmpty ? [first.day] : byMonthDay,
            byDay),
    ];
  }

  /// The days of [year]'s [month] that [monthDays] (negative from its end)
  /// and [byDay] (every such weekday, or the nth) name, in order.
  static List<DateTime> _inMonth(
    DateTime first,
    int year,
    int month,
    List<int> monthDays,
    List<({int ordinal, int weekday})> byDay,
  ) {
    final length = DateTime.utc(year, month + 1, 0).day;
    final days = <int>{};
    for (final d in monthDays) {
      final day = d > 0 ? d : length + d + 1;
      if (day >= 1 && day <= length) days.add(day);
    }
    for (final d in byDay) {
      final firstOfMonth = DateTime.utc(year, month).weekday;
      final firstSuch = 1 + (d.weekday - firstOfMonth + 7) % 7;
      final all = [for (var day = firstSuch; day <= length; day += 7) day];
      if (d.ordinal == 0) {
        days.addAll(all);
      } else if (d.ordinal > 0 && d.ordinal <= all.length) {
        days.add(all[d.ordinal - 1]);
      } else if (d.ordinal < 0 && -d.ordinal <= all.length) {
        days.add(all[all.length + d.ordinal]);
      }
    }
    return [
      for (final day in days.toList()..sort()) _at(first, year, month, day),
    ];
  }
}

/// What the lines of one VEVENT said, until its END.
class _EventBuilder {
  String? uid;
  _IcsDate? start;
  _IcsDate? end;
  Duration? duration;
  String summary = '';
  String location = '';
  String description = '';
  Map<String, String>? rule;
  final Set<int> excluded = {};
  final List<_IcsDate> exdates = [];
  _IcsDate? recurrenceId;
  bool transparent = false;
  bool cancelled = false;

  void read(_IcsLine line) {
    switch (line.name) {
      case 'UID':
        uid = line.value.trim();
      case 'DTSTART':
        start = _IcsDate.parse(line.value, line.params);
      case 'DTEND':
        end = _IcsDate.parse(line.value, line.params);
      case 'DURATION':
        duration = _duration(line.value.trim());
      case 'SUMMARY':
        summary = _text(line.value).trim();
      case 'LOCATION':
        location = _text(line.value).trim();
      case 'DESCRIPTION':
        description = _text(line.value).trim();
      case 'RRULE':
        rule = {
          for (final part in line.value.split(';'))
            if (part.contains('='))
              part.substring(0, part.indexOf('=')).trim().toUpperCase():
                  part.substring(part.indexOf('=') + 1).trim().toUpperCase(),
        };
      case 'EXDATE':
        for (final v in line.value.split(',')) {
          final d = _IcsDate.parse(v, line.params);
          if (d != null) exdates.add(d);
        }
      case 'RECURRENCE-ID':
        recurrenceId = _IcsDate.parse(line.value, line.params);
      case 'TRANSP':
        transparent = line.value.trim().toUpperCase() == 'TRANSPARENT';
      case 'STATUS':
        cancelled = line.value.trim().toUpperCase() == 'CANCELLED';
    }
  }

  IcsEvent? build() {
    final first = start;
    if (first == null) return null;
    final allDay = first.dateOnly;
    final zone = first.zone;
    DateTime instant(_IcsDate d) {
      if (d.dateOnly) return DateTime(d.at.year, d.at.month, d.at.day);
      if (d.utc) return d.at;
      final z = d.zone;
      if (z != null) {
        return instantIn(
          DateTime(d.at.year, d.at.month, d.at.day, d.at.hour, d.at.minute,
              d.at.second),
          z,
        );
      }
      return DateTime(
          d.at.year, d.at.month, d.at.day, d.at.hour, d.at.minute, d.at.second);
    }

    final begins = instant(first);
    final finish = end;
    var length = duration ?? Duration.zero;
    var days = 1;
    if (allDay) {
      if (finish != null && finish.dateOnly) {
        days = DateTime.utc(finish.at.year, finish.at.month, finish.at.day)
            .difference(DateTime.utc(first.at.year, first.at.month, first.at.day))
            .inDays;
      } else if (duration != null) {
        days = duration!.inDays;
      }
      if (days < 1) days = 1;
    } else if (finish != null) {
      length = instant(finish).difference(begins);
      if (length.isNegative) length = Duration.zero;
    }
    final id = recurrenceId;
    return IcsEvent(
      uid: uid ?? '${first.at.millisecondsSinceEpoch}:$summary',
      start: begins,
      summary: summary,
      location: location,
      description: description,
      allDay: allDay,
      length: length,
      days: days,
      zone: zone,
      floating: !allDay && !first.utc && zone == null,
      rule: rule,
      excluded: {for (final d in exdates) instant(d).millisecondsSinceEpoch},
      recurrenceId: id == null ? null : instant(id),
      transparent: transparent,
      cancelled: cancelled,
    );
  }

  static Duration? _duration(String text) {
    final m = RegExp(r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$')
        .firstMatch(text.toUpperCase());
    if (m == null) return null;
    int n(int i) => int.tryParse(m[i] ?? '') ?? 0;
    final d = Duration(
      days: n(2) * 7 + n(3),
      hours: n(4),
      minutes: n(5),
      seconds: n(6),
    );
    return m[1] == '-' ? -d : d;
  }
}

/// A date or a date-time as a line writes it, with the zone it names.
class _IcsDate {
  _IcsDate(this.at, {this.dateOnly = false, this.utc = false, this.zone});

  /// Its figures; an instant where [utc].
  final DateTime at;
  final bool dateOnly;
  final bool utc;

  /// The IANA zone named (TZID), where it is one the phone knows.
  final String? zone;

  static _IcsDate? parse(String text, Map<String, String> params) {
    final v = text.trim();
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$')
        .firstMatch(v.toUpperCase());
    if (m == null) return null;
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    if (m[4] == null) return _IcsDate(DateTime(y, mo, d), dateOnly: true);
    final h = int.parse(m[4]!), mi = int.parse(m[5]!);
    final s = int.parse(m[6] ?? '0');
    if (m[7] != null) {
      return _IcsDate(DateTime.utc(y, mo, d, h, mi, s), utc: true);
    }
    final named = params['TZID'];
    final zone = named == null ? null : ianaZoneOf(named);
    return _IcsDate(DateTime(y, mo, d, h, mi, s), zone: zone);
  }
}

class _IcsLine {
  _IcsLine(this.name, this.params, this.value);

  final String name;
  final Map<String, String> params;
  final String value;

  static _IcsLine? parse(String raw) {
    // The value starts at the first colon outside a quoted parameter.
    var quoted = false;
    var colon = -1;
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (c == '"') quoted = !quoted;
      if (c == ':' && !quoted) {
        colon = i;
        break;
      }
    }
    if (colon < 0) return null;
    final parts = raw.substring(0, colon).split(';');
    return _IcsLine(
      parts.first.trim().toUpperCase(),
      {
        for (final p in parts.skip(1))
          if (p.contains('='))
            p.substring(0, p.indexOf('=')).trim().toUpperCase():
                p.substring(p.indexOf('=') + 1).replaceAll('"', ''),
      },
      raw.substring(colon + 1),
    );
  }
}

/// The text's lines, each folded one put back together: a line that starts
/// with a space or a tab carries on the one before.
List<String> _unfold(String text) {
  final lines = <String>[];
  for (final raw in text.split(RegExp(r'\r\n|\n|\r'))) {
    if (raw.isEmpty) continue;
    if ((raw.startsWith(' ') || raw.startsWith('\t')) && lines.isNotEmpty) {
      lines[lines.length - 1] += raw.substring(1);
    } else {
      lines.add(raw);
    }
  }
  return lines;
}

/// A text value with its escapes undone: \n, \, \; and \\.
String _text(String value) => value
    .replaceAll(r'\N', '\n')
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\,', ',')
    .replaceAll(r'\;', ';')
    .replaceAll(r'\\', r'\');
