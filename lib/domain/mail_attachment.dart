import 'dart:convert';

import 'file_types.dart';

/// A file that came with a message.
///
/// Listed without being downloaded: both IMAP and Graph will describe what is
/// attached for the cost of one small request, and a message with a 12MB
/// slide deck on it should open as fast as any other. The bytes are fetched
/// when someone actually asks for them.
class MailAttachment {
  const MailAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    this.isInline = false,
    this.contentId,
  });

  /// How to ask for the bytes later. A part id on IMAP, an attachment id on
  /// Graph; opaque either way, and only meaningful alongside its message.
  final String id;

  final String name;

  /// What the sender said it is. Not to be trusted, and mostly not used:
  /// see [openAs], which is what gets handed to the system.
  final String mimeType;

  /// The type to open, share, copy or drag this file as.
  ///
  /// Decided by the name, because the sender's answer is so often
  /// `application/octet-stream` that acting on it is how a PDF ends up being
  /// offered to an archive viewer. See [mimeTypeForFile].
  String get openAs => mimeTypeForFile(name, declared: mimeType);

  /// As the server reports it. Encoded size on IMAP, so a base64 part reads
  /// about a third larger than the file that comes out of it.
  final int sizeBytes;

  /// Part of the message's own layout — a logo in a signature, an image the
  /// HTML refers to — rather than something the sender attached on purpose.
  final bool isInline;

  /// The name the message's HTML gives this part in a `cid:` link, without
  /// the angle brackets. How a pasted screenshot or a signature's logo is
  /// put in the body rather than under it. Null for most files.
  final String? contentId;

  MailAttachment copyWith({String? name, int? sizeBytes}) => MailAttachment(
        id: id,
        name: name ?? this.name,
        mimeType: mimeType,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        isInline: isInline,
        contentId: contentId,
      );

  @override
  String toString() => 'MailAttachment($name, $mimeType, $sizeBytes bytes)';
}

/// A name that is safe to write to disk and still recognisable.
///
/// A file name arrives from whoever sent the message, so it is not allowed
/// anywhere near a path until it has been taken apart: a name with a slash in
/// it writes outside the folder it was meant for, one with `..` climbs out of
/// it, and one 400 characters long fails on every filesystem there is.
String safeFileName(String name, {String fallback = 'attachment'}) {
  // Split on separators and drop the segments that mean "somewhere else":
  // empty, "." and "..". What is left is a name rather than a path.
  final segments = name
      .trim()
      .split(RegExp(r'[\\/]'))
      .where((part) => part.isNotEmpty && part != '.' && part != '..');
  var cleaned = segments.join('_').replaceAll(RegExp(r'[\x00-\x1f]'), '_');
  // Reserved on Windows, which the desktop preview and any future export
  // path both have to survive.
  cleaned = cleaned.replaceAll(RegExp(r'[<>:"|?*]'), '_');
  cleaned = cleaned.replaceAll(RegExp(r'^\.+'), '');
  cleaned = cleaned.trim();
  if (cleaned.isEmpty) return fallback;
  if (cleaned.length <= _maxNameChars &&
      utf8.encode(cleaned).length <= _maxNameBytes) {
    return cleaned;
  }

  // Long names are cut in the middle, keeping the extension: the end of a
  // file name is where the meaning usually is.
  final dot = cleaned.lastIndexOf('.');
  final extension =
      dot <= 0 || cleaned.length - dot > 12 ? '' : cleaned.substring(dot);
  final stem = cleaned.substring(0, cleaned.length - extension.length);
  return _cut(
        stem,
        chars: _maxNameChars - extension.length,
        bytes: _maxNameBytes - utf8.encode(extension).length,
      ) +
      extension;
}

/// Long enough to still say what the file is.
const _maxNameChars = 120;

/// What the disk counts is bytes, and its limit is 255 of them. A Chinese or
/// Thai character is three, so 120 characters of one was a name no download
/// could be written under, and the attachment said "Could not download"
/// every time. 200 leaves room for the `.part` a download is written to
/// first.
const _maxNameBytes = 200;

/// The start of [text], no longer than either limit, cut between characters
/// rather than through one: half an emoji is not a name the disk will take.
String _cut(String text, {required int chars, required int bytes}) {
  final kept = StringBuffer();
  var usedChars = 0;
  var usedBytes = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    usedChars += char.length;
    usedBytes += utf8.encode(char).length;
    if (usedChars > chars || usedBytes > bytes) break;
    kept.write(char);
  }
  return kept.toString();
}

/// A size in the units a person reads.
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
}
