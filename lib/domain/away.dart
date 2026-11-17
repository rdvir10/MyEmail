import 'calendar_change.dart' show everyoneOn, isOwnEvent;
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
/// account id; [alsoMine], every address of Ron's (an account without a
/// calendar here too): one of his own meetings with nobody on it but him
/// is an appointment, and a cancellation would tell only himself.
/// Earliest first.
({List<CalendarEvent> invited, List<CalendarEvent> own}) awayMeetings(
  Iterable<CalendarEvent> events, {
  required DateTime first,
  required DateTime last,
  required DateTime now,
  required Map<String, String> ownEmails,
  Iterable<String> alsoMine = const [],
}) {
  final mine = {
    for (final m in [...ownEmails.values, ...alsoMine]) m.trim().toLowerCase(),
  };
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
      if (everyoneOn(e, email)
          .any((a) => !mine.contains(a.email.trim().toLowerCase()))) {
        own.add(e);
      }
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

/// Why [event], an invitation listed by [awayMeetings], starts unticked,
/// each reason as its row says it; none where it starts ticked. A decline
/// writes to its organiser, so one that may not want one waits for Ron:
/// - one of his own addresses ([ownEmails], every account's) organised
///   it: the same meeting on another of his accounts, which a decline
///   would tell only himself;
/// - its account is [hidden] in the calendar's Calendars shown;
/// - it is shown as free: a notice more than a meeting (a colleague's
///   out-of-office, an office closed), probably for information;
/// - it began before [first], the first day away: a meeting from the
///   evening before, a week-long notice already running.
List<String> awayHeldBack(
  CalendarEvent event, {
  required Iterable<String> ownEmails,
  DateTime? first,
  bool hidden = false,
}) {
  final organiser = event.organizer?.email.trim().toLowerCase();
  return [
    if (organiser != null &&
        ownEmails.any((e) => e.trim().toLowerCase() == organiser))
      'You organised it, from ${event.organizer!.email}',
    if (hidden) 'Hidden in the calendar',
    if (event.showAs == EventShowAs.free)
      'Shown as free: probably for information',
    if (first != null &&
        event.start.isBefore(DateTime(first.year, first.month, first.day)))
      'Began before your first day away',
  ];
}

/// Whether [event], listed by [awayMeetings], starts ticked: one Ron was
/// invited to, unless [awayHeldBack] gives a reason; his own meetings
/// never.
bool awayStartsTicked(
  CalendarEvent event,
  Iterable<String> ownEmails, {
  DateTime? first,
  bool hidden = false,
}) =>
    !isOwnEvent(event) &&
    awayHeldBack(event, ownEmails: ownEmails, first: first, hidden: hidden)
        .isEmpty;

/// [invited] as meetings: one meeting on two or more of Ron's accounts (an
/// organiser who invited each, or a meeting sent on from one to the
/// other) is one, known by its title (its letter case and spaces aside),
/// its start and its organiser, as the reminders know one meeting on two
/// calendars. Its organiser is to get one decline: [AwayMeeting.first], on
/// the account first in [accountOrder], is declined as Ron chooses, and
/// each of [AwayMeeting.copies] without a word. In [invited]'s order.
List<AwayMeeting> awaySameMeetings(
  List<CalendarEvent> invited,
  List<String> accountOrder,
) {
  String keyOf(CalendarEvent e) => [
        e.title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' '),
        e.start.toUtc().toIso8601String(),
        e.organizer?.email.trim().toLowerCase() ?? '',
      ].join('\u0000');
  int order(CalendarEvent e) {
    final at = accountOrder.indexOf(e.accountId);
    return at < 0 ? accountOrder.length : at;
  }

  final groups = <String, List<CalendarEvent>>{};
  for (final e in invited) {
    groups.putIfAbsent(keyOf(e), () => []).add(e);
  }
  final meetings = <AwayMeeting>[];
  for (final group in groups.values) {
    final byAccount = <String, CalendarEvent>{};
    for (final e in group) {
      if (byAccount.containsKey(e.accountId)) {
        // A second on the same account is a meeting of its own.
        meetings.add((first: e, copies: const <CalendarEvent>[]));
      } else {
        byAccount[e.accountId] = e;
      }
    }
    final copies = byAccount.values.toList()
      ..sort((a, b) => order(a).compareTo(order(b)));
    meetings.add((first: copies.first, copies: copies.skip(1).toList()));
  }
  // Where [invited] has the first of each.
  int at(AwayMeeting m) => [
        for (final e in [m.first, ...m.copies]) invited.indexOf(e),
      ].reduce((a, b) => a < b ? a : b);
  return meetings..sort((a, b) => at(a).compareTo(at(b)));
}

/// One meeting Ron was invited to: [first], declined as he chooses, and
/// the same meeting on his other accounts, declined without a word.
typedef AwayMeeting = ({CalendarEvent first, List<CalendarEvent> copies});

/// The last day Away takes from [first]: three months on, a day short.
/// A longer absence is more than a calendar's read gives whole, and more
/// than one look at a list can check.
DateTime awayLastAllowed(DateTime first) {
  // The same day three months on, or that month's last where it is short
  // (30 November: 28 February), then a day back.
  final month = DateTime(first.year, first.month + 3);
  final days = DateTime(month.year, month.month + 1, 0).day;
  return DateTime(
      month.year, month.month, (first.day < days ? first.day : days) - 1);
}

/// The out-of-office event on [accountId]'s main calendar among [events]
/// that already covers every day from [first] to [last]: one made by Away
/// before, or by hand. Google keeps only busy or free, so Away's own block
/// comes back from it busy: an all-day event titled as Away titles it
/// ([awayTitle]), with nobody on it, counts too. Null where there is none,
/// and the days are blocked there only if Ron ticks it.
CalendarEvent? awayBlockOn(
  Iterable<CalendarEvent> events,
  String accountId, {
  required DateTime first,
  required DateTime last,
}) {
  final from = DateTime(first.year, first.month, first.day);
  final to = _dayAfter(last);
  for (final e in events) {
    final awaysOwn = e.allDay &&
        e.attendees.isEmpty &&
        e.title.trim().toLowerCase() == awayTitle.toLowerCase();
    if (e.accountId == accountId &&
        e.calendarId == CalendarEvent.mainCalendar &&
        (e.showAs == EventShowAs.outOfOffice || awaysOwn) &&
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
