import 'package:flutter/services.dart';

import '../../domain/error_report.dart' show ReadableError;

/// What the phone's own AI does for the app.
enum AiFeature { summarize, proofread, rewrite, smartReply }

/// Whether a feature can be used on this phone now.
enum AiReadiness {
  available,

  /// Its model has to be fetched first, which the first use does.
  downloadable,
  downloading,

  /// Not on this phone: no AICore, or a phone Gemini Nano does not run on
  /// (the Tab S9+).
  unavailable;

  bool get usable => this != unavailable;
}

/// How a draft is rewritten: ML Kit's rewriting styles, as Outlook's
/// Coaching names them.
enum RewriteStyle {
  shorter('Shorter'),
  friendlier('Friendlier'),
  formal('More formal'),
  longer('Longer'),
  rephrase('Rephrase');

  const RewriteStyle(this.label);
  final String label;
}

/// One message of a conversation, for suggested replies: oldest first,
/// the last one the one replied to.
typedef ConversationLine = ({
  String text,
  DateTime time,
  bool mine,
  String sender,
});

/// The phone's own AI, with nothing leaving the phone (`AiBridge` on the
/// Android side): a summary of a long message, a draft proofread or
/// rewritten (ML Kit's GenAI APIs, on Gemini Nano: the Pixel 9 Pro), and
/// short replies suggested for a message (ML Kit's Smart Reply). English
/// only, as Google ships them.
abstract class OnDeviceAi {
  Future<AiReadiness> readiness(AiFeature feature);

  /// [feature]'s model fetched, waiting until it has been.
  Future<void> download(AiFeature feature);

  /// A few bullet points, one to a line.
  Future<String> summarize(String text);

  /// The text corrected, best first.
  Future<List<String>> proofread(String text);

  /// The text written again in [style], best first.
  Future<List<String>> rewrite(String text, RewriteStyle style);

  /// Up to three short replies to the last of [lines]; none where nothing
  /// fits or the language is not English.
  Future<List<String>> suggestReplies(List<ConversationLine> lines);
}

/// The phone's AI could not do it: a refusal of the model's, or a phone it
/// does not run on.
class AiFailed implements Exception, ReadableError {
  const AiFailed(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

/// Whether [text] is something the phone's AI reads: mostly English, as
/// Google's models are, with at least [minimum] letters to tell by. A
/// Hebrew message is not summarised.
bool readsAsEnglish(String text, {int minimum = 20}) {
  var latin = 0, other = 0;
  for (final r in text.runes) {
    if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
      latin++;
    } else if ((r >= 0x370 && r <= 0x1FFF) ||
        (r >= 0x3040 && r <= 0x9FFF) ||
        (r >= 0xAC00 && r <= 0xD7AF)) {
      // Greek to Arabic, Hebrew among them, and the Far East's scripts.
      other++;
    }
  }
  final letters = latin + other;
  return letters >= minimum && latin / letters >= 0.9;
}

/// Roughly how many tokens [text] is to the models: about four characters
/// each, in English.
int roughTokens(String text) => (text.length / 4).ceil();

class AndroidOnDeviceAi implements OnDeviceAi {
  const AndroidOnDeviceAi();

  static const _channel = MethodChannel('mailtree/ai');

  static const _names = {
    AiFeature.summarize: 'summarize',
    AiFeature.proofread: 'proofread',
    AiFeature.rewrite: 'rewrite',
    AiFeature.smartReply: 'smartReply',
  };

  Future<T?> _call<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw AiFailed(
        "The phone's AI could not do it${e.message == null ? '' : ': ${e.message}'}",
      );
    }
  }

  @override
  Future<AiReadiness> readiness(AiFeature feature) async {
    try {
      final status = await _channel
          .invokeMethod<String>('status', {'feature': _names[feature]});
      return AiReadiness.values.where((r) => r.name == status).firstOrNull ??
          AiReadiness.unavailable;
    } on MissingPluginException {
      return AiReadiness.unavailable;
    } on PlatformException {
      return AiReadiness.unavailable;
    }
  }

  @override
  Future<void> download(AiFeature feature) =>
      _call<bool>('download', {'feature': _names[feature]});

  @override
  Future<String> summarize(String text) async =>
      await _call<String>('summarize', {'text': text}) ?? '';

  @override
  Future<List<String>> proofread(String text) async => [
        for (final s in await _call<List<Object?>>('proofread', {'text': text}) ??
            const [])
          if (s is String && s.trim().isNotEmpty) s,
      ];

  @override
  Future<List<String>> rewrite(String text, RewriteStyle style) async => [
        for (final s in await _call<List<Object?>>(
                'rewrite', {'text': text, 'style': style.name}) ??
            const [])
          if (s is String && s.trim().isNotEmpty) s,
      ];

  @override
  Future<List<String>> suggestReplies(List<ConversationLine> lines) async {
    try {
      return [
        for (final s in await _channel.invokeMethod<List<Object?>>(
              'suggestReplies',
              {
                'messages': [
                  for (final l in lines)
                    {
                      'text': l.text,
                      'time': l.time.millisecondsSinceEpoch,
                      'local': l.mine,
                      'sender': l.sender,
                    },
                ],
              },
            ) ??
            const [])
          if (s is String && s.trim().isNotEmpty) s,
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      // A suggestion is a convenience: none at all is the answer to any
      // trouble with it.
      return const [];
    }
  }
}

/// For tests: answers as it is told.
class FakeOnDeviceAi implements OnDeviceAi {
  FakeOnDeviceAi({
    Map<AiFeature, AiReadiness>? ready,
    this.summary = '• It says something.',
    this.replies = const [],
  }) : ready = {
          for (final f in AiFeature.values) f: AiReadiness.available,
          ...?ready,
        };

  final Map<AiFeature, AiReadiness> ready;
  String summary;
  List<String> replies;

  /// Every text asked about, and what of it.
  final asked = <(String, String)>[];

  @override
  Future<AiReadiness> readiness(AiFeature feature) async =>
      ready[feature] ?? AiReadiness.unavailable;

  @override
  Future<void> download(AiFeature feature) async {
    asked.add(('download', feature.name));
    ready[feature] = AiReadiness.available;
  }

  @override
  Future<String> summarize(String text) async {
    asked.add(('summarize', text));
    return summary;
  }

  @override
  Future<List<String>> proofread(String text) async {
    asked.add(('proofread', text));
    return [text.replaceAll('teh', 'the')];
  }

  @override
  Future<List<String>> rewrite(String text, RewriteStyle style) async {
    asked.add((style.name, text));
    return ['${style.label}: $text'];
  }

  @override
  Future<List<String>> suggestReplies(List<ConversationLine> lines) async {
    asked.add(('replies', lines.last.text));
    return replies;
  }
}
