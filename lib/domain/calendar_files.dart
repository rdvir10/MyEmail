import 'package:flutter/foundation.dart';

import 'calendar_invite.dart';
import 'ics_feed.dart';
import 'meeting.dart';
import 'meeting_repeat.dart';
import 'recurrence.dart';
import 'series_repeat.dart';
import 'time_zones.dart' show wallClockIn;

/// A calendar file opened with MyEmail from another app (calendar idea
/// #67): an .ics from Files, a browser's download, a booking an app hands
/// over. Its events, each to go on one of Ron's calendars as his own, and
/// only when he says.
///
/// Written by a stranger, so read as [IcsFeed] reads a calendar from a
/// link, and nothing here throws: what cannot be read is left out, and a
/// file with nothing left is no calendar.
@immutable
class CalendarFile {
  const CalendarFile({this.name, required this.events});

  /// What the calendar calls itself, where it says.
  final String? name;

  /// Earliest first. Not one cancelled, nor the single meetings of a
  /// series the file moves (see [FileEvent.changed]).
  final List<FileEvent> events;

  /// Larger than this is not read: a calendar of a year's school terms or
  /// a country's holidays for decades is a few hundred kilobytes.
  static const largest = 4 * 1024 * 1024;

  /// [text]'s events, or null where it has none that can be placed in
  /// time. Never throws.
  static CalendarFile? read(String text) {
    try {
      return _read(text);
    } catch (e) {
      debugPrint('[myemail] a calendar file could not be read: '
          '${e.runtimeType}');
      return null;
    }
  }

  static CalendarFile? _read(String text) {
    if (!text.toUpperCase().contains('BEGIN:VEVENT')) return null;
    final feed = IcsFeed.parse(text);
    // A meeting of a series that the file moves or changes is an event of
    // its own with the series' UID: counted against the series, not shown.
    final moved = <String, int>{};
    for (final e in feed.events) {
      if (e.recurrenceId != null) moved[e.uid] = (moved[e.uid] ?? 0) + 1;
    }
    final events = [
      for (final e in feed.events)
        if (!e.cancelled && e.recurrenceId == null && _placed(e))
          FileEvent(e, changed: e.excluded.length + (moved[e.uid] ?? 0)),
    ]..sort((a, b) => a.event.start.compareTo(b.event.start));
    if (events.isEmpty) return null;
    return CalendarFile(name: feed.name, events: events);
  }

  /// A time a calendar can hold: not before 1900 nor after 2200, which
  /// only a mistake writes.
  static bool _placed(IcsEvent e) =>
      e.start.year >= 1900 && e.start.year <= 2200;
}

/// One event of a [CalendarFile], and what it takes to put it on a
/// calendar.
@immutable
class FileEvent {
  const FileEvent(this.event, {this.changed = 0});

  final IcsEvent event;

  /// How many of its meetings the file leaves out or moves (EXDATE, and
  /// single meetings of its own). Added, the series has them as the
  /// series would: New meeting's repeat has no dates left out.
  final int changed;

  String get title {
    final t = event.summary.trim();
    return t.isEmpty ? '(No title)' : t;
  }

  bool get allDay => event.allDay;

  /// Whether it has a meeting on [day] or after, or one running into it:
  /// a series begun long before still runs while its rule has meetings
  /// left (no end, an end from [day] on, a count not yet used up). For the
  /// list to open at what is still to come.
  bool runsOnOrAfter(DateTime day) {
    final from = _day(day);
    final length = allDay ? Duration(days: event.days) : event.length;
    bool reaches(DateTime at) {
      final ends = at.add(length);
      return !_day(allDay ? ends.subtract(const Duration(days: 1)) : ends)
          .isBefore(from);
    }

    if (reaches(event.start)) return true;
    if (event.rule == null) return false;
    try {
      return event
          .occurrences(DateTime(from.year + 100), from: from)
          .any(reaches);
    } catch (_) {
      return false;
    }
  }

  /// Its time names a zone neither the phone knows nor the file defines:
  /// read as written, on the phone's clock, which its row says.
  bool get zoneUnknown => event.zoneUnknown;

  /// The zone a series is set in, where it repeats and names one the phone
  /// knows: it goes on that zone's clock, as it is kept in the file, so it
  /// does not slip an hour in the weeks the two zones change their clocks
  /// apart. Null for anything else, which goes on the phone's clock.
  String? get seriesZone =>
      rule != null && !allDay && !event.floating ? event.zone : null;

  /// [start] and [end] as a calendar is given them: on [seriesZone]'s
  /// clock where there is one, the phone's otherwise.
  ({DateTime start, DateTime end}) get _sent {
    final zone = seriesZone;
    if (zone == null) return (start: start, end: end);
    try {
      return (
        start: wallClockIn(event.start, zone),
        end: wallClockIn(event.start.add(end.difference(start)), zone),
      );
    } catch (_) {
      return (start: start, end: end);
    }
  }

  /// On the phone's clock, the way New meeting has a meeting: for a whole
  /// day, its first day and its last, both at midnight.
  DateTime get start => allDay ? event.start : event.start.toLocal();
  DateTime get end {
    if (allDay) {
      final days = event.days < 1 ? 1 : event.days;
      return DateTime(start.year, start.month, start.day + days - 1);
    }
    // An event with no end, or one before it starts, is half an hour: a
    // calendar will not take a meeting that ends as it begins.
    final length = event.length > Duration.zero
        ? event.length
        : const Duration(minutes: 30);
    return start.add(length);
  }

  /// Its RRULE, rebuilt from its parts, without the name; null for none.
  String? get rule {
    final parts = event.rule;
    if (parts == null || parts.isEmpty) return null;
    return [
      for (final MapEntry(:key, :value) in parts.entries) '$key=$value',
    ].join(';');
  }

  /// The day its first meeting falls on, on the clock the file gives it:
  /// what its repeat's days are counted on.
  DateTime get ownDay {
    final at = event.start;
    if (event.allDay || event.floating) return _day(at);
    final own = event.ownZone?.wallClockOf(at);
    if (own != null) return _day(own);
    final zone = event.zone;
    if (zone != null) {
      try {
        return _day(wallClockIn(at, zone));
      } catch (_) {
        // A zone the phone cannot read: the phone's own day, as the time
        // was read.
        return _day(at.toLocal());
      }
    }
    return _day(at.toUtc());
  }

  /// The same day on the phone's clock.
  DateTime get phoneDay => _day(start);

  /// How it repeats, in New meeting's words, or null where they cannot
  /// say it exactly; not asked of one that does not repeat.
  String? get repeatWords {
    final text = rule;
    if (text == null) return null;
    return MeetingRepeat.fromRule(['RRULE:$text'], start: ownDay)?.describe();
  }

  /// Its repeat in New meeting's terms, for an account's calendar; null
  /// where it does not repeat, and where New meeting could not make it so
  /// (see [repeatKept]): more than 999 meetings is one of those. Read on
  /// the clock it goes on: the series' own zone's, or the phone's, where
  /// its days must then be the phone's days.
  Recurrence? get repeat {
    final text = rule;
    if (text == null) return null;
    if (_tooMany(_partsOf(text))) return null;
    final zone = seriesZone;
    if (zone == null && !_sameDay(text)) return null;
    final first = _sent.start;
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${first.year.toString().padLeft(4, '0')}-'
        '${two(first.month)}-${two(first.day)}';
    return SeriesRepeat.fromGoogle({
      'recurrence': ['RRULE:$text'],
      'start': allDay
          ? {'date': date}
          : {
              'dateTime': '${date}T${two(first.hour)}:${two(first.minute)}:'
                  '${two(first.second)}',
              'timeZone': ?zone,
            },
    })?.repeat;
  }

  /// Whether an account's calendar can be given its repeat: one that does
  /// not repeat, or one whose repeat [repeat] reads.
  bool get repeatKept => rule == null || repeat != null;

  /// Its repeat as the phone's calendar app is handed it, or null: see
  /// [ruleForPhone].
  String? get phoneRule =>
      ruleForPhone(rule, start: event.start, ownDay: ownDay);

  /// Whether the phone's calendar app can be given its repeat.
  bool get phoneRuleKept => rule == null || phoneRule != null;

  /// Its days counted on the phone's clock are its own: the same first
  /// day, or a repeat that does not go by the day.
  bool _sameDay(String text) =>
      ownDay == phoneDay || !_goesByDay(_partsOf(text));

  /// It on [accountId]'s calendar [calendarId], as Ron's own: nobody on it
  /// is invited or told, whoever the file names. [transactionId], the same
  /// for each try, so an Add tried again after an answer that never came
  /// does not make two.
  MeetingDraft draftFor({
    required String accountId,
    required String calendarId,
    String? timeZone,
    String? transactionId,
  }) =>
      MeetingDraft(
        accountId: accountId,
        calendarId: calendarId,
        title: title,
        start: _sent.start,
        end: _sent.end,
        allDay: allDay,
        location: event.location.trim(),
        notes: event.description.trim(),
        // A series in a zone of its own goes on that zone's clock: see
        // [seriesZone]. [timeZone] is the phone's.
        timeZone: seriesZone ?? timeZone,
        recurrence: repeat,
        transactionId: transactionId,
      );
}

DateTime _day(DateTime at) => DateTime(at.year, at.month, at.day);

/// What each part of a repeat handed to the phone's calendar may hold:
/// the parts Android's calendar reads, in the forms RFC 5545 gives them.
final _phoneParts = <String, RegExp>{
  'FREQ': RegExp(r'^(DAILY|WEEKLY|MONTHLY|YEARLY)$'),
  'INTERVAL': RegExp(r'^[1-9]\d{0,2}$'),
  // No more than New meeting makes: a count of 100000 failed only at the
  // calendar, after Add.
  'COUNT': RegExp(r'^[1-9]\d{0,2}$'),
  'UNTIL': RegExp(r'^\d{8}(T\d{6}Z?)?$'),
  'WKST': RegExp(r'^(MO|TU|WE|TH|FR|SA|SU)$'),
  'BYDAY': RegExp(
      r'^[+-]?\d{0,2}(MO|TU|WE|TH|FR|SA|SU)(,[+-]?\d{0,2}(MO|TU|WE|TH|FR|SA|SU))*$'),
  'BYMONTHDAY': RegExp(r'^[+-]?\d{1,2}(,[+-]?\d{1,2})*$'),
  'BYMONTH': RegExp(r'^\d{1,2}(,\d{1,2})*$'),
  'BYSETPOS': RegExp(r'^[+-]?\d{1,3}(,[+-]?\d{1,3})*$'),
};

/// [text]'s parts by name, in upper case; empty where one is not in the
/// form NAME=VALUE.
Map<String, String> _partsOf(String text) {
  final parts = <String, String>{};
  for (final part in text.split(';')) {
    if (part.trim().isEmpty) continue;
    final at = part.indexOf('=');
    if (at <= 0) return const {};
    parts[part.substring(0, at).trim().toUpperCase()] =
        part.substring(at + 1).trim().toUpperCase();
  }
  return parts;
}

/// Whether [parts] count more meetings than New meeting makes, 999.
bool _tooMany(Map<String, String> parts) {
  final count = parts['COUNT'];
  if (count == null) return false;
  final n = int.tryParse(count);
  return n == null || n > 999;
}

/// Whether a repeat's meetings fall on days it names, or on its first
/// meeting's day, rather than every day whatever the day.
bool _goesByDay(Map<String, String> parts) =>
    parts['FREQ'] != 'DAILY' ||
    const ['BYDAY', 'BYMONTHDAY', 'BYMONTH', 'BYSETPOS']
        .any(parts.containsKey);

/// [rule], an event's RRULE without its name, made fit to hand the phone's
/// calendar app with an event starting at [start]: "RRULE:" and its parts,
/// in upper case. Null for none, and for one that is not handed on (the
/// event then goes as one meeting, as before):
///
/// - a part Android's calendar does not read, a part twice, or a value
///   not in its form: a stranger wrote it, and it goes into the intent
///   whole;
/// - a repeat by the day, where the first meeting's day on its own clock,
///   [ownDay], is not its day on the phone's: the phone reads BYDAY=TU on
///   its own clock, and a Tuesday evening in New York is a Wednesday
///   morning here. Where its own day cannot be known, pass
///   [ownDayKnown] false: only a daily repeat goes.
///
/// [local] puts [start] on the phone's clock: [DateTime.toLocal], but for
/// a test. Never throws.
String? ruleForPhone(
  String? rule, {
  required DateTime start,
  DateTime? ownDay,
  bool ownDayKnown = true,
  DateTime Function(DateTime at)? local,
}) {
  try {
    if (rule == null || rule.trim().isEmpty) return null;
    final parts = <String, String>{};
    for (final part in rule.split(';')) {
      if (part.trim().isEmpty) continue;
      final at = part.indexOf('=');
      if (at <= 0) return _refused('a part with no value');
      final name = part.substring(0, at).trim().toUpperCase();
      final value = part.substring(at + 1).trim().toUpperCase();
      final form = _phoneParts[name];
      if (form == null) return _refused('a part the phone does not read');
      if (parts.containsKey(name)) return _refused('a part twice');
      if (!form.hasMatch(value)) return _refused('$name not in its form');
      parts[name] = value;
    }
    if (!parts.containsKey('FREQ')) return _refused('no FREQ');
    if (_goesByDay(parts)) {
      final here = (local ?? (t) => t.toLocal())(start);
      // A time in UTC is on UTC's day, a time on no clock on the phone's.
      final own = ownDay ?? _day(start);
      if (!ownDayKnown || _day(here) != _day(own)) {
        return _refused('${parts['FREQ']}, its day not the phone\'s');
      }
    }
    return 'RRULE:${[
      for (final MapEntry(:key, :value) in parts.entries) '$key=$value',
    ].join(';')}';
  } catch (_) {
    return null;
  }
}

String? _refused(String why) {
  // What kind of part, never the rule: it is the sender's.
  debugPrint('[myemail] a repeat not handed to the phone: $why');
  return null;
}

/// [invite]'s repeat as the phone's calendar app is handed it, or null:
/// see [ruleForPhone]. Its first day on its own clock is the time as the
/// sender wrote it, where the zone was worked out; the UTC day for a time
/// sent in UTC; and unknown for a zone read for its instant alone.
String? ruleForPhoneOf(CalendarInvite invite) {
  final ownDay = _ownDayOf(invite);
  return ruleForPhone(
    invite.rule,
    start: invite.start,
    ownDay: ownDay,
    ownDayKnown: ownDay != null,
  );
}

/// [invite]'s first day on its own clock: see [ruleForPhoneOf]. Null where
/// it cannot be known.
DateTime? _ownDayOf(CalendarInvite invite) {
  final written = invite.localStart;
  // A whole day, a time on no clock, or one in UTC: the day as written.
  if (invite.isAllDay || invite.timeZone == null) return _day(invite.start);
  if (written != null) return _day(written);
  return null;
}

/// [invite]'s repeat in words for its card, or null where it does not
/// repeat; "Repeats" alone where New meeting's words cannot say it.
String? repeatWordsOf(CalendarInvite invite) {
  final rule = invite.rule;
  if (rule == null) return null;
  final first = _ownDayOf(invite) ?? _day(invite.start.toLocal());
  return MeetingRepeat.fromRule(['RRULE:$rule'], start: first)?.describe() ??
      'Repeats';
}
