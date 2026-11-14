import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import 'html_safety.dart';
import 'mail_attachment.dart';
import 'mail_message.dart';

/// Check for threats: what a message gives away about being phishing,
/// malware or a fake, on the phone. What the mail servers already found
/// (Microsoft's and Google's verdicts and the sender checks, in the
/// headers), the sender, the links and the attachments. Google Safe
/// Browsing and VirusTotal add theirs where they are set up; see
/// `threat_check_providers.dart`.

/// How worrying a finding is, and the check as a whole.
enum ThreatLevel { safe, caution, danger }

/// What a finding is about, for grouping them on the sheet.
enum ThreatArea { server, sender, links, attachments, online }

@immutable
class ThreatFinding {
  const ThreatFinding(
    this.level,
    this.area,
    this.title, {
    this.detail = '',
  });

  final ThreatLevel level;
  final ThreatArea area;
  final String title;
  final String detail;

  @override
  bool operator ==(Object other) =>
      other is ThreatFinding &&
      other.level == level &&
      other.area == area &&
      other.title == title &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(level, area, title, detail);

  @override
  String toString() => 'ThreatFinding(${level.name}, $title)';
}

/// The worst of [findings], or safe where there are none.
ThreatLevel worstOf(Iterable<ThreatFinding> findings) => findings.fold(
      ThreatLevel.safe,
      (worst, f) => f.level.index > worst.index ? f.level : worst,
    );

/// The headers the check reads: the receiving server's sender checks and
/// spam verdicts, as Exchange Online and Gmail write them.
const threatHeaderNames = [
  'Authentication-Results',
  'X-Forefront-Antispam-Report',
  'X-Microsoft-Antispam',
  'X-MS-Exchange-Organization-SCL',
  'Received-SPF',
];

/// What the receiving mail server found, from [headers] (lower-cased
/// names): SPF, DKIM and DMARC, and Microsoft's own spam and phishing
/// verdicts.
List<ThreatFinding> checkHeaders(Map<String, String> headers) {
  final found = <ThreatFinding>[];
  void add(ThreatLevel level, String title, [String detail = '']) =>
      found.add(ThreatFinding(level, ThreatArea.server, title, detail: detail));

  // Without its comments: Gmail's ARC result carries the last hop's spf=
  // and dkim= in brackets, ahead of its own.
  final auth = (headers['authentication-results'] ?? '')
      .replaceAll(RegExp(r'\([^()]*\)'), ' ');
  String? result(String method) => RegExp(
        '(?:^|[;\\s])$method=([a-z]+)',
        caseSensitive: false,
      ).firstMatch(auth)?[1]?.toLowerCase();
  final spf = result('spf') ??
      RegExp(r'^\s*([a-z]+)', caseSensitive: false)
          .firstMatch(headers['received-spf'] ?? '')?[1]
          ?.toLowerCase();
  final dkim = result('dkim');
  final dmarc = result('dmarc');
  final compauth = result('compauth');
  if (dmarc == 'fail') {
    add(ThreatLevel.danger, "The sender's domain says this is not from it",
        'DMARC failed: the domain in From publishes a rule this mail breaks. '
            'Mail pretending to be from a company fails it.');
  }
  if (compauth == 'fail') {
    add(ThreatLevel.danger, 'Microsoft could not confirm who sent it',
        'Its composite authentication failed: the sender is likely not who '
            'it says.');
  }
  if ((spf == 'fail' || spf == 'softfail') && dkim != 'pass') {
    add(ThreatLevel.caution, 'It came from a server its domain does not list',
        'SPF ${spf!}: the sending server is not one the domain names.');
  }
  if (dkim == 'fail') {
    add(ThreatLevel.caution, 'Its signature does not match',
        'DKIM failed: it may have been changed on the way.');
  }
  if (spf == 'pass' && dkim == 'pass' && dmarc == 'pass') {
    add(ThreatLevel.safe, "The sender's domain vouches for it",
        'SPF, DKIM and DMARC all passed.');
  } else if (auth.isEmpty && spf == null) {
    add(ThreatLevel.safe, 'The server did not record its sender checks');
  }

  final report = _pairs(headers['x-forefront-antispam-report'] ?? '');
  final cat = report['CAT']?.toUpperCase() ?? '';
  final scl = int.tryParse(report['SCL'] ??
      headers['x-ms-exchange-organization-scl']?.trim() ??
      '');
  if (cat == 'PHSH' || cat == 'HPHSH') {
    add(ThreatLevel.danger, 'Microsoft marked it as phishing');
  } else if (cat == 'MALW') {
    add(ThreatLevel.danger, 'Microsoft found malware in it');
  } else if (const {'SPOOF', 'DIMP', 'UIMP', 'GIMP'}.contains(cat)) {
    add(ThreatLevel.danger, 'Microsoft found it pretending to be someone else');
  } else if (cat == 'SPM' || cat == 'HSPM' || (scl != null && scl >= 5)) {
    add(ThreatLevel.caution, 'Microsoft rated it spam',
        scl == null ? '' : 'Spam level $scl of 9.');
  } else if (scl == -1) {
    add(ThreatLevel.safe, "Microsoft's spam filter let it through unchecked",
        'A safe sender, or a rule of your organisation, skipped it.');
  } else if (scl != null && scl <= 1) {
    add(ThreatLevel.safe, "Microsoft's spam filter found nothing",
        'Spam level $scl of 9.');
  }
  final bulk = int.tryParse(
      _pairs(headers['x-microsoft-antispam'] ?? '')['BCL'] ?? '');
  if (bulk != null && bulk >= 7) {
    add(ThreatLevel.caution, 'Bulk mail many people report as junk',
        'Bulk level $bulk of 9.');
  }
  return found;
}

/// `KEY:value;` pairs, as Microsoft's spam reports write them.
Map<String, String> _pairs(String text) => {
      for (final part in text.split(';'))
        if (part.indexOf(':') case final i when i > 0)
          part.substring(0, i).trim().toUpperCase(): part.substring(i + 1).trim(),
    };

/// A link in a message: the words it is on, as written, and where it
/// really goes once Microsoft's Safe Links and Google's redirects are
/// taken off.
@immutable
class MessageLink {
  const MessageLink({
    required this.text,
    required this.url,
    required this.target,
  });

  final String text;
  final String url;
  final Uri? target;

  /// Where it goes, by host, lower case.
  String get host => target?.host.toLowerCase() ?? '';
}

/// Every link in a message, each once: its HTML's anchors, or the web
/// addresses in its text. Mail and phone links are not links to check.
List<MessageLink> linksIn({String? html, String text = ''}) {
  final found = <MessageLink>[];
  final seen = <String>{};
  void add(String words, String href) {
    final url = href.trim();
    final lower = url.toLowerCase();
    if (url.isEmpty ||
        url.startsWith('#') ||
        lower.startsWith('mailto:') ||
        lower.startsWith('tel:') ||
        lower.startsWith('cid:')) {
      return;
    }
    final shown = words.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!seen.add('$shown\u0000$url')) return;
    found.add(MessageLink(text: shown, url: url, target: unwrapLink(url)));
  }

  if (html != null && html.trim().isNotEmpty) {
    for (final a in html_parser.parse(html).querySelectorAll('a[href]')) {
      add(a.text, a.attributes['href'] ?? '');
    }
  } else {
    for (final m in RegExp(r'''https?://[^\s<>"')]+''', caseSensitive: false)
        .allMatches(text)) {
      // Without the full stop of the sentence it ends.
      final url = m[0]!.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
      add(url, url);
    }
  }
  return found;
}

/// [url] with Microsoft Defender's Safe Links and Google's redirects
/// taken off: where a tap really ends up. Null for one that does not read.
Uri? unwrapLink(String url) {
  var uri = Uri.tryParse(url.trim());
  for (var i = 0; i < 3 && uri != null; i++) {
    final host = uri.host.toLowerCase();
    String? inner;
    try {
      if (host.endsWith('safelinks.protection.outlook.com')) {
        inner = uri.queryParameters['url'];
      } else if ((host == 'www.google.com' || host == 'google.com') &&
          uri.path == '/url') {
        inner = uri.queryParameters['q'] ?? uri.queryParameters['url'];
      }
    } on FormatException {
      inner = null;
    }
    final next = inner == null ? null : Uri.tryParse(inner);
    if (next == null || !next.hasScheme) break;
    uri = next;
  }
  return uri == null ? null : _lookedUpHost(uri);
}

/// [uri] with its host as a browser looks it up: a name in another
/// alphabet's letters in its xn-- form. Dart keeps such a host
/// percent-escaped, %d0%b0pple.com for an аpple.com with a Cyrillic а,
/// which the lookalike-letters rule never saw, which read as no domain
/// at all, and which Google's lists do not hold. One that will not decode,
/// or is too long to be a name, is left escaped; [checkLinks] still reads
/// its % as letters that are not plain.
Uri _lookedUpHost(Uri uri) {
  final host = uri.host;
  if (!host.contains('%') || host.length > 1000) return uri;
  String name;
  try {
    name = Uri.decodeComponent(host);
  } on FormatException {
    return uri;
  }
  // Read as a browser reads it first (see [_asBrowserReads]), then cut at
  // the full stops, those other scripts write too.
  final read = StringBuffer();
  for (final c in name.runes) {
    read.write(_asBrowserReads(c));
  }
  final labels = read
      .toString()
      .replaceAll(RegExp('[\u3002\uff0e\uff61]'), '.')
      .split('.');
  if (labels.any((l) => l.length > 63)) return uri;
  // Plain only if plain before lower-casing: Dart lower-cases a capital
  // dotted I to a plain i, and www.mİcrosoft.com read as Microsoft's own
  // address, where a browser goes to www.xn--microsoft-6jf.com. Read this
  // way, a letter that lower-cases to a plain one in some later Unicode is
  // still told.
  final ascii = [
    for (final l in labels)
      l.runes.every((c) => c < 0x80)
          ? l.toLowerCase()
          : 'xn--${_punycode(l.toLowerCase())}',
  ].join('.');
  try {
    return uri.replace(host: ascii);
  } on FormatException {
    return uri;
  }
}

/// [c] in a name as a browser reads it (UTS46), for what it takes as a
/// plain letter, digit or hyphen: the full-width forms, the mathematical,
/// circled, squared and outlined alphabets, the long s and the Kelvin
/// sign, all of which a lookalike name can be spelled in; nothing for the
/// marks it leaves out (a soft hyphen, the zero-width space, variation
/// selectors); an i with a dot above for İ. Anything else as it is:
/// another letter a browser makes plain (ligatures, Roman numerals and the
/// like) is then left in other letters, so warned of rather than missed.
String _asBrowserReads(int c) {
  String letter(int i) => String.fromCharCode(0x61 + i);
  String digit(int i) => String.fromCharCode(0x30 + i);
  return switch (c) {
    0x0130 => 'i\u0307',
    0x017F => 's',
    0x212A => 'k',
    0xFE63 || 0xFF0D => '-',
    >= 0xFF10 && <= 0xFF19 => digit(c - 0xFF10),
    >= 0xFF21 && <= 0xFF3A => letter(c - 0xFF21),
    >= 0xFF41 && <= 0xFF5A => letter(c - 0xFF41),
    >= 0x2460 && <= 0x2468 => digit(c - 0x2460 + 1),
    >= 0x24B6 && <= 0x24CF => letter(c - 0x24B6),
    >= 0x24D0 && <= 0x24E9 => letter(c - 0x24D0),
    0x24EA => '0',
    >= 0x1CCD6 && <= 0x1CCEF => letter(c - 0x1CCD6),
    >= 0x1CCF0 && <= 0x1CCF9 => digit(c - 0x1CCF0),
    // Capitals and small letters in turn, 26 each; the gaps among them
    // are no characters at all.
    >= 0x1D400 && <= 0x1D6A3 => letter((c - 0x1D400) % 26),
    >= 0x1D7CE && <= 0x1D7FF => digit((c - 0x1D7CE) % 10),
    >= 0x1F130 && <= 0x1F149 => letter(c - 0x1F130),
    >= 0x1FBF0 && <= 0x1FBF9 => digit(c - 0x1FBF0),
    0xAD ||
    0x34F ||
    0x200B ||
    0x3164 ||
    0xFEFF ||
    0xFFA0 ||
    (>= 0x115F && <= 0x1160) ||
    (>= 0x17B4 && <= 0x17B5) ||
    (>= 0x180B && <= 0x180F) ||
    (>= 0x2060 && <= 0x2064) ||
    (>= 0x206A && <= 0x206F) ||
    (>= 0xFE00 && <= 0xFE0F) ||
    (>= 0x1BCA0 && <= 0x1BCA3) ||
    (>= 0x1D173 && <= 0x1D17A) ||
    (>= 0xE0100 && <= 0xE01EF) =>
      '',
    _ => String.fromCharCode(c),
  };
}

/// [label] in Punycode (RFC 3492): how a domain name's label in other
/// letters is written in plain ones, after the xn--.
String _punycode(String label) {
  const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
  final input = label.runes.toList();
  final out = StringBuffer();
  for (final c in input) {
    if (c < 0x80) out.writeCharCode(c);
  }
  final basic = out.length;
  if (basic > 0) out.write('-');
  // 0 to 25 are a to z, 26 to 35 are 0 to 9.
  void digit(int d) => out.writeCharCode(d < 26 ? 0x61 + d : 0x16 + d);
  int adapt(int delta, int points, bool first) {
    delta = first ? delta ~/ damp : delta ~/ 2;
    delta += delta ~/ points;
    var k = 0;
    while (delta > ((base - tMin) * tMax) ~/ 2) {
      delta ~/= base - tMin;
      k += base;
    }
    return k + (base - tMin + 1) * delta ~/ (delta + skew);
  }

  var n = 0x80, delta = 0, bias = 72, handled = basic;
  while (handled < input.length) {
    var m = 0x10FFFF;
    for (final c in input) {
      if (c >= n && c < m) m = c;
    }
    delta += (m - n) * (handled + 1);
    n = m;
    for (final c in input) {
      if (c < n) delta++;
      if (c != n) continue;
      var q = delta;
      for (var k = base;; k += base) {
        final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
        if (q < t) break;
        digit(t + (q - t) % (base - t));
        q = (q - t) ~/ (base - t);
      }
      digit(q);
      bias = adapt(delta, handled + 1, handled == basic);
      delta = 0;
      handled++;
    }
    delta++;
    n++;
  }
  return out.toString();
}

/// Link shorteners, which hide where a link goes.
const _shorteners = {
  'bit.ly', 'tinyurl.com', 't.co', 'goo.gl', 'ow.ly', 'is.gd', 'buff.ly',
  'rebrand.ly', 'cutt.ly', 'shorturl.at', 'tiny.cc', 'rb.gy', 't.ly', 's.id',
  'bl.ink', 'lnkd.in',
};

/// Two-part endings a domain is registered under, as co.uk is.
const _twoPartEndings = {
  'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'co.il', 'org.il', 'ac.il', 'gov.il',
  'net.il', 'muni.il', 'com.au', 'net.au', 'org.au', 'co.nz', 'co.jp',
  'com.br', 'co.za', 'com.mx', 'co.in', 'com.tr', 'com.cn',
};

/// The domain [host] is registered as: hadco.com for mail.hadco.com,
/// example.co.uk for www.example.co.uk.
String baseDomain(String host) {
  final labels = host.toLowerCase().split('.')
    ..removeWhere((l) => l.isEmpty);
  if (labels.length <= 2) return labels.join('.');
  final lastTwo = labels.sublist(labels.length - 2).join('.');
  final keep = _twoPartEndings.contains(lastTwo) ? 3 : 2;
  return labels.sublist(labels.length - keep).join('.');
}

String _domainOf(String email) {
  final at = email.lastIndexOf('@');
  return at < 0 ? '' : email.substring(at + 1).trim().toLowerCase();
}

/// The known domain [domain] is made to look like, or null for none:
/// hadc0.com for hadco.com, rnicrosoft.com for microsoft.com, one letter
/// changed, added or left out of a name of six or more.
String? lookalikeOf(String domain, Set<String> known) {
  final mine = baseDomain(domain);
  if (mine.isEmpty || known.contains(mine)) return null;
  String plain(String d) => d
      .replaceAll('0', 'o')
      .replaceAll('1', 'l')
      .replaceAll('rn', 'm')
      .replaceAll('vv', 'w');
  for (final k in known) {
    final theirs = baseDomain(k);
    if (theirs.isEmpty || theirs == mine) continue;
    if (plain(theirs) == plain(mine)) return theirs;
    final a = mine.split('.').first, b = theirs.split('.').first;
    if (b.length >= 6 && _oneEditApart(a, b)) return theirs;
  }
  return null;
}

bool _oneEditApart(String a, String b) {
  if ((a.length - b.length).abs() > 1 || a == b) return false;
  var i = 0, j = 0, edits = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      i++;
      j++;
      continue;
    }
    if (++edits > 1) return false;
    if (a.length > b.length) {
      i++;
    } else if (a.length < b.length) {
      j++;
    } else {
      i++;
      j++;
    }
  }
  return edits + (a.length - i) + (b.length - j) <= 1;
}

bool _isIp(String host) =>
    RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) || host.contains(':');

/// A web address or domain the words of a link show, or null for words
/// like "Click here", or a file's name: a share from OneDrive or Google
/// Drive links the file's name, and Quote-2026.pdf going to sharepoint.com
/// read as an address going somewhere else.
String? _domainShown(String text) {
  final m = RegExp(
    r'^(?:https?://)?(?:www\.)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?:[/:?#]\S*)?$',
    caseSensitive: false,
  ).firstMatch(text.trim());
  final shown = m?[1]?.toLowerCase();
  if (shown == null || _fileEndings.contains(shown.split('.').last)) {
    return null;
  }
  return shown;
}

/// Kinds of file people share that no domain ends in. Not .zip or .mov,
/// which are endings as well; nor the ones that run, whose name on a link
/// is worth the warning either way.
const _fileEndings = {
  'pdf', 'doc', 'docx', 'docm', 'xls', 'xlsx', 'xlsm', 'xlsb', 'ppt', 'pptx',
  'pptm', 'txt', 'csv', 'rtf', 'odt', 'ods', 'odp', 'jpg', 'jpeg', 'png',
  'gif', 'bmp', 'tif', 'tiff', 'heic', 'webp', 'eml', 'msg', 'ics', 'vcf',
  'json', 'xml',
};

/// What each link gives away: words showing one address over a link to
/// another, a hidden address, a bare internet address, lookalike letters,
/// a shortener, a script, or a domain made to look like one [known].
List<ThreatFinding> checkLinks(
  List<MessageLink> links, {
  Set<String> known = const {},
}) {
  final found = <ThreatFinding>[];
  void add(ThreatLevel level, String title, [String detail = '']) =>
      found.add(ThreatFinding(level, ThreatArea.links, title, detail: detail));
  for (final l in links) {
    final t = l.target;
    final scheme = t?.scheme.toLowerCase() ?? '';
    if (const {'javascript', 'data', 'vbscript', 'file'}.contains(scheme)) {
      add(ThreatLevel.danger, 'A link runs something rather than opening a page',
          l.url.length > 80 ? '${l.url.substring(0, 80)}…' : l.url);
      continue;
    }
    if (t == null || (scheme != 'http' && scheme != 'https')) continue;
    final host = l.host;
    if (t.userInfo.isNotEmpty) {
      add(ThreatLevel.danger, 'A link hides where it goes',
          'Everything before the @ is decoration; it goes to $host.');
    }
    final shown = _domainShown(l.text);
    if (shown != null && baseDomain(shown) != baseDomain(host)) {
      add(ThreatLevel.danger, 'A link reads $shown but goes to $host');
    }
    final like = lookalikeOf(host, known);
    if (like != null) {
      add(ThreatLevel.danger, 'A link goes to $host, which looks like $like');
    }
    if (_isIp(host)) {
      add(ThreatLevel.caution, 'A link goes to a bare internet address',
          host);
    }
    if (host.contains('%') ||
        host.split('.').any((p) => p.startsWith('xn--'))) {
      add(ThreatLevel.caution, "A link's address uses lookalike letters",
          host);
    }
    if (_shorteners.contains(host)) {
      add(ThreatLevel.caution, 'A shortened link hides where it goes', host);
    }
  }
  return found;
}

/// What the sender gives away: a name that shows another address, replies
/// that go elsewhere, a domain made to look like one [known], or a first
/// mail from an address never seen ([knownAddresses]).
List<ThreatFinding> checkSender(
  MailMessage message, {
  Set<String> knownAddresses = const {},
  Set<String> known = const {},
}) {
  final found = <ThreatFinding>[];
  void add(ThreatLevel level, String title, [String detail = '']) =>
      found.add(ThreatFinding(level, ThreatArea.sender, title, detail: detail));
  final from = message.from.email.trim().toLowerCase();
  final domain = _domainOf(from);
  final name = message.from.name?.trim() ?? '';
  final inName = RegExp(r'[\w.+-]+@[\w-]+(\.[\w-]+)+').firstMatch(name)?[0];
  if (inName != null && inName.toLowerCase() != from) {
    add(ThreatLevel.danger, 'Its name shows $inName, but it comes from $from');
  }
  for (final r in message.replyTo) {
    final to = r.email.trim().toLowerCase();
    if (to.isEmpty || to == from) continue;
    if (baseDomain(_domainOf(to)) != baseDomain(domain)) {
      add(ThreatLevel.caution, 'Replies go to $to, not to the sender');
    }
  }
  final like = lookalikeOf(domain, known);
  if (like != null) {
    add(ThreatLevel.danger, 'It comes from $domain, which looks like $like');
  }
  if (from.isNotEmpty && !knownAddresses.contains(from)) {
    add(ThreatLevel.safe, 'The first mail from this address',
        'You have not written to it before.');
  }
  return found;
}

/// Kinds of file that run, or install, when opened.
const _runs = {
  'exe', 'scr', 'bat', 'cmd', 'com', 'pif', 'msi', 'msp', 'js', 'jse', 'vbs',
  'vbe', 'wsf', 'wsh', 'ps1', 'psm1', 'jar', 'apk', 'hta', 'lnk', 'reg',
  'cpl', 'iso', 'img', 'vhd', 'vhdx', 'cab', 'appx', 'msix', 'application',
  'gadget', 'scf', 'chm', 'dll', 'sys', 'url',
};

/// Office files that carry macros.
const _macros = {
  'docm', 'dotm', 'xlsm', 'xltm', 'xlam', 'pptm', 'potm', 'ppam', 'ppsm',
  'sldm',
};

/// Web pages, a fake sign-in's favourite way in.
const _pages = {'html', 'htm', 'shtml', 'xhtml', 'svg', 'mht', 'mhtml'};

/// Archives, whose insides cannot be looked at here.
const _archives = {'zip', 'rar', '7z', 'gz', 'tar', 'tgz', 'ace', 'arj', 'xz'};

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).trim().toLowerCase();
}

/// Whether [a] is a kind of file worth fearing: it runs, carries macros or
/// is a web page.
bool isRiskyAttachment(MailAttachment a) {
  final ext = _extensionOf(a.name);
  return _runs.contains(ext) || _macros.contains(ext) || _pages.contains(ext);
}

/// The attachments [html] shows as pictures, by id: each marked inline, of
/// a picture's type, that the body names by its Content-ID or, where that
/// is not known, by the one Outlook builds from its name, as
/// attachmentsShownInBody finds them. A signature's logo is part of the
/// letter, not a file to fingerprint.
///
/// Nothing else marked inline: the mark is the sender's own, Apple Mail
/// puts it on ordinary documents, and such a part is a chip under the
/// message that opens like any file, so an .exe or a fake sign-in page sent
/// that way passed as safe. Nor a picture whose name says it runs, carries
/// macros or is a page.
Set<String> picturesShownIn(String? html, List<MailAttachment> attachments) {
  if (html == null || !namesInlinePictures(html)) return const {};
  final named = contentIdsNamedIn(html);
  bool shown(MailAttachment a) => switch (a.contentId?.toLowerCase()) {
        final own? => named.contains(own),
        null =>
          named.any((id) => id.split('@').first == a.name.toLowerCase()),
      };
  bool picture(MailAttachment a) {
    final declared = a.mimeType.toLowerCase().split(';').first.trim();
    return (declared.startsWith('image/') ? declared : a.openAs)
        .startsWith('image/');
  }

  return {
    for (final a in attachments)
      if (a.isInline && picture(a) && !isRiskyAttachment(a) && shown(a)) a.id,
  };
}

/// What each attachment gives away by its kind: a program or script, a
/// disk image, a name that hides its kind, macros, a web page, an archive.
/// Inline or not, by its name: a picture's gives none of them away (see
/// [picturesShownIn]).
List<ThreatFinding> checkAttachments(List<MailAttachment> attachments) {
  final found = <ThreatFinding>[];
  void add(ThreatLevel level, String title, [String detail = '']) => found
      .add(ThreatFinding(level, ThreatArea.attachments, title, detail: detail));
  for (final a in attachments) {
    final name = a.name.trim();
    final ext = _extensionOf(name);
    final parts = name.toLowerCase().split('.');
    final hides = parts.length > 2 &&
        _runs.contains(ext) &&
        RegExp(r'^[a-z0-9]{2,4}$').hasMatch(parts[parts.length - 2]);
    if (hides) {
      add(ThreatLevel.danger, '$name hides what it is',
          'It reads as a ${parts[parts.length - 2]} but is a .$ext, which '
              'runs when opened.');
    } else if (_runs.contains(ext)) {
      add(ThreatLevel.danger, '$name runs when opened',
          'A .$ext is a program, a script or a disk image.');
    } else if (_macros.contains(ext)) {
      add(ThreatLevel.caution, '$name carries macros',
          'Office files with macros are a common way in for malware.');
    } else if (_pages.contains(ext)) {
      add(ThreatLevel.caution, '$name is a web page',
          'Attached pages are often fake sign-in pages.');
    } else if (_archives.contains(ext)) {
      add(ThreatLevel.safe, '$name is an archive',
          'What is inside it cannot be checked here.');
    }
  }
  return found;
}

/// A message's threat check as it stands: what was found, its links and
/// attachments, and which outside checks were asked.
@immutable
class ThreatReport {
  const ThreatReport({
    required this.findings,
    this.links = const [],
    this.attachments = const [],
    this.safeBrowsing = false,
    this.virusTotal = false,
    this.checking = false,
  });

  final List<ThreatFinding> findings;
  final List<MessageLink> links;
  final List<MailAttachment> attachments;

  /// Whether Google Safe Browsing and VirusTotal were asked: each where
  /// its key is set.
  final bool safeBrowsing;
  final bool virusTotal;

  /// Still asking them.
  final bool checking;

  ThreatLevel get level => worstOf(findings);

  ThreatReport withOnline(
    List<ThreatFinding> found, {
    required bool checking,
  }) =>
      ThreatReport(
        findings: [...findings, ...found],
        links: links,
        attachments: attachments,
        safeBrowsing: safeBrowsing,
        virusTotal: virusTotal,
        checking: checking,
      );
}

/// Google Safe Browsing's name for a threat, as said to a person.
String threatTypeName(String type) => switch (type) {
      'SOCIAL_ENGINEERING' => 'phishing',
      'MALWARE' => 'malware',
      'UNWANTED_SOFTWARE' => 'unwanted software',
      'POTENTIALLY_HARMFUL_APPLICATION' => 'a harmful app',
      _ => 'dangerous',
    };
