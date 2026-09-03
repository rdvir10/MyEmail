import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mailtree/ui/folder_tree/folder_tree_panel.dart';

Widget _harness({Size size = const Size(400, 800)}) {
  return ProviderScope(
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: const Scaffold(body: FolderTreePanel()),
      ),
    ),
  );
}

void main() {
  testWidgets('tree renders accounts and system folders', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // Section headers render account names uppercased.
    expect(find.text('PERSONAL'), findsOneWidget);
    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.text('INBOX'), findsWidgets);
    expect(find.text('Search folders'), findsOneWidget);
  });

  testWidgets('tapping the twisty expands a folder', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text('Receipts'), findsNothing);

    final financeTile = find.ancestor(
      of: find.text('Finance'),
      matching: find.byType(InkWell),
    );
    final twisty = find.descendant(
      of: financeTile.first,
      matching: find.byType(IconButton),
    );
    await tester.tap(twisty.first);
    await tester.pumpAndSettle();

    expect(find.text('Receipts'), findsOneWidget);
  });

  testWidgets('search filters the tree and clears again', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'travel');
    await tester.pumpAndSettle();

    expect(find.text('Travel'), findsOneWidget);
    expect(find.text('Newsletters'), findsNothing);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('Newsletters'), findsOneWidget);
  });
}
