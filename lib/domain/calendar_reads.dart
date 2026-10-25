import 'package:flutter/foundation.dart';

import 'calendar_event.dart';

/// One stretch of one calendar as it was read at [readAt]: what the
/// device keeps of a calendar is a run of these, each event in it as that
/// read found it. See `CacheStore.keepCalendar`.
@immutable
class CalendarRead {
  const CalendarRead({
    this.calendarId = CalendarEvent.mainCalendar,
    required this.start,
    required this.end,
    required this.readAt,
  });

  final String calendarId;
  final DateTime start;
  final DateTime end;
  final DateTime readAt;

  bool overlaps(DateTime from, DateTime to) =>
      start.isBefore(to) && from.isBefore(end);

  @override
  bool operator ==(Object other) =>
      other is CalendarRead &&
      other.calendarId == calendarId &&
      other.start == start &&
      other.end == end &&
      other.readAt == readAt;

  @override
  int get hashCode => Object.hash(calendarId, start, end, readAt);

  @override
  String toString() => 'CalendarRead($calendarId, $start–$end at $readAt)';
}

/// What the device keeps of a calendar over a stretch: its events, and when
/// that stretch was read, the oldest part's time where it was read in
/// parts, or null where some of it never was.
typedef KeptCalendar = ({List<CalendarEvent> events, DateTime? readAt});

/// Nothing kept.
const KeptCalendar nothingKept = (events: <CalendarEvent>[], readAt: null);

/// Whether [read] is older than what [reads] already hold for any of the
/// same stretch of the same calendar: an answer that took longer than one
/// asked for after it, which must not undo the newer one.
bool readIsStale(List<CalendarRead> reads, CalendarRead read) => reads.any(
      (r) =>
          r.calendarId == read.calendarId &&
          r.overlaps(read.start, read.end) &&
          r.readAt.isAfter(read.readAt),
    );

/// [reads] with [read] among them: over its stretch it is what counts, and
/// an older read keeps only what lies outside it. Other calendars' reads
/// are left as they are. In order of where each starts.
List<CalendarRead> withRead(List<CalendarRead> reads, CalendarRead read) {
  final out = <CalendarRead>[];
  for (final r in reads) {
    if (r.calendarId != read.calendarId || !r.overlaps(read.start, read.end)) {
      out.add(r);
      continue;
    }
    if (r.start.isBefore(read.start)) {
      out.add(CalendarRead(
        calendarId: r.calendarId,
        start: r.start,
        end: read.start,
        readAt: r.readAt,
      ));
    }
    if (read.end.isBefore(r.end)) {
      out.add(CalendarRead(
        calendarId: r.calendarId,
        start: read.end,
        end: r.end,
        readAt: r.readAt,
      ));
    }
  }
  out.add(read);
  out.sort((a, b) {
    final byCalendar = a.calendarId.compareTo(b.calendarId);
    return byCalendar != 0 ? byCalendar : a.start.compareTo(b.start);
  });
  return out;
}

/// When all of [start]..[end] of [calendarId] was last read: the oldest
/// part's time, where [reads] cover it end to end, and null where they
/// leave any of it out.
DateTime? readAtOver(
  List<CalendarRead> reads,
  DateTime start,
  DateTime end, {
  String calendarId = CalendarEvent.mainCalendar,
}) {
  final over = [
    for (final r in reads)
      if (r.calendarId == calendarId && r.overlaps(start, end)) r,
  ]..sort((a, b) => a.start.compareTo(b.start));
  var reached = start;
  DateTime? oldest;
  for (final r in over) {
    if (r.start.isAfter(reached)) return null;
    if (r.end.isAfter(reached)) reached = r.end;
    if (oldest == null || r.readAt.isBefore(oldest)) oldest = r.readAt;
  }
  return reached.isBefore(end) ? null : oldest;
}

/// Whether [event] is one a read of [start]..[end] answers for: anything
/// of it falls in the stretch, as `CalendarEvent.fallsOn` counts a day.
bool eventIsIn(CalendarEvent event, DateTime start, DateTime end) =>
    event.start.isBefore(end) &&
    (event.end.isAfter(start) ||
        (event.end == event.start && !event.start.isBefore(start)));

/// How far back the device keeps a calendar: a little over a year, past
/// which events and reads are let go as each read is kept.
const keptCalendarBack = Duration(days: 400);
