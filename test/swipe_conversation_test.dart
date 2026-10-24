import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/folder_capabilities.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/conversations.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/conversation_tile.dart';
import 'package:myemail/ui/messages/message_list_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Swiping a conversation acts on the whole thread, the way its menu does.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  MailMessage m(int uid, {bool isRead = true, bool isFlagged = false}) =>
      MailMessage(
        id: 'a:INBOX#$uid',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: uid,
        subject: 'Numbers',
        preview: '',
        from: const MailAddress(email: 'dana@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: DateTime(2026, 9, 20, uid),
        isRead: isRead,
        isFlagged: isFlagged,
      );

  group('what the label says', () {
    test('one message reads as it always did', () {
      expect(swipeActionShortLabel(SwipeAction.delete, [m(1)]), 'Delete');
      expect(swipeActionShortLabel(SwipeAction.toggleRead, [m(1)]), 'Unread');
      expect(
        swipeActionShortLabel(SwipeAction.toggleRead, [m(1, isRead: false)]),
        'Read',
      );
      expect(swipeActionShortLabel(SwipeAction.none, [m(1)]), '');
    });

    test('a thread says how many are about to go', () {
      final thread = [m(1), m(2), m(3)];
      expect(swipeActionShortLabel(SwipeAction.delete, thread), 'Delete 3');
      expect(swipeActionShortLabel(SwipeAction.archive, thread), 'Archive 3');
    });

    test('read and flag speak for the thread, not for one of it', () {
      // Mixed: anything unread means the swipe marks everything read, and
      // the label has to say the thing it will do.
      final mixed = [m(1, isRead: false), m(2)];
      expect(swipeActionShortLabel(SwipeAction.toggleRead, mixed), 'Read 2');
      expect(
        swipeActionShortLabel(SwipeAction.toggleRead, [m(1), m(2)]),
        'Unread 2',
      );
      final someFlagged = [m(1, isFlagged: true), m(2)];
      expect(
        swipeActionShortLabel(SwipeAction.toggleFlag, someFlagged),
        'Unflag 2',
      );
      expect(swipeActionShortLabel(SwipeAction.toggleFlag, [m(1)]), 'Flag');
    });
  });

  group('on the list', () {
    Future<(ProviderContainer, Conversation)> open(
      WidgetTester tester, {
      SwipeAction left = SwipeAction.delete,
    }) async {
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
      c.read(displayProvider.notifier)
        ..setConversations(true)
        ..setSwipeLeft(left);
      await tester.pumpAndSettle();

      final tile = tester.widget<ConversationTile>(
        find.byType(ConversationTile).first,
      );
      return (c, tile.conversation);
    }

    List<MailMessage> listOf(ProviderContainer c) =>
        c.read(messagesProvider(c.read(effectiveSelectedFolderIdProvider)!)).value!;

    testWidgets('swiping it takes every message in it', (tester) async {
      final (c, thread) = await open(tester);
      final ids = thread.messages.map((m) => m.id).toSet();
      expect(ids.length, greaterThan(1));

      await tester.drag(
        find.byKey(ValueKey('thread:${thread.id}')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();

      final after = listOf(c).map((m) => m.id).toSet();
      expect(after.intersection(ids), isEmpty, reason: 'the whole thread went');
      expect(find.textContaining('deleted'), findsOneWidget);
    });

    testWidgets('a half-finished swipe says how many it is about to take',
        (tester) async {
      final (_, thread) = await open(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('thread:${thread.id}'))),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-160, 0));
      await tester.pump();

      expect(find.text('Delete ${thread.length}'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('read marks the whole thread read in one go', (tester) async {
      final (c, thread) = await open(tester, left: SwipeAction.toggleRead);
      final ids = thread.messages.map((m) => m.id).toSet();
      expect(thread.hasUnread, isTrue,
          reason: 'the sample inbox has unread mail in its threads');

      await tester.drag(
        find.byKey(ValueKey('thread:${thread.id}')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();

      final after = [for (final m in listOf(c)) if (ids.contains(m.id)) m];
      expect(after, hasLength(ids.length), reason: 'nothing left the list');
      expect(after.every((m) => m.isRead), isTrue);
    });

    testWidgets('a message row still swipes on its own', (tester) async {
      final (c, _) = await open(tester);
      // A conversation of one is drawn as a plain row.
      final loose = listOf(c).firstWhere((x) =>
          groupIntoConversations(listOf(c))
              .firstWhere((g) => g.messages.any((y) => y.id == x.id))
              .length ==
          1);

      // Rows carry a sender address and the list carries date bars now,
      // so the row this picks may be below the fold.
      final row = find.byKey(ValueKey('tile:${loose.id}'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.drag(row, const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(listOf(c).any((x) => x.id == loose.id), isFalse);
    });
  });

  testWidgets('Archive in the unified Inbox files only the row\'s own '
      'account\'s mail', (tester) async {
    // A Projects message answering a Personal one was one conversation
    // there, and Archive sent both to the oldest one's Archive: the
    // Projects mail was copied into the Personal mailbox and taken out of
    // its own.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _AnsweredAcross();
    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    c.read(displayProvider.notifier)
      ..setConversations(true)
      ..setSwipeLeft(SwipeAction.archive);
    await tester.pumpAndSettle();
    expect(c.read(effectiveSelectedFolderIdProvider), kUnifiedInboxId);

    await tester.drag(
      find.descendant(
        of: find.byType(MessageListPane),
        matching: find.text('Plans'),
      ),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();

    expect(engine.filed, {
      _AnsweredAcross.original.id: MailFolder.idFor('acct-personal', 'Archive'),
    });
  });
}

/// Both accounts' Inboxes and nothing else in them: a Personal message,
/// and a Projects one answering it. Each account has an Archive that
/// takes mail. Moves are written down rather than made, since the sample
/// store moves only the messages it made itself.
class _AnsweredAcross extends SampleMailEngine {
  static final original = MailMessage(
    id: MailMessage.idFor('acct-personal:INBOX', 1),
    accountId: 'acct-personal',
    folderId: 'acct-personal:INBOX',
    uid: 1,
    subject: 'Plans',
    preview: '',
    from: const MailAddress(email: 'dana@example.com'),
    to: const [MailAddress(email: 'personal@example.com')],
    date: DateTime.now().subtract(const Duration(minutes: 30)),
    isRead: true,
    messageId: 'plans@example.com',
  );
  static final answer = MailMessage(
    id: MailMessage.idFor('acct-side:INBOX', 1),
    accountId: 'acct-side',
    folderId: 'acct-side:INBOX',
    uid: 1,
    subject: 'Re: Plans',
    preview: '',
    from: const MailAddress(email: 'lee@example.com'),
    to: const [MailAddress(email: 'projects@example.com')],
    date: DateTime.now().subtract(const Duration(minutes: 10)),
    isRead: true,
    messageId: 're-plans@example.com',
    inReplyTo: 'plans@example.com',
  );

  /// Each message moved, and the folder it was moved to.
  final filed = <String, String>{};

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      [
        if (offset == 0)
          for (final m in [original, answer])
            if (m.folderId == folderId && !filed.containsKey(m.id)) m,
      ];

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) =>
      loadMessages(folderId, offset: offset, limit: limit);

  @override
  Future<List<MessageMove>> moveMessages(
    List<String> messageIds,
    String toFolderId,
  ) async {
    for (final id in messageIds) {
      filed[id] = toFolderId;
    }
    return [
      for (final id in messageIds)
        MessageMove(
          fromFolderId: id.substring(0, id.lastIndexOf('#')),
          toFolderId: toFolderId,
          movedIds: ['$toFolderId#$id'],
        ),
    ];
  }

  List<MailFolder> _withArchive(String accountId, List<MailFolder> folders) =>
      [
        ...folders,
        MailFolder.at(
          accountId: accountId,
          path: 'Archive',
          role: FolderRole.archive,
          capabilities: const FolderCapabilities.userFolder(),
          sortIndex: folders.length,
        ),
      ];

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async =>
      _withArchive(accountId, await super.loadFolders(accountId));

  @override
  Future<List<MailFolder>> cachedFolders(String accountId) async =>
      _withArchive(accountId, await super.cachedFolders(accountId));
}
