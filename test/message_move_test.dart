import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/state/folder_drag.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_imap_transport.dart';

import 'fakes/fake_webview.dart';

void main() {
  // The list lands on a message now, so a wide layout renders the reading
  // pane — and with it a WebView, which needs a platform in a unit test.
  setUpAll(FakeWebViewPlatform.install);

  group('sample engine move and delete', () {
    late SampleMailEngine engine;

    setUp(() async {
      engine = SampleMailEngine();
      await engine.loadAccounts();
      await engine.loadFolders('acct-personal');
    });

    Future<int> unreadOf(String folderId) async {
      final folders = await engine.loadFolders('acct-personal');
      return folders.firstWhere((f) => f.id == folderId).unreadCount;
    }

    test('a moved message leaves one folder and joins the other', () async {
      final inbox = await engine.loadMessages('acct-personal:INBOX');
      final target = inbox.firstWhere((m) => !m.isRead);
      final unreadBefore = await unreadOf('acct-personal:INBOX');

      await engine.moveMessages([target.id], 'acct-personal:Travel');

      final after = await engine.loadMessages('acct-personal:INBOX');
      expect(after.map((m) => m.id), isNot(contains(target.id)));
      expect(await unreadOf('acct-personal:INBOX'), unreadBefore - 1);

      final travel = await engine.loadMessages('acct-personal:Travel');
      expect(travel.first.subject, target.subject);
      expect(travel.first.id, startsWith('acct-personal:Travel#'));
      expect(await unreadOf('acct-personal:Travel'), 1);
    });

    test('moving between accounts is refused', () async {
      await engine.loadFolders('acct-side');
      final inbox = await engine.loadMessages('acct-personal:INBOX');
      expect(
        () => engine.moveMessages([inbox.first.id], 'acct-side:Invoices'),
        throwsA(isA<FolderOperationNotSupported>()),
      );
    });

    test('moving into the same folder does nothing', () async {
      final before = await engine.loadMessages('acct-personal:INBOX');
      await engine.moveMessages([before.first.id], 'acct-personal:INBOX');
      final after = await engine.loadMessages('acct-personal:INBOX');
      expect(after.length, before.length);
    });

    test('delete moves to Trash, and from Trash deletes for good', () async {
      final inbox = await engine.loadMessages('acct-personal:INBOX');
      final target = inbox.first;
      const trashId = 'acct-personal:[Gmail]/Trash';

      await engine.deleteMessages([target.id]);
      final trash = await engine.loadMessages(trashId);
      expect(trash.first.subject, target.subject);

      final inTrash = trash.first;
      await engine.deleteMessages([inTrash.id]);
      final afterPurge = await engine.loadMessages(trashId);
      expect(afterPurge.map((m) => m.id), isNot(contains(inTrash.id)));
    });
  });

  group('cached engine move and delete', () {
    late FakeImapTransport server;
    late CachedImapEngine engine;
    late MemoryCacheStore cache;
    late Account account;

    setUp(() async {
      server = FakeImapTransport();
      cache = MemoryCacheStore();
      server.folder('INBOX', role: FolderRole.inbox);
      server.folder('[Gmail]/Trash', role: FolderRole.deleted);
      server.folder('Work');
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: cache,
        transportFactory: (_, _) => server,
      );
      account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
    });

    test('move goes over the wire and leaves the source cache', () async {
      server.folder('INBOX').deliver(subject: 'To file');
      final inbox = await engine.loadMessages('${account.id}:INBOX');
      expect(inbox, hasLength(1));

      await engine
          .moveMessages([inbox.single.id], '${account.id}:Work');

      expect(server.calls.any((c) => c.startsWith('UID MOVE INBOX')), isTrue);
      expect(await cache.countMessages(account.id, 'INBOX'), 0);
      final work = await engine.loadMessages('${account.id}:Work');
      expect(work.single.subject, 'To file');
    });

    test('a batch in one folder is one server call', () async {
      final inbox = server.folder('INBOX');
      for (var i = 0; i < 3; i++) {
        inbox.deliver();
      }
      final messages = await engine.loadMessages('${account.id}:INBOX');
      server.calls.clear();

      await engine.moveMessages(
        [for (final m in messages) m.id],
        '${account.id}:Work',
      );

      final moves = server.calls.where((c) => c.startsWith('UID MOVE'));
      expect(moves, hasLength(1));
      expect(moves.single, contains('3,2,1'));
    });

    test('delete goes to Trash; from Trash it expunges', () async {
      server.folder('INBOX').deliver();
      final inbox = await engine.loadMessages('${account.id}:INBOX');
      await engine.deleteMessages([inbox.single.id]);
      expect(server.calls.any((c) => c.contains('UID MOVE INBOX')), isTrue);

      final trash = await engine.loadMessages('${account.id}:[Gmail]/Trash');
      expect(trash, hasLength(1));
      server.calls.clear();

      await engine.deleteMessages([trash.single.id]);
      expect(server.calls.any((c) => c.contains('+MessageFlag.deleted')), isTrue);
      expect(server.calls, contains('EXPUNGE [Gmail]/Trash'));
      expect(server.folder('[Gmail]/Trash').messages, isEmpty);
    });

    test('moving between accounts is refused before any server call',
        () async {
      server.folder('INBOX').deliver();
      final inbox = await engine.loadMessages('${account.id}:INBOX');
      server.calls.clear();
      await expectLater(
        engine.moveMessages([inbox.single.id], 'other-account:Work'),
        throwsA(isA<FolderOperationNotSupported>()),
      );
      expect(server.calls, isEmpty);
    });
  });

  group('drop rules for messages', () {
    test('only same-account folders that accept messages take a drop',
        () async {
      final engine = SampleMailEngine();
      await engine.loadAccounts();
      final personal = await engine.loadFolders('acct-personal');
      final side = await engine.loadFolders('acct-side');
      final inbox = await engine.loadMessages('acct-personal:INBOX');
      final one = [inbox.first];

      MailFolderFinder find(List folders) => MailFolderFinder(folders);

      expect(canDropMessagesOn(one, find(personal).byPath('Travel')), isTrue);
      expect(
        canDropMessagesOn(one, find(personal).byPath('[Gmail]/Sent Mail')),
        isFalse,
        reason: 'Gmail refuses arbitrary appends to Sent',
      );
      expect(
        canDropMessagesOn(one, find(personal).byPath('[Gmail]/All Mail')),
        isFalse,
        reason: 'archiving is an action, not a destination',
      );
      expect(canDropMessagesOn(one, find(personal).byPath('INBOX')), isFalse,
          reason: 'already there');
      expect(canDropMessagesOn(one, find(side).byPath('Invoices')), isFalse,
          reason: 'different account');
      expect(canDropMessagesOn(const [], find(personal).byPath('Travel')),
          isFalse);
    });
  });

  group('message list gestures', () {
    Widget app() => const ProviderScope(child: MaterialApp(home: AppShell()));

    void wide(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('swiping left deletes and says so', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final first = tester.widget<MessageTile>(find.byType(MessageTile).first);
      final subject = first.message.subject;

      await tester.drag(find.byType(MessageTile).first, const Offset(-500, 0));
      await tester.pumpAndSettle();

      expect(find.text('Message deleted'), findsOneWidget);
      final subjects = tester
          .widgetList<MessageTile>(find.byType(MessageTile))
          .map((t) => t.message.subject);
      expect(subjects.where((s) => s == subject), isEmpty);
    });

    testWidgets('swiping right opens Move to, and cancelling keeps the row',
        (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final before = find.byType(MessageTile).evaluate().length;
      await tester.drag(find.byType(MessageTile).first, const Offset(500, 0));
      await tester.pumpAndSettle();

      expect(find.text('Move to'), findsOneWidget);
      expect(find.text('Travel'), findsWidgets);

      // Dismiss without choosing.
      await tester.tapAt(const Offset(700, 30));
      await tester.pumpAndSettle();
      expect(find.byType(MessageTile).evaluate().length, before);
    });

    testWidgets('choosing a destination moves the message and records it',
        (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // Work in a single account's folder so the move target is unambiguous.
      await tester.tap(find.text('Inbox').first);
      await tester.pumpAndSettle();

      // Count built tiles, not the list length: ListView only builds what is
      // visible, so a row leaving can pull another into view.
      final moved = tester
          .widget<MessageTile>(find.byType(MessageTile).first)
          .message;
      await tester.drag(find.byType(MessageTile).first, const Offset(500, 0));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ListTile, 'Travel').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('moved to Travel'), findsOneWidget);
      final remaining = tester
          .widgetList<MessageTile>(find.byType(MessageTile))
          .map((t) => t.message.id);
      expect(remaining, isNot(contains(moved.id)));

      // The destination is remembered for next time.
      await tester.drag(find.byType(MessageTile).first, const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(find.text('RECENT'), findsOneWidget);
    });

    testWidgets('the long-press menu offers move, flag, read and delete',
        (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MessageTile).first);
      await tester.pumpAndSettle();

      // Scoped to the sheet: the ribbon above the panes carries its own
      // Delete and Move, so a bare find.text would match either.
      final sheet = find.byType(BottomSheet);
      expect(find.descendant(of: sheet, matching: find.text('Move to…')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Delete')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.textContaining('Mark as')),
          findsOneWidget);
    });
  });
}

/// Small helper so the drop-rule test reads clearly.
class MailFolderFinder {
  MailFolderFinder(this.folders);

  final List folders;

  dynamic byPath(String path) =>
      folders.firstWhere((dynamic f) => f.path == path);
}
