import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/mail_attachment.dart';

/// Where a downloaded attachment lives while it is being used.
///
/// The cache directory, not documents: these are copies of something that
/// still exists on the server, and Android is free to delete them when it
/// needs the space. Saving one somewhere permanent is a separate, deliberate
/// act, and goes wherever the person points the file picker.
///
/// The layout is `attachments/<attachment>/<file name>`, one directory per
/// attachment, so two messages can both carry `invoice.pdf` without one
/// standing in for the other — which would be the kind of wrong that is
/// never noticed until the wrong invoice is sent on.
abstract class AttachmentFiles {
  /// The file for this attachment if it has already been downloaded.
  Future<File?> cached(String messageId, MailAttachment attachment);

  /// Write the bytes and hand back the file.
  Future<File> write(
    String messageId,
    MailAttachment attachment,
    Uint8List bytes,
  );
}

class DiskAttachmentFiles implements AttachmentFiles {
  const DiskAttachmentFiles();

  @override
  Future<File?> cached(String messageId, MailAttachment attachment) async {
    final file = await _fileFor(messageId, attachment);
    if (!file.existsSync()) return null;
    // A zero-length file is a download that was interrupted, not a file.
    if (file.lengthSync() == 0) return null;
    return file;
  }

  @override
  Future<File> write(
    String messageId,
    MailAttachment attachment,
    Uint8List bytes,
  ) async {
    final file = await _fileFor(messageId, attachment);
    await file.parent.create(recursive: true);
    // Written whole and then moved into place, so an interrupted download
    // cannot leave half a file behind that looks complete.
    final partial = File('${file.path}.part');
    await partial.writeAsBytes(bytes, flush: true);
    return partial.rename(file.path);
  }

  Future<File> _fileFor(String messageId, MailAttachment attachment) async {
    final root = await getTemporaryDirectory();
    return File(
      '${root.path}/attachments/${await folderFor(messageId, attachment)}/'
      '${safeFileName(attachment.name)}',
    );
  }

  /// The directory one attachment is kept in.
  ///
  /// Not the message id alone. `acct:INBOX#42` names a place in a folder,
  /// not a message: IMAP numbers a recreated folder from 1 again, and
  /// Microsoft's messages are numbered here and start again once a folder
  /// is forgotten. A new message then opened an old one's file of the same
  /// name. The attachment's own id and size go in too: Microsoft's ids are
  /// unique by themselves, and over IMAP, where a part id is only "2", it
  /// would take another file with the same name, place and size to the
  /// byte. Hashed, because an id holds a colon and a slash, and a deep
  /// folder path can be longer than a directory name may be.
  static Future<String> folderFor(
    String messageId,
    MailAttachment attachment,
  ) async {
    final hash = await Sha256().hash(utf8.encode(
      '$messageId\n${attachment.id}\n${attachment.sizeBytes}',
    ));
    return [
      for (final b in hash.bytes.take(16)) b.toRadixString(16).padLeft(2, '0'),
    ].join();
  }
}

/// Keeps the bytes in memory. Tests, and the browser preview.
class MemoryAttachmentFiles implements AttachmentFiles {
  final Map<String, Uint8List> written = {};

  String _key(String messageId, MailAttachment a) => '$messageId/${a.id}';

  @override
  Future<File?> cached(String messageId, MailAttachment attachment) async =>
      written.containsKey(_key(messageId, attachment))
          ? File('/memory/${safeFileName(attachment.name)}')
          : null;

  @override
  Future<File> write(
    String messageId,
    MailAttachment attachment,
    Uint8List bytes,
  ) async {
    written[_key(messageId, attachment)] = bytes;
    return File('/memory/${safeFileName(attachment.name)}');
  }
}
