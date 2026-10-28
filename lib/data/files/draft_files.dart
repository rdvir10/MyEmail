import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../domain/draft.dart';
import '../../domain/mail_attachment.dart' show safeFileName;
import 'file_bridge.dart';

/// Where a file on a message being written is put for another app to open:
/// the cache, as a read message's attachments are, since the message holds
/// the bytes and the file is only a copy to look at. Each in a folder of
/// its own, so two files of one name never stand in for each other.
abstract class DraftFiles {
  /// The file's path, written.
  Future<String> write(DraftAttachment attachment);
}

class DiskDraftFiles implements DraftFiles {
  const DiskDraftFiles();

  @override
  Future<String> write(DraftAttachment attachment) async {
    final root = await getTemporaryDirectory();
    final dir = Directory(
      '${root.path}/outgoing/${DateTime.now().microsecondsSinceEpoch}',
    );
    await dir.create(recursive: true);
    final file = File('${dir.path}/${safeFileName(attachment.fileName)}');
    await file.writeAsBytes(attachment.bytes, flush: true);
    return file.path;
  }
}

/// Never touches a disk: hands back a path and remembers what was in it.
class MemoryDraftFiles implements DraftFiles {
  final Map<String, Uint8List> written = {};

  @override
  Future<String> write(DraftAttachment attachment) async {
    final path = '/memory/outgoing/${safeFileName(attachment.fileName)}';
    written[path] = attachment.bytes;
    return path;
  }
}

/// A picture made smaller to send: Small, Medium or Large as a message being
/// written offers them.
abstract class PictureShrinker {
  /// [picture] no longer than [longSide] on its longer side, turned upright,
  /// a JPEG; or null where it could not be read as a picture.
  Future<DraftAttachment?> shrink(DraftAttachment picture, int longSide);
}

/// The phone's: the picture written out for the file bridge to scale, as
/// Insert Pictures has it scaled, and the result read back.
class DevicePictureShrinker implements PictureShrinker {
  const DevicePictureShrinker(this.bridge);

  final FileBridge bridge;

  @override
  Future<DraftAttachment?> shrink(DraftAttachment picture, int longSide) async {
    final root = await getTemporaryDirectory();
    final dir = Directory('${root.path}/outgoing');
    await dir.create(recursive: true);
    final source = File(
      '${dir.path}/${DateTime.now().microsecondsSinceEpoch}-'
      '${safeFileName(picture.fileName)}',
    );
    await source.writeAsBytes(picture.bytes, flush: true);
    try {
      final scaled = await bridge.scaleImage(source.path, maxSide: longSide);
      // Handed back as it was: not a picture the phone can read.
      if (scaled == source.path) return null;
      final out = File(scaled);
      try {
        return DraftAttachment(
          fileName: jpegName(picture.fileName),
          mimeType: 'image/jpeg',
          bytes: await out.readAsBytes(),
        );
      } finally {
        unawaited(out.delete().then((_) {}, onError: (_) {}));
      }
    } finally {
      unawaited(source.delete().then((_) {}, onError: (_) {}));
    }
  }
}

/// Never shrinks anything: the browser preview, and every test that does
/// not bring its own.
class NoPictureShrinker implements PictureShrinker {
  const NoPictureShrinker();

  @override
  Future<DraftAttachment?> shrink(DraftAttachment picture, int longSide) async =>
      null;
}

/// [name] as the JPEG it becomes: "IMG_1201.heic" is "IMG_1201.jpg".
String jpegName(String name) {
  final dot = name.lastIndexOf('.');
  return '${dot <= 0 ? name : name.substring(0, dot)}.jpg';
}
