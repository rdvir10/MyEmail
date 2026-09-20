import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/mail_message.dart';

/// A message written out as a file, so it can go where files go: onto the
/// clipboard, into a drag, into another message as an attachment.
///
/// The file is the message as it arrived (RFC 822 text, the `.eml` every
/// mail client reads), written under the app's cache so the system may
/// clear it later. A port so tests can hand back a path without a disk.
abstract class MessageFiles {
  Future<File> writeEml(String fileName, String raw);
}

class DiskMessageFiles implements MessageFiles {
  const DiskMessageFiles();

  @override
  Future<File> writeEml(String fileName, String raw) async {
    final root = await getTemporaryDirectory();
    final dir = Directory('${root.path}${Platform.pathSeparator}eml');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(raw, flush: true);
    return file;
  }
}

/// Never touches a disk: hands back a path and remembers what it was for.
class FakeMessageFiles implements MessageFiles {
  final Map<String, String> written = {};

  @override
  Future<File> writeEml(String fileName, String raw) async {
    written[fileName] = raw;
    return File('/fake/eml/$fileName');
  }
}

/// `<subject>-<date>.eml`: says which message it was when there are twenty
/// in a folder, and survives every filesystem.
String emlFileName(MailMessage message) {
  final when = message.date.toLocal();
  final stamp = '${when.year}-${_two(when.month)}-${_two(when.day)}';
  var name = message.subject.trim().toLowerCase();
  name = name.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  name = name.replaceAll(RegExp(r'^-+|-+$'), '');
  if (name.length > 40) {
    name = name.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
  }
  if (name.isEmpty) name = 'message';
  return '$name-$stamp.eml';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// The MIME type of an `.eml` file.
const emlMimeType = 'message/rfc822';
