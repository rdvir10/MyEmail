import 'calendar_event.dart';
import 'meeting_alerts.dart' show nextMeetingLead;

/// Where a meeting stands at a moment, as its sheet says it (calendar idea
/// #93): whether it is near enough that Join is the button to press, and
/// how long until it starts.

/// Whether [event] is near at [now]: from [nextMeetingLead] before it
/// begins until it ends, the window in which the bar over the mail shows
/// it with its Join. A meeting with a time of its own that is still on, as
/// the bar has it: not a whole day or one that lasts a day or more, not
/// cancelled, not declined.
bool meetingIsNear(CalendarEvent event, DateTime now) =>
    !event.inAllDayRow &&
    !event.cancelled &&
    !event.declined &&
    !now.isBefore(event.start.subtract(nextMeetingLead)) &&
    now.isBefore(event.end);

/// How long until [event] starts, seen from [now], as its sheet says it
/// on a line of its own under the time, so with a capital: "In 2 h 10
/// min", "In 12 min" (the words and the rounding of the bar over the mail,
/// a part of a minute counted as one), or "Now" while it is on, as the
/// Agenda's row says it; and as a screen reader says it, in words: "Starts
/// in 2 hours 10 minutes", "On now".
///
/// Null for a meeting starting on another day than [now]'s, a whole day or
/// one that lasts a day or more, one cancelled, and once it is over.
({String shown, String spoken})? timeToStart(
  CalendarEvent event,
  DateTime now,
) {
  if (event.inAllDayRow || event.cancelled || !event.end.isAfter(now)) {
    return null;
  }
  if (!event.start.isAfter(now)) return (shown: 'Now', spoken: 'On now');
  final start = event.start;
  if (start.year != now.year ||
      start.month != now.month ||
      start.day != now.day) {
    return null;
  }
  final left = (start.difference(now).inSeconds / 60).ceil();
  final minutes = left < 1 ? 1 : left;
  final h = minutes ~/ 60, m = minutes % 60;
  String count(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
  final shown = [if (h > 0) '$h h', if (m > 0) '$m min'];
  final spoken = [
    if (h > 0) count(h, 'hour'),
    if (m > 0) count(m, 'minute'),
  ];
  return (
    shown: 'In ${shown.join(' ')}',
    spoken: 'Starts in ${spoken.join(' ')}',
  );
}
