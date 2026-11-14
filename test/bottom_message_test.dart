import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Messages along the bottom go away by themselves, Undo or not, unless
/// one is told to stay on purpose.
void main() {
  test('every message with a button is told whether to stay', () {
    // Flutter keeps a message with an action until it is dismissed, so
    // "Deleted — Undo" sat over the list for good. Each says, then. The
    // one told to stay is the only way back to a message that was not
    // sent, where the window it was written in has gone.
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      final actions = 'SnackBarAction('.allMatches(source).length;
      final told = RegExp(r'persist: (false|true)').allMatches(source).length;
      expect(told, greaterThanOrEqualTo(actions), reason: file.path);
    }
  });
}
