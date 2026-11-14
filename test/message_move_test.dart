import 'dart:async';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/imap/imap_transport.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
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

    test('a message moved into another account is in that account',
        () async {
      await engine.loadFolders('acct-side');
      final inbox = await engine.loadMessages('acct-personal:INBOX');
      final target = inbox.first;

      await engine.moveMessages([target.id], 'acct-side:Invoices');

      final after = await engine.loadMessages('acct-personal:INBOX');
      expect(after.map((m) => m.id), isNot(contains(target.id)));
      final invoices = await engine.loadMessages('acct-side:Invoices');
      expect(invoices.first.subject, target.subject);
      expect(invoices.first.accountId, 'acct-side');
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

    group('Gmail\'s All Mail', () {
      setUp(() => server.folder('[Gmail]/All Mail', role: FolderRole.archive));

      test('an archive is a move into it, and its Undo a copy back out',
          () async {
        // Out of All Mail a message only ever goes by a copy, which adds
        // the label it goes to. A move takes it out of All Mail as well,
        // which Gmail reads as a delete: the Undo of an Archive would have
        // sent it to Trash.
        server.folder('INBOX').deliver(subject: 'Done with');
        final inbox = await engine.loadMessages('${account.id}:INBOX');
        await engine.loadFolders(account.id);

        final moves = await engine.moveMessages(
            [inbox.single.id], '${account.id}:[Gmail]/All Mail');
        expect(server.calls.last, startsWith('UID MOVE INBOX'));
        expect(await cache.countMessages(account.id, 'INBOX'), 0);

        server.calls.clear();
        await engine.undoMoves(moves);

        expect(server.calls.where((c) => c.startsWith('UID MOVE')), isEmpty);
        expect(
          server.calls,
          contains(startsWith('UID COPY [Gmail]/All Mail')),
        );
        final back = await engine.loadMessages('${account.id}:INBOX');
        expect(back.single.subject, 'Done with');
        expect(server.folder('[Gmail]/All Mail').messages, isNotEmpty,
            reason: 'still in All Mail, where every message is');
      });

      test('a message filed from it is copied, and stays in it', () async {
        server.folder('[Gmail]/All Mail').deliver(subject: 'Old');
        await engine.loadFolders(account.id);
        final all = await engine.loadMessages('${account.id}:[Gmail]/All Mail');

        await engine.moveMessages([all.single.id], '${account.id}:Work');

        expect(server.calls, contains(startsWith('UID COPY [Gmail]/All Mail')));
        expect(server.calls.where((c) => c.startsWith('UID MOVE')), isEmpty);
        expect(await cache.countMessages(account.id, '[Gmail]/All Mail'), 1);
      });
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

    test('a move that went is not reported as failed when the refresh after '
        'it fails', () async {
      // On a weak connection the move lands and the look at the destination
      // afterwards does not. That used to fail the whole delete: the app
      // said the message was where it was and put its row back, although
      // it was already in Trash.
      final flaky = _OfflineAfterMove();
      flaky.folder('INBOX', role: FolderRole.inbox).deliver(subject: 'Bin');
      flaky.folder('[Gmail]/Trash', role: FolderRole.deleted);
      final engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: cache,
        transportFactory: (_, _) => flaky,
      );
      final account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      final inbox = await engine.loadMessages('${account.id}:INBOX');
      // Trash has been opened before, so the move is followed by a sync.
      await engine.loadMessages('${account.id}:[Gmail]/Trash');

      final moves = await engine.deleteMessages([inbox.single.id]);

      expect(moves.single.toFolderId, '${account.id}:[Gmail]/Trash');
      expect(await cache.countMessages(account.id, 'INBOX'), 0);
    });

    test('a delete answers before Trash is synced, and a run of them shares '
        'one sync', () async {
      // Undo showed only once a whole sync of Trash had run, about ten
      // requests on a Microsoft account, and a run of deletes queued one
      // such sync each.
      final slow = _HeldSelect();
      final inbox = slow.folder('INBOX', role: FolderRole.inbox);
      for (var i = 0; i < 3; i++) {
        inbox.deliver(subject: 'Bin $i');
      }
      slow.folder('[Gmail]/Trash', role: FolderRole.deleted);
      final engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: cache,
        transportFactory: (_, _) => slow,
      );
      final account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      final rows = await engine.loadMessages('${account.id}:INBOX');
      // Trash has been opened before, so the move is followed by a sync.
      await engine.loadMessages('${account.id}:[Gmail]/Trash');
      slow.held = '[Gmail]/Trash';
      slow.calls.clear();

      var answered = 0;
      for (final m in rows) {
        unawaited(engine.deleteMessages([m.id]).then((_) => answered++));
        await pumpEventQueue();
      }

      expect(answered, 3, reason: 'none waits for the sync of Trash');
      slow.release.complete();
      await pumpEventQueue();
      expect(
        slow.calls.where((c) => c == 'SELECT [Gmail]/Trash'),
        hasLength(2),
        reason: 'the one under way, and one more after it for the rest',
      );
      expect(await cache.countMessages(account.id, '[Gmail]/Trash'), 3);
    });

    test('closing waits for the sync behind a move, so it does not run on '
        'into a connection closed', () async {
      // A background job closes the engine as soon as its delete answers.
      // The sync behind it carried on after, and over IMAP its next command
      // connected again, from an isolate about to go.
      final slow = _HeldSelect();
      slow.folder('INBOX', role: FolderRole.inbox).deliver(subject: 'Bin');
      slow.folder('[Gmail]/Trash', role: FolderRole.deleted);
      final engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: cache,
        transportFactory: (_, _) => slow,
      );
      final account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      final rows = await engine.loadMessages('${account.id}:INBOX');
      await engine.loadMessages('${account.id}:[Gmail]/Trash');
      slow.held = '[Gmail]/Trash';
      await engine.deleteMessages([rows.single.id]);
      slow.calls.clear();

      Timer(const Duration(milliseconds: 20), slow.release.complete);
      await engine.close();

      expect(slow.calls.last, 'LOGOUT');
      expect(slow.calls, contains('SELECT [Gmail]/Trash'));
    });

    group('with the sync of Trash behind a delete still running', () {
      late _HeldSelect slow;
      late CachedImapEngine engine;
      late Account account;
      late String trash;

      setUp(() async {
        slow = _HeldSelect();
        slow.folder('INBOX', role: FolderRole.inbox).deliver(subject: 'Bin');
        slow.folder('[Gmail]/Trash', role: FolderRole.deleted);
        engine = CachedImapEngine(
          accountStore: MemoryAccountStore(),
          credentialStore: MemoryCredentialStore(),
          cache: cache,
          transportFactory: (_, _) => slow,
        );
        account = await engine.addAccount(
          displayName: 'P',
          emailAddress: 'p@example.com',
          provider: MailProvider.gmail,
          secret: 'abcdabcdabcdabcd',
        );
        trash = '${account.id}:[Gmail]/Trash';
        await engine.loadMessages(trash);
        final rows = await engine.loadMessages('${account.id}:INBOX');
        slow
          ..held = '[Gmail]/Trash'
          ..holdOnce = true;
        await engine.deleteMessages([rows.single.id]);
      });

      test('removing the account leaves nothing of it behind', () async {
        // The sync carried on after the account's cache was deleted, and
        // wrote rows and a folder state for an account that was gone, which
        // nothing ever cleans up.
        Timer(const Duration(milliseconds: 20), slow.release.complete);

        await engine.removeAccount(account.id);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(await cache.readFolderState(account.id, '[Gmail]/Trash'),
            isNull);
        expect(await cache.countMessages(account.id, '[Gmail]/Trash'), 0);
      });

      test('opening Trash waits for it, rather than syncing beside it',
          () async {
        // Two syncs of the folder at once: on a Microsoft account both
        // looked back across its cache, twice the pages.
        List<MailMessage>? loaded;
        unawaited(engine.loadMessages(trash).then((rows) => loaded = rows));
        await pumpEventQueue();

        expect(loaded, isNull, reason: 'its own sync not begun beside it');
        slow.release.complete();
        await pumpEventQueue();
        expect(loaded?.map((m) => m.subject), ['Bin']);
      });
    });

    group('mail taken out of a folder while the sync behind a move into it '
        'runs', () {
      // That sync has read the folder by then, and wrote its row for the
      // message after the message had gone: back in the list until the
      // folder next synced. Each of these waits for it first.
      late _HeldSelect slow;
      late CachedImapEngine engine;
      late Account account;
      late MailMessage bin;

      setUp(() async {
        slow = _HeldSelect();
        slow.folder('INBOX', role: FolderRole.inbox).deliver(subject: 'Bin');
        slow.folder('[Gmail]/Trash', role: FolderRole.deleted);
        slow.folder('Work');
        slow.folder('Archive');
        engine = CachedImapEngine(
          accountStore: MemoryAccountStore(),
          credentialStore: MemoryCredentialStore(),
          cache: cache,
          transportFactory: (_, _) => slow,
        );
        account = await engine.addAccount(
          displayName: 'P',
          emailAddress: 'p@example.com',
          provider: MailProvider.gmail,
          secret: 'abcdabcdabcdabcd',
        );
        await engine.loadMessages('${account.id}:[Gmail]/Trash');
        await engine.loadMessages('${account.id}:Work');
        bin = (await engine.loadMessages('${account.id}:INBOX')).single;
      });

      Future<int> rows(String path) => cache.countMessages(account.id, path);

      test('moved on again', () async {
        // Filed, and filed again from the search results.
        slow.fetchHeld = 'Work';
        final moves = await engine.moveMessages([bin.id], '${account.id}:Work');
        await pumpEventQueue();
        Timer(const Duration(milliseconds: 20), slow.release.complete);

        await engine.moveMessages(
            moves.single.movedIds, '${account.id}:Archive');
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(slow.folder('Work').messages, isEmpty);
        expect(await rows('Work'), 0);
      });

      test('deleted for good from Trash', () async {
        slow.fetchHeld = '[Gmail]/Trash';
        final moves = await engine.deleteMessages([bin.id]);
        await pumpEventQueue();
        Timer(const Duration(milliseconds: 20), slow.release.complete);

        await engine.deleteMessages(moves.single.movedIds);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(slow.folder('[Gmail]/Trash').messages, isEmpty);
        expect(await rows('[Gmail]/Trash'), 0);
      });

      test('Trash emptied, with a delete kept for later sent first', () async {
        // Empty sends what is waiting before it empties, and that delete,
        // sent, starts a sync of the very folder about to be emptied.
        slow.offline = true;
        final moves = await engine.deleteMessages([bin.id]);
        expect(moves.single.isWaiting, isTrue);
        slow.offline = false;
        slow.fetchHeld = '[Gmail]/Trash';
        Timer(const Duration(milliseconds: 20), slow.release.complete);

        await engine.emptyFolder('${account.id}:[Gmail]/Trash');
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(slow.folder('[Gmail]/Trash').messages, isEmpty);
        expect(await rows('[Gmail]/Trash'), 0);
      });
    });

    group('Undo, with the sync behind a move not waited for', () {
      late _HeldSelect slow;
      late CachedImapEngine engine;
      late Account account;
      late MailMessage oops;

      setUp(() async {
        slow = _HeldSelect();
        slow.folder('INBOX', role: FolderRole.inbox).deliver(subject: 'Oops');
        slow.folder('[Gmail]/Trash', role: FolderRole.deleted);
        engine = CachedImapEngine(
          accountStore: MemoryAccountStore(),
          credentialStore: MemoryCredentialStore(),
          cache: cache,
          transportFactory: (_, _) => slow,
        );
        account = await engine.addAccount(
          displayName: 'P',
          emailAddress: 'p@example.com',
          provider: MailProvider.gmail,
          secret: 'abcdabcdabcdabcd',
        );
        await engine.loadMessages('${account.id}:[Gmail]/Trash');
        oops = (await engine.loadMessages('${account.id}:INBOX')).single;
      });

      test('has the message back in its folder on the device when it is done',
          () async {
        // The lists are asked again once Undo is done, and draw what the
        // device has first: the Inbox, synced behind the move back, did not
        // have it yet, and the message showed only after a sync.
        final moves = await engine.deleteMessages([oops.id]);
        await pumpEventQueue();
        slow.held = 'INBOX';
        Timer(const Duration(milliseconds: 20), slow.release.complete);

        await engine.undoMoves(moves);

        final inbox = await engine.cachedMessages('${account.id}:INBOX');
        expect(inbox.map((m) => m.subject), ['Oops']);
      });

      test('leaves no row in Trash for the sync behind the delete to write',
          () async {
        // That sync had read Trash before the Undo, and wrote its row for
        // the message after the Undo had taken it out.
        slow.fetchHeld = '[Gmail]/Trash';
        final moves = await engine.deleteMessages([oops.id]);
        await pumpEventQueue();
        Timer(const Duration(milliseconds: 20), slow.release.complete);

        await engine.undoMoves(moves);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(await cache.countMessages(account.id, '[Gmail]/Trash'), 0);
        expect(slow.folder('[Gmail]/Trash').messages, isEmpty);
      });
    });
  });

  group('cached engine move into another account', () {
    late FakeImapTransport home;
    late FakeImapTransport away;
    late CachedImapEngine engine;
    late MemoryCacheStore cache;
    late Account mine;
    late Account work;

    setUp(() async {
      home = FakeImapTransport();
      away = FakeImapTransport();
      cache = MemoryCacheStore();
      for (final server in [home, away]) {
        server.folder('INBOX', role: FolderRole.inbox);
        server.folder('[Gmail]/Trash', role: FolderRole.deleted);
      }
      away.folder('Receipts');
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: cache,
        transportFactory: (account, _) =>
            account.emailAddress == 'p@example.com' ? home : away,
      );
      mine = await engine.addAccount(
        displayName: 'Personal',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      work = await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'w@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
    });

    String receipts() => '${work.id}:Receipts';
    String binHere() => '${mine.id}:[Gmail]/Trash';

    test('it is copied there as it was, and the original goes to Trash here',
        () async {
      final sent = DateTime.utc(2026, 3, 4, 5, 6);
      home.folder('INBOX').deliver(subject: 'Invoice 12', date: sent)
          .isFlagged = true;
      final inbox = await engine.loadMessages('${mine.id}:INBOX');

      final moves = await engine.moveMessages([inbox.single.id], receipts());

      expect(away.calls, contains(r'FILE Receipts \Flagged'),
          reason: 'unread and flagged, as it was');
      final there = away.folder('Receipts').messages.values.single;
      expect(there.subject, 'Invoice 12');
      expect(there.date, sent, reason: 'dated when it arrived, not now');
      expect(home.folder('INBOX').messages, isEmpty);
      expect(home.folder('[Gmail]/Trash').messages.values.single.subject,
          'Invoice 12',
          reason: 'deleted here the way a delete is, into Trash');
      expect(await cache.countMessages(mine.id, 'INBOX'), 0);

      final move = moves.single;
      expect(move.toFolderId, receipts());
      expect(move.movedIds.single, startsWith('${receipts()}#'));
      expect(move.originals?.toFolderId, binHere());
      expect(move.landedIn, containsAll([receipts(), binHere()]));
      expect(canUndoAll(moves, 1), isTrue);
    });

    test('undo brings the original back and takes the copy out', () async {
      home.folder('INBOX').deliver(subject: 'Invoice 12', isRead: true);
      final inbox = await engine.loadMessages('${mine.id}:INBOX');
      final moves = await engine.moveMessages([inbox.single.id], receipts());
      away.calls.clear();

      await engine.undoMoves(moves);

      expect(home.folder('INBOX').messages.values.single.subject,
          'Invoice 12');
      expect(home.folder('[Gmail]/Trash').messages, isEmpty);
      expect(away.folder('Receipts').messages, isEmpty);
      // Out of the folder where it is, never through Trash: on Gmail a copy
      // of mail it had already is that mail, and Trash would delete it.
      expect(away.folder('[Gmail]/Trash').messages, isEmpty);
      expect(away.calls.where((c) => c.startsWith('UID MOVE')), isEmpty);
      expect(away.calls, contains('EXPUNGE Receipts'));
    });

    test('undo finds the copy by its Message-ID where the server gave no id',
        () async {
      away.reportsCopyUids = false;
      home.folder('INBOX').deliver(subject: 'Invoice 12');
      final inbox = await engine.loadMessages('${mine.id}:INBOX');
      await engine.loadMessages(receipts());
      final moves = await engine.moveMessages([inbox.single.id], receipts());
      expect(moves.single.movedIds, isEmpty);
      expect(canUndoAll(moves, 1), isTrue);

      await engine.undoMoves(moves);

      expect(home.folder('INBOX').messages, hasLength(1));
      expect(away.folder('Receipts').messages, isEmpty);
    });

    test('a copy that will not go leaves the original where it was',
        () async {
      home.folder('INBOX').deliver(subject: 'Invoice 12');
      final inbox = await engine.loadMessages('${mine.id}:INBOX');
      away.refuseFiling = (_) => true;

      await expectLater(
        engine.moveMessages([inbox.single.id], receipts()),
        throwsA(isA<ConnectionFailed>()),
      );

      expect(home.folder('INBOX').messages, hasLength(1));
      expect(home.folder('[Gmail]/Trash').messages, isEmpty);
      expect(away.folder('Receipts').messages, isEmpty);
    });

    test('stopping part way, the ones copied are moved and said to be',
        () async {
      home.folder('INBOX')
        ..deliver(subject: 'One')
        ..deliver(subject: 'Two');
      final inbox = await engine.loadMessages('${mine.id}:INBOX');
      final one = inbox.firstWhere((m) => m.subject == 'One');
      final two = inbox.firstWhere((m) => m.subject == 'Two');
      away.refuseFiling = (mime) => mime.contains('Subject: Two');

      final part = await engine
          .moveMessages([one.id, two.id], receipts())
          .then<PartialMove?>((_) => null, onError: (Object e) => e as PartialMove);

      expect(part?.moved, [one.id]);
      expect(canUndoAll(part!.done, 1), isTrue);
      expect(away.folder('Receipts').messages.values.single.subject, 'One');
      expect(home.folder('INBOX').messages.values.single.subject, 'Two');
      expect(home.folder('[Gmail]/Trash').messages.values.single.subject,
          'One');
    });

    test('an original that cannot be taken out says it is in both', () async {
      home.folder('INBOX').deliver(subject: 'Invoice 12');
      final inbox = await engine.loadMessages('${mine.id}:INBOX');
      home.refuseMovesFrom.add('INBOX');

      await expectLater(
        engine.moveMessages([inbox.single.id], receipts()),
        throwsA(isA<ConnectionFailed>().having(
            (e) => e.message, 'message', contains('in both'))),
      );

      expect(away.folder('Receipts').messages, hasLength(1));
      expect(home.folder('INBOX').messages, hasLength(1));
    });

    test('out of Trash into another account cannot be undone', () async {
      home.folder('[Gmail]/Trash').deliver(subject: 'Old');
      final trash = await engine.loadMessages(binHere());

      final moves = await engine.moveMessages([trash.single.id], receipts());

      expect(away.folder('Receipts').messages, hasLength(1));
      expect(home.folder('[Gmail]/Trash').messages, isEmpty,
          reason: 'deleted for good, the way a delete in Trash is');
      expect(canUndoAll(moves, 1), isFalse,
          reason: 'there is no original left to put back');
    });
  });

  group('drop rules for messages', () {
    test('only folders that accept messages, in any account, take a drop',
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
      expect(canDropMessagesOn(one, find(side).byPath('Invoices')), isTrue,
          reason: 'another mailbox is somewhere to move it too');
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

    // The row that raised the bar is gone by the time Undo is tapped, and so
    // is anything it held.
    testWidgets('Undo after a swipe puts the row back', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final first = tester.widget<MessageTile>(find.byType(MessageTile).first);
      final subject = first.message.subject;

      await tester.drag(find.byType(MessageTile).first, const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('Message put back'), findsOneWidget);
      final subjects = tester
          .widgetList<MessageTile>(find.byType(MessageTile))
          .map((t) => t.message.subject);
      expect(subjects.where((s) => s == subject), hasLength(1));
    });

    testWidgets('Undo after a move puts it back', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inbox').first);
      await tester.pumpAndSettle();
      final moved = tester
          .widget<MessageTile>(find.byType(MessageTile).first)
          .message;

      await tester.drag(find.byType(MessageTile).first, const Offset(500, 0));
      await tester.pumpAndSettle();
      await tester.tap(_moveTarget('Travel'));
      await tester.pumpAndSettle();
      expect(find.textContaining('moved to Travel'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('Message put back'), findsOneWidget);
      final back = tester
          .widgetList<MessageTile>(find.byType(MessageTile))
          .map((t) => t.message)
          .where((m) => m.subject == moved.subject && m.date == moved.date);
      expect(back, hasLength(1));
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

      await tester.tap(_moveTarget('Travel'));
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

    testWidgets('the right-click menu offers reply, move, flag, read and delete',
        (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(MessageTile).first, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      // Reply, Reply all, Forward and Delete are the row of icons across
      // its top (3.7.0). Scoped to the menu's entries: the ribbon above the
      // panes carries its own Delete and Move, so a bare find.text would
      // match either.
      for (final key in ['reply', 'replyAll', 'forward', 'delete']) {
        expect(find.byKey(ValueKey('menu-$key')), findsOneWidget, reason: key);
      }
      Finder entry(String text) => find.widgetWithText(PopupMenuItem<String>, text);
      expect(entry('Move to…'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<String>),
          matching: find.textContaining('Mark as'),
        ),
        findsOneWidget,
      );
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

/// A server whose connection goes the moment a move has been done.
class _OfflineAfterMove extends FakeImapTransport {
  @override
  Future<List<int>?> moveMessages(
    String fromPath,
    List<int> uids,
    String toPath,
  ) async {
    final landed = await super.moveMessages(fromPath, uids, toPath);
    offline = true;
    return landed;
  }
}

/// A server that holds every SELECT of [held] until [release] completes,
/// or only the first with [holdOnce], and every page of headers from
/// [fetchHeld], read, until then too.
class _HeldSelect extends FakeImapTransport {
  String? held;
  bool holdOnce = false;
  String? fetchHeld;
  final release = Completer<void>();

  @override
  Future<FolderStatus> selectFolder(String path) async {
    if (path == held) {
      if (holdOnce) held = null;
      await release.future;
    }
    return super.selectFolder(path);
  }

  @override
  Future<List<RemoteHeader>> fetchHeadersBySequence(
    String path,
    int start,
    int end,
  ) async {
    final headers = await super.fetchHeadersBySequence(path, start, end);
    if (path == fetchHeld) await release.future;
    return headers;
  }

  @override
  Future<List<RemoteHeader>> fetchHeadersFromUid(
    String path,
    int fromUid, {
    DateTime? windowStart,
  }) async {
    final headers = await super.fetchHeadersFromUid(
      path,
      fromUid,
      windowStart: windowStart,
    );
    if (path == fetchHeld) await release.future;
    return headers;
  }
}

/// A folder in the Move to sheet, by name: a row of the tree, or of Recent.
Finder _moveTarget(String name) => find
    .ancestor(
      of: find.text(name),
      matching: find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          RegExp(r'^move-(tree|option)-')
              .hasMatch((w.key as ValueKey<String>).value)),
    )
    .first;
