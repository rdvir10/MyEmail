import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/mail_message.dart';
import '../mail_engine.dart' show rawMessageBytes;

/// A message written out as a file, so it can go where files go: onto the
/// clipboard, into a drag, into another message as an attachment.
///
/// The file is the message as it arrived (RFC 822 text, the `.eml` every
/// mail client reads), written under the app's cache so the system may
/// clear it later. A port so tests can hand back a path without a disk.
///
/// [messageId] says which message it is, and each message's file goes in a
/// folder of its own. The name alone is not enough: a Hebrew subject keeps
/// none of its letters, and two replies in one thread on one day share a
/// date, so several messages dragged at once were written to one path in
/// turn and arrived as that many copies of the last.
abstract class MessageFiles {
  Future<File> writeEml(String fileName, String raw, {required String messageId});
}

class DiskMessageFiles implements MessageFiles {
  const DiskMessageFiles();

  @override
  Future<File> writeEml(
    String fileName,
    String raw, {
    required String messageId,
  }) async {
    final root = await getTemporaryDirectory();
    final dir = Directory([
      root.path,
      'eml',
      emlFolderFor(messageId),
    ].join(Platform.pathSeparator));
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(rawMessageBytes(raw), flush: true);
    return file;
  }
}

/// A folder name for one message's file: readable, safe on every
/// filesystem, and different for two messages whose ids differ only in the
/// characters that had to be replaced.
String emlFolderFor(String messageId) {
  final readable = messageId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  // FNV-1a over the id: the same every run, unlike hashCode.
  var hash = 0x811c9dc5;
  for (final unit in messageId.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return '$readable-${hash.toRadixString(16)}';
}

/// Never touches a disk: hands back a path and remembers what it was for.
class FakeMessageFiles implements MessageFiles {
  final Map<String, String> written = {};

  @override
  Future<File> writeEml(
    String fileName,
    String raw, {
    required String messageId,
  }) async {
    written[fileName] = raw;
    return File('/fake/eml/${emlFolderFor(messageId)}/$fileName');
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
