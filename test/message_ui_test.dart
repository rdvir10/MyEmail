import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/ui/messages/message_tile.dart';
import 'package:mailtree/ui/messages/reading_pane.dart';
import 'package:mailtree/ui/shell/app_shell.dart';

Widget _app() => const ProviderScope(child: MaterialApp(home: AppShell()));

void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
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

    expect(find.textContaining('Select a message'), findsOneWidget);

    final first = find.byType(MessageTile).first;
    final subject = tester.widget<MessageTile>(first).message.subject;
    await tester.tap(first);
    await tester.pumpAndSettle();

    expect(find.byType(MessageScreen), findsNothing, reason: 'nothing pushed');
    expect(find.byType(ReadingPane), findsOneWidget);
    expect(find.text(subject), findsNWidgets(2),
        reason: 'once in the list, once as the reading pane title');
  });

  testWidgets('wide: changing folder clears the reading pane', (tester) async {
    _useSize(tester, const Size(1400, 900));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(MessageTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(ReadingPane), findsOneWidget);

    await tester.tap(find.text('Travel'));
    await tester.pumpAndSettle();
    expect(find.byType(ReadingPane), findsNothing);
    expect(find.textContaining('Select a message'), findsOneWidget);
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
