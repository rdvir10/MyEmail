import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

Widget _app() => const ProviderScope(child: MaterialApp(home: AppShell()));

void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  // Reading a message renders its body in a web view, which needs a
  // platform implementation in a unit test.
  setUpAll(FakeWebViewPlatform.install);

  testWidgets('phone: the inbox lists messages and opening one pushes a screen',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.byType(MessageTile), findsWidgets);
    expect(find.byType(ReadingPane), findsNothing);

    final first = find.byType(MessageTile).first;
    final subject = tester.widget<MessageTile>(first).message.subject;
    await tester.tap(first);
    await tester.pumpAndSettle();

    expect(find.byType(MessageScreen), findsOneWidget);
    expect(find.byType(ReadingPane), findsOneWidget);
    expect(find.widgetWithText(AppBar, subject), findsOneWidget);
    expect(find.textContaining('Hi,'), findsOneWidget, reason: 'body loaded');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(MessageScreen), findsNothing);
  });

  testWidgets('wide: opening a message fills the reading pane in place',
      (tester) async {
    _useSize(tester, const Size(1400, 900));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // The pane already holds the message the list landed on. What this is
    // really about is that choosing another one replaces it in place rather
    // than pushing a screen.
    expect(find.byType(ReadingPane), findsOneWidget);

    final first = find.byType(MessageTile).first;
    final subject = tester.widget<MessageTile>(first).message.subject;
    await tester.tap(first);
    await tester.pumpAndSettle();

    expect(find.byType(MessageScreen), findsNothing, reason: 'nothing pushed');
    expect(find.byType(ReadingPane), findsOneWidget);
    expect(find.text(subject), findsNWidgets(2),
        reason: 'once in the list, once as the reading pane title');
  });

  testWidgets('wide: changing folder moves the reading pane with it',
      (tester) async {
    // The message left behind in the old folder must not stay on screen next
    // to a list it is not in. The pane follows the folder, landing on its
    // first message.
    _useSize(tester, const Size(1400, 900));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(MessageTile).first);
    await tester.pumpAndSettle();
    final before = tester.widget<ReadingPane>(find.byType(ReadingPane)).message;

    await tester.tap(find.text('Travel'));
    await tester.pumpAndSettle();

    final after = tester.widget<ReadingPane>(find.byType(ReadingPane)).message;
    expect(after.id, isNot(before.id));
    expect(
      after.id,
      tester.widget<MessageTile>(find.byType(MessageTile).first).message.id,
    );
  });

  testWidgets('unified inbox marks each message with its account colour',
      (tester) async {
    _useSize(tester, const Size(1400, 900));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final tiles = tester.widgetList<MessageTile>(find.byType(MessageTile));
    expect(tiles.every((t) => t.accountColor != null), isTrue);
    expect(tiles.map((t) => t.accountColor).toSet().length, 2,
        reason: 'both accounts appear near the top of the merged list');
  });

  testWidgets('medium: tree and list side by side, message pushes a screen',
      (tester) async {
    _useSize(tester, const Size(1000, 800));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Search folders'), findsOneWidget);
    expect(find.byTooltip('Open navigation menu'), findsNothing);
    expect(find.textContaining('Select a message'), findsNothing,
        reason: 'no reading pane at this width');

    await tester.tap(find.byType(MessageTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(MessageScreen), findsOneWidget);
  });
}
