import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/move_to_sheet.dart';

/// Finding the destination in a mailbox that has hundreds of folders.
void main() {
  Future<(ProviderContainer, List<MailFolder>)> open(
    WidgetTester tester, {
    MemoryUiStateStore? store,
  }) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(store ?? MemoryUiStateStore()),
      ],
    );
    addTearDown(c.dispose);
    // The sample engine answers after a short delay, which a widget test's
    // fake clock never reaches: these two have to run in real time.
    final (account, folders) = (await tester.runAsync(() async {
      final accounts = await c.read(accountsProvider.future);
      return (accounts.first, await c.read(foldersProvider.future));
    }))!;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showMoveToSheet(
                    context,
                    accountId: account.id,
                    fromFolderId: '${account.id}:INBOX',
                    messageCount: 1,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (c, folders[account.id]!);
  }

  /// A folder with folders under it that can take a message, and one of
  /// them.
  (MailFolder, MailFolder) branch(List<MailFolder> folders) {
    final child = folders.firstWhere((f) =>
        f.parentId != null &&
        f.capabilities.canAcceptMessages &&
        folders.any((p) => p.id == f.parentId && p.parentId == null));
    return (folders.firstWhere((f) => f.id == child.parentId), child);
  }

  Finder row(MailFolder f) => find.byKey(ValueKey('move-tree-${f.id}'));

  Future<void> expand(WidgetTester tester, MailFolder f) async {
    await tester.tap(find.descendant(of: row(f), matching: find.byTooltip('Expand')));
    await tester.pumpAndSettle();
  }

  testWidgets('it opens with a search box and the tree, branches folded',
      (tester) async {
    final (_, folders) = await open(tester);
    final (parent, child) = branch(folders);

    expect(find.widgetWithText(TextField, 'Search folders'), findsOneWidget);
    expect(find.text('Move to'), findsOneWidget);
    expect(row(parent), findsOneWidget);
    expect(row(child), findsNothing, reason: 'the branch is folded');

    await expand(tester, parent);
    expect(row(child), findsOneWidget);
  });

  testWidgets('it opens where the folder pane has its branches open',
      (tester) async {
    final store = MemoryUiStateStore();
    // The sample engine's folders, known before the sheet opens.
    final engine = SampleMailEngine();
    final account = (await tester.runAsync(engine.loadAccounts))!.first;
    final folders = (await tester.runAsync(() => engine.loadFolders(account.id)))!;
    final (parent, child) = branch(folders);
    await store.writeIds(UiStateKeys.expanded, {parent.id});

    await open(tester, store: store);

    expect(row(child), findsOneWidget);
  });

  testWidgets('each folder has its own icon, and a subfolder sits further in',
      (tester) async {
    final (_, folders) = await open(tester);
    final (parent, child) = branch(folders);
    await expand(tester, parent);

    double iconLeft(MailFolder f) => tester
        .getTopLeft(find.descendant(of: row(f), matching: find.byType(Icon)).last)
        .dx;
    expect(iconLeft(child), greaterThan(iconLeft(parent)));
    final inbox = folders.firstWhere((f) => f.role == FolderRole.inbox);
    expect(
      find.descendant(of: row(inbox), matching: find.byIcon(Icons.inbox_outlined)),
      findsOneWidget,
      reason: 'the Inbox looks as it does in the pane',
    );
  });

  testWidgets('the folder it is in now is there, greyed, and says so',
      (tester) async {
    final (_, folders) = await open(tester);
    final inbox = folders.firstWhere((f) => f.role == FolderRole.inbox);

    expect(find.descendant(of: row(inbox), matching: find.text('Here now')),
        findsOneWidget);
    await tester.tap(row(inbox));
    await tester.pumpAndSettle();
    expect(find.text('Move to'), findsOneWidget, reason: 'nothing chosen');
  });

  testWidgets('typing narrows it to what was typed', (tester) async {
    final (_, folders) = await open(tester);
    final target = folders.firstWhere(
      (f) => f.capabilities.canAcceptMessages && f.displayName.length > 4,
    );
    final others = folders
        .where((f) =>
            f.capabilities.canAcceptMessages &&
            !f.displayName.toLowerCase().contains(target.displayName.toLowerCase()))
        .toList();
    expect(others, isNotEmpty);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search folders'),
      target.displayName,
    );
    await tester.pumpAndSettle();

    expect(find.text(target.displayName), findsWidgets);
    for (final gone in others.take(4)) {
      expect(find.text(gone.displayName), findsNothing, reason: gone.path);
    }
  });

  testWidgets('a search that matches nothing says so', (tester) async {
    await open(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search folders'),
      'zzzznothing',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No folder matches'), findsOneWidget);
  });

  testWidgets('choosing one closes the sheet with that folder', (tester) async {
    final (_, folders) = await open(tester);
    final (parent, _) = branch(folders);

    await tester.tap(row(parent));
    await tester.pumpAndSettle();

    expect(find.text('Move to'), findsNothing, reason: 'the sheet closed');
  });
}
