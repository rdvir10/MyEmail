import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/move_to_sheet.dart';

/// Finding the destination in a mailbox that has hundreds of folders.
void main() {
  Future<(ProviderContainer, List<MailFolder>)> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
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

  testWidgets('it opens with a search box and the whole tree', (tester) async {
    final (_, folders) = await open(tester);

    expect(find.widgetWithText(TextField, 'Search folders'), findsOneWidget);
    expect(find.text('Move to'), findsOneWidget);
    // A folder that can take a message, somewhere down the tree.
    final nested = folders.firstWhere((f) => f.parentId != null);
    expect(find.text(nested.displayName), findsWidgets);
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

  testWidgets('a nested folder is indented under where it lives',
      (tester) async {
    final (_, folders) = await open(tester);
    final nestedNames = {
      for (final f in folders)
        if (f.parentId != null) f.displayName,
    };

    // Measured from what is actually offered, since the source folder and
    // the ones that cannot take a message are not on the list.
    double? nestedLeft, topLeft;
    for (final tile in find.byType(ListTile).evaluate()) {
      final title = (tile.widget as ListTile).title;
      if (title is! Text || title.data == null) continue;
      final left = tester.getTopLeft(find.byWidget(tile.widget)).dx +
          ((tile.widget as ListTile).contentPadding as EdgeInsets).left;
      if (nestedNames.contains(title.data)) {
        nestedLeft ??= left;
      } else {
        topLeft ??= left;
      }
    }

    expect(topLeft, isNotNull);
    expect(nestedLeft, isNotNull, reason: 'the sample account has subfolders');
    expect(nestedLeft, greaterThan(topLeft!));
  });

  testWidgets('choosing one closes the sheet with that folder', (tester) async {
    await open(tester);
    final chosen = find
        .byWidgetPredicate((w) => w is ListTile && w.onTap != null)
        .first;

    await tester.tap(chosen);
    await tester.pumpAndSettle();

    expect(find.text('Move to'), findsNothing, reason: 'the sheet closed');
  });
}
