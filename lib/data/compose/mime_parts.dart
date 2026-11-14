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
/// was blind-copied to, the thread it answers, its importance, whether it
/// asks for a read receipt, and for a reply or forward, which it is and the
/// Message-ID of the message it was written from, to find it by (see
/// [draftOnlyHeaders]).
///
/// A reopened draft used to lose the first three, so sending it left the
/// Bcc people out and started a new thread. It also came back as a new
/// message, whatever it had been.
({
  List<MailAddress> bcc,
  String? inReplyTo,
  List<String> references,
  Importance importance,
  bool requestReadReceipt,
  ComposeKind kind,
  String? original,
}) savedDraftHeaders(String raw) {
  final message = em.MimeMessage.parseFromData(rawMessageBytes(raw));
  final (:kind, :original) = _kindAndOriginal(message);
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
    kind: original == null ? ComposeKind.newMessage : kind!,
    original: original,
  );
}

/// What a saved draft carries for this app alone, as headers: whether it is
/// a reply, a reply to all or a forward ([kind]), and the Message-ID of the
/// message it was written from ([original], without its angle brackets),
/// by which that message is found again when the draft is opened, wherever
/// it is filed by then. Nothing else keeps them once it is in Drafts.
/// Without them a reply put away and finished later went as a new message:
/// without the Thread-Index that keeps it in its conversation in Outlook,
/// and with the original never marked answered.
///
/// A Message-ID, which everyone who had that message has already, and
/// never where it is filed: a saved draft can leave whole, finished in
/// another mail app or forwarded as an attachment, and the names of Ron's
/// folders are his own. The engine puts these on what it saves, never on
/// what it sends, and [withoutDraftOnlyHeaders] takes them off a message
/// leaving as a file.
Map<String, String> draftOnlyHeaders(ComposeKind kind, String? original) {
  if (original == null ||
      kind == ComposeKind.newMessage ||
      !_bareMessageId.hasMatch(original)) {
    return const {};
  }
  return {_kindHeader: kind.name, _originalHeader: '<$original>'};
}

const _kindHeader = 'X-MyEmail-Kind';
const _originalHeader = 'X-MyEmail-Original';

/// A Message-ID with nothing around it, and nothing in it that could end
/// or split a header.
final _bareMessageId = RegExp(r'^[^<>\s]+$');

/// The reply or forward and its original's Message-ID, as
/// [draftOnlyHeaders] wrote them; both or neither.
({ComposeKind? kind, String? original}) _kindAndOriginal(
  em.MimeMessage message,
) {
  final name = message.getHeaderValue(_kindHeader)?.trim();
  final kind = ComposeKind.values
      .where((k) => k != ComposeKind.newMessage && k.name == name)
      .firstOrNull;
  // Folded, a long one gains white space where it was cut; a Message-ID
  // has none of its own.
  final written = message
      .getHeaderValue(_originalHeader)
      ?.replaceAll(RegExp(r'\s'), '');
  final original =
      written == null ? null : RegExp(r'^<([^<>]+)>$').firstMatch(written);
  if (kind == null || original == null) return (kind: null, original: null);
  return (kind: kind, original: original.group(1));
}

/// [raw], a whole message, without the headers [draftOnlyHeaders] puts on a
/// saved draft, and otherwise as it is, byte for byte: for a message that
/// leaves as a file, as Forward as attachment sends one, or a copy for
/// another app. What they hold is for this app alone.
String withoutDraftOnlyHeaders(String raw) {
  // The headers end at the first empty line.
  final blank = RegExp(r'\r?\n\r?\n').firstMatch(raw);
  final cut = blank == null
      ? raw.length
      : blank.start + (raw.startsWith('\r\n', blank.start) ? 2 : 1);
  final head = raw.substring(0, cut);
  if (!head.toLowerCase().contains('x-myemail-')) return raw;
  final kept = StringBuffer();
  var dropping = false;
  // Each line with its own line break.
  for (final line in RegExp(r'[^\n]*\n|[^\n]+$').allMatches(head)) {
    final text = line[0]!;
    // A line that starts with a space or a tab goes on with the header
    // above it.
    if (!text.startsWith(' ') && !text.startsWith('\t')) {
      dropping = text.toLowerCase().startsWith('x-myemail-');
    }
    if (!dropping) kept.write(text);
  }
  return '$kept${raw.substring(cut)}';
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
