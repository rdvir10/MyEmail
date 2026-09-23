import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Messages along the bottom go away by themselves, Undo or not.
void main() {
  test('every message with a button is told not to stay', () {
    // Flutter keeps a message with an action until it is dismissed, so
    // "Deleted — Undo" sat over the list for good.
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      final actions = 'SnackBarAction('.allMatches(source).length;
      final told = 'persist: false'.allMatches(source).length;
      expect(told, greaterThanOrEqualTo(actions), reason: file.path);
    }
  });
}
