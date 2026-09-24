/// What kind of file this is, decided by its name rather than by what the
/// sender called it.
///
/// The sender's `Content-Type` is not a reliable answer and never has been.
/// Scanners, accounting systems and plenty of mail clients label every
/// attachment `application/octet-stream`, which means "some bytes". Hand
/// that to Android and the list of apps offered to open a PDF is every app
/// that has ever said it can open anything: file managers, archivers, text
/// editors. The file is a PDF and the person can see that it is, because the
/// name ends in `.pdf`.
///
/// So the extension decides where it is recognised, and what the sender said
/// is the fallback rather than the other way round. Where neither says
/// anything useful the answer is `*/*`, which is honest: Android then asks
/// rather than guessing.
library;

/// The media type to hand the system for a file called [name].
///
/// [declared] is what the sender said, used only when the name does not say.
String mimeTypeForFile(String name, {String? declared}) {
  final byName = _byExtension[_extensionOf(name)];
  if (byName != null) return byName;
  final said = _withoutParameters(declared);
  if (said != null && !_isVague(said) && said != _androidPackage) return said;
  return 'application/octet-stream';
}

/// An app to install, which is never what opening an attachment should do.
///
/// Android sends this type straight to its installer, and because MyEmail
/// may install apps (its own updates), a mailed APK tapped once was a
/// "Do you want to install this app?" with MyEmail as the source. So an APK
/// goes out as bytes, by name or by what the sender claimed: a file with no
/// extension that says it is an app gets no more trust than one called
/// `.apk`. Saved to Files, it can still be installed from there, on purpose.
/// The updater hands its download to the installer itself.
const _androidPackage = 'application/vnd.android.package-archive';

/// Whether a media type says anything worth acting on.
///
/// These three are what a mail system sends when it does not know or did not
/// look. Treating them as fact is what puts a PDF in front of a zip viewer.
bool _isVague(String type) =>
    type == 'application/octet-stream' ||
    type == 'application/unknown' ||
    type == 'binary/octet-stream' ||
    type == '*/*';

/// `application/pdf; name=invoice.pdf` is a header, not a media type.
/// Android matches on the type alone and ignores an intent whose type has a
/// semicolon in it.
String? _withoutParameters(String? raw) {
  if (raw == null) return null;
  final type = raw.split(';').first.trim().toLowerCase();
  return type.isEmpty ? null : type;
}

String _extensionOf(String name) {
  final cut = name.lastIndexOf('.');
  if (cut < 0 || cut == name.length - 1) return '';
  return name.substring(cut + 1).toLowerCase().trim();
}

/// The types worth naming: what actually arrives on mail, and what a phone
/// has an app for. Anything not here falls through to what the sender said.
const _byExtension = <String, String>{
  // Documents
  'pdf': 'application/pdf',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'odt': 'application/vnd.oasis.opendocument.text',
  'ods': 'application/vnd.oasis.opendocument.spreadsheet',
  'rtf': 'application/rtf',
  'txt': 'text/plain',
  'csv': 'text/csv',
  'log': 'text/plain',
  'md': 'text/markdown',
  'html': 'text/html',
  'htm': 'text/html',
  'xml': 'text/xml',
  'json': 'application/json',
  // Mail and calendar
  'eml': 'message/rfc822',
  'msg': 'application/vnd.ms-outlook',
  'ics': 'text/calendar',
  'vcf': 'text/vcard',
  // Pictures
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'svg': 'image/svg+xml',
  // Archives
  'zip': 'application/zip',
  '7z': 'application/x-7z-compressed',
  'rar': 'application/vnd.rar',
  'gz': 'application/gzip',
  'tar': 'application/x-tar',
  // Sound and pictures that move
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'amr': 'audio/amr',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'avi': 'video/x-msvideo',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  '3gp': 'video/3gpp',
  // Drawings and the rest
  'dwg': 'image/vnd.dwg',
  'dxf': 'image/vnd.dxf',
  // Not the installer's type: see [_androidPackage].
  'apk': 'application/octet-stream',
  'epub': 'application/epub+zip',
};
