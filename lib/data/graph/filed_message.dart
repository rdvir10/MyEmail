import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/draft.dart' show DraftAttachment;
import '../compose/mime_parts.dart' show attachmentsInMime;
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
  final html = mime.decodeTextHtmlPart();
  final text = html == null ? mime.decodeTextPlainPart() : null;
  final sent = mime.decodeDate();
  final received = arrived ?? sent;
  final messageId = mime.getHeaderValue('message-id')?.trim();
  final importance = _importanceOf(mime);
  final from = mime.from;

  return (
    message: {
      'subject': mime.decodeSubject() ?? '',
      'body': {
        'contentType': html != null ? 'html' : 'text',
        'content': html ?? text ?? '',
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
