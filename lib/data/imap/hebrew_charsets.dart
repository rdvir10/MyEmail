import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;

/// Hebrew that mail arrives in and enough_mail cannot read.
///
/// enough_mail reads text with a table of charsets that has iso-8859-8
/// but not windows-1255, the Hebrew most Windows mail programs, banks and
/// town halls write, nor iso-8859-8-i, the name ISO Hebrew is usually sent
/// under. Given a charset it does not know, it reads the bytes as UTF-8,
/// which Hebrew letters in either are not, so every one came out as �; and
/// it leaves an encoded word in such a charset, a subject, a sender's name
/// or a file's name, as it came: `=?windows-1255?B?...?=`.
///
/// Nor is the iso-8859-8 it has quite right: its table (enough_convert's)
/// gives U+8206 and U+8207, two Chinese characters, for the marks that set
/// the direction of the text, and ? for a byte with no character. So that
/// is read here too, with its -i and -e names.
///
/// Microsoft mail never needs this: Exchange turns it into Unicode before
/// the app sees it.

/// Text in [charset] from its [bytes], transfer encoding already undone.
///
/// enough_mail's own reading, [em.MailCodec.decodeAsText] as 8bit, for
/// every charset but the Hebrew it cannot read.
String decodeCharset(List<int> bytes, String? charset) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final name = _charsetName(charset);
  // The -i of iso-8859-8-i says only that the letters are written in the
  // order they are read; they are the same letters at the same bytes.
  final high = _windows1255Names.contains(name)
      ? _windows1255High
      : _isoHebrewNames.contains(name)
          ? _isoHebrewHigh
          : null;
  if (high == null) return em.MailCodec.decodeAsText(data, '8bit', charset);
  return String.fromCharCodes([
    for (final b in data) b < 0x80 ? b : high[b - 0x80],
  ]);
}

/// Whether [charset] is Hebrew that [decodeCharset] reads rather than
/// enough_mail.
bool isHebrewCharset(String? charset) {
  final name = _charsetName(charset);
  return _windows1255Names.contains(name) || _isoHebrewNames.contains(name);
}

/// [text], a header as enough_mail decoded it, with the encoded words it
/// left decoded here: one in Hebrew it has no table for, and every word
/// after it, which it gives up on with it.
///
/// Text with no encoded word in such a charset comes back as it is, so
/// nothing enough_mail already reads changes.
String? decodeHebrewWords(String? text) {
  if (text == null || !text.contains('=?')) return text;
  final words = _encodedWord.allMatches(text).toList();
  if (!words.any((w) => isHebrewCharset(_wordCharset(w)))) return text;
  final out = StringBuffer();
  var at = 0;
  for (final w in words) {
    final between = text.substring(at, w.start);
    // Space between two encoded words is where a long header was folded,
    // not part of the text (RFC 2047, 6.2).
    if (at == 0 || between.trim().isNotEmpty) out.write(between);
    out.write(_decodeWord(w) ?? w[0]);
    at = w.end;
  }
  out.write(text.substring(at));
  return out.toString();
}

/// `=?charset?B?...?=` or `=?charset?Q?...?=` (RFC 2047).
final _encodedWord = RegExp(r'=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=');

/// Less a language, as RFC 2231 lets a word name one: `windows-1255*he`.
String _wordCharset(RegExpMatch word) => word[1]!.split('*').first;

String? _decodeWord(RegExpMatch word) {
  final payload = word[3]!;
  final List<int> bytes;
  try {
    bytes = word[2]!.toLowerCase() == 'b'
        ? em.MailCodec.base64.decodeData(payload)
        : _qBytes(payload);
  } on FormatException {
    return null;
  }
  return decodeCharset(bytes, _wordCharset(word));
}

/// The Q encoding: `=XX` is the byte XX and `_` a space.
List<int> _qBytes(String payload) {
  int hex(int c) => switch (c) {
        >= 0x30 && <= 0x39 => c - 0x30,
        >= 0x41 && <= 0x46 => c - 0x41 + 10,
        >= 0x61 && <= 0x66 => c - 0x61 + 10,
        _ => -1,
      };
  final out = <int>[];
  for (var i = 0; i < payload.length; i++) {
    final c = payload.codeUnitAt(i);
    if (c == 0x5F) {
      out.add(0x20);
    } else if (c == 0x3D &&
        i + 2 < payload.length &&
        hex(payload.codeUnitAt(i + 1)) >= 0 &&
        hex(payload.codeUnitAt(i + 2)) >= 0) {
      out.add(hex(payload.codeUnitAt(i + 1)) * 16 +
          hex(payload.codeUnitAt(i + 2)));
      i += 2;
    } else {
      out.add(c);
    }
  }
  return out;
}

String _charsetName(String? charset) =>
    (charset ?? '').replaceAll('"', '').trim().toLowerCase();

const _windows1255Names = {'windows-1255', 'cp1255', 'cp-1255', 'x-cp1255'};

const _isoHebrewNames = {
  'iso-8859-8',
  'iso8859-8',
  'iso-8859-8-i',
  'iso-8859-8-e',
  'iso8859-8-i',
  'iso8859-8-e',
  'iso_8859-8-i',
  'iso_8859-8-e',
  'iso_8859-8',
  'csiso88598i',
  'csiso88598e',
};

/// Bytes 0x80 to 0xFF of windows-1255, as browsers read it (the WHATWG
/// index): points at C0 to D8, the letters from E0, the marks for
/// direction at FD and FE. A byte with no character is U+FFFD.
const _x = 0xFFFD;
const _windows1255High = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, // 80
  0x02C6, 0x2030, 0x008A, 0x2039, 0x008C, 0x008D, 0x008E, 0x008F, // 88
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 90
  0x02DC, 0x2122, 0x009A, 0x203A, 0x009C, 0x009D, 0x009E, 0x009F, // 98
  0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x20AA, 0x00A5, 0x00A6, 0x00A7, // A0
  0x00A8, 0x00A9, 0x00D7, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF, // A8
  0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7, // B0
  0x00B8, 0x00B9, 0x00F7, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF, // B8
  0x05B0, 0x05B1, 0x05B2, 0x05B3, 0x05B4, 0x05B5, 0x05B6, 0x05B7, // C0
  0x05B8, 0x05B9, 0x05BA, 0x05BB, 0x05BC, 0x05BD, 0x05BE, 0x05BF, // C8
  0x05C0, 0x05C1, 0x05C2, 0x05C3, 0x05F0, 0x05F1, 0x05F2, 0x05F3, // D0
  0x05F4, _x, _x, _x, _x, _x, _x, _x, // D8
  0x05D0, 0x05D1, 0x05D2, 0x05D3, 0x05D4, 0x05D5, 0x05D6, 0x05D7, // E0
  0x05D8, 0x05D9, 0x05DA, 0x05DB, 0x05DC, 0x05DD, 0x05DE, 0x05DF, // E8
  0x05E0, 0x05E1, 0x05E2, 0x05E3, 0x05E4, 0x05E5, 0x05E6, 0x05E7, // F0
  0x05E8, 0x05E9, 0x05EA, _x, _x, 0x200E, 0x200F, _x, // F8
];

/// Bytes 0x80 to 0xFF of iso-8859-8, as Unicode publishes it (8859-8.TXT,
/// which the WHATWG index agrees with): control codes at 80 to 9F, Latin-1
/// at A0 to BE but × at AA and ÷ at BA, the double low line at DF, the
/// letters from E0, the marks for direction at FD and FE. A byte with no
/// character is U+FFFD.
const _isoHebrewHigh = [
  0x0080, 0x0081, 0x0082, 0x0083, 0x0084, 0x0085, 0x0086, 0x0087, // 80
  0x0088, 0x0089, 0x008A, 0x008B, 0x008C, 0x008D, 0x008E, 0x008F, // 88
  0x0090, 0x0091, 0x0092, 0x0093, 0x0094, 0x0095, 0x0096, 0x0097, // 90
  0x0098, 0x0099, 0x009A, 0x009B, 0x009C, 0x009D, 0x009E, 0x009F, // 98
  0x00A0, _x, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7, // A0
  0x00A8, 0x00A9, 0x00D7, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF, // A8
  0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7, // B0
  0x00B8, 0x00B9, 0x00F7, 0x00BB, 0x00BC, 0x00BD, 0x00BE, _x, // B8
  _x, _x, _x, _x, _x, _x, _x, _x, // C0
  _x, _x, _x, _x, _x, _x, _x, _x, // C8
  _x, _x, _x, _x, _x, _x, _x, _x, // D0
  _x, _x, _x, _x, _x, _x, _x, 0x2017, // D8
  0x05D0, 0x05D1, 0x05D2, 0x05D3, 0x05D4, 0x05D5, 0x05D6, 0x05D7, // E0
  0x05D8, 0x05D9, 0x05DA, 0x05DB, 0x05DC, 0x05DD, 0x05DE, 0x05DF, // E8
  0x05E0, 0x05E1, 0x05E2, 0x05E3, 0x05E4, 0x05E5, 0x05E6, 0x05E7, // F0
  0x05E8, 0x05E9, 0x05EA, _x, _x, 0x200E, 0x200F, _x, // F8
];
