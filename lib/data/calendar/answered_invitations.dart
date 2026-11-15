import '../../domain/calendar_change.dart' show isOwnEvent;
import '../../domain/calendar_event.dart';
import '../../domain/calendar_invite.dart';
import '../../domain/calendar_meeting.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../mail_engine.dart';

/// A meeting answered in the calendar takes its invitation out of the Inbox
/// (#51), as "Delete invitations once answered" takes one answered from its
/// card. Only the meeting's own invitation goes, and only one the account's
/// calendar itself ties to the meeting answered: through the link Exchange
/// keeps from the message to the event, or the invitation's UID, which is
/// how the card finds its meeting too ([MailEngine.meetingOnCalendar]). The
/// same title from the same organiser is not enough: an invitation that is
/// less sure than that stays where it is.

/// How many of the Inbox's meeting mail with the meeting's title are looked
/// into, newest first. Each takes the invitation's calendar part and a
/// question to the calendar.
const _lookedInto = 5;

/// How far into the Inbox this device's own copy is looked through.
const _heldLookedThrough = 200;

/// Whether [invite], an invitation the calendar has as [meeting], is
/// [event]'s own: the one answering [event] answers, and with [wholeSeries]
/// answering every meeting of [event]'s series.
///
/// A series' invitation belongs to the whole series: one meeting of it
/// answered leaves it in the Inbox. One Outlook sent for one changed meeting
/// of a series belongs to that meeting alone, and goes only with it.
bool isInvitationTo(
  CalendarEvent event,
  CalendarInvite invite,
  CalendarMeeting meeting, {
  required bool wholeSeries,
}) {
  if (!invite.isRequest || meeting.accountId != event.accountId) return false;
  if (!wholeSeries) return meeting.eventId == event.id;
  final series = event.seriesId;
  return series != null &&
      invite.recurrenceId == null &&
      meeting.eventId == series;
}

/// The invitations to [event], just answered (with [wholeSeries], every
/// meeting of its series), in its account's Inbox, newest first: each one
/// its calendar ties to [event] (see [isInvitationTo]). Found as
/// [placedInvitations] finds them.
Future<List<MailMessage>> answeredInvitations(
  MailEngine engine,
  CalendarEvent event, {
  required bool wholeSeries,
}) async =>
    invitationsTo(
      event,
      await placedInvitations(engine, event),
      wholeSeries: wholeSeries,
    );

/// An invitation in the Inbox, and the meeting its calendar has for it.
typedef PlacedInvitation = ({
  MailMessage message,
  CalendarInvite invite,
  CalendarMeeting meeting,
});

/// Of [placed], the invitations to [event], answered (with [wholeSeries],
/// every meeting of its series): see [isInvitationTo].
List<MailMessage> invitationsTo(
  CalendarEvent event,
  Iterable<PlacedInvitation> placed, {
  required bool wholeSeries,
}) =>
    [
      for (final p in placed)
        if (isInvitationTo(event, p.invite, p.meeting,
            wholeSeries: wholeSeries))
          p.message,
    ];

/// The invitations in [event]'s account's Inbox that may be [event]'s, each
/// with the meeting its calendar has for it, newest first: the Inbox's
/// meeting mail with [event]'s title in its subject, as this device holds
/// it and as the server finds it, each read for its invitation and placed
/// on the calendar. Which is [event]'s own, [invitationsTo] says.
///
/// Placed while the calendar still has [event]: once a meeting is taken off
/// it, the calendar has nothing to place its invitation on.
///
/// Empty for a meeting with no title, or one of the account's own. A
/// message that cannot be read, or that the calendar cannot place, is
/// passed over; this throws only where the account's folders cannot be had
/// at all.
Future<List<PlacedInvitation>> placedInvitations(
  MailEngine engine,
  CalendarEvent event,
) async {
  final title = event.title.trim();
  if (title.isEmpty || isOwnEvent(event)) return const [];
  bool isInbox(MailFolder f) => f.role == FolderRole.inbox;
  var folders = await engine.cachedFolders(event.accountId);
  if (!folders.any(isInbox)) {
    folders = await engine.loadFolders(event.accountId);
  }
  final inbox = folders.where(isInbox).firstOrNull;
  if (inbox == null) return const [];

  // Asked at once, while what the device holds is placed: the server finds
  // one older than the device holds, and the device one just arrived,
  // which a server's search may not have taken in yet.
  final searched = engine
      .searchMessages(
        title,
        SearchScope.folder(inbox.id),
        field: SearchField.subject,
        limit: 20,
      )
      .catchError((Object _) => const <MailMessage>[]);
  List<MailMessage> held;
  try {
    held = await engine.cachedMessages(inbox.id, limit: _heldLookedThrough);
  } catch (_) {
    held = const [];
  }

  // Google writes the time after the title, "Invitation: Budget @ Tue 17
  // Nov"; Outlook's subject is the title alone.
  final wanted = title.toLowerCase();
  final seen = <String>{};
  final placed = <PlacedInvitation>[];
  var looked = 0;
  Future<void> place(List<MailMessage> messages) async {
    final candidates = [
      for (final m in messages)
        if (m.folderId == inbox.id &&
            m.isMeeting &&
            m.subject.toLowerCase().contains(wanted) &&
            seen.add(m.id))
          m,
    ]..sort((a, b) => b.date.compareTo(a.date));
    for (final m in candidates) {
      if (looked == _lookedInto) return;
      looked++;
      try {
        final part = (await engine.loadMessageBody(m.id)).calendar;
        final invite = part == null ? null : CalendarInvite.parse(part);
        if (invite == null || !invite.isRequest) continue;
        final meeting = await engine.meetingOnCalendar(m.id, invite);
        if (meeting != null) {
          placed.add((message: m, invite: invite, meeting: meeting));
        }
      } catch (_) {
        // Not read, or not placed: not sure, so it stays.
      }
    }
  }

  // What the device holds first, the likeliest: placed sooner, before a
  // meeting about to be taken off goes.
  await place(held);
  await place(await searched);
  return placed..sort((a, b) => b.message.date.compareTo(a.message.date));
}
