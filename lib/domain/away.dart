import 'calendar_change.dart' show hasOthers, isOwnEvent;
import 'calendar_event.dart';
import 'meeting.dart';

/// I am away (calendar idea #53): the days blocked as out of office, and
/// the meetings in them declined or cancelled, as Ron ticks them on the
/// screen, and nothing of it before he has seen the list and pressed its
/// button. What is listed, what starts ticked, and what the button says.

/// The title of the all-day event that blocks the days, as Outlook names
/// its own.
const awayTitle = 'Out of office';

/// What Away does with one thing on its list.
enum AwayAction { block, decline, cancel }

/// Where one thing on the list has got to.
enum AwayState {
  /// Not done: waiting for the button, ticked or not.
  waiting,

  /// Being done now.
  going,

  /// Done: never done again.
  done,

  /// Refused, or no answer came; the reason beside it. Tried again only
  /// once the calendar has been read again and still has it as it was.
  failed,

  /// No longer on the calendar when it was tried, before anything was
  /// sent for it: declined, cancelled or deleted elsewhere. Nothing is.
  gone,

  /// Sent once, its answer lost on the way back, and no longer on the
  /// calendar when looked for again: it went. Not sent again.
  sentGone,
}

/// The day after [day], at midnight.
DateTime _dayAfter(DateTime day) => DateTime(day.year, day.month, day.day + 1);

/// The meetings to list for the days [first] to [last] (both, at
/// midnight): those someone else invited Ron to, which a decline answers,
/// and his own with others on them, which a cancellation tells. Each
/// meeting of a series that falls in the days is listed on its own, and
/// only it is ever answered or cancelled: never its series.
///
/// Left out: what is over by [now]; meetings already declined, or
/// cancelled by their organiser; appointments with nobody else on them,
/// an out-of-office block among them; anything on a calendar the account
/// only reads; and anything on a calendar beside an account's main one,
/// where a calendar shared with Ron to look after (a family's, a
/// manager's) has meetings that are its owner's to answer, and a decline
/// would go in their name. [ownEmails] is each account's own address, by
/// account id. Earliest first.
({List<CalendarEvent> invited, List<CalendarEvent> own}) awayMeetings(
  Iterable<CalendarEvent> events, {
  required DateTime first,
  required DateTime last,
  required DateTime now,
  required Map<String, String> ownEmails,
}) {
  final from = DateTime(first.year, first.month, first.day);
  final to = _dayAfter(last);
  final invited = <CalendarEvent>[];
  final own = <CalendarEvent>[];
  final seen = <String>{};
  for (final e in events) {
    final email = ownEmails[e.accountId];
    if (email == null) continue;
    if (e.readOnly || e.calendarId != CalendarEvent.mainCalendar) continue;
    // A series itself, never one of its meetings: nothing here touches it.
    if (e.seriesId != null && e.id == e.seriesId) continue;
    if (!e.start.isBefore(to) || !e.end.isAfter(from)) continue;
    if (!e.end.isAfter(now)) continue;
    if (e.cancelled || e.declined) continue;
    if (!seen.add(awayKey(e))) continue;
    if (isOwnEvent(e)) {
      if (hasOthers(e, email)) own.add(e);
    } else if (e.organizer != null) {
      invited.add(e);
    }
  }
  int byStart(CalendarEvent a, CalendarEvent b) {
    final at = a.start.compareTo(b.start);
    return at != 0 ? at : a.end.compareTo(b.end);
  }

  return (invited: invited..sort(byStart), own: own..sort(byStart));
}

/// One meeting on Away's list, by its account, calendar and id: a meeting
/// of a series by its own id, never the series'.
String awayKey(CalendarEvent e) =>
    '${e.accountId}\u0000${e.calendarId}\u0000${e.id}';

/// Whether [event], listed by [awayMeetings], starts ticked: one Ron was
/// invited to, unless one of his own addresses ([ownEmails]) organised it
/// (the same meeting on another of his accounts, which a decline would
/// tell only himself); his own meetings never.
bool awayStartsTicked(CalendarEvent event, Iterable<String> ownEmails) {
  if (isOwnEvent(event)) return false;
  final organiser = event.organizer?.email.trim().toLowerCase();
  return !ownEmails.any((e) => e.trim().toLowerCase() == organiser);
}

/// The out-of-office event on [accountId]'s main calendar among [events]
/// that already covers every day from [first] to [last]: one made by Away
/// before, or by hand. Null where there is none, and the days are blocked
/// there only if Ron ticks it.
CalendarEvent? awayBlockOn(
  Iterable<CalendarEvent> events,
  String accountId, {
  required DateTime first,
  required DateTime last,
}) {
  final from = DateTime(first.year, first.month, first.day);
  final to = _dayAfter(last);
  for (final e in events) {
    if (e.accountId == accountId &&
        e.calendarId == CalendarEvent.mainCalendar &&
        e.showAs == EventShowAs.outOfOffice &&
        !e.cancelled &&
        !e.start.isAfter(from) &&
        !e.end.isBefore(to)) {
      return e;
    }
  }
  return null;
}

/// The all-day event that blocks [first] to [last] on [accountId]'s main
/// calendar: shown as out of office, with nobody on it, so nobody is told,
/// and no reminder. [transactionId] is the same each time it is sent from
/// one screen, so a try whose answer was lost and a try again make one
/// event, not two. [timeZone] is the phone's, as New meeting sends it.
MeetingDraft awayBlock({
  required String accountId,
  required DateTime first,
  required DateTime last,
  required String transactionId,
  String? timeZone,
}) =>
    MeetingDraft(
      accountId: accountId,
      title: awayTitle,
      start: DateTime(first.year, first.month, first.day),
      end: DateTime(last.year, last.month, last.day),
      allDay: true,
      showAs: EventShowAs.outOfOffice,
      reminder: const Reminder.none(),
      timeZone: timeZone,
      transactionId: transactionId,
    );

/// What Away's button says it will do, in numbers: "Block the days,
/// decline 5, cancel 2". "Block on 2 calendars" where the days are
/// blocked on more than one. [again] after a press that left some not
/// done: "Try again: decline 2". Null where nothing is ticked.
String? awayButtonWords({
  required int blocks,
  required int declines,
  required int cancels,
  bool again = false,
}) {
  final parts = [
    if (blocks == 1) 'block the days',
    if (blocks > 1) 'block on $blocks calendars',
    if (declines > 0) 'decline $declines',
    if (cancels > 0) 'cancel $cancels',
  ];
  if (parts.isEmpty) return null;
  final words = parts.join(', ');
  return again
      ? 'Try again: $words'
      : '${words[0].toUpperCase()}${words.substring(1)}';
}
