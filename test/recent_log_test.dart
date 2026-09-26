import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/recent_log.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/ui/settings/recent_log_screen.dart';

/// The log the phone keeps for itself, and the screen that shows it.
void main() {
  group('RecentLog', () {
    test('keeps lines stamped with the time, oldest first, up to its '
        'capacity', () {
      var now = DateTime(2026, 9, 25, 18, 5, 7);
      final log = RecentLog(capacity: 3, clock: () => now);
      log.add('one');
      now = now.add(const Duration(seconds: 1));
      log.add('two');
      expect(log.lines, ['18:05:07 one', '18:05:08 two']);

      log.add('three');
      log.add('four');
      expect(log.lines, ['18:05:08 two', '18:05:08 three', '18:05:08 four'],
          reason: 'the oldest goes as the capacity is reached');
      expect(log.text, '18:05:08 two\n18:05:08 three\n18:05:08 four');
    });

    test('keeps what debugPrint is told, and still prints it', () {
      final was = debugPrint;
      addTearDown(() => debugPrint = was);
      final printed = <String>[];
      debugPrint = (String? m, {int? wrapWidth}) => printed.add(m ?? '');
      RecentLog.instance.clear();

      keepRecentLog();
      debugPrint('[myemail] verbs Inbox: 1=104');

      expect(printed, ['[myemail] verbs Inbox: 1=104']);
      expect(RecentLog.instance.lines.single,
          endsWith('[myemail] verbs Inbox: 1=104'));
    });
  });

  group('the screen', () {
    late FakeFileBridge bridge;
    late RecentLog log;

    setUp(() {
      bridge = FakeFileBridge();
      var t = DateTime(2026, 9, 25, 18, 0, 0);
      log = RecentLog(clock: () => t = t.add(const Duration(seconds: 1)));
    });

    Widget app() => ProviderScope(
          overrides: [fileBridgeProvider.overrideWithValue(bridge)],
          child: MaterialApp(home: RecentLogScreen(log: log)),
        );

    Finder button(IconData icon) =>
        find.ancestor(of: find.byIcon(icon), matching: find.byType(IconButton));

    testWidgets('shows the lines newest first', (tester) async {
      log.add('[myemail] first');
      log.add('[myemail] second');
      await tester.pumpWidget(app());

      expect(
        tester.getTopLeft(find.textContaining('second')).dy,
        lessThan(tester.getTopLeft(find.textContaining('first')).dy),
      );
    });

    testWidgets('Copy puts the whole log on the clipboard', (tester) async {
      log.add('[myemail] a line');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(app());

      await tester.tap(button(Icons.copy_outlined));
      await tester.pumpAndSettle();

      final set = calls.singleWhere((c) => c.method == 'Clipboard.setData');
      expect((set.arguments as Map)['text'], log.text);
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('Share hands the log to the share sheet as a text file',
        (tester) async {
      // The temporary directory comes over a platform channel that has no
      // other side under test: answered here with the test machine's own.
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => Directory.systemTemp.path,
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      log.add('[myemail] a line');
      await tester.pumpWidget(app());

      // Writing the file is real work on a real clock, which the test's
      // fake one never reaches: waited out under runAsync.
      await tester.runAsync(() async {
        await tester.tap(button(Icons.share_outlined));
        for (var i = 0; i < 40 && bridge.shared.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });

      final path = bridge.shared.single;
      expect(path, endsWith('myemail-log.txt'));
      expect(File(path).readAsStringSync(), log.text);
    });

    testWidgets('with nothing noted, says so and offers nothing',
        (tester) async {
      await tester.pumpWidget(app());

      expect(find.text('Nothing noted yet.'), findsOneWidget);
      expect(tester.widget<IconButton>(button(Icons.copy_outlined)).onPressed,
          isNull);
      expect(tester.widget<IconButton>(button(Icons.share_outlined)).onPressed,
          isNull);
    });
  });
}
