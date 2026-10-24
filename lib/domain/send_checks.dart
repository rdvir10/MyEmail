import 'package:html/parser.dart' as html_parser;

/// What the person wrote in a message, without what the window put there
/// itself: the quote of what it answers, and the signature. What the checks
/// before Send read, so a forwarded "see attached" is not taken for this
/// message's.
String ownTextOf(String html) {
  final body = html_parser.parseFragment(html);
  for (final added in body.querySelectorAll(
    'blockquote, .mailtree-signature, .mailtree-quote',
  )) {
    added.remove();
  }
  return (body.text ?? '').replaceAll(' ', ' ');
}

/// Whether [text] says a file is attached, in English or Hebrew: Outlook's
/// Attachment Reminder, which looks for the same words.
///
/// English by whole word ("attached", "attachment", "enclosed"), so
/// "attachable" and "unattached" do not count. Hebrew by stem, since its
/// words carry their prefixes and endings with them: מצורף and מצורפת,
/// מצרף, צירפתי, בצירוף, and the letters מצ"ב and רצ"ב that business mail
/// writes for "attached herewith".
bool mentionsAttachment(String text) {
  if (_english.hasMatch(text)) return true;
  final hebrew = text.replaceAll('״', '"').replaceAll('״', '"');
  return _hebrew.any(hebrew.contains);
}

final _english = RegExp(
  r'\b(attach(ed|es|ing|ment|ments)?|enclos(ed|ing|ure|ures))\b',
  caseSensitive: false,
);

const _hebrew = [
  'מצורף',
  'מצורפ',
  'מצרף',
  'מצרפ',
  'צירפתי',
  'צרפתי',
  'בצירוף',
  'בצרוף',
  'מצ"ב',
  'רצ"ב',
];
