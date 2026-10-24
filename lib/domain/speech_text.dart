/// One piece of a message read aloud: a paragraph, or a few sentences of a
/// long one, and the voice to read it in. Pieces are what Read Aloud skips
/// between and what each language change falls between.
typedef SpeechPiece = ({String text, String language});

/// The voices: Hebrew and English, which is what Ron's mail is written in.
const hebrewVoice = 'he-IL';
const englishVoice = 'en-US';

/// How long a piece may run before it is cut at a sentence: short enough
/// that Next skips a little, long enough to be read as one breath.
const maxPieceLength = 400;

/// [subject] and [body] as Read Aloud reads them: the subject, then each
/// paragraph, a long one cut between sentences, each with the voice its
/// letters call for.
///
/// What is no use heard is left out or said shortly: a web address is
/// "link" (read out, one is a minute of letters), a line of dashes or
/// underscores is nothing, and the `>` before a quoted line goes.
List<SpeechPiece> speechPieces({String subject = '', required String body}) {
  final pieces = <SpeechPiece>[];
  var language = englishVoice;
  void add(String text) {
    final said = _sayable(text);
    if (!_hasWords(said)) return;
    language = voiceFor(said, otherwise: language);
    pieces.add((text: said, language: language));
  }

  add(subject);
  final paragraphs = body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split(RegExp(r'\n[ \t>]*\n'));
  for (final paragraph in paragraphs) {
    final lines = [
      for (final line in paragraph.split('\n'))
        line.replaceFirst(RegExp(r'^[ \t>]+'), ''),
    ].where((line) => !_isRule(line));
    final joined = lines.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final part in _cut(joined)) {
      add(part);
    }
  }
  return pieces;
}

/// The voice for [text]: Hebrew where its Hebrew letters are as many as
/// its Latin ones, English where the Latin ones are more, and [otherwise]
/// where it has neither, a line of numbers say, which goes on in the voice
/// before it.
String voiceFor(String text, {String otherwise = englishVoice}) {
  var hebrew = 0;
  var latin = 0;
  for (final rune in text.runes) {
    if (rune >= 0x05D0 && rune <= 0x05EA) {
      hebrew++;
    } else if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
      latin++;
    }
  }
  if (hebrew == 0 && latin == 0) return otherwise;
  return hebrew >= latin ? hebrewVoice : englishVoice;
}

final _link = RegExp(
  r'''(?:https?://|www\.)[^\s<>"')\]]+''',
  caseSensitive: false,
);

String _sayable(String text) =>
    text.replaceAll(_link, 'link').replaceAll(RegExp(r'\s+'), ' ').trim();

bool _hasWords(String text) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text);

/// A line that is only a rule drawn with punctuation: `-----`, `_____`,
/// `=====`, `*****`.
bool _isRule(String line) => RegExp(r'^\s*[-_=*~#.]{3,}\s*$').hasMatch(line);

/// [text] cut between sentences into pieces no longer than
/// [maxPieceLength], and a sentence longer than that between words.
List<String> _cut(String text) {
  if (text.length <= maxPieceLength) return [text];
  final sentences = text.split(RegExp(r'(?<=[.!?…])\s+'));
  final pieces = <String>[];
  var current = StringBuffer();
  void flush() {
    if (current.isNotEmpty) pieces.add(current.toString().trim());
    current = StringBuffer();
  }

  for (final sentence in sentences) {
    for (final part in _byWords(sentence)) {
      if (current.length + part.length + 1 > maxPieceLength) flush();
      if (current.isNotEmpty) current.write(' ');
      current.write(part);
    }
  }
  flush();
  return pieces;
}

/// A sentence too long for one piece, cut between words.
List<String> _byWords(String sentence) {
  if (sentence.length <= maxPieceLength) return [sentence];
  final parts = <String>[];
  var current = StringBuffer();
  for (final word in sentence.split(' ')) {
    if (current.length + word.length + 1 > maxPieceLength && current.isNotEmpty) {
      parts.add(current.toString());
      current = StringBuffer();
    }
    if (current.isNotEmpty) current.write(' ');
    current.write(word);
  }
  if (current.isNotEmpty) parts.add(current.toString());
  return parts;
}
