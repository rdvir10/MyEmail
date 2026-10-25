import 'calendar_event.dart';

/// Finding in the calendar: a search through it (#36), the meetings with
/// someone (#37), and what else is on while an invitation's meeting would
/// be (#34). From the events the calendars hold a year either side of
/// today, which the device keeps.

/// The stretch the calendar is searched over: a year back from [now] and a
/// year ahead.
({DateTime start, DateTime end}) searchSpan(DateTime now) => (
      start: DateTime(now.year - 1, now.month, now.day),
      end: DateTime(now.year + 1, now.month, now.day + 1),
    );

/// Everything about [event] a search looks in: its title, place, notes,
/// organiser and people, by name and address.
String _haystack(CalendarEvent e) => [
      e.title,
      e.location,
      e.preview,
      if (e.organizer case final o?) ...[o.name ?? '', o.email],
      for (final a in e.attendees) ...[a.address.name ?? '', a.address.email],
      ...e.categories,
    ].join('\n').toLowerCase();

/// Whether [event] answers [query]: every word of it somewhere in the
/// event, whatever the case. An empty query answers nothing.
bool eventMatches(CalendarEvent event, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((w) => w.isEmpty);
  if (words.isEmpty) return false;
  final hay = _haystack(event);
  return words.every(hay.contains);
}

/// [events] that answer [query]: those still to come, soonest first, and
/// those gone by, the latest first. Each once, however many reads it was in.
({List<CalendarEvent> coming, List<CalendarEvent> past}) searchEvents(
  Iterable<CalendarEvent> events,
  String query,
  DateTime now,
) {
  final seen = <String>{};
  final coming = <CalendarEvent>[];
  final past = <CalendarEvent>[];
  for (final e in events) {
    if (!eventMatches(e, query)) continue;
    if (!seen.add('${e.accountId}|${e.calendarId}|${e.id}|${e.start}')) continue;
    (e.end.isAfter(now) ? coming : past).add(e);
  }
  coming.sort((a, b) => a.start.compareTo(b.start));
  past.sort((a, b) => b.start.compareTo(a.start));
  return (coming: coming, past: past);
}

/// Whether the person at [email] is on [event]: its organiser, or invited.
bool isWith(CalendarEvent event, String email) {
  final who = email.trim().toLowerCase();
  if (who.isEmpty) return false;
  if (event.organizer?.email.trim().toLowerCase() == who) return true;
  return event.attendees
      .any((a) => a.address.email.trim().toLowerCase() == who);
}

/// The next meeting with the person at [email] after [now], and the last
/// before it: what their card says. Declined and cancelled ones are not
/// meetings with them.
({CalendarEvent? next, CalendarEvent? last}) meetingsWith(
  Iterable<CalendarEvent> events,
  String email,
  DateTime now,
) {
  CalendarEvent? next;
  CalendarEvent? last;
  for (final e in events) {
    if (e.cancelled || e.declined || !isWith(e, email)) continue;
    if (e.start.isAfter(now)) {
      if (next == null || e.start.isBefore(next.start)) next = e;
    } else if (last == null || e.start.isAfter(last.start)) {
      last = e;
    }
  }
  return (next: next, last: last);
}

/// What else is on while a meeting from [start] to [end] would be: timed,
/// not declined, cancelled or shown as free, and not that meeting itself,
/// already on the calendar as an invitation not answered ([title] at the
/// same time). Earliest first.
List<CalendarEvent> clashesWith(
  Iterable<CalendarEvent> events,
  DateTime start,
  DateTime end, {
  String title = '',
}) {
  final same = title.trim().toLowerCase();
  final seen = <String>{};
  return [
    for (final e in events)
      if (!e.allDay &&
          !e.cancelled &&
          !e.declined &&
          e.showAs != EventShowAs.free &&
          e.start.isBefore(end) &&
          e.end.isAfter(start) &&
          !(e.start == start &&
              e.end == end &&
              e.title.trim().toLowerCase() == same) &&
          seen.add('${e.accountId}|${e.id}|${e.start}'))
        e,
  ]..sort((a, b) => a.start.compareTo(b.start));
}
