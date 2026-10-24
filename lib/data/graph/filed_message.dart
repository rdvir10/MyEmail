import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/draft.dart' show DraftAttachment;
import '../compose/mime_parts.dart' show attachmentsInMime, isFilePart;
import '../compose/reply_draft.dart' show escapeHtml;
import '../mail_engine.dart' show rawMessageBytes;
import 'graph_mail_api.dart';

/// A message from another account, as Graph's JSON for filing it in a
/// Microsoft mailbox, and the files it carries, which go up after it.
///
/// See [GraphMailApi.fileMessage] for why not MIME. What JSON cannot carry
/// is the message's own headers past the ones a mail app shows, and its
/// MIME layout; what a person reads, who it was from and to, when it came,
/// and every file and picture on it, all go.
///
/// It is filed read, and not a draft: [GraphMailApi.messageFlagsProperty]
/// says both at once. Unread is set after, if it was.
({Map<String, Object?> message, List<DraftAttachment> attachments})
    filedMessageFromMime(
  String raw, {
  bool flagged = false,
  DateTime? arrived,
}) {
  final mime = em.MimeMessage.parseFromData(rawMessageBytes(raw));
  final body = _bodyOf(mime);
  final sent = mime.decodeDate();
  final received = arrived ?? sent;
  final messageId = mime.getHeaderValue('message-id')?.trim();
  final importance = _importanceOf(mime);
  final from = mime.from;

  return (
    message: {
      'subject': mime.decodeSubject() ?? '',
      'body': {
        'contentType': body.isHtml ? 'html' : 'text',
        'content': body.content,
      },
      if (from != null && from.isNotEmpty) 'from': _recipient(from.first),
      'toRecipients': _recipients(mime.to),
      'ccRecipients': _recipients(mime.cc),
      'bccRecipients': _recipients(mime.bcc),
      'replyTo': _recipients(mime.replyTo),
      if (messageId != null && messageId.isNotEmpty)
        'internetMessageId': messageId,
      'importance': ?importance,
      if (flagged) 'flag': {'flagStatus': 'flagged'},
      'singleValueExtendedProperties': [
        // MSGFLAG_READ, and without MSGFLAG_UNSENT: read, and not a draft.
        {'id': GraphMailApi.messageFlagsProperty, 'value': '1'},
        if (received != null)
          {'id': GraphMailApi.deliveryTimeProperty, 'value': _utc(received)},
        if (sent != null)
          {'id': GraphMailApi.submitTimeProperty, 'value': _utc(sent)},
      ],
    },
    attachments: attachmentsInMime(raw),
  );
}

/// What a person reads of [message], as HTML where any of it is HTML and
/// as text where none of it is.
///
/// Walked part by part rather than asked of enough_mail, which hands over
/// the first HTML part it meets, a file among them: a plain message with a
/// page attached was filed with the page for its body, and the sender's
/// words were gone. And it hands over one part where there can be several:
/// Apple Mail writes the text either side of a picture as parts of their
/// own, and everything after the first picture was lost.
({String content, bool isHtml}) _bodyOf(em.MimePart message) {
  final pieces = _readable(message);
  final isHtml = pieces.any((p) => p.isHtml);
  if (!isHtml) {
    return (
      content: [for (final p in pieces) p.text].join('\n'),
      isHtml: false,
    );
  }
  if (pieces.length == 1) return (content: pieces.single.text, isHtml: true);
  // One page made of several, so each goes without its own page around it.
  return (
    content: [
      for (final p in pieces)
        p.isHtml ? _inBody(p.text) : _asHtml(p.text),
    ].join('\n'),
    isHtml: true,
  );
}

/// The parts of [part] a person reads, in order.
List<({String text, bool isHtml})> _readable(em.MimePart part) {
  final type = part.mediaType;
  if (type.top == em.MediaToptype.multipart) {
    final children = [
      for (final child in part.parts ?? const <em.MimePart>[])
        _readable(child),
    ];
    if (type.sub == em.MediaSubtype.multipartAlternative) {
      // One message in several forms, plainest first: the richest that
      // can be filed, and only that one.
      return children.lastWhere(
        (pieces) => pieces.any((p) => p.isHtml),
        orElse: () => children.firstWhere(
          (pieces) => pieces.isNotEmpty,
          orElse: () => const [],
        ),
      );
    }
    return [for (final pieces in children) ...pieces];
  }
  if (isFilePart(part)) return const [];
  final isHtml = type.sub == em.MediaSubtype.textHtml;
  if (!isHtml && type.sub != em.MediaSubtype.textPlain) return const [];
  final text = part.decodeContentText();
  if (text == null || text.trim().isEmpty) return const [];
  return [(text: text, isHtml: isHtml)];
}

/// What is inside the body of an HTML page, or all of it if it has none.
String _inBody(String html) =>
    RegExp(r'<body[^>]*>([\s\S]*)</body>', caseSensitive: false)
        .firstMatch(html)
        ?.group(1) ??
    html;

/// Plain text as HTML, line for line.
String _asHtml(String text) {
  final lines = escapeHtml(text.trim()).replaceAll('\r\n', '\n');
  return '<div>${lines.replaceAll('\n', '<br>')}</div>';
}

Map<String, Object?> _recipient(em.MailAddress a) => {
      'emailAddress': {
        'address': a.email,
        if (a.personalName?.trim() case final name? when name.isNotEmpty)
          'name': name,
      },
    };

List<Map<String, Object?>> _recipients(List<em.MailAddress>? list) => [
      for (final a in list ?? const <em.MailAddress>[])
        if (a.email.isNotEmpty) _recipient(a),
    ];

String _utc(DateTime when) => when.toUtc().toIso8601String();

/// High or low, from `Importance` or the older `X-Priority`; null for
/// normal, which is what Graph assumes.
String? _importanceOf(em.MimeMessage mime) {
  final said = mime.getHeaderValue('importance')?.trim().toLowerCase();
  if (said == 'high' || said == 'low') return said;
  final priority =
      int.tryParse(mime.getHeaderValue('x-priority')?.trim().split(' ').first ?? '');
  if (priority == null) return null;
  if (priority <= 2) return 'high';
  if (priority >= 4) return 'low';
  return null;
}
