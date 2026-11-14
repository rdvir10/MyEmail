import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// How finely a date found in text is known, as ML Kit's DateTimeEntity
/// says: "October" is a month, "Tuesday" a day, "3pm" a time.
enum DateGrain { year, month, week, day, hour, minute, second }

/// A date or time found in a piece of text by the phone's ML Kit: where in
/// the text, what it says there, and when it means.
@immutable
class FoundDate {
  const FoundDate({
    required this.start,
    required this.end,
    required this.text,
    required this.at,
    required this.grain,
  });

  /// Where it is in the text it was found in.
  final int start;
  final int end;

  /// What the text says: "Thursday at 1pm".
  final String text;

  /// When it means, on the phone's clock.
  final DateTime at;
  final DateGrain grain;

  /// A time of day, not only a day.
  bool get hasTime => grain.index >= DateGrain.hour.index;

  /// A day at least: "Tuesday", "3pm tomorrow". A month or a year alone is
  /// no meeting's time.
  bool get isDay => grain.index >= DateGrain.day.index;

  /// What the bridge sent, or null for anything else.
  static FoundDate? fromMap(Object? map) {
    if (map is! Map) return null;
    final start = map['start'], end = map['end'], text = map['text'];
    final at = map['at'], grain = map['granularity'];
    if (start is! int || end is! int || text is! String || at is! int) {
      return null;
    }
    return FoundDate(
      start: start,
      end: end,
      text: text,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      grain: grain is int && grain >= 0 && grain < DateGrain.values.length
          ? DateGrain.values[grain]
          : DateGrain.day,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FoundDate &&
      other.start == start &&
      other.end == end &&
      other.text == text &&
      other.at == at &&
      other.grain == grain;

  @override
  int get hashCode => Object.hash(start, end, text, at, grain);

  @override
  String toString() => 'FoundDate($text: $at)';
}

/// A meeting typed in a line, as read from it: what it is, when, where.
typedef QuickMeeting = ({
  String title,
  DateTime? start,
  DateTime? end,
  bool allDay,
  String location,
});

/// The little words that join a time on, left hanging when it is taken out.
final _joiners = RegExp(
  r'^(?:on|at|from|to|until|till|by|between|and|for|-|–|,)$',
  caseSensitive: false,
);

/// [line], "Lunch with Dana Thursday 1pm at Café Noir", as a meeting:
/// the first day or time [dates] found in it is when (a second time later
/// that day, when it ends), "at" or "in" what is left names the place, and
/// the rest is the title. A day with no time is a whole day. Nothing found
/// leaves the whole line as the title, and no time.
QuickMeeting readQuickMeeting(
  String line,
  List<FoundDate> dates, {
  Duration length = const Duration(hours: 1),
}) {
  final found = [
    for (final d in dates)
      if (d.isDay && d.start >= 0 && d.end <= line.length && d.start < d.end) d,
  ]..sort((a, b) => a.start.compareTo(b.start));
  if (found.isEmpty) {
    return (
      title: line.trim(),
      start: null,
      end: null,
      allDay: false,
      location: '',
    );
  }
  final first = found.first;
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  final until = found
      .skip(1)
      .where((d) =>
          first.hasTime &&
          d.hasTime &&
          d.at.isAfter(first.at) &&
          sameDay(d.at, first.at))
      .firstOrNull;

  // The line with what was read as the time taken out, last first so the
  // places of the others hold.
  var rest = line;
  for (final d in [?until, first]..sort((a, b) => b.start.compareTo(a.start))) {
    rest = '${rest.substring(0, d.start)} \u0000 ${rest.substring(d.end)}';
  }
  // The words around each gap that only joined the time on.
  final words = rest.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final kept = <String>[];
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (w == '\u0000') continue;
    final nextIsGap = i + 1 < words.length && words[i + 1] == '\u0000';
    final afterGap = i > 0 && words[i - 1] == '\u0000';
    final last = i + 1 == words.length;
    // Before a time it joined it on ("on Tuesday"); after one, only where
    // nothing follows but another time ("2pm to 3pm") or the end. "At" a
    // place after the time stays, and names the place.
    if (_joiners.hasMatch(w) && (nextIsGap || (afterGap && last))) continue;
    kept.add(w);
  }
  while (kept.isNotEmpty && _joiners.hasMatch(kept.last)) {
    kept.removeLast();
  }
  final text = kept.join(' ');
  final place = RegExp(r'^(.+?)\s+(?:at|in|@)\s+(.+)$', caseSensitive: false)
      .firstMatch(text);
  final title = (place?[1] ?? text).trim();
  final location = (place?[2] ?? '').trim();

  if (!first.hasTime) {
    final day = DateTime(first.at.year, first.at.month, first.at.day);
    return (
      title: title,
      start: day,
      end: day,
      allDay: true,
      location: location,
    );
  }
  return (
    title: title,
    start: first.at,
    end: until?.at ?? first.at.add(length),
    allDay: false,
    location: location,
  );
}

/// The address a date link in a message points to, which the reading pane
/// catches: the time, and whether it is a whole day.
String dateLinkOf(FoundDate d) =>
    'myemail-date:${d.at.millisecondsSinceEpoch}:${d.hasTime ? 'time' : 'day'}';

/// What [dateLinkOf] wrote: when, and whether a whole day; null for any
/// other address.
({DateTime at, bool allDay})? readDateLink(String url) {
  final m = RegExp(r'^myemail-date:(\d+):(time|day)$').firstMatch(url);
  if (m == null) return null;
  return (
    at: DateTime.fromMillisecondsSinceEpoch(int.parse(m[1]!)),
    allDay: m[2] == 'day',
  );
}

/// The dates in a message worth a link: a day or a time, from today on.
/// Last week's meeting is no meeting to make.
List<FoundDate> datesWorthLinking(List<FoundDate> dates, {DateTime? now}) {
  final today = () {
    final n = now ?? DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }();
  return [
    for (final d in dates)
      if (d.isDay && !d.at.isBefore(today) && d.text.trim().length > 2) d,
  ];
}

/// The longest message [withDateLinks] reads, in characters. A message
/// is parsed whole to find its text; past this, it is left without links.
const dateLinksUpTo = 300000;

/// How many tags a message may open for [withDateLinks] to read it; see
/// [tagsOpened]. A long thread from Outlook, a few to a line, is inside
/// it; a newsletter that big goes without links.
const dateLinksTagsUpTo = 5000;

/// How long [withDateLinksAway] lets its isolate work: past this the
/// isolate is stopped, and the message is shown without date links.
const dateLinksWithin = Duration(seconds: 5);

/// [html] with each of [dates]' words in its text made a link the reading
/// pane catches ([dateLinkOf]), dotted under as Outlook marks them. Only
/// text: never inside a link already, a script, a style or the head. Words
/// split across tags ("<b>Tuesday</b> at 3pm") are left as they are.
///
/// Left as it is past [dateLinksUpTo], or opening more than
/// [dateLinksTagsUpTo] tags. The parser walks every element still open at
/// many a tag, so thousands nested cost it the square of that: 20,000
/// `<div>`s took most of a minute on a desktop, and the walk below then
/// ran out of stack. How deep they nest cannot be told from the tags
/// without parsing (a `<div/>` stays open; a stray `</span>` closes
/// nothing), but whatever is open was opened by a tag, or copied from one.
String withDateLinks(String html, List<FoundDate> dates) {
  if (dates.isEmpty ||
      html.length > dateLinksUpTo ||
      tagsOpened(html) > dateLinksTagsUpTo) {
    return html;
  }
  final targets = <String, FoundDate>{};
  for (final d in dates) {
    targets.putIfAbsent(d.text, () => d);
  }
  final texts = targets.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final pattern = RegExp(texts.map(RegExp.escape).join('|'));
  final doc = html_parser.parse(html);
  var changed = false;
  void walk(dom.Node node) {
    for (final child in [...node.nodes]) {
      if (child is dom.Element) {
        const skip = {'a', 'script', 'style', 'head', 'title', 'textarea'};
        if (skip.contains(child.localName)) continue;
        walk(child);
        continue;
      }
      if (child is! dom.Text) continue;
      final text = child.text;
      final matches = pattern.allMatches(text).toList();
      if (matches.isEmpty) continue;
      final parts = <dom.Node>[];
      var at = 0;
      for (final m in matches) {
        if (m.start > at) parts.add(dom.Text(text.substring(at, m.start)));
        final link = dom.Element.tag('a')
          ..attributes['href'] = dateLinkOf(targets[m[0]]!)
          ..attributes['style'] =
              'color:inherit;text-decoration:underline dotted'
          ..append(dom.Text(m[0]));
        parts.add(link);
        at = m.end;
      }
      if (at < text.length) parts.add(dom.Text(text.substring(at)));
      final parent = child.parentNode!;
      final index = parent.nodes.indexOf(child);
      child.remove();
      parent.nodes.insertAll(index, parts);
      changed = true;
    }
  }

  walk(doc.body ?? doc.documentElement ?? doc);
  return changed ? doc.outerHtml : html;
}

/// [withDateLinks] on an isolate of its own, where a long message's parse
/// keeps off the screen's thread, and stopped past [within]. As it was,
/// should that fail or be stopped.
Future<String> withDateLinksAway(
  String html,
  List<FoundDate> dates, {
  Duration within = dateLinksWithin,
}) async {
  // Not even copied to an isolate where it would only come back.
  if (dates.isEmpty || html.length > dateLinksUpTo) return html;
  final answer = ReceivePort();
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
      _linkDatesFor,
      (reply: answer.sendPort, html: html, dates: dates),
      onError: answer.sendPort,
      onExit: answer.sendPort,
      debugName: 'date links',
    );
    // The links, or else the error it met or its exit, as null.
    final reply = await answer.first.timeout(within);
    return reply is String ? reply : html;
  } catch (e) {
    debugPrint('[myemail] dates not linked: $e');
    return html;
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    answer.close();
  }
}

void _linkDatesFor(
  ({SendPort reply, String html, List<FoundDate> dates}) job,
) =>
    job.reply.send(withDateLinks(job.html, job.dates));

/// How many tags [html] could open: every `<` before a letter, which is
/// where the parser starts one, counted wherever it is (in a comment, a
/// style, a quoted value) as more than the parser opens, never fewer.
int tagsOpened(String html) => _tagStart.allMatches(html).length;

final _tagStart = RegExp('<[a-zA-Z]');
