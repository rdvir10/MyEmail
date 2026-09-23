import 'dart:convert';
import 'dart:typed_data';

import 'draft.dart';
import 'mail_message.dart';

/// What a second window is opened to show.
///
/// A window is a whole second copy of the app — its own Dart isolate, its
/// own state — so what it shows has to be handed across as data, not as
/// an object. A draft carries everything typed so far, attachments
/// included; a message carries enough to draw the header at once, and
/// the body is read from the shared cache the way it always is.
sealed class WindowRequest {
  const WindowRequest();

  Map<String, Object?> toJson();

  static WindowRequest fromJson(Map<String, Object?> json) =>
      switch (json['window']) {
        'compose' => ComposeWindow(
            _draftFromJson(json['draft'] as Map),
            disposable: json['disposable'] == true,
          ),
        'message' => MessageWindow(_messageFromJson(json['message'] as Map)),
        final other => throw FormatException('not a window: $other'),
      };

  String encode() => jsonEncode(toJson());

  static WindowRequest decode(String text) =>
      fromJson((jsonDecode(text) as Map).cast<String, Object?>());
}

/// A message being written, moved to a window of its own.
class ComposeWindow extends WindowRequest {
  const ComposeWindow(this.draft, {this.disposable = false});

  final Draft draft;

  /// Whether the draft is only what a new compose window starts with, so
  /// closing it untouched loses nothing. False for one moved across from
  /// another window, which holds typing that exists nowhere else.
  final bool disposable;

  @override
  Map<String, Object?> toJson() => {
        'window': 'compose',
        'draft': _draftToJson(draft),
        if (disposable) 'disposable': true,
      };
}

/// A message opened in a window of its own.
class MessageWindow extends WindowRequest {
  const MessageWindow(this.message);

  final MailMessage message;

  @override
  Map<String, Object?> toJson() => {
        'window': 'message',
        'message': _messageToJson(message),
      };
}

Map<String, Object?> _addressToJson(MailAddress a) => {
      'email': a.email,
      if (a.name != null) 'name': a.name,
    };

MailAddress _addressFromJson(Map json) => MailAddress(
      email: json['email'] as String,
      name: json['name'] as String?,
    );

Map<String, Object?> _draftToJson(Draft d) => {
      'accountId': d.accountId,
      'kind': d.kind.name,
      'to': [for (final a in d.to) _addressToJson(a)],
      'cc': [for (final a in d.cc) _addressToJson(a)],
      'bcc': [for (final a in d.bcc) _addressToJson(a)],
      'subject': d.subject,
      'htmlBody': d.htmlBody,
      'attachments': [
        for (final a in d.attachments)
          {
            'fileName': a.fileName,
            'mimeType': a.mimeType,
            'bytes': base64Encode(a.bytes),
            if (a.contentId != null) 'contentId': a.contentId,
          },
      ],
      if (d.inReplyTo != null) 'inReplyTo': d.inReplyTo,
      'references': d.references,
      if (d.originalMessageId != null) 'originalMessageId': d.originalMessageId,
      if (d.savedAs != null) 'savedAs': d.savedAs,
      'lostAttachmentNames': d.lostAttachmentNames,
    };

Draft _draftFromJson(Map json) => Draft(
      accountId: json['accountId'] as String,
      kind: ComposeKind.values.byName(json['kind'] as String),
      to: [for (final a in json['to'] as List) _addressFromJson(a as Map)],
      cc: [for (final a in json['cc'] as List) _addressFromJson(a as Map)],
      bcc: [for (final a in json['bcc'] as List) _addressFromJson(a as Map)],
      subject: json['subject'] as String,
      htmlBody: json['htmlBody'] as String,
      attachments: [
        for (final a in json['attachments'] as List)
          DraftAttachment(
            fileName: (a as Map)['fileName'] as String,
            mimeType: a['mimeType'] as String,
            bytes: Uint8List.fromList(base64Decode(a['bytes'] as String)),
            contentId: a['contentId'] as String?,
          ),
      ],
      inReplyTo: json['inReplyTo'] as String?,
      references: (json['references'] as List).cast<String>(),
      originalMessageId: json['originalMessageId'] as String?,
      savedAs: json['savedAs'] as String?,
      lostAttachmentNames: (json['lostAttachmentNames'] as List).cast<String>(),
    );

Map<String, Object?> _messageToJson(MailMessage m) => {
      'id': m.id,
      'accountId': m.accountId,
      'folderId': m.folderId,
      'uid': m.uid,
      'subject': m.subject,
      'from': _addressToJson(m.from),
      'to': [for (final a in m.to) _addressToJson(a)],
      'cc': [for (final a in m.cc) _addressToJson(a)],
      if (m.replyTo.isNotEmpty)
        'replyTo': [for (final a in m.replyTo) _addressToJson(a)],
      'date': m.date.toUtc().toIso8601String(),
      'preview': m.preview,
      'isRead': m.isRead,
      'isFlagged': m.isFlagged,
      'hasAttachments': m.hasAttachments,
      'attachmentBytes': m.attachmentBytes,
      'isMeeting': m.isMeeting,
      if (m.messageId != null) 'messageId': m.messageId,
      if (m.inReplyTo != null) 'inReplyTo': m.inReplyTo,
    };

MailMessage _messageFromJson(Map json) => MailMessage(
      id: json['id'] as String,
      accountId: json['accountId'] as String,
      folderId: json['folderId'] as String,
      uid: json['uid'] as int,
      subject: json['subject'] as String,
      from: _addressFromJson(json['from'] as Map),
      to: [for (final a in json['to'] as List) _addressFromJson(a as Map)],
      // Absent in a request written before these were carried.
      cc: [
        for (final a in (json['cc'] as List?) ?? const [])
          _addressFromJson(a as Map),
      ],
      replyTo: [
        for (final a in (json['replyTo'] as List?) ?? const [])
          _addressFromJson(a as Map),
      ],
      date: DateTime.parse(json['date'] as String),
      preview: json['preview'] as String,
      isRead: json['isRead'] as bool,
      isFlagged: json['isFlagged'] as bool,
      hasAttachments: json['hasAttachments'] as bool,
      attachmentBytes: (json['attachmentBytes'] as int?) ?? 0,
      isMeeting: (json['isMeeting'] as bool?) ?? false,
      messageId: json['messageId'] as String?,
      inReplyTo: json['inReplyTo'] as String?,
    );
