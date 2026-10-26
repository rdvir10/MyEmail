import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

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
  return uri;
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
/// like "Click here".
String? _domainShown(String text) {
  final m = RegExp(
    r'^(?:https?://)?(?:www\.)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?:[/:?#]\S*)?$',
    caseSensitive: false,
  ).firstMatch(text.trim());
  return m?[1]?.toLowerCase();
}

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
    if (host.split('.').any((p) => p.startsWith('xn--'))) {
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

/// What each attachment gives away by its kind: a program or script, a
/// disk image, a name that hides its kind, macros, a web page, an archive.
List<ThreatFinding> checkAttachments(List<MailAttachment> attachments) {
  final found = <ThreatFinding>[];
  void add(ThreatLevel level, String title, [String detail = '']) => found
      .add(ThreatFinding(level, ThreatArea.attachments, title, detail: detail));
  for (final a in attachments) {
    if (a.isInline) continue;
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
