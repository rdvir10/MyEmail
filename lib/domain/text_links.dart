import 'package:flutter/foundation.dart';

/// What a stretch of plain text links to: a web page, someone to write to,
/// a number to ring.
enum TextLinkKind { web, email, phone }

/// One link found in plain text: where it is, as offsets into the text,
/// and where a tap on it goes.
@immutable
class TextLink {
  const TextLink(this.start, this.end, this.kind, this.target);

  final int start;
  final int end;
  final TextLinkKind kind;

  /// An http(s) address, a mailto: or a tel:.
  final Uri target;
}

/// The links in [text], plain text as a meeting's notes are shown (#43):
/// web addresses, email addresses and phone numbers, in order, none inside
/// another. A web address is one over https or http, as a message's links
/// open, or a www. one, taken as https; it leaves out the full stop or
/// bracket of the sentence it ends. A phone number keeps the pauses and
/// code a dial-in writes after it ("+1 469-555-0123,,123456789#"), which
/// the dialler takes too. A meeting ID, a passcode, a date and a time are
/// not numbers to ring.
List<TextLink> linksInText(String text) {
  final found = <TextLink>[
    ..._web(text),
    for (final m in _email.allMatches(text))
      TextLink(
        m.start,
        m.end,
        TextLinkKind.email,
        Uri(scheme: 'mailto', path: m[0]),
      ),
    for (final pattern in _phones)
      for (final m in pattern.allMatches(text))
        if (_ringable(m[0]!))
          TextLink(
            m.start,
            m.end,
            TextLinkKind.phone,
            Uri(scheme: 'tel', path: m[0]!.replaceAll(_notDialled, '')),
          ),
  ]..sort((a, b) => a.start.compareTo(b.start));
  final kept = <TextLink>[];
  for (final link in found) {
    if (kept.isNotEmpty && link.start < kept.last.end) continue;
    kept.add(link);
  }
  return kept;
}

final _webStart = RegExp(r'https?://|www\.', caseSensitive: false);

/// What a web address written out in text can hold: printable ASCII but
/// for the space, quotes, angle brackets and the few others none holds
/// unescaped.
bool _inAddress(int c) =>
    c > 0x20 && c < 0x7f && !_notInAddresses.contains(c);

final _notInAddresses = '<>"\'`{}|\\^[]'.codeUnits.toSet();

/// The web addresses in [text]: from an http:// or https://, or a www.
/// that starts a word, to the end of what an address can hold.
Iterable<TextLink> _web(String text) sync* {
  var from = 0;
  for (final m in _webStart.allMatches(text)) {
    // One found inside the last, www. in https://www…, is that one.
    if (m.start < from) continue;
    // A word that runs into www. is not an address that starts there.
    if (m.start > 0 &&
        _inAddress(text.codeUnitAt(m.start - 1)) &&
        !m[0]!.toLowerCase().startsWith('http')) {
      continue;
    }
    var end = m.end;
    while (end < text.length && _inAddress(text.codeUnitAt(end))) {
      end++;
    }
    var address = text.substring(m.start, end);
    while (address.isNotEmpty) {
      final last = address[address.length - 1];
      final unopened = last == ')' &&
          '('.allMatches(address).length < ')'.allMatches(address).length;
      if (!'.,;:!?*'.contains(last) && !unopened) break;
      address = address.substring(0, address.length - 1);
    }
    from = m.start + address.length;
    if (address.length <= m[0]!.length) continue;
    final bare = address.toLowerCase().startsWith('www.');
    final target = Uri.tryParse(bare ? 'https://$address' : address);
    if (target == null || target.host.isEmpty) continue;
    yield TextLink(m.start, from, TextLinkKind.web, target);
  }
}

final _email = RegExp(
    r'(?<![\w.%+-])[\w.%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
    r'(?![\w-])');

/// The ways a phone number is written that are not something else: from
/// a + with the country, with the pauses and code a dial-in puts after it;
/// with its area code in brackets; and in groups joined by hyphens or dots,
/// as 054-555-1234, 03-555-1234, 555-123-4567 and 1-800-555-1234. Groups
/// joined by spaces alone, without a +, are a meeting's ID as often as a
/// number, and are left.
final _phones = [
  RegExp(r'(?<![\w+])\+\d[\d ().-]{5,18}\d(?:,+[\d*#]+)*(?![\w])'),
  RegExp(r'(?<![\w(])\(\d{2,4}\) ?\d{3,4}[ .-]?\d{3,4}(?![\w])'),
  RegExp(r'(?<![\w.-])(?:1[.-])?\d{2,3}[.-]\d{3}[.-]?\d{4}(?![\w-])'),
];

/// What a dialler is not handed of a number as written: its spaces,
/// brackets, hyphens and dots.
final _notDialled = RegExp(r'[^\d+,*#]');

/// Whether [number] has the digits a phone number has, before the pauses.
bool _ringable(String number) {
  final digits =
      number.split(',').first.replaceAll(RegExp(r'\D'), '').length;
  return digits >= 7 && digits <= 15;
}
