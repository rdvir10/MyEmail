import 'package:flutter/foundation.dart';

import 'mail_message.dart';

/// Why a compose window is open. Reply and forward carry the message being
/// answered, which supplies the quote, the threading headers and, for a
/// forward, the attachments.
enum ComposeKind { newMessage, reply, replyAll, forward }

/// A file being attached, held as bytes so it survives the picker's temporary
/// file being cleaned up before the message is sent.
@immutable
class DraftAttachment {
  const DraftAttachment({
    required this.fileName,
    required this.mimeType,
    required this.bytes,
  });

  final String fileName;
  final String mimeType;
  final Uint8List bytes;

  int get size => bytes.length;

  /// "12 KB", "3.4 MB": what a person needs to judge whether to send it.
  String get readableSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).round()} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// A message being written.
///
/// [htmlBody] is what the editor holds, including the quoted original when
/// there is one, because the user can edit inside the quote. There is no
/// separate "your text" and "the quote": once the editor has them, they are
/// one document, which is the whole reason for the WebView editor.
@immutable
class Draft {
  const Draft({
    required this.accountId,
    required this.kind,
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.subject = '',
    this.htmlBody = '',
    this.attachments = const [],
    this.inReplyTo,
    this.references = const [],
    this.originalMessageId,
  });

  final String accountId;
  final ComposeKind kind;
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final List<MailAddress> bcc;
  final String subject;
  final String htmlBody;
  final List<DraftAttachment> attachments;

  /// Threading headers, so replies land in the right conversation.
  final String? inReplyTo;
  final List<String> references;

  /// The message this is a reply to or forward of, as `<folderId>#<uid>`.
  /// Used to set \Answered once the reply is away.
  final String? originalMessageId;

  bool get hasRecipients => to.isNotEmpty || cc.isNotEmpty || bcc.isNotEmpty;

  int get attachmentBytes =>
      attachments.fold(0, (sum, a) => sum + a.size);

  Draft copyWith({
    List<MailAddress>? to,
    List<MailAddress>? cc,
    List<MailAddress>? bcc,
    String? subject,
    String? htmlBody,
    List<DraftAttachment>? attachments,
    String? accountId,
  }) {
    return Draft(
      accountId: accountId ?? this.accountId,
      kind: kind,
      to: to ?? this.to,
      cc: cc ?? this.cc,
      bcc: bcc ?? this.bcc,
      subject: subject ?? this.subject,
      htmlBody: htmlBody ?? this.htmlBody,
      attachments: attachments ?? this.attachments,
      inReplyTo: inReplyTo,
      references: references,
      originalMessageId: originalMessageId,
    );
  }
}

/// Why a send was refused, so the UI can say something specific.
class SendFailed implements Exception {
  const SendFailed(this.message);

  final String message;

  @override
  String toString() => message;
}
