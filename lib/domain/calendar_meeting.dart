import 'package:flutter/foundation.dart';

import 'calendar_invite.dart';

/// A meeting as the account's own calendar has it now: what a message about
/// it is checked against (an update, a cancellation, a new time proposed),
/// and what Remove from calendar and Accept proposal act on.
///
/// Read again each time the message is opened rather than kept: the
/// calendar is the record, and Outlook, the web and the server's own
/// processing of meeting mail all change it too.
@immutable
class CalendarMeeting {
  const CalendarMeeting({
    required this.accountId,
    required this.eventId,
    required this.start,
    this.end,
    this.isAllDay = false,
    this.isCancelled = false,
    this.isOrganizer = false,
    this.isSeries = false,
    this.timeZone,
  });

  /// Whose calendar it is on.
  final String accountId;

  /// The calendar's own id for it.
  final String eventId;

  /// UTC. For a whole day, the first day at midnight, and [end] the day
  /// after the last, as calendars count it.
  final DateTime start;
  final DateTime? end;
  final bool isAllDay;

  /// Cancelled by its organiser and still on the calendar: Outlook keeps one
  /// there, with "Canceled:" before its title, until it is removed.
  final bool isCancelled;

  /// Whether the account is the one that sent it out.
  final bool isOrganizer;

  /// The whole of a recurring series rather than one meeting of it.
  final bool isSeries;

  /// The zone the calendar keeps the times in, by the name it uses, where
  /// it says: given back with a new time, so the meeting keeps its zone.
  final String? timeZone;

  /// Whether this is at the time [invite] gives (for a new time proposed,
  /// the time proposed). Null where that cannot be said: an invitation
  /// whose time zone could not be worked out.
  bool? isAtTimeOf(CalendarInvite invite) {
    if (!invite.timeIsKnown) return null;
    if (invite.isAllDay != isAllDay) return false;
    final otherEnd = invite.end;
    if (isAllDay) {
      return _sameDay(start, invite.start) &&
          (end == null || otherEnd == null || _sameDay(end!, otherEnd));
    }
    return _sameMinute(start, invite.start) &&
        (end == null || otherEnd == null || _sameMinute(end!, otherEnd));
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static bool _sameMinute(DateTime a, DateTime b) =>
      a.toUtc().difference(b.toUtc()).inSeconds.abs() < 60;

  @override
  bool operator ==(Object other) =>
      other is CalendarMeeting &&
      other.accountId == accountId &&
      other.eventId == eventId &&
      other.start == start &&
      other.end == end &&
      other.isAllDay == isAllDay &&
      other.isCancelled == isCancelled &&
      other.isOrganizer == isOrganizer &&
      other.isSeries == isSeries &&
      other.timeZone == timeZone;

  @override
  int get hashCode => Object.hash(accountId, eventId, start, end, isAllDay,
      isCancelled, isOrganizer, isSeries, timeZone);

  @override
  String toString() => 'CalendarMeeting($eventId at $start'
      '${isCancelled ? ', cancelled' : ''}'
      '${isOrganizer ? ', organiser' : ''}'
      '${isSeries ? ', series' : ''})';
}

/// Of the meetings of a series, each paired with when a calendar says it was
/// set for, the one a message names by [at] (`CalendarInvite.recurrenceStart`),
/// or null where none is.
///
/// To the minute for a time. A whole day is a date with no zone, which a
/// calendar may give as midnight in any zone, so the closest within the
/// widest gap between zones, fourteen hours.
T? occurrenceAt<T>(Iterable<(DateTime, T)> occurrences, DateTime at) {
  final wholeDay = !at.isUtc &&
      at.hour == 0 &&
      at.minute == 0 &&
      at.second == 0 &&
      at.millisecond == 0;
  final target = wholeDay ? DateTime.utc(at.year, at.month, at.day) : at.toUtc();
  final tolerance =
      wholeDay ? const Duration(hours: 14) : const Duration(minutes: 1);
  T? best;
  Duration? bestGap;
  for (final (original, item) in occurrences) {
    final gap = original.toUtc().difference(target).abs();
    if (gap >= tolerance) continue;
    if (bestGap == null || gap < bestGap) {
      best = item;
      bestGap = gap;
    }
  }
  return best;
}
