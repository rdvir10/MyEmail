import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/html_safety.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import '../compose/mime_parts.dart' show bareContentId;
import '../imap/imap_mapping.dart';

/// An email that came attached to another, read from its own bytes: an
/// Outlook item downloaded from Microsoft, or a message forwarded as an
/// attachment. Everything is in the file; nothing is asked of a server.
class AttachedMessage {
  AttachedMessage._(
    this._mime, {
    required this.subject,
    required this.from,
    required this.to,
    required this.cc,
    required this.date,
    required this.body,
    required this.files,
    required this.inlinePictures,
  });

  /// The message in [bytes], or null if they are not one.
  static AttachedMessage? parse(Uint8List bytes) {
    final em.MimeMessage mime;
    try {
      mime = em.MimeMessage.parseFromData(bytes);
    } catch (_) {
      return null;
    }
    final from = mime.from?.firstOrNull ?? mime.sender;
    final subject = mime.decodeSubject()?.trim();
    // Nothing a message has: some other file called .eml.
    if (from == null && subject == null && mime.decodeDate() == null) {
      return null;
    }

    final files = <MailAttachment>[];
    final pictures = <String, String>{};
    for (final disposition in [
      em.ContentDisposition.attachment,
      em.ContentDisposition.inline,
    ]) {
      // Not into a message attached to this one: its files are its own,
      // and show when it is opened.
      for (final info in mime.findContentInfo(
        disposition: disposition,
        complete: false,
      )) {
        final type =
            info.contentType?.mediaType.toString() ??
            'application/octet-stream';
        if (disposition == em.ContentDisposition.inline &&
            type.startsWith('text/')) {
          continue;
        }
        if (info.fetchId.isEmpty) continue;
        final part = mime.getPart(info.fetchId);
        final data = part == null ? null : _bytesOf(part);
        if (data == null) continue;
        final isMessage = type.toLowerCase() == 'message/rfc822';
        final named = info.fileName ?? part?.decodeFileName();
        files.add(
          MailAttachment(
            id: info.fetchId,
            name: safeFileName(
              named ?? (isMessage ? 'Attached message.eml' : 'attachment'),
            ),
            mimeType: type,
            sizeBytes: data.length,
            isInline: disposition == em.ContentDisposition.inline,
            contentId: bareContentId(info.cid),
          ),
        );
      }
    }
    // Pictures the body shows by Content-ID, whether or not they say they
    // are inline: some senders give a picture an ID and nothing else.
    void walk(em.MimePart part, String? fetchId) {
      final contentId = bareContentId(part.getHeaderValue('content-id'));
      final type = part.mediaType;
      if (contentId != null && type.top == em.MediaToptype.image) {
        final data = _bytesOf(part);
        if (data != null) {
          pictures[contentId.toLowerCase()] =
              'data:${type.text};base64,${base64Encode(data)}';
          if (fetchId != null && !files.any((f) => f.id == fetchId)) {
            files.add(
              MailAttachment(
                id: fetchId,
                name: safeFileName(part.decodeFileName() ?? 'picture'),
                mimeType: type.text,
                sizeBytes: data.length,
                isInline: true,
                contentId: contentId,
              ),
            );
          }
        }
      }
      // An attached message's own parts stay its own.
      if (type.sub == em.MediaSubtype.messageRfc822) return;
      final children = part.parts ?? const <em.MimePart>[];
      for (var i = 0; i < children.length; i++) {
        walk(children[i], fetchId == null ? '${i + 1}' : '$fetchId.${i + 1}');
      }
    }

    walk(mime, null);

    return AttachedMessage._(
      mime,
      subject: (subject == null || subject.isEmpty) ? '(No subject)' : subject,
      from: from == null ? const MailAddress(email: '') : addressFromMime(from),
      to: [
        for (final a in mime.to ?? const <em.MailAddress>[]) addressFromMime(a),
      ],
      cc: [
        for (final a in mime.cc ?? const <em.MailAddress>[]) addressFromMime(a),
      ],
      date: mime.decodeDate(),
      body: bodyFromMime(mime),
      files: files,
      inlinePictures: pictures,
    );
  }

  final em.MimeMessage _mime;
  final String subject;
  final MailAddress from;
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final DateTime? date;
  final MailBody body;

  /// What is attached to it, pictures in the body among them, marked.
  final List<MailAttachment> files;

  /// The pictures the body names by Content-ID, as data: URIs; see
  /// [withInlinePictures].
  final Map<String, String> inlinePictures;

  /// The files to list: not a picture the body already shows.
  List<MailAttachment> get listed {
    final html = body.html;
    final shown = html == null ? const <String>{} : contentIdsNamedIn(html);
    return [
      for (final f in files)
        if (f.contentId == null ||
            !shown.contains(f.contentId!.toLowerCase()) ||
            !inlinePictures.containsKey(f.contentId!.toLowerCase()))
          f,
    ];
  }

  /// The bytes of one of [files].
  Uint8List? bytesOf(MailAttachment file) {
    final part = _mime.getPart(file.id);
    return part == null ? null : _bytesOf(part);
  }

  /// A part's content as the file it is.
  ///
  /// enough_mail's own answer drops every line break from a part that is
  /// not encoded, which is how an email attached to an email is sent: the
  /// one inside came back as a single run-on line with no subject. Such a
  /// message is written out again from what was read of it, and unencoded
  /// text is taken as text.
  static Uint8List? _bytesOf(em.MimePart part) {
    if (part.mediaType.sub == em.MediaSubtype.messageRfc822) {
      final inner = part.decodeContentMessage();
      return inner == null ? null : utf8.encode(inner.renderMessage());
    }
    final encoding =
        part.getHeaderValue('content-transfer-encoding')?.trim().toLowerCase();
    if (encoding == 'base64' || encoding == 'quoted-printable') {
      return part.decodeContentBinary();
    }
    final text = part.decodeContentText();
    return text == null ? null : utf8.encode(text);
  }
}
