import 'calendar_invite.dart';
import 'mail_message.dart';

/// Replies to your meetings filed away by themselves (calendar idea #52):
/// Settings, Calendar's choice, kept with the rest of the calendar's
/// settings. An Accepted, Maybe or Declined to a meeting you organised,
/// with nothing written in it, goes to Deleted Items as it arrives, with
/// no notification: the meeting's sheet counts the answers from the
/// calendar, and the message adds nothing. One with words in it stays.
enum ReplyFiling {
  /// Every reply stays in the Inbox, as before.
  off,

  /// Accepted, Maybe and Declined alike.
  all,

  /// Accepted and Maybe; a Declined stays in the Inbox, and is announced.
  keepDeclines,
}

/// Why [message], new in the Inbox of the account at [ownAddress], stays
/// there under [filing], in a few words for the pass's log and nothing of
/// the message's own; null where it is a reply to a meeting that account
/// organised with nothing written in it, to go to Deleted Items.
///
/// When in doubt, it stays: it must never file something Ron needed to
/// read. "Nothing written" is what the answering calendar wrote by itself,
/// and nothing else:
///
/// - Outlook and Exchange send an answer with an empty body (the words
///   are a space, or none), and put any note in the body and in the
///   calendar part's COMMENT.
/// - Google Calendar writes the whole message itself ("Dana Levi has
///   accepted this invitation.", then the meeting, then its own lines at
///   the foot), in the guest's language; the one thing the guest writes
///   is the note, which it puts on the guest's line in the calendar part
///   (X-RESPONSE-COMMENT), and on screen.
/// - MyEmail's own answer is one line ("… has accepted this invitation."),
///   with the note in a paragraph after it.
///
/// Anything else with words in it stays, whoever sent it. So does a new
/// time proposed (Outlook's COUNTER, or an answer whose subject says so,
/// or whose words do where Google wrote them),
/// an answer that is not one of the three, someone else's meeting, and a
/// reply read, flagged, marked important or with a file of its own.
/// Never throws: the calendar part is written by whoever answered.
String? whyReplyStays(
  MailMessage message,
  MailBody body, {
  required ReplyFiling filing,
  required String ownAddress,
}) {
  try {
    return _whyStays(message, body, filing, ownAddress);
  } catch (_) {
    return 'unreadable';
  }
}

String? _whyStays(
  MailMessage message,
  MailBody body,
  ReplyFiling filing,
  String ownAddress,
) {
  if (filing == ReplyFiling.off) return 'switched off';
  if (message.isRead) return 'read';
  if (message.isFlagged) return 'flagged';
  if (message.importance == Importance.high) return 'marked important';
  if (body.calendarPending) return 'calendar part not fetched';
  final reply = CalendarInvite.parse(body.calendar ?? '');
  if (reply == null) return 'no calendar part';
  if (!reply.isReply) return 'not an answer';
  final answer = reply.responderAnswer;
  if (answer == null) return 'an answer not one of the three';
  if (answer == InviteResponse.declined &&
      filing == ReplyFiling.keepDeclines) {
    return 'a decline, kept';
  }
  if (!_toYourMeeting(reply, message, ownAddress)) return 'not your meeting';
  if (reply.responderNote != null) return 'a note';
  if (_newTimeProposed.hasMatch(message.subject)) return 'a new time';
  if (message.hasAttachments &&
      (message.attachmentNames.isEmpty ||
          message.attachmentNames
              .any((n) => !n.toLowerCase().trim().endsWith('.ics')))) {
    return 'files attached';
  }
  if (_wordsWritten(body.text, reply)) return 'words written';
  return null;
}

/// A subject that says a new time is proposed, as Outlook's and Google's
/// do, for one sent as an answer rather than as a COUNTER.
final _newTimeProposed = RegExp(
  r'^\s*(new time proposed|proposed new time)',
  caseSensitive: false,
);

/// Whether [reply] is to a meeting the account at [own] organised: the
/// organiser its calendar part names, or where it names none, the message
/// addressed to the account. Addresses come in any case.
bool _toYourMeeting(CalendarInvite reply, MailMessage message, String own) {
  final me = own.trim().toLowerCase();
  if (me.isEmpty) return false;
  final organizer = reply.organizer?.email.trim().toLowerCase();
  if (organizer != null && organizer.isNotEmpty) return organizer == me;
  return message.to.any((a) => a.email.trim().toLowerCase() == me);
}

/// Whether [text], an answer's words, holds any its sender wrote: anything
/// at all, but for what the answering calendar writes by itself (see
/// [whyReplyStays]).
bool _wordsWritten(String text, CalendarInvite reply) {
  final words = text.replaceAll(_invisible, '').trim();
  if (words.isEmpty) return false;
  // Every word of Google's is its own, but for a new time it may say is
  // proposed; the guest's note is in the calendar part, looked at already.
  if (_isGoogleCalendar(reply.productId)) {
    return _proposes.hasMatch(words);
  }
  // MyEmail's own line, and nothing after it.
  return !_ownLine.hasMatch(words);
}

/// Characters that take no room: a zero-width space or joiner, a byte
/// order mark. An empty Outlook body is sometimes nothing but these.
final _invisible = RegExp('[​‌‍⁠﻿]');

final _proposes = RegExp(
  r'proposed a new time|new time proposed|proposed new time',
  caseSensitive: false,
);

bool _isGoogleCalendar(String? productId) =>
    productId != null &&
    productId.toLowerCase().contains('//google inc//google calendar');

/// "Dana Levi has tentatively accepted this invitation.", as MyEmail sends
/// an answer (see `InviteResponseWords.pastTense`): one line, whole.
final _ownLine = RegExp(
  r'^[^\n]{1,200} has (accepted|tentatively accepted|declined) this '
  r'invitation\.$',
);
