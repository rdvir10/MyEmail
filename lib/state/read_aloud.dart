import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/speech/speech_engine.dart';
import '../domain/mail_message.dart';
import '../domain/speech_text.dart';

/// The phone's voice. main() puts Android's in on a device; everywhere
/// else it says nothing and keeps a note.
final speechEngineProvider =
    Provider<SpeechEngine>((ref) => FakeSpeechEngine());

/// What Read Aloud is reading, and where it has got to.
@immutable
class ReadAloudState {
  const ReadAloudState({
    required this.messageId,
    required this.pieces,
    this.index = 0,
    this.playing = true,
    this.rate = 1.0,
    this.missingVoice,
    this.unavailable = false,
  });

  /// The message being read: its reading pane shows the controls.
  final String messageId;
  final List<SpeechPiece> pieces;

  /// The piece being read, or paused at.
  final int index;
  final bool playing;

  /// How fast: 1 is the voice's own pace.
  final double rate;

  /// A language the message is in that the phone has no voice for, whose
  /// pieces are passed over: said, with the way to Android's settings.
  final String? missingVoice;

  /// The phone has no voice at all, so nothing can be read.
  final bool unavailable;

  ReadAloudState copyWith({int? index, bool? playing, double? rate}) =>
      ReadAloudState(
        messageId: messageId,
        pieces: pieces,
        index: index ?? this.index,
        playing: playing ?? this.playing,
        rate: rate ?? this.rate,
        missingVoice: missingVoice,
        unavailable: unavailable,
      );

  ReadAloudState stalled() => ReadAloudState(
        messageId: messageId,
        pieces: pieces,
        index: index,
        playing: false,
        rate: rate,
        missingVoice: missingVoice,
        unavailable: true,
      );
}

/// Read Aloud, as Outlook has it on the Home tab: the open message read
/// out in the phone's own voice, Hebrew pieces in a Hebrew one, with pause,
/// back and forward a paragraph, and speed.
///
/// Null while nothing is being read. Reading stops when its message's pane
/// goes ([stopFor]), which is also when another message is opened.
class ReadAloud extends Notifier<ReadAloudState?> {
  late SpeechEngine _engine;

  /// The id of the piece being said, so a finish from a piece that was
  /// skipped or stopped is not taken for the one now being said.
  String? _speaking;
  int _serial = 0;

  @override
  ReadAloudState? build() {
    _engine = ref.watch(speechEngineProvider);
    _engine.onFinished(_finished);
    ref.onDispose(() {
      _speaking = null;
      _engine.stop();
    });
    return null;
  }

  bool readingMessage(String messageId) => state?.messageId == messageId;

  /// Begin reading [message] from its subject, in place of anything being
  /// read. Pieces in a language the phone has no voice for are passed over
  /// and said so.
  Future<void> start(MailMessage message, MailBody body) async {
    _stopSpeaking();
    var pieces = speechPieces(subject: message.subject, body: body.text);
    String? missing;
    for (final language in {for (final p in pieces) p.language}) {
      bool has;
      try {
        has = await _engine.hasLanguage(language);
      } catch (_) {
        has = true;
      }
      if (!has) {
        missing ??= language;
        pieces = [
          for (final p in pieces)
            if (p.language != language) p,
        ];
      }
    }
    state = ReadAloudState(
      messageId: message.id,
      pieces: pieces,
      playing: pieces.isNotEmpty,
      rate: state?.rate ?? 1.0,
      missingVoice: missing,
    );
    await _speak();
  }

  void pause() {
    final s = state;
    if (s == null || !s.playing) return;
    _stopSpeaking();
    state = s.copyWith(playing: false);
  }

  /// Go on from the start of the piece it was paused in.
  Future<void> resume() async {
    final s = state;
    if (s == null || s.playing || s.pieces.isEmpty) return;
    state = s.copyWith(playing: true);
    await _speak();
  }

  Future<void> next() async {
    final s = state;
    if (s == null) return;
    if (s.index + 1 >= s.pieces.length) {
      stop();
      return;
    }
    await _go(s.index + 1);
  }

  /// Back a piece; from the first, the first again.
  Future<void> previous() async {
    final s = state;
    if (s == null) return;
    await _go(s.index > 0 ? s.index - 1 : 0);
  }

  Future<void> setRate(double rate) async {
    final s = state;
    if (s == null || s.rate == rate) return;
    state = s.copyWith(rate: rate);
    if (s.playing) await _speak();
  }

  void stop() {
    _stopSpeaking();
    state = null;
  }

  /// Stop, if what is being read is [messageId]: its pane is going. The
  /// whole app may be going with it, and this with it, first.
  void stopFor(String messageId) {
    if (!ref.mounted) return;
    if (readingMessage(messageId)) stop();
  }

  Future<void> _go(int index) async {
    final s = state!;
    _stopSpeaking();
    state = s.copyWith(index: index, playing: true);
    await _speak();
  }

  void _stopSpeaking() {
    if (_speaking == null) return;
    _speaking = null;
    _engine.stop();
  }

  Future<void> _speak() async {
    final s = state;
    if (s == null || !s.playing || s.pieces.isEmpty) return;
    final piece = s.pieces[s.index];
    final id = '${++_serial}';
    _speaking = id;
    try {
      final started = await _engine.speak(
        id: id,
        text: piece.text,
        language: piece.language,
        rate: s.rate,
      );
      if (!started && _speaking == id) _finished(id, failed: true);
    } on SpeechUnavailable {
      if (_speaking == id) {
        _speaking = null;
        state = state?.stalled();
      }
    } catch (e) {
      debugPrint('[myemail] read aloud: $e');
      if (_speaking == id) _finished(id, failed: true);
    }
  }

  /// A piece came to its end, or could not be said: on to the next, and
  /// at the end of the message, done.
  void _finished(String id, {required bool failed}) {
    if (id != _speaking) return;
    _speaking = null;
    final s = state;
    if (s == null) return;
    if (failed) debugPrint('[myemail] read aloud passed over a piece');
    if (s.index + 1 >= s.pieces.length) {
      state = null;
      return;
    }
    state = s.copyWith(index: s.index + 1);
    _speak();
  }
}

final readAloudProvider =
    NotifierProvider<ReadAloud, ReadAloudState?>(ReadAloud.new);
