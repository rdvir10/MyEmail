import 'calendar_event.dart';
import 'meeting_link.dart' show knownMeetingService;

/// Links to join an online meeting (calendar idea #39), found in what
/// someone else wrote: a meeting's place and notes, and an invitation's
/// lines. Anyone who sends Ron an invitation writes those, so a link is
/// taken only where it is one of the services below, by the host its
/// parsed address names, exactly or as a name under it, never by the
/// letters it holds; only over https; and, where the service has pages
/// besides its meetings, only on a path that joins one.
/// zoom.us.example.com, evilzoom.us, an http:// link and a host with a
/// letter from another alphabet in it are none of them Zoom. A link a
/// work mailbox has inside Microsoft Defender's Safe Links is known by the
/// link it holds, and kept, and opened, as Safe Links gives it.

/// The first link in [text] that joins a meeting, as it is written there;
/// null for none. [mayBeCut] is for text that may stop part way through,
/// a calendar's first lines of a meeting's notes: a link that runs to its
/// very end may have lost its last part, a passcode or a digit of the
/// meeting, and is passed over.
String? meetingLinkIn(String? text, {bool mayBeCut = false}) {
  if (text == null || text.isEmpty) return null;
  for (final (link, atEnd) in _candidates(text)) {
    if (mayBeCut && atEnd) continue;
    final found = _joinLink(link);
    if (found != null) return found;
  }
  return null;
}

/// What to look a meeting's [place] up by in a maps app (#40): the place
/// as written, less any part that only names an online meeting or is a
/// link, Outlook's "Microsoft Teams Meeting; Room 4" being Room 4. Null
/// where nothing is left to find: a place that is a meeting's link, or
/// says only "Microsoft Teams Meeting", has Join instead.
String? placeToFind(String place) {
  final parts = [
    for (final part in place.split(';')) ?_somewhere(part),
  ];
  return parts.isEmpty ? null : parts.join('; ');
}

/// [part] of a place, without its links and the signs that led to them,
/// where what is left is somewhere: words, and not an online meeting's
/// name.
String? _somewhere(String part) {
  final words = part
      .replaceAll(RegExp(r'(?:https?://|www\.)\S*', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s:,|/·–—-]+|[\s:,|/·–—-]+$'), '');
  if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(words)) return null;
  final name = words
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), '')
      .trim();
  return _onlineNames.contains(name) ? null : words;
}

/// A meeting's [place] for one line: a list's row, a block, a reminder, the
/// meeting's sheet. As written, but with each link in it named, never
/// written out. A Zoom link as a meeting's place is a line of letters with
/// its passcode in it (seen in the Agenda on the tablet, 2026-11-16);
/// "Zoom" says where, without the passcode a link carries. A link is named
/// by its service, or by its host, less www., where the service is not one
/// known here; one inside Safe Links by the link it holds. The words beside
/// a link stay, and where they say its service already it is not said
/// twice. Empty for a place with nothing to say.
///
/// Only links are taken out: one written from https://, http:// or www.
/// A passcode written out in words beside one stays, and so does an
/// address written with none of those.
String placeNamed(String place) {
  if (!_writtenLink.hasMatch(place)) return place.trim();
  final words = _besideLinks(place.replaceAll(_writtenLink, ' '));
  final said = words.toLowerCase();
  final names = <String>[];
  for (final m in _writtenLink.allMatches(place)) {
    final name = _linkName(m[0]!);
    if (names.contains(name)) continue;
    if (said.contains(name.toLowerCase())) continue;
    names.add(name);
  }
  return [if (words.isNotEmpty) words, ...names].join(' · ');
}

/// The link to open from a meeting's [place] that is nowhere to find on a
/// map ([placeToFind] is null) and is not a meeting's own link, which Join
/// opens: a map's link, or a document's, written as the place. As it is
/// written, Safe Links' wrapping and all. Null for a place with none.
///
/// Its name is all that is shown of it ([placeNamed]), so without this a
/// place that was only such a link could no longer be read or opened.
Uri? placeLinkToOpen(String place) {
  for (final m in _writtenLink.allMatches(place)) {
    final link = _asWritten(m[0]!);
    if (_joinLink(link) != null) continue;
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) continue;
    if (uri.isScheme('https') || uri.isScheme('http')) return uri;
  }
  return null;
}

/// Where [e] is, for one line: its place with its links named
/// ([placeNamed]); "Online" for one held online with no place written;
/// null with neither.
String? placeLine(CalendarEvent e) {
  final place = placeNamed(e.location);
  if (place.isNotEmpty) return place;
  return e.joinUrl != null ? 'Online' : null;
}

/// A link as it is written in a place: from https://, http:// or a www.
/// that begins a word, to the next space.
final _writtenLink = RegExp(
  r'(?:https?://|(?<![\p{L}\p{N}])www\.)\S+',
  caseSensitive: false,
  unicode: true,
);

/// [written], a link as [_writtenLink] found it, as a link to read: without
/// the full stop, comma or bracket that closed the words around it, and
/// with its https:// where it was written from www.
String _asWritten(String written) {
  final link = written.replaceFirst(RegExp(r'''[.,;:!?)\]}>'"]+$'''), '');
  return link.toLowerCase().startsWith('www.') ? 'https://$link' : link;
}

/// What is left of a place with its links taken out: its words, without
/// the signs that led to a link or held it. Empty where no word is left.
String _besideLinks(String text) {
  final words = text
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(
          RegExp(r'^[\s:,;|/·–—()\[\]<>-]+|[\s:,;|/·–—()\[\]<>-]+$'), '');
  return RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(words) ? words : '';
}

/// What [written], a link in a place, is called: its service, or its host
/// less www., in its own letters. "Link" for one with no host to name, so
/// a place that is only such a link still has a line.
String _linkName(String written) {
  final uri = Uri.tryParse(_asWritten(written));
  if (uri == null || uri.host.isEmpty) return 'Link';
  final target = throughSafeLinks(uri) ?? uri;
  final known = knownMeetingService(target.toString());
  if (known != null) return known;
  var host = target.host;
  try {
    // A name in another alphabet comes back as %d7%93…: as it is written.
    host = Uri.decodeComponent(host);
  } on ArgumentError {
    // Not to be read: as it came.
  }
  host = host.replaceFirst(RegExp(r'\.+$'), '');
  if (host.toLowerCase().startsWith('www.')) host = host.substring(4);
  return host.isEmpty ? 'Link' : host;
}

/// What a place says that names nowhere but an online meeting, in lower
/// case: Outlook's own words for a Teams meeting's place, in English and
/// in Hebrew, and the services' names.
const _onlineNames = {
  'microsoft teams meeting', 'microsoft teams', 'teams meeting', 'teams',
  'פגישת microsoft teams', 'google meet', 'meet', 'google hangouts',
  'hangouts', 'zoom', 'zoom meeting', 'webex', 'webex meeting',
  'cisco webex', 'skype', 'skype meeting', 'skype for business',
  'skype for business meeting', 'gotomeeting', 'goto meeting',
  'ringcentral', 'ringcentral video', 'bluejeans', 'whereby',
  'amazon chime', 'chime', 'jitsi', 'jitsi meet', 'online',
  'online meeting', 'virtual', 'virtual meeting',
};

/// [read], what a read of a calendar that did not look in its meetings'
/// notes found, each with the link the device [kept] for it where the read
/// found none: the same meeting, with the same place and the same first
/// lines of notes, as far as such a read can tell. A read longer than a
/// few days asks for no notes, and would otherwise take away every link
/// the reads of days found in them. What a read of days found is what is
/// kept for its days, so a link it found gone is not kept to be carried,
/// and a longer read asked before it is not kept over it (see
/// `readIsStale`).
List<CalendarEvent> withLinksKept(
  List<CalendarEvent> read,
  Iterable<CalendarEvent> kept,
) {
  final links = {
    for (final k in kept)
      if (k.joinUrl != null) (k.calendarId, k.id): k,
  };
  if (links.isEmpty) return read;
  CalendarEvent withLink(CalendarEvent e) {
    if (e.joinUrl != null) return e;
    final k = links[(e.calendarId, e.id)];
    if (k == null || k.location != e.location || k.preview != e.preview) {
      return e;
    }
    return e.copyWith(joinUrl: k.joinUrl);
  }

  return [for (final e in read) withLink(e)];
}

/// The longest link taken: a Teams link and its context run to some
/// hundreds of characters, and one inside Safe Links to more.
const _longest = 4096;

final _https = RegExp('https://', caseSensitive: false);

/// What a link written out in text can hold: printable ASCII but for the
/// space, quotes, angle brackets and the few others none holds unescaped.
/// A letter from another alphabet ends it too.
bool _inLink(int c) => c > 0x20 && c < 0x7f && !_notInLinks.contains(c);

final _notInLinks = '<>"\'`{}|\\^[]'.codeUnits.toSet();

/// The signs a link broken across lines could not have ended on: each
/// leads into more of it.
final _leadOn = '=&?%'.codeUnits.toSet();

/// Each link in [text], as it may be meant, in turn, and whether it runs to
/// the very end of [text].
Iterable<(String, bool)> _candidates(String text) sync* {
  for (final m in _https.allMatches(text)) {
    final start = m.start;
    // In angle brackets, as Outlook writes a link after its words ("Click
    // here to join the meeting<https://…>"): to the bracket that closes
    // it, put back together where a line break fell inside.
    if (start > 0 && text.codeUnitAt(start - 1) == 0x3c) {
      final close = text.indexOf('>', start);
      if (close > 0 && close - start <= _longest) {
        final inside = text.substring(start, close);
        if (inside.contains('\n') && !inside.contains('<')) {
          yield (_trimmed(inside.replaceAll(RegExp(r'\s+'), '')), false);
        }
      }
    }
    final link = StringBuffer();
    var from = start;
    var at = m.end;
    while (true) {
      while (at < text.length && _inLink(text.codeUnitAt(at))) {
        at++;
      }
      link.write(text.substring(from, at));
      // Broken across lines where it could not have ended: the next line
      // is more of it.
      final next = _afterLineBreak(text, at);
      if (next < 0 ||
          next >= text.length ||
          !_inLink(text.codeUnitAt(next)) ||
          !_leadOn.contains(text.codeUnitAt(at - 1)) ||
          link.length > _longest) {
        break;
      }
      from = next;
      at = next;
    }
    yield (_trimmed(link.toString()), at >= text.length);
  }
}

/// Where the line after a line break at [at] begins, or -1 where there is
/// none there.
int _afterLineBreak(String text, int at) {
  if (at < text.length && text.codeUnitAt(at) == 0x0a) return at + 1;
  if (at + 1 < text.length &&
      text.codeUnitAt(at) == 0x0d &&
      text.codeUnitAt(at + 1) == 0x0a) {
    return at + 2;
  }
  return -1;
}

/// [link] as the link it is: its ampersands as an HTML page writes them
/// read back, and without the full stop, comma or bracket of the sentence
/// it ends.
String _trimmed(String link) {
  var s = link.replaceAll(
      RegExp(r'&(?:amp|#0*38|#x0*26);', caseSensitive: false), '&');
  while (s.isNotEmpty) {
    final last = s[s.length - 1];
    final unopened =
        last == ')' && '('.allMatches(s).length < ')'.allMatches(s).length;
    if (!'.,;:!?*'.contains(last) && !unopened) break;
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// What comes between https:// and the path.
final _authority = RegExp(r'^https://([^/?#]*)', caseSensitive: false);

/// A host as a link to a meeting writes it: plain letters, digits, dots
/// and hyphens. So no name in another alphabet, no %-escape, nobody@ in
/// front of it, and no port but https' own.
final _plainHost = RegExp(r'^[A-Za-z0-9.-]+(:443)?$');

/// [link], as written, where it joins a meeting on a known service, or is
/// Safe Links' wrapping of a link that does. A link written out never has
/// a space in it; one held inside Safe Links might.
String? _joinLink(String link, {bool unwrap = true}) {
  if (link.length > _longest || _space.hasMatch(link)) return null;
  final authority = _authority.firstMatch(link)?[1];
  if (authority == null || !_plainHost.hasMatch(authority)) return null;
  final Uri uri;
  final List<String> path;
  try {
    uri = Uri.parse(link);
    path = [...uri.pathSegments];
  } on FormatException {
    return null;
  }
  if (uri.scheme != 'https') return null;
  while (path.isNotEmpty && path.last.isEmpty) {
    path.removeLast();
  }
  final host = uri.host;
  // Microsoft Defender's Safe Links, which a work mailbox's invitations
  // come through. The link it holds, held to the same rules, says whether
  // this is a meeting's; it is opened as Safe Links gives it, so Defender
  // still checks it when it is tapped. That is Hadco IT's to set.
  if (unwrap && _under(host, 'safelinks.protection.outlook.com')) {
    final inner = _theOneUrl(uri);
    final joins = inner != null && _joinLink(inner, unwrap: false) != null;
    return joins ? link : null;
  }
  for (final (domain, joins) in _services) {
    if (_under(host, domain)) return joins(path) ? link : null;
  }
  return null;
}

final _space = RegExp(r'\s');

/// Where [link] goes when it is Microsoft Defender's Safe Links: the one
/// link it holds, by the rule Join holds it to (see [_theOneUrl]). Null for
/// a link that is not Safe Links', and for one that holds none, or two.
Uri? throughSafeLinks(Uri link) {
  if (!link.isScheme('https') ||
      !_under(link.host, 'safelinks.protection.outlook.com')) {
    return null;
  }
  final inner = _theOneUrl(link);
  return inner == null || _space.hasMatch(inner) ? null : Uri.tryParse(inner);
}

/// The link [wrapper], a Safe Links address, holds: where it has one
/// parameter named url, in any case, with one value; null otherwise. What
/// is opened must be what was checked, and Defender may follow the first
/// of two url values, or a URL= in capitals, where Dart reads the last
/// url= alone.
String? _theOneUrl(Uri wrapper) {
  final Map<String, List<String>> all;
  try {
    all = wrapper.queryParametersAll;
  } on FormatException {
    return null;
  }
  final named = [
    for (final MapEntry(:key, :value) in all.entries)
      if (key.toLowerCase() == 'url') value,
  ];
  if (named.length != 1 || named.single.length != 1) return null;
  return named.single.single;
}

/// Whether [host] is [domain] or a name under it.
bool _under(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

/// The services, by the domain their links are on, and whether a path
/// there, by its parts, joins a meeting.
final List<(String, bool Function(List<String>))> _services = [
  ('zoom.us', _zoom),
  ('zoomgov.com', _zoom),
  ('webex.com', _webex),
  ('gotomeeting.com', (p) => _after(p, 'join') && _digits(p[1])),
  ('gotomeet.me', _oneName),
  ('meet.goto.com', _oneName),
  ('ringcentral.com', (p) => _after(p, 'j') || _after(p, 'join')),
  ('bluejeans.com', (p) => p.isNotEmpty && _digits(p[0])),
  (
    'whereby.com',
    (p) => _oneName(p) && !_wherebyPages.contains(p[0].toLowerCase()),
  ),
  ('chime.aws', (p) => p.isNotEmpty && _digits(p[0]) || _after(p, 'meetings')),
  (
    'teams.microsoft.com',
    (p) => p.length >= 3 && _is(p[0], 'l') && _is(p[1], 'meetup-join') ||
        _after(p, 'meet'),
  ),
  ('teams.live.com', (p) => _after(p, 'meet')),
  (
    'meet.google.com',
    (p) => p.length == 1 && _meetCode.hasMatch(p[0]) ||
        p.length == 2 && _after(p, 'lookup'),
  ),
  ('join.skype.com', (p) => _oneName(p) || _after(p, 'invite')),
  ('meet.jit.si', _oneName),
];

/// Whether [p] goes on past [word], its first part, to a meeting's own.
bool _after(List<String> p, String word) =>
    p.length >= 2 && _is(p[0], word) && p[1].isNotEmpty;

/// Zoom's meeting (/j/), webinar (/w/) and personal room (/my/).
bool _zoom(List<String> p) =>
    p.length >= 2 &&
    switch (p[0].toLowerCase()) {
      'j' || 'w' => _digits(p[1]),
      'my' => p[1].isNotEmpty,
      _ => false,
    };

/// Webex's meeting (j.php), personal room (/meet/, /join/), and joining
/// from the browser.
bool _webex(List<String> p) {
  final s = [for (final x in p) x.toLowerCase()];
  return s.isNotEmpty &&
      (s.last == 'j.php' ||
          s.length >= 2 && (s[0] == 'meet' || s[0] == 'join') ||
          s[0] == 'wbxmjs' && s.contains('joinservice') ||
          s[0] == 'webappng' && s.contains('meeting'));
}

/// A room by its name alone.
bool _oneName(List<String> p) => p.length == 1 && p[0].isNotEmpty;

/// Whereby's own pages, each a name alone as a room is.
const _wherebyPages = {
  'about', 'blog', 'download', 'embed', 'help', 'information', 'legal',
  'login', 'org', 'pricing', 'privacy', 'product', 'signup', 'support',
  'terms', 'user',
};

/// A Meet meeting's code: abc-defg-hij.
final _meetCode =
    RegExp(r'^[a-z]{3}-[a-z]{4}-[a-z]{3}$', caseSensitive: false);

bool _is(String part, String word) => part.toLowerCase() == word;

bool _digits(String s) => RegExp(r'^\d+$').hasMatch(s);
