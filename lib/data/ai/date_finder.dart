import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import '../../domain/found_dates.dart';

/// Dates and times in text, found on the phone (`EntityBridge` on the
/// Android side, ML Kit's entity extraction): for a meeting typed in a line,
/// and the dates a message names. English only, as Google ships it; the
/// model is fetched the first time it is wanted, and nothing read leaves
/// the phone.
abstract class DateFinder {
  /// The model fetched where it is not here yet. True once it is.
  Future<bool> prepare();

  /// The dates in [text], read as though written at [now]. Empty, never an
  /// error, where they cannot be had: no model yet, no connection to fetch
  /// it, or a phone without the bridge.
  Future<List<FoundDate>> find(String text, {DateTime? now});
}

class AndroidDateFinder implements DateFinder {
  const AndroidDateFinder();

  static const _channel = MethodChannel('mailtree/dates');

  @override
  Future<bool> prepare() async {
    try {
      return await _channel.invokeMethod<bool>('prepare') ?? false;
    } catch (e) {
      debugPrint('[myemail] the date finder could not be readied: $e');
      return false;
    }
  }

  @override
  Future<List<FoundDate>> find(String text, {DateTime? now}) async {
    if (text.trim().isEmpty) return const [];
    try {
      final found = await _channel.invokeMethod<List<Object?>>('dates', {
        'text': text,
        'now': (now ?? DateTime.now()).millisecondsSinceEpoch,
      });
      return [
        for (final f in found ?? const <Object?>[]) ?FoundDate.fromMap(f),
      ];
    } catch (e) {
      debugPrint('[myemail] no dates found: $e');
      return const [];
    }
  }
}

/// For tests and the browser preview: finds what it was told to.
class FakeDateFinder implements DateFinder {
  FakeDateFinder([this.dates = const {}]);

  /// What to find in a text that has each key in it, where it is in that
  /// text worked out on finding: the date the key's words mean.
  final Map<String, ({DateTime at, DateGrain grain})> dates;

  final List<String> asked = [];

  @override
  Future<bool> prepare() async => true;

  @override
  Future<List<FoundDate>> find(String text, {DateTime? now}) async {
    asked.add(text);
    return [
      for (final MapEntry(key: words, value: d) in dates.entries)
        if (text.indexOf(words) case final at when at >= 0)
          FoundDate(
            start: at,
            end: at + words.length,
            text: words,
            at: d.at,
            grain: d.grain,
          ),
    ];
  }
}
