import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Opening a folder puts you on a message, and coming back puts you on the
/// one you left.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  List<String> idsOnScreen(WidgetTester tester) => tester
      .widgetList<MessageTile>(find.byType(MessageTile))
      .map((t) => t.message.id)
      .toList();

  /// Two folders holding different mail, so the test can move between them
  /// without naming folders the fake happens to have. They have to be
  /// disjoint: the unified Inbox holds every account's inbox mail, so leaving
  /// one for the other would find the same message still in the list and
  /// rightly stay on it.
  Future<List<String>> twoSeparateFolders(
    WidgetTester tester,
    ProviderContainer c,
  ) async {
    final found = <String, Set<String>>{};
    for (final id in c.read(folderIndexProvider).keys) {
      c.read(selectedFolderIdProvider.notifier).select(id);
      await tester.pumpAndSettle();
      final ids = idsOnScreen(tester);
      if (ids.length < 3) continue;
      final seen = ids.toSet();
      for (final other in found.entries) {
        if (other.value.intersection(seen).isEmpty) return [other.key, id];
      }
      found[id] = seen;
    }
    return const [];
  }

  testWidgets('a folder opens on its first message', (tester) async {
    final c = await pump(tester);

    expect(c.read(selectedMessageIdProvider), idsOnScreen(tester).first);
  });

  testWidgets('landing does not mark the message read', (tester) async {
    // Walking past a folder in the tree is not reading what is in it. Only a
    // message the person chose counts as opened.
    //
    // It compared the row with itself, read twice with nothing in between,
    // so it could not fail. The sample's newest message is unread: landing
    // on it has to leave it so, in the list and on the server.
    final c = await pump(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final landed = c.read(selectedMessageIdProvider)!;
    final folder = c.read(effectiveSelectedFolderIdProvider)!;

    final row = tester.widget<MessageTile>(find.byType(MessageTile).first);
    expect(row.message.id, landed);
    expect(row.message.isRead, isFalse);
    final listed = c.read(messagesProvider(folder)).value!;
    expect(listed.firstWhere((m) => m.id == landed).isRead, isFalse);
  });

  testWidgets('coming back lands where the folder was left', (tester) async {
    final c = await pump(tester);
    final folders = await twoSeparateFolders(tester, c);
    if (folders.length < 2) return; // Nothing to move between.

    c.read(selectedFolderIdProvider.notifier).select(folders.first);
    await tester.pumpAndSettle();
    final third = idsOnScreen(tester)[2];
    await tester.tap(find.byKey(ValueKey('tile:$third')));
    await tester.pumpAndSettle();

    c.read(selectedFolderIdProvider.notifier).select(folders[1]);
    await tester.pumpAndSettle();
    expect(c.read(selectedMessageIdProvider), isNot(third));

    c.read(selectedFolderIdProvider.notifier).select(folders.first);
    await tester.pumpAndSettle();
    expect(c.read(selectedMessageIdProvider), third);
  });
}
