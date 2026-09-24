import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
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

  group('with new mail arriving between pages', () {
    const folder = 'acct-1:INBOX';

    ProviderContainer containerFor(_GrowingEngine engine) {
      final c = ProviderContainer(overrides: [
        mailEngineProvider.overrideWithValue(engine),
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('more than a page of it goes at the top, all of it', () async {
      // The sync behind the next page brings in the new mail first, which
      // pushes everything down. Asked for what followed the fifty shown,
      // the folder answered with new mail, which went under the old at
      // the bottom, and the newest of it did not show at all.
      final engine = _GrowingEngine(folder)..arrive(60);
      final c = containerFor(engine);
      final first = await c.read(messagesProvider(folder).future);
      expect(first, hasLength(Messages.pageSize));

      engine.arrive(70);
      await c.read(messagesProvider(folder).notifier).loadMore();

      final shown = c.read(sortedMessagesProvider(folder));
      final newest = engine.server.first;
      expect(shown.first.id, newest.id, reason: 'the newest is at the top');
      final ids = shown.map((m) => m.id).toList();
      expect(ids, containsAllInOrder(engine.server.take(ids.length).map((m) => m.id)),
          reason: 'no gap: the list is the top of the folder');
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('a message being deleted does not come back with the page',
        () async {
      // The server still has it until the delete finishes, and the page
      // is read from the top.
      final engine = _GrowingEngine(folder)..arrive(60);
      final c = containerFor(engine);
      final first = await c.read(messagesProvider(folder).future);
      final gone = first.first.id;

      final notifier = c.read(messagesProvider(folder).notifier);
      engine.holdDelete = Completer<void>();
      final deleting = notifier.delete([gone]);
      await notifier.loadMore();

      expect(
        c.read(messagesProvider(folder)).value!.map((m) => m.id),
        isNot(contains(gone)),
      );
      engine.holdDelete!.complete();
      await deleting;
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

/// One folder whose server end gains mail on request, newest first, and
/// answers pages by offset the way a real one does.
class _GrowingEngine extends SampleMailEngine {
  _GrowingEngine(this.folderId);

  final String folderId;
  final List<MailMessage> server = [];
  var _next = 1;

  /// Held open to keep a delete on its way.
  Completer<void>? holdDelete;

  /// [count] messages arrive, each newer than anything already there.
  void arrive(int count) {
    for (var i = 0; i < count; i++) {
      final uid = _next++;
      server.insert(
        0,
        MailMessage(
          id: MailMessage.idFor(folderId, uid),
          accountId: 'acct-1',
          folderId: folderId,
          uid: uid,
          subject: 'Message $uid',
          preview: '',
          from: const MailAddress(email: 'dana@example.com'),
          to: const [],
          date: DateTime(2026, 9, 1).add(Duration(minutes: uid)),
          isRead: true,
        ),
      );
    }
  }

  List<MailMessage> _page(int offset, int limit) => offset >= server.length
      ? const []
      : List.of(server.sublist(offset, min(server.length, offset + limit)));

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      const [];

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      _page(offset, limit);

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    await holdDelete?.future;
    server.removeWhere((m) => messageIds.contains(m.id));
    return const [];
  }
}
