import 'package:flutter/foundation.dart';

@immutable
class MailAddress {
  const MailAddress({required this.email, this.name});

  final String email;
  final String? name;

  /// The name if there is one, otherwise the address.
  String get display {
    final n = name?.trim();
    return (n == null || n.isEmpty) ? email : n;
  }

  @override
  bool operator ==(Object other) =>
      other is MailAddress && other.email == email && other.name == name;

  @override
  int get hashCode => Object.hash(email, name);

  @override
  String toString() => name == null ? email : '$name <$email>';
}

/// A message's Reply-To, less the case where it only repeats the sender.
///
/// Empty means "reply to From". An IMAP server's ENVELOPE fills Reply-To in
/// with From when the header is absent, so without this every message would
/// carry its sender twice.
List<MailAddress> replyToBesidesSender(
  List<MailAddress> replyTo,
  MailAddress from,
) {
  final named = [
    for (final a in replyTo)
      if (a.email.trim().isNotEmpty) a,
  ];
  if (named.length == 1 &&
      named.first.email.toLowerCase() == from.email.toLowerCase()) {
    return const [];
  }
  return named;
}

/// A message as it appears in a list: headers and a preview, no body.
///
/// Identity is `<folderId>#<uid>`. IMAP UIDs are only unique within a folder
/// (and only for one UIDVALIDITY, which milestone 3 handles in the cache),
/// so the folder is part of the id.
@immutable
class MailMessage {
  const MailMessage({
    required this.id,
    required this.accountId,
    required this.folderId,
    required this.uid,
    required this.subject,
    required this.from,
    required this.to,
    required this.date,
    required this.preview,
    this.arrived,
    this.cc = const [],
    this.replyTo = const [],
    this.isRead = false,
    this.isFlagged = false,
    this.hasAttachments = false,
    this.attachmentBytes = 0,
    this.isMeeting = false,
    this.isAnswered = false,
    this.isForwarded = false,
    this.messageId,
    this.inReplyTo,
    this.conversationId,
  });

  static String idFor(String folderId, int uid) => '$folderId#$uid';

  final String id;
  final String accountId;
  final String folderId;
  final int uid;
  final String subject;
  final MailAddress from;
  final List<MailAddress> to;

  /// Everyone else it went to openly.
  ///
  /// Worth as much as [to] on a work mailbox: a message addressed to two
  /// people and copied to five is a message five people are watching, and
  /// a header that shows only the two is describing a different message.
  /// Bcc is deliberately absent — it is not in what arrives.
  final List<MailAddress> cc;

  /// Where the sender asked for replies to go, when that is not [from]:
  /// a ticket address behind a no-reply sender, a list, a form. Empty when
  /// the header was absent or named only the sender, and on anything cached
  /// before it was read.
  final List<MailAddress> replyTo;
  final DateTime date;

  /// When the server took it in, where that is not [date].
  ///
  /// [date] is what the sender's Date header says, which a message sent
  /// offline or through a slow relay can put hours before it arrived, and a
  /// wrong clock can put in the future. Gmail's arrival time is kept here;
  /// Microsoft's [date] is already the arrival, so this is null there, and
  /// on anything cached before it was read.
  final DateTime? arrived;

  /// The first line or so of the body, for the list.
  final String preview;
  final bool isRead;
  final bool isFlagged;
  final bool hasAttachments;

  /// An invitation, a change to one, or a cancellation.
  ///
  /// Known from the header alone, which is what lets the list say so before
  /// anything is opened. Over IMAP the structure the header fetch already
  /// asks for names a `text/calendar` part; Microsoft types the message as
  /// a meeting request outright. Neither costs a request.
  final bool isMeeting;

  /// Whether it has been replied to, and whether it has been forwarded.
  ///
  /// Kept on the server, so a reply made in another mail app that marks it
  /// shows here too. IMAP keeps the two apart, as `\Answered` and the
  /// `$Forwarded` keyword, and a message can carry both. Exchange keeps only
  /// what was done to a message last, so on a Microsoft account it is one or
  /// the other.
  final bool isAnswered;
  final bool isForwarded;

  /// What the files on it add up to, or 0 where the server did not say.
  ///
  /// Free over IMAP: the structure the header fetch already asks for
  /// carries a size per part. Microsoft sends no size with a list row, so
  /// this is 0 there unless the sizes were asked for separately.
  final int attachmentBytes;

  /// This message's own `Message-ID`, and the id of the one it answers.
  /// Both are what conversation grouping chains on. Either can be null: the
  /// headers are optional in practice, and anything cached before threading
  /// existed has neither, which is why grouping also falls back to subject.
  final String? messageId;
  final String? inReplyTo;

  /// The conversation the server keeps this in, where it keeps one:
  /// Exchange puts one on every message, and it is what Outlook groups by.
  /// Null on an IMAP account, and on a Microsoft row cached before it was
  /// kept. Grouping trusts it over the subject: two unrelated messages
  /// called "SEO" are two conversations there, and were one here.
  final String? conversationId;

  /// Every field is carried across. Cc, the attachment size and the meeting
  /// flag used to be left behind, so a message that had just been marked
  /// read lost its Cc line, and Reply all from it left those people out.
  MailMessage copyWith({
    bool? isRead,
    bool? isFlagged,
    bool? isAnswered,
    bool? isForwarded,
  }) {
    return MailMessage(
      id: id,
      accountId: accountId,
      folderId: folderId,
      uid: uid,
      subject: subject,
      from: from,
      to: to,
      cc: cc,
      replyTo: replyTo,
      date: date,
      arrived: arrived,
      preview: preview,
      isRead: isRead ?? this.isRead,
      isFlagged: isFlagged ?? this.isFlagged,
      hasAttachments: hasAttachments,
      attachmentBytes: attachmentBytes,
      isMeeting: isMeeting,
      isAnswered: isAnswered ?? this.isAnswered,
      isForwarded: isForwarded ?? this.isForwarded,
      messageId: messageId,
      inReplyTo: inReplyTo,
      conversationId: conversationId,
    );
  }

  /// Equal when it is the same message in the same state.
  ///
  /// The id alone is not enough, however natural that looks. Riverpod skips
  /// notifying listeners when a provider's new value equals the old one, so a
  /// provider that hands out a message would go silent the moment the only
  /// thing that changed was a flag: the reading pane and the ribbon would
  /// keep showing "mark as read" for a message that had just been read.
  ///
  /// Every field is compared, not just the flags. A UID's headers are fixed
  /// on the server, but not on this device: a draft edited elsewhere comes
  /// back under the same Microsoft id with a new subject and preview, and a
  /// cached row can be filled in later (a preview, an attachment size). The
  /// list keeps its old copy when a refresh compares equal, so comparing the
  /// flags alone kept the old subject on screen until a restart.
  @override
  bool operator ==(Object other) =>
      other is MailMessage &&
      other.id == id &&
      other.isRead == isRead &&
      other.isFlagged == isFlagged &&
      other.accountId == accountId &&
      other.folderId == folderId &&
      other.uid == uid &&
      other.subject == subject &&
      other.from == from &&
      listEquals(other.to, to) &&
      listEquals(other.cc, cc) &&
      listEquals(other.replyTo, replyTo) &&
      other.date == date &&
      other.arrived == arrived &&
      other.preview == preview &&
      other.hasAttachments == hasAttachments &&
      other.attachmentBytes == attachmentBytes &&
      other.isMeeting == isMeeting &&
      other.isAnswered == isAnswered &&
      other.isForwarded == isForwarded &&
      other.messageId == messageId &&
      other.inReplyTo == inReplyTo &&
      other.conversationId == conversationId;

  /// The id and the flags only: enough to spread messages out, and equal
  /// messages still hash alike.
  @override
  int get hashCode => Object.hash(id, isRead, isFlagged);

  @override
  String toString() => 'MailMessage($id, "$subject")';
}

/// The body of one message, fetched on demand when it is opened.
///
/// [html] is rendered in the sandboxed WebView on Android; [text] is the
/// plain-text alternative, or a text rendering of the HTML when the sender
/// supplied none, and is what the browser preview shows.
@immutable
class MailBody {
  const MailBody({required this.text, this.html, this.calendar});

  final String text;
  final String? html;

  /// The `text/calendar` part, when the message carries an invitation:
  /// iCalendar text, parsed by `CalendarInvite.parse` where it is shown.
  final String? calendar;
}
