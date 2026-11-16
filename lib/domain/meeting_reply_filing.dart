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
/// read. It goes only where all of this holds:
///
/// - the calendar part is an answer (REPLY), Accepted, Maybe or Declined,
///   with one attendee in it, who is the message's sender: the one who
///   answered sent it, and nobody else's answer rides with it;
/// - it names its organiser, and that is the account;
/// - the subject is the answer's own, as the answering calendar writes
///   it: the part's title (Exchange writes "Accepted: Planning" in both),
///   or MyEmail's "Accepted: Planning" over a part titled "Planning";
///   a forward, a reply, anything else stays;
/// - no note anywhere in the part (a COMMENT with words, an attendee's
///   X-RESPONSE-COMMENT with anything in it);
/// - no word in the body: an Outlook answer sent as it was, with no note,
///   has none; MyEmail's own answer has its one line, and nothing after;
/// - no file but the invitation; not read, flagged or marked important.
///
/// Google Calendar's answers have words of Google's in every one, which
/// cannot be told from a guest's until a real one has been read from
/// Ron's own mail: they stay. (On a Microsoft account Exchange writes the
/// answer again in its own way first.) Never throws: the calendar part is
/// written by whoever answered.
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
  if (!_fromTheOneWhoAnswered(reply, message)) {
    return 'not from the one who answered';
  }
  if (!_toYourMeeting(reply, ownAddress)) return 'not your meeting';
  if (reply.responderNote != null || reply.attendeeNoted) return 'a note';
  if (!_answersOwnSubject(message.subject, reply, answer)) {
    return "a subject not the answer's";
  }
  if (message.hasAttachments &&
      (message.attachmentNames.isEmpty ||
          message.attachmentNames
              .any((n) => !n.toLowerCase().trim().endsWith('.ics')))) {
    return 'files attached';
  }
  if (_wordsWritten(body.text, reply)) return 'words written';
  return null;
}

/// Whether [reply] has one attendee, and that is who sent [message].
/// Addresses come in any case.
bool _fromTheOneWhoAnswered(CalendarInvite reply, MailMessage message) {
  if (reply.attendees.length != 1) return false;
  final sender = message.from.email.trim().toLowerCase();
  return sender.isNotEmpty &&
      reply.attendees.single.email.trim().toLowerCase() == sender;
}

/// Whether [reply] names the account at [own] as its organiser. One that
/// names none, which an answer must, stays.
bool _toYourMeeting(CalendarInvite reply, String own) {
  final me = own.trim().toLowerCase();
  final organizer = reply.organizer?.email.trim().toLowerCase() ?? '';
  return me.isNotEmpty && organizer == me;
}

/// Whether [subject] is the answer's own: the part's title, or, where
/// MyEmail wrote the part, its answer's word before the title, as
/// `inviteReplySubject` writes it. Spaces aside, letter for letter.
bool _answersOwnSubject(
  String subject,
  CalendarInvite reply,
  InviteResponse answer,
) {
  final said = _spaced(subject);
  if (said.isEmpty) return false;
  if (said == _spaced(reply.summary)) return true;
  return _isMyEmail(reply.productId) &&
      said == _spaced('${answer.word}: ${reply.summary}');
}

String _spaced(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Whether [text], an answer's words, holds any its sender wrote: any word
/// at all, but for MyEmail's own line where MyEmail wrote the part.
bool _wordsWritten(String text, CalendarInvite reply) {
  final words = text.replaceAll(_invisible, '').trim();
  if (words.isEmpty) return false;
  return !(_isMyEmail(reply.productId) && _ownLine.hasMatch(words));
}

/// Characters that take no room: a zero-width space or joiner, a byte
/// order mark. An empty Outlook body is sometimes nothing but these.
final _invisible = RegExp('[\u200b\u200c\u200d\u2060\ufeff]');

/// MyEmail's own answer, as `iMipReply` marks it.
bool _isMyEmail(String? productId) => productId == '-//MyEmail//EN';

/// "Dana Levi has tentatively accepted this invitation.", as MyEmail sends
/// an answer (see `InviteResponseWords.pastTense`): one line, whole.
final _ownLine = RegExp(
  r'^[^\n]{1,200} has (accepted|tentatively accepted|declined) this '
  r'invitation\.$',
);
