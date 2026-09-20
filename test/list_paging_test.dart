import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// A folder's list starts with one page and grows as it is scrolled.
///
/// The sample Inbox says it holds 2310 messages and can hand over 60, so it
/// stands for a real folder that is deeper than any one screen: the first
/// page is 50, the second is what is left, and the third is empty.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<String> inboxOf(ProviderContainer c, {int account = 0}) async {
    final accounts = await c.read(accountsProvider.future);
    final folders = await c.read(foldersProvider.future);
    return folders[accounts[account].id]!
        .firstWhere((f) => f.role == FolderRole.inbox)
        .id;
  }

  group('the list', () {
    test('starts with one page', () async {
      final c = container();
      final inbox = await inboxOf(c);

      final shown = await c.read(messagesProvider(inbox).future);

      expect(shown, hasLength(Messages.pageSize));
      expect(c.read(listHasMoreProvider(inbox)), isTrue,
          reason: 'the folder says it holds far more');
    });

    test('grows by a page when asked, keeping what it had', () async {
      final c = container();
      final inbox = await inboxOf(c);
      final first = await c.read(messagesProvider(inbox).future);

      await c.read(messagesProvider(inbox).notifier).loadMore();

      final shown = c.read(messagesProvider(inbox)).value!;
      expect(shown.length, greaterThan(first.length));
      expect(shown.take(first.length).map((m) => m.id), first.map((m) => m.id),
          reason: 'older mail goes under the newer, which does not move');
      expect(c.read(listDepthProvider(inbox)).pages, 2);
    });

    test('stops asking once a page comes back empty', () async {
      // The folder's total is bigger than what the engine can give, as a
      // stale count would be. An empty page, not the count, is what ends it.
      final c = container();
      final inbox = await inboxOf(c);
      await c.read(messagesProvider(inbox).future);
      final notifier = c.read(messagesProvider(inbox).notifier);

      await notifier.loadMore();
      expect(c.read(listHasMoreProvider(inbox)), isTrue);
      await notifier.loadMore();

      expect(c.read(listHasMoreProvider(inbox)), isFalse);
      expect(c.read(listDepthProvider(inbox)).exhausted, isTrue);
    });

    test('comes back as deep as it was after a refresh', () async {
      // Every sync rebuilds the list. One that snapped back to the first
      // page would throw away the scrolling that got you to page six.
      final c = container();
      final inbox = await inboxOf(c);
      await c.read(messagesProvider(inbox).future);
      await c.read(messagesProvider(inbox).notifier).loadMore();
      final deep = c.read(messagesProvider(inbox)).value!.length;

      c.invalidate(messagesProvider(inbox));
      final again = await c.read(messagesProvider(inbox).future);

      expect(again.length, deep);
    });

    test('pages every account at once in the unified Inbox', () async {
      final c = container();
      await c.read(accountsProvider.future);
      await c.read(foldersProvider.future);
      final first = await c.read(messagesProvider(kUnifiedInboxId).future);
      final accounts = first.map((m) => m.accountId).toSet();

      await c.read(messagesProvider(kUnifiedInboxId).notifier).loadMore();

      final shown = c.read(messagesProvider(kUnifiedInboxId)).value!;
      for (final a in accounts) {
        expect(
          shown.where((m) => m.accountId == a).length,
          greaterThan(first.where((m) => m.accountId == a).length),
          reason: 'account $a got its next page',
        );
      }
      for (var i = 1; i < shown.length; i++) {
        expect(shown[i].date.isAfter(shown[i - 1].date), isFalse,
            reason: 'still newest first once merged');
      }
    });
  });

  group('on screen', () {
    testWidgets('scrolling to the bottom brings the next page', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();
      final inbox = await inboxOf(c);
      c.read(selectedFolderIdProvider.notifier).select(inbox);
      await tester.pumpAndSettle();
      expect(c.read(messagesProvider(inbox)).value, hasLength(Messages.pageSize));

      // The message list, not the folder tree beside it.
      final list = find
          .ancestor(
            of: find.byType(MessageTile).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byType(CircularProgressIndicator),
        400,
        scrollable: list,
      );
      await tester.pumpAndSettle();

      expect(
        c.read(messagesProvider(inbox)).value!.length,
        greaterThan(Messages.pageSize),
      );
      expect(find.byType(MessageTile), findsWidgets);
    });
  });
}
