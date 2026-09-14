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
    this.isRead = false,
    this.isFlagged = false,
    this.hasAttachments = false,
  });

  static String idFor(String folderId, int uid) => '$folderId#$uid';

  final String id;
  final String accountId;
  final String folderId;
  final int uid;
  final String subject;
  final MailAddress from;
  final List<MailAddress> to;
  final DateTime date;

  /// The first line or so of the body, for the list.
  final String preview;
  final bool isRead;
  final bool isFlagged;
  final bool hasAttachments;

  MailMessage copyWith({bool? isRead, bool? isFlagged}) {
    return MailMessage(
      id: id,
      accountId: accountId,
      folderId: folderId,
      uid: uid,
      subject: subject,
      from: from,
      to: to,
      date: date,
      preview: preview,
      isRead: isRead ?? this.isRead,
      isFlagged: isFlagged ?? this.isFlagged,
      hasAttachments: hasAttachments,
    );
  }

  @override
  bool operator ==(Object other) => other is MailMessage && other.id == id;

  @override
  int get hashCode => id.hashCode;

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
  const MailBody({required this.text, this.html});

  final String text;
  final String? html;
}
