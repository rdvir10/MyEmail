import 'package:flutter/services.dart';

/// The phone's text-to-speech, one piece at a time: see `SpeechBridge` on
/// the Android side, and `ReadAloud`, which decides the pieces.
abstract class SpeechEngine {
  /// Say [text] in [language] (`he-IL`, `en-US`) at [rate] (1 is the
  /// voice's own pace), in place of anything being said. True once it is
  /// under way. Throws [SpeechUnavailable] where the phone has no voice.
  Future<bool> speak({
    required String id,
    required String text,
    required String language,
    double rate = 1.0,
  });

  /// Stop speaking, at once. What was cut short is not reported finished.
  Future<void> stop();

  /// Whether a voice for [language] is installed.
  Future<bool> hasLanguage(String language);

  /// Android's text-to-speech settings, where voices are installed. False
  /// where the phone has no such page.
  Future<bool> openSettings();

  /// [handler] hears each piece's id as it finishes, and whether it failed
  /// rather than finished. One handler: the last set.
  void onFinished(void Function(String id, {required bool failed}) handler);
}

/// The phone has no text-to-speech engine that works.
class SpeechUnavailable implements Exception {
  const SpeechUnavailable();

  @override
  String toString() => 'This phone has no text-to-speech voice.';
}

class AndroidSpeechEngine implements SpeechEngine {
  AndroidSpeechEngine() {
    _channel.setMethodCallHandler((call) async {
      final id = '${call.arguments}';
      switch (call.method) {
        case 'done':
          _handler?.call(id, failed: false);
        case 'error':
          _handler?.call(id, failed: true);
      }
      return null;
    });
  }

  static const _channel = MethodChannel('mailtree/speech');

  void Function(String id, {required bool failed})? _handler;

  @override
  void onFinished(void Function(String id, {required bool failed}) handler) =>
      _handler = handler;

  @override
  Future<bool> speak({
    required String id,
    required String text,
    required String language,
    double rate = 1.0,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('speak', {
            'id': id,
            'text': text,
            'language': language,
            'rate': rate,
          }) ??
          false;
    } on PlatformException catch (e) {
      if (e.code == 'unavailable') throw const SpeechUnavailable();
      rethrow;
    }
  }

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  @override
  Future<bool> hasLanguage(String language) async =>
      await _channel.invokeMethod<bool>('hasLanguage', {'language': language}) ??
      false;

  @override
  Future<bool> openSettings() async =>
      await _channel.invokeMethod<bool>('openSettings') ?? false;
}

/// Says nothing, and keeps a note of what it was asked to say. Tests, and
/// the browser preview. A test finishes a piece with [finish].
class FakeSpeechEngine implements SpeechEngine {
  FakeSpeechEngine({this.languages = const {'he-IL', 'en-US'}});

  /// The voices installed.
  final Set<String> languages;

  /// Everything said, in order, and how many times it was stopped.
  final List<({String id, String text, String language, double rate})> said =
      [];
  int stops = 0;
  int settingsOpened = 0;

  /// Where the phone is to have no voice at all.
  bool unavailable = false;

  void Function(String id, {required bool failed})? _handler;

  @override
  void onFinished(void Function(String id, {required bool failed}) handler) =>
      _handler = handler;

  /// Pretend the piece last said came to its end.
  void finish({bool failed = false}) {
    if (said.isEmpty) return;
    _handler?.call(said.last.id, failed: failed);
  }

  @override
  Future<bool> speak({
    required String id,
    required String text,
    required String language,
    double rate = 1.0,
  }) async {
    if (unavailable) throw const SpeechUnavailable();
    said.add((id: id, text: text, language: language, rate: rate));
    return true;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<bool> hasLanguage(String language) async =>
      languages.contains(language);

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}
