import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'calendar_change.dart' show everyoneOn, isOwnEvent;
import 'calendar_event.dart';
import 'clock_text.dart';
import 'free_busy.dart' show defaultWorkWeek;

/// What MyEmail says about meetings away from the calendar: the bar over
/// the mail, each meeting's reminder, the morning's agenda and the
/// home-screen widget. Worked out here from the events, so the screen, the
/// background pass and the tests agree.

/// How long before a meeting the bar over the mail says it is coming:
/// Outlook for Android's quarter of an hour.
const nextMeetingLead = Duration(minutes: 15);

/// [event] as one key: the same occurrence read twice is the same key, and
/// one moved to another time is a new one.
String meetingKey(CalendarEvent event) =>
    '${event.accountId}|${event.id}|${event.start.millisecondsSinceEpoch}';

/// A meeting with a time of its own, still on: not a whole day, not
/// declined, not cancelled.
bool _timedAndOn(CalendarEvent e) => !e.allDay && !e.cancelled && !e.declined;

String _titleOf(CalendarEvent e) =>
    e.title.trim().isEmpty ? '(No title)' : e.title.trim();

/// The meeting the bar over the mail shows at [now]: the next to start
/// within [nextMeetingLead], or else the one under way that began last.
/// Null where there is neither, or each was swiped away ([dismissed], by
/// [meetingKey]).
CalendarEvent? nextMeeting(
  Iterable<CalendarEvent> events,
  DateTime now, {
  Set<String> dismissed = const {},
}) {
  CalendarEvent? coming;
  CalendarEvent? going;
  for (final e in events) {
    if (!_timedAndOn(e) || !e.end.isAfter(now)) continue;
    if (dismissed.contains(meetingKey(e))) continue;
    if (e.start.isAfter(now)) {
      if (e.start.difference(now) > nextMeetingLead) continue;
      if (coming == null || e.start.isBefore(coming.start)) coming = e;
    } else if (going == null || e.start.isAfter(going.start)) {
      going = e;
    }
  }
  return coming ?? going;
}

/// When [event] is, seen from [now], as the bar says it: "in 12 min", or
/// "now, until 10:30" once it has begun.
String startsText(CalendarEvent event, DateTime now, {required bool use24h}) {
  if (!event.start.isAfter(now)) {
    return 'now, until ${formatClock(event.end, use24h: use24h)}';
  }
  final minutes = (event.start.difference(now).inSeconds / 60).ceil();
  return 'in ${minutes < 1 ? 1 : minutes} min';
}

/// A meeting as a notification or the widget carries it: enough to find it
/// again on the device, and to say it again without looking.
@immutable
class MeetingRef {
  const MeetingRef({
    required this.accountId,
    required this.eventId,
    required this.start,
    required this.end,
    this.calendarId = CalendarEvent.mainCalendar,
    this.title = '',
    this.body = '',
    this.joinUrl,
    this.canTellLate = false,
  });

  factory MeetingRef.of(
    CalendarEvent e, {
    String body = '',
    bool canTellLate = false,
  }) =>
      MeetingRef(
        accountId: e.accountId,
        eventId: e.id,
        calendarId: e.calendarId,
        start: e.start,
        end: e.end,
        title: _titleOf(e),
        body: body,
        joinUrl: e.joinUrl,
        canTellLate: canTellLate,
      );

  final String accountId;
  final String eventId;
  final String calendarId;
  final DateTime start;
  final DateTime end;

  /// What its reminder says, so a Snooze can say it again.
  final String title;
  final String body;

  /// Where to join it online, for the reminder's Join.
  final String? joinUrl;

  /// Whether there is anyone to tell, for the reminder's Running late: the
  /// organiser, or the people on a meeting of your own.
  final bool canTellLate;

  static const _meeting = 'myemail-meeting:';
  static const _join = 'myemail-join:';

  /// As a notification's payload: a tap opens the meeting.
  String get payload => '$_meeting${jsonEncode(_json)}';

  /// As a press of Join hands it back: the app opens [joinUrl].
  String get joinPayload => '$_join${jsonEncode(_json)}';

  Map<String, Object?> get _json => {
        'a': accountId,
        'e': eventId,
        if (calendarId.isNotEmpty) 'c': calendarId,
        's': start.millisecondsSinceEpoch,
        'n': end.millisecondsSinceEpoch,
        if (title.isNotEmpty) 't': title,
        if (body.isNotEmpty) 'b': body,
        'j': ?joinUrl,
        if (canTellLate) 'l': true,
      };

  /// [payload], a reminder's, as Join hands it back; anything else as it
  /// was.
  static String? joining(String? payload) =>
      payload != null && payload.startsWith(_meeting)
          ? '$_join${payload.substring(_meeting.length)}'
          : payload;

  /// Whether [payload] is a press of Join.
  static bool isJoin(String? payload) => payload?.startsWith(_join) ?? false;

  /// The meeting in a [payload] or a [joinPayload]; null for anything else.
  static MeetingRef? fromPayload(String? payload) {
    if (payload == null) return null;
    final String text;
    if (payload.startsWith(_meeting)) {
      text = payload.substring(_meeting.length);
    } else if (payload.startsWith(_join)) {
      text = payload.substring(_join.length);
    } else {
      return null;
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map) return null;
      final account = json['a'], event = json['e'];
      final start = json['s'], end = json['n'];
      if (account is! String || event is! String) return null;
      if (start is! int || end is! int) return null;
      String textOf(Object? v) => v is String ? v : '';
      final join = json['j'];
      return MeetingRef(
        accountId: account,
        eventId: event,
        calendarId: textOf(json['c']),
        start: DateTime.fromMillisecondsSinceEpoch(start),
        end: DateTime.fromMillisecondsSinceEpoch(end),
        title: textOf(json['t']),
        body: textOf(json['b']),
        joinUrl: join is String && join.isNotEmpty ? join : null,
        canTellLate: json['l'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MeetingRef &&
      other.accountId == accountId &&
      other.eventId == eventId &&
      other.calendarId == calendarId &&
      other.start == start &&
      other.end == end &&
      other.title == title &&
      other.body == body &&
      other.joinUrl == joinUrl &&
      other.canTellLate == canTellLate;

  @override
  int get hashCode => Object.hash(accountId, eventId, calendarId, start, end,
      title, body, joinUrl, canTellLate);
}

const _calendarDay = 'myemail-calendar:';

/// A notification's payload that opens the calendar on [day]: the morning
/// agenda's.
String calendarDayPayload(DateTime day) =>
    '$_calendarDay${day.year}-${day.month}-${day.day}';

/// The day in a [calendarDayPayload]; null for anything else.
DateTime? calendarDayOf(String? payload) {
  if (payload == null || !payload.startsWith(_calendarDay)) return null;
  final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$')
      .firstMatch(payload.substring(_calendarDay.length));
  if (m == null) return null;
  return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// The notification id of [event]'s reminder: the same for the same
/// occurrence at the same time.
int meetingReminderId(CalendarEvent event) =>
    'meeting:${meetingKey(event)}'.hashCode & 0x7fffffff;

/// What a meeting's reminder says under its title: when, and where.
String reminderBody(CalendarEvent e, {required bool use24h}) => [
      '${formatClock(e.start, use24h: use24h)}–'
          '${formatClock(e.end, use24h: use24h)}',
      if (e.location.trim().isNotEmpty)
        e.location.trim()
      else if (e.joinUrl != null)
        'Online',
    ].join(' · ');

/// A meeting's reminder, as MyEmail sets it with Android.
@immutable
class MeetingReminder {
  const MeetingReminder({
    required this.id,
    required this.at,
    required this.meeting,
  });

  final int id;

  /// When it goes off.
  final DateTime at;

  /// The meeting, with what the reminder says and which buttons it has.
  final MeetingRef meeting;

  bool get canJoin => meeting.joinUrl != null;
  bool get canTellLate => meeting.canTellLate;
}

/// The reminders to set at [now] for [events]: each meeting's own, its
/// calendar's minutes before it begins, for those beginning within
/// [ahead]. One whose time has passed while its meeting has not begun is
/// in the list too, with its time as it was: the caller sets it for now,
/// unless it went off already.
///
/// [ownEmails] is each account's address, by account id, to know whether
/// there is anyone else on a meeting for Running late to tell.
List<MeetingReminder> meetingRemindersFor(
  Iterable<CalendarEvent> events, {
  required DateTime now,
  required bool use24h,
  Map<String, String> ownEmails = const {},
  Duration ahead = const Duration(hours: 26),
}) {
  final found = <MeetingReminder>[];
  final seen = <int>{};
  for (final e in events) {
    final minutes = e.reminderMinutes;
    if (minutes == null || minutes < 0 || !_timedAndOn(e)) continue;
    if (!e.start.isAfter(now) || e.start.difference(now) > ahead) continue;
    final id = meetingReminderId(e);
    if (!seen.add(id)) continue;
    final own = (ownEmails[e.accountId] ?? '').trim().toLowerCase();
    final organiser = e.organizer?.email.trim().toLowerCase();
    final anyoneToTell = isOwnEvent(e)
        ? everyoneOn(e, own).isNotEmpty
        : organiser != null && organiser != own;
    found.add(MeetingReminder(
      id: id,
      at: e.start.subtract(Duration(minutes: minutes)),
      meeting: MeetingRef.of(
        e,
        body: reminderBody(e, use24h: use24h),
        canTellLate: anyoneToTell,
      ),
    ));
  }
  found.sort((a, b) => a.at.compareTo(b.at));
  return found;
}

/// How long Snooze puts a meeting's reminder off.
const snoozeFor = Duration(minutes: 5);

/// When a reminder snoozed at [now] goes off again: [snoozeFor] on, or as
/// [meeting] begins if that is sooner. Null once the meeting is over, or
/// would be by then.
DateTime? snoozedUntil(MeetingRef meeting, DateTime now) {
  var at = now.add(snoozeFor);
  if (meeting.start.isAfter(now) && meeting.start.isBefore(at)) {
    at = meeting.start;
  }
  return at.isBefore(meeting.end) ? at : null;
}

/// The morning's agenda: when it goes, and what it says.
@immutable
class MorningAgenda {
  const MorningAgenda({
    required this.day,
    required this.at,
    required this.title,
    required this.body,
    required this.lines,
  });

  /// The day it is about, at midnight.
  final DateTime day;
  final DateTime at;
  final String title;
  final String body;

  /// A line for each meeting, then each whole day, for the expanded row.
  final List<String> lines;
}

/// The next working morning after [now], at [minutes] past midnight, on a
/// day of [workWeek].
DateTime nextAgendaTime(DateTime now, int minutes, Set<int> workWeek) {
  final days = workWeek.isEmpty ? defaultWorkWeek : workWeek;
  for (var i = 0; i < 8; i++) {
    final at = DateTime(
        now.year, now.month, now.day + i, minutes ~/ 60, minutes % 60);
    if (days.contains(at.weekday) && at.isAfter(now)) return at;
  }
  return DateTime(now.year, now.month, now.day + 1, minutes ~/ 60,
      minutes % 60);
}

/// The agenda for the next working morning after [now], at [minutes] past
/// midnight: how many meetings that day, and when the first begins. Null
/// for a day with no meeting at a time, which stays quiet.
MorningAgenda? morningAgendaFor(
  Iterable<CalendarEvent> events, {
  required DateTime now,
  required int minutes,
  required Set<int> workWeek,
  required bool use24h,
}) {
  final at = nextAgendaTime(now, minutes, workWeek);
  final day = DateTime(at.year, at.month, at.day);
  final next = DateTime(day.year, day.month, day.day + 1);
  final seen = <String>{};
  final timed = [
    for (final e in events)
      if (_timedAndOn(e) &&
          !e.start.isBefore(day) &&
          e.start.isBefore(next) &&
          seen.add(meetingKey(e)))
        e,
  ]..sort((a, b) => a.start.compareTo(b.start));
  if (timed.isEmpty) return null;
  final wholeDays = [
    for (final e in events)
      if (e.allDay &&
          !e.cancelled &&
          !e.declined &&
          e.start.isBefore(next) &&
          e.end.isAfter(day) &&
          seen.add(meetingKey(e)))
        e,
  ];
  String clock(DateTime t) => formatClock(t, use24h: use24h);
  final first = timed.first;
  return MorningAgenda(
    day: day,
    at: at,
    title: timed.length == 1
        ? '1 meeting today'
        : '${timed.length} meetings today',
    body: 'The first at ${clock(first.start)}: ${_titleOf(first)}',
    lines: [
      for (final e in timed) '${clock(e.start)}  ${_titleOf(e)}',
      for (final e in wholeDays) 'All day  ${_titleOf(e)}',
    ],
  );
}

/// What the calendar widget lists at [now]: today's and tomorrow's
/// meetings not over yet, whole days among them, earliest first.
/// [showDeclined] keeps those turned down, as the calendar shows them.
List<CalendarEvent> widgetMeetings(
  Iterable<CalendarEvent> events,
  DateTime now, {
  bool showDeclined = false,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final dayAfter = DateTime(today.year, today.month, today.day + 2);
  final seen = <String>{};
  return [
    for (final e in events)
      if (!e.cancelled &&
          (showDeclined || !e.declined) &&
          e.end.isAfter(now) &&
          e.start.isBefore(dayAfter) &&
          seen.add(meetingKey(e)))
        e,
  ]..sort((a, b) {
      // A whole day first on its day, as the calendar lists it.
      if (a.allDay != b.allDay && _sameDay(a.start, b.start)) {
        return a.allDay ? -1 : 1;
      }
      return a.start.compareTo(b.start);
    });
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
