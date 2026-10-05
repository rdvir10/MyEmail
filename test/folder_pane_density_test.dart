import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/folder_tree/folder_tile.dart';
import 'package:myemail/ui/folder_tree/folder_tree_panel.dart';

/// The folder pane, compact: Ron asked to see more of the favourites and the
/// tree at once.
void main() {
  Future<ProviderContainer> pumpPane(WidgetTester tester) async {
    tester.view.physicalSize = const Size(340, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
    ]);
    addTearDown(c.dispose);
    final accounts =
        (await tester.runAsync(() => c.read(accountsProvider.future)))!;
    final folders =
        (await tester.runAsync(() => c.read(foldersProvider.future)))!;
    c.read(favoriteFoldersProvider.notifier).toggle(
        folders[accounts.first.id]!.firstWhere((f) => f.path == 'INBOX').id);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: FolderTreePanel())),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  double heightOf(WidgetTester tester, String name) => tester
      .getSize(find.ancestor(
        of: find.text(name).first,
        matching: find.byType(FolderTile),
      ))
      .height;

  testWidgets('a folder row is compact, with or without folders inside it',
      (tester) async {
    await pumpPane(tester);

    expect(heightOf(tester, 'Travel'), FolderTile.minHeight);
    // The expand arrow padded itself out to a 48 touch area, and every
    // folder with folders inside it was a taller row than the rest.
    expect(heightOf(tester, 'Family'), FolderTile.minHeight);
  });

  testWidgets('a favourite is one line, its account beside its name',
      (tester) async {
    await pumpPane(tester);

    final favourite = find.ancestor(
      of: find.text('Personal'),
      matching: find.byType(FolderTile),
    );
    expect(tester.getSize(favourite).height, FolderTile.minHeight);
    final name = find.descendant(of: favourite, matching: find.text('Inbox'));
    expect(tester.getCenter(find.text('Personal')).dy,
        closeTo(tester.getCenter(name).dy, 3),
        reason: 'on the same line');
  });

  testWidgets("an account's heading is one line, its address beside it",
      (tester) async {
    await pumpPane(tester);

    expect(tester.getCenter(find.text('personal@example.com')).dy,
        closeTo(tester.getCenter(find.text('PERSONAL')).dy, 3));
  });
}
