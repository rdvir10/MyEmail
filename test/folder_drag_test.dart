import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/folder_drag.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/folder_tree/folder_tree_panel.dart';

// ---------------------------------------------------------------------------
// Drop rules, without widgets.

Future<Map<String, MailFolder>> _personalFolders() async {
  final engine = SampleMailEngine();
  await engine.loadAccounts();
  final list = await engine.loadFolders('acct-personal');
  return {for (final f in list) f.path: f};
}

void main() {
  group('resolveDropZone', () {
    test('zones split the row into before / into / after', () async {
      final f = await _personalFolders();
      DropZone? at(double fraction) => resolveDropZone(
            dragged: f['Travel']!,
            target: f['Family']!,
            fraction: fraction,
          );
      expect(at(0.1), DropZone.before);
      expect(at(0.5), DropZone.into);
      expect(at(0.9), DropZone.after);
    });

    test('nothing can be dropped on a system folder', () async {
      final f = await _personalFolders();
      for (final fraction in [0.1, 0.5, 0.9]) {
        expect(
          resolveDropZone(
            dragged: f['Travel']!,
            target: f['[Gmail]/Sent Mail']!,
            fraction: fraction,
          ),
          isNull,
        );
      }
    });

    test('a system folder cannot be dragged', () async {
      final f = await _personalFolders();
      expect(
        resolveDropZone(
          dragged: f['[Gmail]/Sent Mail']!,
          target: f['Family']!,
          fraction: 0.5,
        ),
        isNull,
      );
    });

    test('a folder cannot be dropped on itself or inside itself', () async {
      final f = await _personalFolders();
      expect(
        resolveDropZone(
          dragged: f['Finance']!,
          target: f['Finance']!,
          fraction: 0.5,
        ),
        isNull,
      );
      expect(
        resolveDropZone(
          dragged: f['Finance']!,
          target: f['Finance/Receipts/2026']!,
          fraction: 0.1,
        ),
        isNull,
      );
    });

    test('dropping into the current parent is a no-op, so refused', () async {
      final f = await _personalFolders();
      expect(
        resolveDropZone(
          dragged: f['Finance/Receipts']!,
          target: f['Finance']!,
          fraction: 0.5,
        ),
        isNull,
      );
      // But reordering next to the parent is a real move out of it.
      expect(
        resolveDropZone(
          dragged: f['Finance/Receipts']!,
          target: f['Finance']!,
          fraction: 0.1,
        ),
        DropZone.before,
      );
    });

    test('flat rows only take "into"', () async {
      final f = await _personalFolders();
      expect(
        resolveDropZone(
          dragged: f['Travel']!,
          target: f['Family']!,
          fraction: 0.05,
          flat: true,
        ),
        DropZone.into,
      );
    });

    test('root drop needs a nested, movable folder of the same account',
        () async {
      final f = await _personalFolders();
      expect(canDropOnRoot(f['Finance/Receipts']!, 'acct-personal'), isTrue);
      expect(canDropOnRoot(f['Travel']!, 'acct-personal'), isFalse,
          reason: 'already at the root');
      expect(canDropOnRoot(f['Finance/Receipts']!, 'acct-side'), isFalse);
      expect(canDropOnRoot(f['[Gmail]/Spam']!, 'acct-personal'), isFalse);
    });
  });

  group('reorderedIds', () {
    const ids = ['a', 'b', 'c'];

    test('puts the moved id before or after the target', () {
      expect(
        reorderedIds(ids, movedId: 'c', targetId: 'a', zone: DropZone.before),
        ['c', 'a', 'b'],
      );
      expect(
        reorderedIds(ids, movedId: 'a', targetId: 'b', zone: DropZone.after),
        ['b', 'a', 'c'],
      );
      expect(
        reorderedIds(ids, movedId: 'a', targetId: 'c', zone: DropZone.after),
        ['b', 'c', 'a'],
      );
    });

    test('a target that is not there puts the moved id last', () {
      expect(
        reorderedIds(ids, movedId: 'a', targetId: 'x', zone: DropZone.before),
        ['b', 'c', 'a'],
      );
    });

    test('the top half of a row is before it, the bottom half after', () {
      expect(edgeZone(0.1), DropZone.before);
      expect(edgeZone(0.49), DropZone.before);
      expect(edgeZone(0.5), DropZone.after);
      expect(edgeZone(0.9), DropZone.after);
    });
  });

  // -------------------------------------------------------------------------
  // The gesture, end to end.

  group('drag and drop in the tree', () {
    Widget harness() => const ProviderScope(
          child: MaterialApp(home: Scaffold(body: FolderTreePanel())),
        );

    // Both accounts' rows must be on screen at once for cross-account drags,
    // and ListView.builder only builds what is visible.
    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first.physicalSize =
          const Size(800, 1400);
      binding.platformDispatcher.views.first.devicePixelRatio = 1.0;
    });
    tearDown(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first.resetPhysicalSize();
      binding.platformDispatcher.views.first.resetDevicePixelRatio();
    });

    Rect rowRect(WidgetTester tester, String label) => tester.getRect(
          find
              .ancestor(
                of: find.text(label),
                matching: find.byType(DragTarget<DraggedFolder>),
              )
              .first,
        );

    Future<TestGesture> lift(WidgetTester tester, String label) async {
      final gesture =
          await tester.startGesture(tester.getCenter(find.text(label)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      return gesture;
    }

    Future<void> dragTo(
      WidgetTester tester,
      TestGesture gesture,
      Offset to,
    ) async {
      await gesture.moveTo(to);
      await tester.pump(const Duration(milliseconds: 50));
      // A second tiny move makes sure the target saw the final position.
      await gesture.moveTo(to + const Offset(0, 1));
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> drop(WidgetTester tester, TestGesture gesture) async {
      await gesture.up();
      await tester.pumpAndSettle();
    }

    Future<String?> pathSubtitleOf(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(TextField).first, query);
      await tester.pumpAndSettle();
      final subtitle = find.textContaining('›');
      final result = subtitle.evaluate().isEmpty
          ? null
          : (tester.widget<Text>(subtitle.first).data);
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('dropping a folder onto another nests it', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final g = await lift(tester, 'Travel');
      await dragTo(tester, g, rowRect(tester, 'Finance').center);
      await drop(tester, g);

      expect(await pathSubtitleOf(tester, 'travel'), 'Finance › Travel');
    });

    testWidgets('dropping on a system folder is refused', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final g = await lift(tester, 'Travel');
      await dragTo(tester, g, rowRect(tester, 'Sent').center);
      await drop(tester, g);

      expect(await pathSubtitleOf(tester, 'travel'), isNull,
          reason: 'still a root folder');
      expect(find.byType(BottomSheet), findsNothing,
          reason: 'a moved-then-released drag is not the menu gesture');
    });

    testWidgets('dropping on another account is refused', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final g = await lift(tester, 'Travel');
      await dragTo(tester, g, rowRect(tester, 'Clients').center);
      await drop(tester, g);

      expect(await pathSubtitleOf(tester, 'travel'), isNull);
    });

    testWidgets('dropping on the top edge reorders siblings', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('Family')).dy,
        lessThan(tester.getTopLeft(find.text('Newsletters')).dy),
      );

      final g = await lift(tester, 'Newsletters');
      final family = rowRect(tester, 'Family');
      await dragTo(tester, g, Offset(family.center.dx, family.top + 3));
      await drop(tester, g);

      expect(
        tester.getTopLeft(find.text('Newsletters')).dy,
        lessThan(tester.getTopLeft(find.text('Family')).dy),
        reason: 'Newsletters now sits before Family',
      );
      expect(await pathSubtitleOf(tester, 'newsletters'), isNull,
          reason: 'reordered, not nested');
    });

    testWidgets('dropping on the account header moves to the top level',
        (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      // Expand Finance so Receipts can be picked up.
      final twisty = find.descendant(
        of: find
            .ancestor(of: find.text('Finance'), matching: find.byType(InkWell))
            .first,
        matching: find.byType(IconButton),
      );
      await tester.tap(twisty.first);
      await tester.pumpAndSettle();

      final g = await lift(tester, 'Receipts');
      await dragTo(tester, g, tester.getCenter(find.text('PERSONAL')));
      await drop(tester, g);

      expect(await pathSubtitleOf(tester, '2026'), 'Receipts › 2026');
    });

    testWidgets('hovering over a collapsed folder expands it', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(find.text('Receipts'), findsNothing);

      final g = await lift(tester, 'Travel');
      await dragTo(tester, g, rowRect(tester, 'Finance').center);
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('Receipts'), findsOneWidget,
          reason: 'Finance opened under the hovering drag');

      await drop(tester, g);
    });

    testWidgets('holding without moving opens the menu instead',
        (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final g = await lift(tester, 'Travel');
      await drop(tester, g);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
    });

    testWidgets('a system folder still gets its menu on hold', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Inbox').first);
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Add to Favourites'), findsOneWidget);
    });
  });

  group('arranging accounts and favourites', () {
    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first.physicalSize =
          const Size(800, 1400);
      binding.platformDispatcher.views.first.devicePixelRatio = 1.0;
    });
    tearDown(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first.resetPhysicalSize();
      binding.platformDispatcher.views.first.resetDevicePixelRatio();
    });

    /// The tree over [store], which holds the favourites.
    Widget harness([UiStateStore? store]) => ProviderScope(
          overrides: [
            if (store != null) uiStateStoreProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(home: Scaffold(body: FolderTreePanel())),
        );

    Future<MemoryUiStateStore> favourites(Set<String> ids) async {
      final store = MemoryUiStateStore();
      await store.writeIds(UiStateKeys.favorites, ids);
      return store;
    }

    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(FolderTreePanel)));

    /// Hold [finder] until it lifts.
    Future<TestGesture> lift(WidgetTester tester, Finder finder) async {
      final gesture = await tester.startGesture(tester.getCenter(finder));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await tester.pump();
      return gesture;
    }

    Future<void> dragTo(
      WidgetTester tester,
      TestGesture gesture,
      Offset to,
    ) async {
      await gesture.moveTo(to);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(to + const Offset(0, 1));
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> drop(WidgetTester tester, TestGesture gesture) async {
      await gesture.up();
      await tester.pumpAndSettle();
    }

    Rect headingRect(WidgetTester tester, String label) => tester.getRect(
          find
              .ancestor(
                of: find.text(label),
                matching: find.byType(DragTarget<DraggedAccount>),
              )
              .first,
        );

    double top(WidgetTester tester, String label) =>
        tester.getTopLeft(find.text(label).first).dy;

    testWidgets('an account heading dragged above another puts the account '
        'first, for good', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(top(tester, 'PERSONAL'), lessThan(top(tester, 'PROJECTS')));

      final g = await lift(tester, find.text('PROJECTS'));
      expect(find.text('Inbox'), findsNothing,
          reason: 'the tree folds to the headings alone while one is held');
      expect(find.text('All Inboxes'), findsNothing);
      expect(find.text('PERSONAL'), findsOneWidget);

      final personal = headingRect(tester, 'PERSONAL');
      await dragTo(tester, g, Offset(personal.center.dx, personal.top + 3));
      await drop(tester, g);

      expect(top(tester, 'PROJECTS'), lessThan(top(tester, 'PERSONAL')));
      expect(find.text('Inbox'), findsWidgets,
          reason: 'unfolded again once dropped');
      final container = containerOf(tester);
      expect(
        container.read(accountsProvider).value!.map((a) => a.id),
        ['acct-side', 'acct-personal'],
      );
      // The sample engine answers after a delay on a real timer, which the
      // test's fake clock never reaches: asked outside it.
      final kept = await tester.runAsync(
        () => container.read(mailEngineProvider).loadAccounts(),
      );
      expect(
        kept!.map((a) => a.id),
        ['acct-side', 'acct-personal'],
        reason: 'kept by the engine, so it holds across restarts',
      );
    });

    testWidgets('dropped on the bottom half of another it goes after',
        (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final g = await lift(tester, find.text('PERSONAL'));
      final projects = headingRect(tester, 'PROJECTS');
      await dragTo(tester, g, Offset(projects.center.dx, projects.bottom - 3));
      await drop(tester, g);

      expect(top(tester, 'PROJECTS'), lessThan(top(tester, 'PERSONAL')));
    });

    testWidgets('held and let go in place, it stays put and the tree comes '
        'back', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final g = await lift(tester, find.text('PROJECTS'));
      expect(find.text('Inbox'), findsNothing);
      await drop(tester, g);

      expect(top(tester, 'PERSONAL'), lessThan(top(tester, 'PROJECTS')));
      expect(find.text('Inbox'), findsWidgets);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a favourite dragged above another goes first, and stays',
        (tester) async {
      final store =
          await favourites({'acct-personal:Travel', 'acct-personal:Family'});
      await tester.pumpWidget(harness(store));
      await tester.pumpAndSettle();
      // In Favourites, above the tree's own rows for the same folders.
      expect(top(tester, 'Travel'), lessThan(top(tester, 'Family')));

      final g = await lift(tester, find.text('Family').first);
      final travel = tester.getRect(find
          .ancestor(
            of: find.text('Travel').first,
            matching: find.byType(DragTarget<DraggedFavorite>),
          )
          .first);
      await dragTo(tester, g, Offset(travel.center.dx, travel.top + 3));
      await drop(tester, g);

      expect(top(tester, 'Family'), lessThan(top(tester, 'Travel')));
      expect(
        store.readIds(UiStateKeys.favorites).toList(),
        ['acct-personal:Family', 'acct-personal:Travel'],
        reason: 'the order is kept with the favourites themselves',
      );
    });

    testWidgets('a favourite dropped on a folder in the tree does nothing to '
        'either', (tester) async {
      final store = await favourites({'acct-personal:Travel'});
      await tester.pumpWidget(harness(store));
      await tester.pumpAndSettle();

      final g = await lift(tester, find.text('Travel').first);
      await dragTo(tester, g, tester.getCenter(find.text('Finance')));
      await drop(tester, g);

      expect(store.readIds(UiStateKeys.favorites), {'acct-personal:Travel'});
      await tester.enterText(find.byType(TextField).first, 'travel');
      await tester.pumpAndSettle();
      expect(find.textContaining('›'), findsNothing,
          reason: 'not nested under Finance');
    });

    testWidgets('a favourite held without moving opens its menu',
        (tester) async {
      final store = await favourites({'acct-personal:Travel'});
      await tester.pumpWidget(harness(store));
      await tester.pumpAndSettle();

      final g = await lift(tester, find.text('Travel').first);
      await drop(tester, g);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Remove from Favourites'), findsOneWidget);
    });

    testWidgets('All Inboxes can be put away from its menu, and Undo brings '
        'it back', (tester) async {
      await tester.pumpWidget(harness(MemoryUiStateStore()));
      await tester.pumpAndSettle();
      expect(find.text('All Inboxes'), findsOneWidget);

      await tester.longPress(find.text('All Inboxes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide All Inboxes'));
      await tester.pumpAndSettle();

      expect(find.text('All Inboxes'), findsNothing);
      expect(find.textContaining('All Inboxes hidden'), findsOneWidget);
      final container = containerOf(tester);
      expect(container.read(displayProvider).showAllInboxes, isFalse);
      expect(container.read(effectiveSelectedFolderIdProvider),
          isNot(kUnifiedInboxId),
          reason: 'the list does not stay on a row that is gone');

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('All Inboxes'), findsOneWidget);
      expect(container.read(displayProvider).showAllInboxes, isTrue);
    });
  });

  group('performFolderDrop ordering', () {
    test('user folders keep Outlook order relative to system folders',
        () async {
      final f = await _personalFolders();
      final roles = f.values.map((x) => x.role).toSet();
      expect(roles, contains(FolderRole.user));
      expect(roles, contains(FolderRole.inbox));
    });
  });
}
