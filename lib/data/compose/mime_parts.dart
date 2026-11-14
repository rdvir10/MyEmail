import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/draft.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import '../imap/imap_mapping.dart' show decodePart;
import '../mail_engine.dart' show rawMessageBytes;

/// Reading a message's own MIME back into the pieces a draft needs.
///
/// Both kinds of account can hand over a message as it is stored — RFC 822
/// text, every part in it — so this works the same for Gmail and Microsoft,
/// and needs nothing a list of attachments would not give.

/// Every file a message carries, with the bytes, ready to go on a draft.
///
/// For a forward, which used to arrive with the quoted text and none of the
/// files, and for a draft reopened from the Drafts folder, which used to come
/// back without its attachments.
///
/// The message's own text is not a file: a `text/*` part is left out unless
/// it was attached on purpose or has a name of its own. A picture the HTML
/// shows in place keeps its
/// Content-ID, so the `cid:` link in the quote still finds it. An attached
/// message comes across whole, as the `.eml` it was.
List<DraftAttachment> attachmentsInMime(String raw) {
  final message = em.MimeMessage.parseFromData(rawMessageBytes(raw));
  final found = <DraftAttachment>[];

  void visit(em.MimePart part) {
    final type = part.mediaType;
    if (type.top == em.MediaToptype.multipart) {
      for (final child in part.parts ?? const <em.MimePart>[]) {
        visit(child);
      }
      return;
    }

    if (!isFilePart(part)) return;
    final attached = part.getHeaderContentDisposition()?.disposition ==
        em.ContentDisposition.attachment;

    // The message itself, where it is nothing but a file, ends where the
    // message does, not at a boundary.
    final bytes = partBytes(part, inMultipart: !identical(part, message));
    if (bytes == null || bytes.isEmpty) return;

    final isMessage = type.text.toLowerCase() == 'message/rfc822';
    final name = part.decodeFileName() ??
        (isMessage ? 'message.eml' : _nameFor(type.text));
    found.add(DraftAttachment(
      fileName: safeFileName(name),
      mimeType: type.text,
      bytes: bytes,
      contentId: attached ? null : bareContentId(part.getHeaderValue('content-id')),
    ));
  }

  visit(message);
  return found;
}

/// What [part] holds, as the file it is: its body as the message has it,
/// with the transfer encoding it names undone by [decodePart]. [part] is
/// read from bytes, as [em.MimeMessage.parseFromData] reads them.
///
/// Not enough_mail's decodeContentBinary, which leaves quoted-printable as
/// it came, =3D and all, and takes every line break out of a part that
/// names no encoding, as an email attached to another is sent: a forward
/// carried it as one run-on line with no subject.
///
/// The line break before the boundary that ends a part is the boundary's
/// (RFC 2046), not the file's. Where [inMultipart] is false, [part] is the
/// message itself, which no boundary ends.
Uint8List? partBytes(em.MimePart part, {bool inMultipart = true}) {
  // Asked for as 7bit, enough_mail hands the body back as it found it.
  var body = part.mimeData?.decodeBinary('7bit');
  if (body == null) return null;
  final encoding = part.getHeaderValue('content-transfer-encoding');
  final n = body.length;
  if (inMultipart && n >= 2 && body[n - 2] == 0x0D && body[n - 1] == 0x0A) {
    body = Uint8List.sublistView(body, 0, n - 2);
    // In quoted-printable an = ending a line joins it to the next. Ending
    // the last one, it stood before the boundary's line break, and with
    // that gone it joins nothing.
    if (encoding?.trim().toLowerCase() == 'quoted-printable' &&
        body.isNotEmpty &&
        body.last == 0x3D) {
      body = Uint8List.sublistView(body, 0, body.length - 1);
    }
  }
  return decodePart(body, encoding);
}

/// The message as it would be without the files [attachmentsInMime] finds
/// on it: its headers, its text and its layout, for a message too large to
/// put anywhere in one piece, whose files go up after it.
String mimeWithoutFiles(String raw) {
  final message = em.MimeMessage.parseFromData(rawMessageBytes(raw));

  bool strip(em.MimePart part) {
    final parts = part.parts;
    if (parts == null) return false;
    final before = parts.length;
    parts.removeWhere(isFilePart);
    var changed = parts.length != before;
    for (final child in parts) {
      if (strip(child)) changed = true;
    }
    // Drawn again from what is left of its parts. Its own text, as it was
    // read, still holds the files.
    if (changed) part.mimeData = null;
    return changed;
  }

  strip(message);
  return message.renderMessage();
}

/// Whether [part] is one of a message's files rather than its text or its
/// layout: anything that is not text, and text attached on purpose or
/// given a file name, which a mail app shows as a file however it is
/// placed.
bool isFilePart(em.MimePart part) {
  final type = part.mediaType;
  if (type.top == em.MediaToptype.multipart) return false;
  if (type.top != em.MediaToptype.text) return true;
  return part.getHeaderContentDisposition()?.disposition ==
          em.ContentDisposition.attachment ||
      part.decodeFileName() != null;
}

/// The headers of a saved draft that the message list does not keep: who it
/// was blind-copied to, the thread it answers, its importance, and whether
/// it asks for a read receipt.
///
/// A reopened draft used to lose the first three, so sending it left the
/// Bcc people out and started a new thread.
({
  List<MailAddress> bcc,
  String? inReplyTo,
  List<String> references,
  Importance importance,
  bool requestReadReceipt,
}) savedDraftHeaders(String raw) {
  final message = em.MimeMessage.parseFromData(rawMessageBytes(raw));
  final inReplyTo = message.getHeaderValue('in-reply-to')?.trim();
  final references = [
    for (final id in (message.getHeaderValue('references') ?? '')
        .split(RegExp(r'\s+')))
      // The send path appends In-Reply-To itself; keeping it here too would
      // list it twice on every save.
      if (id.isNotEmpty && id != inReplyTo) id,
  ];
  return (
    bcc: [
      for (final a in message.bcc ?? const <em.MailAddress>[])
        MailAddress(email: a.email, name: a.personalName),
    ],
    inReplyTo: inReplyTo == null || inReplyTo.isEmpty ? null : inReplyTo,
    references: references,
    importance: Importance.fromHeaders(
      importance: message.getHeaderValue('importance'),
      xPriority: message.getHeaderValue('x-priority'),
    ),
    requestReadReceipt:
        message.getHeaderValue('disposition-notification-to') != null,
  );
}

/// A Content-ID as the `cid:` link names it: no angle brackets, no space.
String? bareContentId(String? header) {
  final id = header?.trim().replaceAll(RegExp(r'^<|>$'), '').trim();
  return id == null || id.isEmpty ? null : id;
}

String _nameFor(String mediaType) {
  final sub = mediaType.split('/').last.split(RegExp(r'[+;]')).first.trim();
  return sub.isEmpty || sub == 'octet-stream' ? 'attachment' : 'attachment.$sub';
}
