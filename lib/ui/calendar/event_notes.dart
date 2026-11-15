import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/files/file_bridge.dart' show MailtoLink;
import '../../data/graph/graph_calendar_api.dart' show GraphCalendarApi;
import '../../domain/calendar_change.dart' show EventNotes;
import '../../domain/calendar_event.dart';
import '../../domain/meeting_links.dart' show throughSafeLinks;
import '../../domain/text_links.dart';
import '../../state/providers.dart';
import '../common/linked_text.dart';
import '../compose/open_compose.dart' show openMailto;

/// How many lines of a meeting's notes show before Show more.
const notesFoldAfter = 12;

/// A meeting's notes at the foot of its sheet (#43): the first lines the
/// calendar's read gave, at once, then the whole of them, asked for once
/// each time the sheet opens, with their web addresses, email addresses
/// and phone numbers a tap away, and a link written as words a tap from
/// its address, as a message's links are. Long notes fold under Show more.
/// Where the whole cannot be had, with no signal or from a calendar that
/// will not answer, the first lines stay and nothing more is said.
class EventNotesView extends ConsumerStatefulWidget {
  const EventNotesView({
    super.key,
    required this.event,
    required this.reachable,
    this.style,
    this.onEmail,
  });

  final CalendarEvent event;

  /// Whether the meeting's calendar can be asked for the whole: one that
  /// an account signed in with Microsoft or Google itself reads, its
  /// holidays, birthdays and shared calendars among them. A calendar from
  /// a link has its first lines alone.
  final bool reachable;
  final TextStyle? style;

  /// A new message to an address tapped in the notes.
  final void Function(String address)? onEmail;

  @override
  ConsumerState<EventNotesView> createState() => _EventNotesViewState();
}

class _EventNotesViewState extends ConsumerState<EventNotesView>
    with AutomaticKeepAliveClientMixin {
  /// The whole of the notes once they have come, with their named links;
  /// null until then, and where they could not be had.
  ShownNotes? _whole;

  /// The sheet builds its rows as they scroll into sight and lets go of
  /// them as they leave it. The notes are kept, so they are asked for once
  /// each time the sheet opens, and Show more stays as Ron left it.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // A meeting with no first lines has no notes to ask for.
    if (widget.reachable && widget.event.preview.trim().isNotEmpty) {
      unawaited(_fetch());
    }
  }

  Future<void> _fetch() async {
    try {
      final notes =
          await ref.read(mailEngineProvider).eventNotes(widget.event);
      final whole = notesAsShown(notes);
      if (mounted && whole.text.isNotEmpty) setState(() => _whole = whole);
    } catch (e) {
      debugPrint('[myemail] the whole of the notes not read: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final text = _whole?.text ?? widget.event.preview.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: LinkedText(
        text,
        key: const ValueKey('event-notes'),
        links: _whole?.links ?? const [],
        style: widget.style,
        foldAfter: notesFoldAfter,
        onEmail: widget.onEmail,
      ),
    );
  }
}

/// A new message to [address], an email address tapped in a meeting's
/// notes, from [accountId]'s account where the meeting is one of its own.
Future<void> writeTo(
  BuildContext context,
  WidgetRef ref,
  String address, {
  String? accountId,
}) =>
    openMailto(context, ref, MailtoLink(to: [address]), accountId: accountId);

/// A meeting's notes as its sheet shows them: their text, and the links
/// written as words in it, by where they are in the text.
typedef ShownNotes = ({String text, List<TextLink> links});

/// [notes] as the sheet shows them: what was written, and under it the
/// lines of Exchange's Teams block, its dial-in numbers among them, as the
/// meeting screen shows the block. Without the rows of underscores the
/// block is fenced with, which a page draws as a rule and text as a line
/// and a half of nothing.
///
/// Where the notes are a page, a link written as words ("Q3 deck.pptx",
/// "Click here for the agenda") keeps its address: its words are a tap
/// from it, as in a message, and one with no words shows its address. Only
/// an address a message's link would open (http, https, mailto, tel); any
/// other stays the words it was.
ShownNotes notesAsShown(EventNotes notes) {
  // Each link stands in the page as marks around its words while the page
  // becomes text, and the marks are read out once it has.
  final targets = <Uri>[];
  String marked(String html) => html.replaceAllMapped(_anchor, (m) {
        final target = _target(_unescaped(m[1] ?? m[2] ?? m[3] ?? ''));
        if (target == null) return m[4]!;
        targets.add(target);
        return '$_open${targets.length - 1}$_words${m[4]}$_close';
      });
  final html = notes.html;
  final below = notes.keptBelow;
  final text = [
    html == null
        ? notes.text.trim()
        : GraphCalendarApi.textOfHtml(marked(html)).trim(),
    if (below != null) GraphCalendarApi.inviteTextOf(marked(below)),
  ].where((part) => part.isNotEmpty).join('\n\n');
  return _readOut(
    text
        .split('\n')
        .where((line) => !_rule.hasMatch(line))
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim(),
    targets,
  );
}

final _rule = RegExp(r'^\s*_{10,}\s*$');

/// An HTML link with an address, and its words: the address in double
/// quotes, single quotes or none.
final _anchor = RegExp(
  r'''<a\s+(?:[^>]*?\s)?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))'''
  r'''[^>]*>(.*?)</a\s*>''',
  caseSensitive: false,
  dotAll: true,
);

/// The marks a link stands as in the page while it becomes text: before
/// the number of its address, before its words, and after them. Characters
/// of Unicode's private area, which no page writes and nothing on the way
/// takes out.
const _open = '\u{E000}', _words = '\u{E001}', _close = '\u{E002}';
final _marks = RegExp('[$_open$_words$_close]');

/// [marked], the notes as text with each link's marks still in, as the
/// text the sheet shows and the links in it, to [targets].
ShownNotes _readOut(String marked, List<Uri> targets) {
  final text = StringBuffer();
  final links = <TextLink>[];
  var at = 0;
  while (at < marked.length) {
    final open = marked.indexOf(_open, at);
    if (open < 0) {
      text.write(marked.substring(at).replaceAll(_marks, ''));
      break;
    }
    text.write(marked.substring(at, open).replaceAll(_marks, ''));
    final words = marked.indexOf(_words, open);
    final close = words < 0 ? -1 : marked.indexOf(_close, words);
    final index =
        close < 0 ? null : int.tryParse(marked.substring(open + 1, words));
    if (index == null || index < 0 || index >= targets.length) {
      // A mark on its own, or one the page wrote itself: dropped.
      at = open + 1;
      continue;
    }
    final target = targets[index];
    var shown = marked.substring(words + 1, close).replaceAll(_marks, '');
    if (shown.trim().isEmpty) {
      shown = target.isScheme('http') || target.isScheme('https')
          ? '$target'
          : _decoded(target.path);
    }
    // The link is its words, not the spaces either side of them.
    final start = text.length + shown.length - shown.trimLeft().length;
    text.write(shown);
    final end = text.length - (shown.length - shown.trimRight().length);
    if (end > start && _saysElsewhere(shown, target)) {
      // Words that are an address, an email address or a number of their
      // own, and the link goes elsewhere: the oldest way to fool someone.
      // The words stay words, which open only what they say themselves, as
      // in plain text, and where the link goes is shown beside them, and
      // is the link: what Ron sees is where a tap takes him.
      text.write(' (');
      final from = text.length;
      text.write(_destinationOf(target));
      links.add(TextLink(from, text.length, _kindOf(target), target));
      text.write(')');
    } else if (end > start) {
      links.add(TextLink(start, end, _kindOf(target), target));
    }
    at = close + 1;
  }
  return (text: text.toString(), links: links);
}

/// Whether [words], a link's own, are an address, an email address or a
/// number themselves, in whole or in part, that [target] is not: another
/// host for a web address (Safe Links' wrapping of the same host is the
/// same), another address for an email address, other digits for a number.
/// Ordinary words ("Q3 deck.pptx", "Click here") say nothing of where they
/// go.
bool _saysElsewhere(String words, Uri target) {
  final found = linksInText(words);
  final said = [
    ...found,
    for (final m in _bareHost.allMatches(words))
      if (!_fileKinds.contains(m[2]!.toLowerCase()) &&
          !found.any((f) => m.start < f.end && f.start < m.end))
        TextLink(m.start, m.end, TextLinkKind.web,
            Uri(scheme: 'https', host: m[1]!.toLowerCase())),
  ];
  return said.any((s) => !_goesTo(s, target));
}

/// Whether [target] goes where [said], an address in a link's words, says.
bool _goesTo(TextLink said, Uri target) => switch (said.kind) {
      TextLinkKind.web =>
        (target.isScheme('http') || target.isScheme('https')) &&
            _sameHost(
              said.target.host,
              (throughSafeLinks(target) ?? target).host,
            ),
      TextLinkKind.email => target.isScheme('mailto') &&
          _decoded(said.target.path).toLowerCase() ==
              _decoded(target.path).toLowerCase(),
      TextLinkKind.phone =>
        target.isScheme('tel') && _numberOf(said.target) == _numberOf(target),
    };

/// The same host, a www. in front of either or not.
bool _sameHost(String a, String b) {
  String bare(String host) {
    final h = host.toLowerCase();
    return h.startsWith('www.') ? h.substring(4) : h;
  }

  return bare(a) == bare(b);
}

/// A number to ring's own digits: before any pause, and a dial-in's code.
String _numberOf(Uri tel) =>
    _decoded(tel.path).split(',').first.replaceAll(RegExp(r'\D'), '');

/// Where [target] goes, as shown beside words that say otherwise: a web
/// page's host (through Safe Links, the host of the page it holds), an
/// email address, a number to ring.
String _destinationOf(Uri target) =>
    target.isScheme('http') || target.isScheme('https')
        ? (throughSafeLinks(target) ?? target).host
        : _decoded(target.path);

/// A host written bare, with no https:// or www. before it, as words
/// write one: hadco.sharepoint.com, hadco.sharepoint.com/q3.
final _bareHost = RegExp(
  r'(?<![\w@.-])((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+([a-z]{2,24}))'
  r'(?![\w-])',
  caseSensitive: false,
);

/// What a file's name ends in, which a host's never does here: Q3
/// deck.pptx is a file's name, not a place on the web.
const _fileKinds = {
  'pdf', 'doc', 'docx', 'docm', 'dot', 'dotx', 'xls', 'xlsx', 'xlsm',
  'xlsb', 'ppt', 'pptx', 'pptm', 'pps', 'ppsx', 'txt', 'csv', 'rtf', 'odt',
  'ods', 'odp', 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'svg', 'webp', 'heic',
  'tif', 'tiff', 'zip', 'rar', 'gz', 'tar', 'mp3', 'mp4', 'mov', 'avi',
  'wav', 'm4a', 'msg', 'eml', 'ics', 'vcf', 'htm', 'html', 'xml', 'json',
  'js', 'ts', 'py', 'java', 'md', 'log', 'exe', 'msi', 'apk', 'dmg', 'iso',
  'one', 'vsd', 'vsdx', 'mpp', 'pub', 'key', 'pages', 'numbers', 'dwg',
  'dxf', 'step', 'stp', 'igs',
};

/// [s] with its %-escapes read, or as it is where one does not read.
String _decoded(String s) {
  try {
    return Uri.decodeComponent(s);
  } on ArgumentError {
    return s;
  } on FormatException {
    return s;
  }
}

/// Where a message's link to [address] goes, as the gate it goes through
/// takes it (`openExternally`: http, https, mailto, tel), each with
/// somewhere to go; null for anywhere else. A number to ring is rung as a
/// number in the notes' text is: its digits, pauses and code, the code's #
/// kept, from a + or a digit, so never a code to the phone (*21*…#).
/// What a tel: link writes after a ; is not the number: an extension, or
/// digits for once the call is answered, go after a pause, as a phone dials
/// them; anything else there is not dialled.
Uri? _target(String address) {
  final uri = Uri.tryParse(address);
  if (uri == null) return null;
  switch (uri.scheme.toLowerCase()) {
    case 'http' || 'https':
      return uri.host.isEmpty ? null : uri;
    case 'mailto':
      final to = _decoded(uri.path).trim();
      if (to.isEmpty) return null;
      return Uri(
        scheme: 'mailto',
        path: to,
        query: uri.hasQuery ? uri.query : null,
      );
    case 'tel':
      final String written;
      try {
        written = Uri.decodeComponent(address.substring(4));
      } on ArgumentError {
        return null;
      } on FormatException {
        return null;
      }
      final parts = written.split(';');
      var dial = parts.first.replaceAll(RegExp(r'[^\d+,*#]'), '');
      for (final part in parts.skip(1)) {
        final equals = part.indexOf('=');
        if (equals < 0) continue;
        final value = part.substring(equals + 1);
        switch (part.substring(0, equals).trim().toLowerCase()) {
          case 'ext':
            final ext = value.replaceAll(RegExp(r'\D'), '');
            if (ext.isNotEmpty) dial = '$dial,$ext';
          case 'postd':
            final after = value
                .toLowerCase()
                .replaceAll(RegExp('[pw]'), ',')
                .replaceAll(RegExp(r'[^\d*#,]'), '');
            if (after.replaceAll(',', '').isNotEmpty) {
              dial = '$dial${after.startsWith(',') ? '' : ','}$after';
            }
        }
      }
      final digits =
          dial.split(',').first.replaceAll(RegExp(r'\D'), '').length;
      if (!RegExp(r'^\+?\d').hasMatch(dial) || digits < 7 || digits > 15) {
        return null;
      }
      return Uri(scheme: 'tel', path: dial);
    default:
      return null;
  }
}

TextLinkKind _kindOf(Uri address) => address.isScheme('mailto')
    ? TextLinkKind.email
    : address.isScheme('tel')
        ? TextLinkKind.phone
        : TextLinkKind.web;

/// An attribute's value as the page means it: its entities read.
String _unescaped(String value) => value
    .replaceAllMapped(RegExp(r'&#[xX]([0-9a-fA-F]+);'),
        (m) => _char(int.tryParse(m[1]!, radix: 16)))
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => _char(int.tryParse(m[1]!)))
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .trim();

String _char(int? code) =>
    code == null || code > 0x10FFFF ? '' : String.fromCharCode(code);
