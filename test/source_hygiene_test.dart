import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// No invisible control characters in the source.
///
/// This is not style policing. Three files in this project have carried
/// literal NUL bytes, each in a string that was meant to hold the escape for
/// U+0000 and instead held the character itself: a separator in the cache's
/// composite keys, another in the recent-move list, and one more in a regex.
/// They all worked, which is why they survived.
///
/// What they cost is everything else. Git and grep classify the file as
/// binary and stop searching it, so the code inside becomes invisible to
/// every tool that looks for text. Editors, formatters and patch tools are
/// entitled to drop or mangle a stray control byte, and if one ever did, the
/// separator would change silently and two accounts' cache entries would
/// merge — a data bug with no stack trace and no obvious cause.
///
/// Escapes behave identically at runtime and have none of that. This test is
/// the thing that keeps them escapes.
void main() {
  test('no Dart source file contains a control character', () {
    final offenders = <String>[];

    for (final directory in ['lib', 'test']) {
      final entries = Directory(directory)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));

      for (final file in entries) {
        final bytes = file.readAsBytesSync();
        for (var i = 0; i < bytes.length; i++) {
          final byte = bytes[i];
          // Tab, newline and carriage return are the legitimate ones.
          final isAllowed = byte == 9 || byte == 10 || byte == 13;
          if (byte < 32 && !isAllowed) {
            offenders.add('${file.path} at byte $i (0x${byte.toRadixString(16)})');
            break;
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Write the character as an escape instead — "\\u0000" rather '
          'than the byte itself. A literal control character makes the whole '
          'file read as binary to git and grep, and any tool that drops it '
          'changes the value silently.',
    );
  });
}
