import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/ui/folder_tree/folder_tree_panel.dart';

Widget _harness() {
  return const ProviderScope(
    child: MaterialApp(home: Scaffold(body: FolderTreePanel())),
  );
}

Future<void> _openMenuFor(WidgetTester tester, Finder target) async {
  await tester.longPress(target);
  await tester.pumpAndSettle();
}

Future<void> _pumpTree(WidgetTester tester) async {
  await tester.pumpWidget(_harness());
  await tester.pumpAndSettle();
}

void main() {
  // Every row these tests look for must be on screen: ListView.builder does
  // not build what is below the fold, and the tree has a footer now.
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(800, 1400);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  group('menu contents follow capabilities', () {
    testWidgets('a user folder gets the full menu', (tester) async {
      await _pumpTree(tester);
      await _openMenuFor(tester, find.text('Travel'));

      expect(find.byType(BottomSheet), findsOneWidget);
      for (final label in [
        'New subfolder',
        'Rename',
        'Move to…',
        'Add to Favourites',
        'Delete',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Mark all as read'), findsNothing,
          reason: 'Travel has nothing unread');
      expect(find.text('Empty folder'), findsNothing,
          reason: 'only Trash and Junk can be emptied');
    });

    testWidgets('a Gmail system folder gets only what Gmail allows',
        (tester) async {
      await _pumpTree(tester);
      await _openMenuFor(tester, find.text('Sent').first);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Add to Favourites'), findsOneWidget);
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Move to…'), findsNothing);
      expect(find.text('New subfolder'), findsNothing);
    });

    testWidgets('Deleted (Gmail Trash) offers Empty folder', (tester) async {
      await _pumpTree(tester);
      await _openMenuFor(tester, find.text('Deleted').first);

      expect(find.text('Empty folder'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('a folder with unread mail offers Mark all as read',
        (tester) async {
      await _pumpTree(tester);
      await _openMenuFor(tester, find.text('Newsletters'));

      expect(find.text('Mark all as read'), findsOneWidget);
    });

    testWidgets('the unified inbox has no menu', (tester) async {
      await _pumpTree(tester);
      await _openMenuFor(tester, find.text('All Inboxes'));

      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  group('actions', () {
    testWidgets('rename updates the tree', (tester) async {
      await _pumpTree(tester);
      await _openMenuFor(tester, find.text('Travel'));
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      expect(find.text('Rename folder'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Trips');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(find.text('Rename folder'), findsNothing, reason: 'dialog closed');
      expect(find.text('Trips'), findsOneWidget);
      expect(find.text('Travel'), findsNothing);
    });

    testWidgets('renaming onto a sibling shows an inline conflict',
        (tester) async {
      await _pumpTree(tester);
      await _openMenuFor(tester, find.text('Travel'));
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'Newsletters');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(find.textContaining('already exists'), findsOneWidget);
      expect(find.text('Rename folder'), findsOneWidget,
          reason: 'dialog stays open so the user can fix the name');
      expect(find.byType(SnackBar), findsNothing,
          reason: 'a conflict is inline, not a snackbar');
    });

    testWidgets('a name with a slash is rejected before reaching the engine',
        (tester) async {
      await _pumpTree(tester);
      await _openMenuFor(tester, find.text('Travel'));
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'a/b');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(find.textContaining('cannot contain'), findsOneWidget);
      expect(find.text('Rename folder'), findsOneWidget,
          reason: 'dialog stays open');
      expect(find.text('Travel'), findsOneWidget,
          reason: 'the tree behind the dialog is untouched');
    });

    testWidgets('new subfolder lands under an auto-expanded parent',
        (tester) async {
      await _pumpTree(tester);
      expect(find.text('Insurance'), findsNothing);

      await _openMenuFor(tester, find.text('Finance'));
      await tester.tap(find.text('New subfolder'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'Insurance');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(find.text('Insurance'), findsOneWidget);
      expect(find.text('Receipts'), findsOneWidget,
          reason: 'parent was expanded to show the new child');
    });

    testWidgets('delete confirms with the subtree size, then removes it',
        (tester) async {
      await _pumpTree(tester);
      await _openMenuFor(tester, find.text('Finance'));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('3 subfolders'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Finance'), findsNothing);
    });

    testWidgets('cancelling delete leaves the folder alone', (tester) async {
      await _pumpTree(tester);
      await _openMenuFor(tester, find.text('Travel'));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Travel'), findsOneWidget);
    });

    testWidgets('favourite adds the folder to a Favourites section',
        (tester) async {
      await _pumpTree(tester);
      expect(find.text('FAVOURITES'), findsNothing);

      await _openMenuFor(tester, find.text('Travel'));
      await tester.tap(find.text('Add to Favourites'));
      await tester.pumpAndSettle();

      expect(find.text('FAVOURITES'), findsOneWidget);
      expect(find.text('Travel'), findsNWidgets(2),
          reason: 'once in Favourites, once in the account tree');

      // The menu now offers the reverse.
      await _openMenuFor(tester, find.text('Travel').last);
      expect(find.text('Remove from Favourites'), findsOneWidget);
      expect(find.text('Add to Favourites'), findsNothing);
      await tester.tap(find.text('Remove from Favourites'));
      await tester.pumpAndSettle();
      expect(find.text('FAVOURITES'), findsNothing);
    });

    testWidgets('move to top level re-parents the subtree', (tester) async {
      await _pumpTree(tester);
      // Expand Finance so Receipts is visible.
      final twisty = find.descendant(
        of: find.ancestor(
          of: find.text('Finance'),
          matching: find.byType(InkWell),
        ).first,
        matching: find.byType(IconButton),
      );
      await tester.tap(twisty.first);
      await tester.pumpAndSettle();

      await _openMenuFor(tester, find.text('Receipts'));
      await tester.tap(find.text('Move to…'));
      await tester.pumpAndSettle();

      final inSheet = find.byType(BottomSheet);
      expect(find.text('Top level'), findsOneWidget);
      expect(
        find.descendant(of: inSheet, matching: find.text('Finance')),
        findsNothing,
        reason: 'the current parent is not offered as a destination',
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('Travel')),
        findsOneWidget,
        reason: 'another user folder is',
      );
      await tester.tap(find.text('Top level'));
      await tester.pumpAndSettle();

      // Searching shows the new path of the grandchild.
      await tester.enterText(find.byType(TextField).first, '2026');
      await tester.pumpAndSettle();
      expect(find.text('Receipts › 2026'), findsOneWidget);
    });

    testWidgets('mark all as read clears the unread badge', (tester) async {
      await _pumpTree(tester);
      expect(find.text('231'), findsOneWidget, reason: 'Newsletters unread');

      await _openMenuFor(tester, find.text('Newsletters'));
      await tester.tap(find.text('Mark all as read'));
      await tester.pumpAndSettle();

      expect(find.text('231'), findsNothing);
    });
  });
}
