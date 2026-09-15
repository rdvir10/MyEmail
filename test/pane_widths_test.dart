import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mailtree/data/ui_state_store.dart';
import 'package:mailtree/state/pane_widths.dart';
import 'package:mailtree/state/providers.dart';
import 'package:mailtree/ui/folder_tree/folder_tree_panel.dart';
import 'package:mailtree/ui/shell/app_shell.dart';

Widget _app() => const ProviderScope(child: MaterialApp(home: AppShell()));

void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ProviderContainer _container([UiStateStore? store]) {
  final c = ProviderContainer(
    overrides: [
      uiStateStoreProvider.overrideWithValue(store ?? MemoryUiStateStore()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('PaneLayout', () {
    test('a drag moves the edge it was made on, and only that one', () {
      final c = _container();

      c.read(paneWidthsProvider.notifier).dragTree(40);

      expect(c.read(paneWidthsProvider).tree, PaneLayout.defaultTree + 40);
      expect(c.read(paneWidthsProvider).list, PaneLayout.defaultList);
    });

    test('a pane cannot be dragged past what it can usefully show', () {
      final c = _container();
      final notifier = c.read(paneWidthsProvider.notifier);

      notifier.dragTree(-9999);
      expect(c.read(paneWidthsProvider).tree, PaneLayout.minTree);

      notifier.dragTree(9999);
      expect(c.read(paneWidthsProvider).tree, PaneLayout.maxTree);

      notifier.dragList(-9999);
      expect(c.read(paneWidthsProvider).list, PaneLayout.minList);
    });

    test('a reset puts both panes back', () {
      final c = _container();
      c.read(paneWidthsProvider.notifier)
        ..dragTree(60)
        ..dragList(-60);

      c.read(paneWidthsProvider.notifier).reset();

      expect(c.read(paneWidthsProvider), const PaneLayout());
    });

    test('widths are remembered across a restart', () {
      final store = MemoryUiStateStore();
      final first = _container(store);
      first.read(paneWidthsProvider.notifier).dragTree(55);

      final second = _container(store);
      expect(second.read(paneWidthsProvider).tree, PaneLayout.defaultTree + 55);
    });

    test('a narrower window keeps the reading pane usable', () {
      // Rotating a tablet can leave less room than the saved widths want. The
      // reading pane is last and has no width of its own, so without this it
      // gets whatever is left over, which can be nothing.
      const wide = PaneLayout(tree: 460, list: 620);
      final fitted = wide.fitted(900, hasReadingPane: true);

      expect(
        fitted.tree + fitted.list,
        lessThanOrEqualTo(900 - PaneLayout.minReading),
      );
      expect(fitted.tree / fitted.list, closeTo(460 / 620, 0.001),
          reason: 'the two panes give space back in proportion');
    });

    test('widths that already fit are left exactly alone', () {
      const panes = PaneLayout();
      expect(panes.fitted(1400, hasReadingPane: true), panes);
    });

    test('with no reading pane only the tree has to fit', () {
      const panes = PaneLayout(tree: 460, list: 620);
      expect(panes.fitted(700, hasReadingPane: false).tree, 460,
          reason: 'the message list is the pane that expands here');
    });
  });

  group('three-pane shell', () {
    testWidgets('dragging the divider widens the folder pane', (tester) async {
      _useSize(tester, const Size(1400, 900));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final before = tester.getSize(find.byType(FolderTreePanel)).width;
      await tester.drag(find.byType(PaneDivider).first, const Offset(60, 0));
      await tester.pumpAndSettle();

      // Greater, not exact: the recognizer swallows the touch slop before it
      // starts reporting, and how much is Flutter's business. What this test
      // is for is that the divider reaches the layout at all. The arithmetic
      // is pinned in the PaneLayout group above.
      expect(tester.getSize(find.byType(FolderTreePanel)).width,
          greaterThan(before));
    });

    testWidgets('the empty reading pane names the folder in view',
        (tester) async {
      _useSize(tester, const Size(1400, 900));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.textContaining('Select a message in'), findsOneWidget);
    });

    testWidgets('both edges are draggable and labelled', (tester) async {
      _useSize(tester, const Size(1400, 900));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final labels = tester
          .widgetList<PaneDivider>(find.byType(PaneDivider))
          .map((d) => d.label);
      expect(labels, ['Folder pane width', 'Message list width']);
    });

    testWidgets('the medium layout has one edge, not two', (tester) async {
      _useSize(tester, const Size(900, 1200));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.byType(PaneDivider), findsOneWidget);
    });

    testWidgets('the phone layout has none', (tester) async {
      _useSize(tester, const Size(400, 900));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.byType(PaneDivider), findsNothing);
    });
  });
}
