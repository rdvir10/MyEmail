import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../domain/mail_message.dart';

/// Saving a message exactly as it arrived.
///
/// For the times a message does not look right and the only way to find out
/// why is to read what the sender actually sent. The file is the body
/// untouched — no images stripped, no wrapper added — under a header saying
/// which message it was, so it can be opened in a browser or handed to
/// someone who can read HTML.
///
/// Nothing is uploaded anywhere. It writes where the person points it.

/// The file a saved message becomes.
String messageSourceFile(MailMessage message, MailBody body) {
  final html = body.html;
  final header = StringBuffer()
    ..writeln('<!--')
    ..writeln('  MyEmail: saved message source')
    ..writeln('  Subject: ${message.subject}')
    ..writeln('  From:    ${message.from.email}')
    ..writeln('  To:      ${message.to.map((a) => a.email).join(', ')}')
    ..writeln('  Date:    ${message.date.toUtc().toIso8601String()}')
    ..writeln('  Folder:  ${message.folderId}')
    ..writeln('-->');

  if (html != null && html.trim().isNotEmpty) return '$header\n$html';

  // A plain-text message still saves as a file that opens, rather than as
  // something whose extension lies about what is in it.
  return '$header\n<pre>${_escape(body.text)}</pre>';
}

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// A file name that survives every filesystem, and still says which message
/// it was when there are twenty of them in a folder.
String messageSourceFileName(MailMessage message, {DateTime? now}) {
  final when = message.date.toLocal();
  final stamp = '${when.year}-${_two(when.month)}-${_two(when.day)}';
  var name = message.subject.trim().toLowerCase();
  name = name.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  name = name.replaceAll(RegExp(r'^-+|-+$'), '');
  if (name.length > 40) name = name.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
  if (name.isEmpty) name = 'message';
  return '$name-$stamp.html';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Put it somewhere the person chooses. True if they did.
Future<bool> saveMessageSource(MailMessage message, MailBody body) async {
  final uri = await FilePicker.saveFile(
    fileName: messageSourceFileName(message),
    bytes: Uint8List.fromList(utf8.encode(messageSourceFile(message, body))),
    mimeType: 'text/html',
    dialogTitle: 'Save the message source',
  );
  return uri != null;
}
