import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/domain/pending_change.dart';

import 'fakes/fake_imap_transport.dart';

/// A move, a delete or a mark made while the server is out of reach.
///
/// Ron, on an aeroplane, 2026-11-12: "Could not delete: Microsoft is having
/// trouble (HTTP 502). Try again shortly." It's nice to see the message,
/// "but you should be able to delete, move,... offline and sync it later".
/// Now the change shows at once, waits in the database, and goes when the
/// server answers.
void main() {
  late FakeImapTransport server;
  late MemoryAccountStore accounts;
  late MemoryCredentialStore secrets;
  late MemoryCacheStore cache;
  late CachedImapEngine engine;
  late DateTime now;
  late int asked;
  late String accountId;
  late String inbox;

  setUp(() async {
    server = FakeImapTransport();
    accounts = MemoryAccountStore();
    secrets = MemoryCredentialStore();
    cache = MemoryCacheStore();
    now = DateTime(2026, 11, 12, 9);
    asked = 0;
    engine = CachedImapEngine(
      accountStore: accounts,
      credentialStore: secrets,
      cache: cache,
      transportFactory: (_, _) => server,
      onChangesWaiting: () => asked++,
      clock: () => now,
    );
    server.folder('INBOX', role: FolderRole.inbox)
      ..deliver(subject: 'Lunch')
      ..deliver(subject: 'Invoice')
      ..deliver(subject: 'Drawings');
    server.folder('[Gmail]/Trash', role: FolderRole.deleted);
    server.folder('Work');
    server.folder(CachedImapEngine.snoozedFolderName);
    accountId = (await engine.addAccount(
      displayName: 'Personal',
      emailAddress: 'me@example.com',
      provider: MailProvider.gmail,
      secret: 'abcdabcdabcdabcd',
    ))
        .id;
    inbox = '$accountId:INBOX';
    // As the app has them: the folders listed, and the Inbox opened.
    await engine.loadFolders(accountId);
    await engine.loadMessages(inbox);
  });

  Future<List<String>> shown([String? folderId]) async => [
        for (final m in await engine.cachedMessages(folderId ?? inbox))
          m.subject,
      ];

  Future<MailMessage> row(String subject) async =>
      (await engine.cachedMessages(inbox)).firstWhere((m) => m.subject == subject);

  List<String> onServer(String path) =>
      [for (final m in server.folder(path).ordered) m.subject];

  FakeMessage serverCopy(String path, String subject) =>
      server.folder(path).ordered.firstWhere((m) => m.subject == subject);

  /// Past the time a change is held for its Undo.
  void later([Duration by = const Duration(seconds: 10)]) => now = now.add(by);

  group('a delete with the server out of reach', () {
    test('shows as done, and waits', () async {
      final lunch = await row('Lunch');
      server.offline = true;

      final moves = await engine.deleteMessages([lunch.id]);

      expect(moves.single.isWaiting, isTrue);
      expect(moves.single.toFolderId, '$accountId:[Gmail]/Trash');
      expect(canUndoAll(moves, 1), isTrue);
      expect(await shown(), isNot(contains('Lunch')));
      expect(onServer('INBOX'), contains('Lunch'));
      expect(await engine.changesWaiting(), {accountId: 1});
      expect(asked, 1, reason: 'something is asked to send it later');
    });

    test('goes once the server answers and its Undo has run out', () async {
      final lunch = await row('Lunch');
      server.offline = true;
      await engine.deleteMessages([lunch.id]);
      server.offline = false;

      expect((await engine.sendWaitingChanges()).sent, 0,
          reason: 'held while its Undo is on screen');
      later();
      final sent = await engine.sendWaitingChanges();

      expect(sent.sent, 1);
      expect(sent.waiting, 0);
      expect(sent.folders, containsAll([inbox, '$accountId:[Gmail]/Trash']));
      expect(onServer('INBOX'), isNot(contains('Lunch')));
      expect(onServer('[Gmail]/Trash'), ['Lunch']);
      expect(await engine.changesWaiting(), isEmpty);
      expect(await shown(), isNot(contains('Lunch')));
    });

    test('waits on while the server is still out of reach', () async {
      server.offline = true;
      await engine.deleteMessages([(await row('Lunch')).id]);
      later();

      final sent = await engine.sendWaitingChanges();

      expect((sent.sent, sent.waiting, sent.failed), (0, 1, 0));
      expect(await shown(), isNot(contains('Lunch')));
    });

    test('a sync that finds it still there does not bring it back', () async {
      // The server has it until the change goes, and says so every sync.
      server.offline = true;
      await engine.deleteMessages([(await row('Lunch')).id]);
      server.offline = false;

      final listed = await engine.loadMessages(inbox);

      expect([for (final m in listed) m.subject], isNot(contains('Lunch')));
      expect(onServer('INBOX'), contains('Lunch'));
    });

    test('the Inbox counts it gone meanwhile', () async {
      final before = (await engine.cachedFolders(accountId))
          .firstWhere((f) => f.path == 'INBOX');
      server.offline = true;
      await engine.deleteMessages([(await row('Lunch')).id]);

      final after = (await engine.cachedFolders(accountId))
          .firstWhere((f) => f.path == 'INBOX');

      expect(after.totalCount, before.totalCount - 1);
      expect(after.unreadCount, before.unreadCount - 1);
    });

    test('Undo takes it back before it goes', () async {
      server.offline = true;
      final moves = await engine.deleteMessages([(await row('Lunch')).id]);

      await engine.undoMoves(moves);

      expect(await shown(), contains('Lunch'));
      expect(await engine.changesWaiting(), isEmpty);
      server.offline = false;
      later();
      expect((await engine.sendWaitingChanges()).sent, 0);
      expect(onServer('INBOX'), contains('Lunch'));
      expect(onServer('[Gmail]/Trash'), isEmpty);
    });

    test('Undo after it went fetches it back from Trash', () async {
      server.offline = true;
      final moves = await engine.deleteMessages([(await row('Lunch')).id]);
      server.offline = false;
      later();
      await engine.sendWaitingChanges();

      await engine.undoMoves(moves);

      expect(onServer('INBOX'), contains('Lunch'));
      expect(onServer('[Gmail]/Trash'), isEmpty);
    });

    test('one in Trash already is deleted for good when it goes, and can '
        'still be taken back before then', () async {
      await engine.deleteMessages([(await row('Lunch')).id]);
      final trash = '$accountId:[Gmail]/Trash';
      final binned = (await engine.loadMessages(trash)).single;
      server.offline = true;

      final moves = await engine.deleteMessages([binned.id]);

      expect(canUndoAll(moves, 1), isTrue,
          reason: 'not gone for good until it goes');
      expect(await shown(trash), isEmpty);
      server.offline = false;
      later();
      await engine.sendWaitingChanges();
      expect(onServer('[Gmail]/Trash'), isEmpty);
    });
  });

  group('the list while messages are on their way out', () {
    test('a page is still a page, from the top and further down', () async {
      final folder = server.folder('INBOX');
      for (var i = 0; i < 10; i++) {
        folder.deliver(subject: 'More $i');
      }
      final all = await engine.loadMessages(inbox, limit: 50);
      expect(all, hasLength(13));
      server.offline = true;
      // The three newest: wherever they are, the page reads past them.
      await engine.deleteMessages([for (final m in all.take(3)) m.id]);

      final first = await engine.cachedMessages(inbox, limit: 5);
      final second = await engine.cachedMessages(inbox, offset: 5, limit: 5);

      expect([for (final m in first) m.id], [for (final m in all.skip(3).take(5)) m.id]);
      expect([for (final m in second) m.id], [for (final m in all.skip(8).take(5)) m.id]);
    });
  });

  group('Undo of a change a sender has in hand', () {
    test('waits for it, and fetches back what went', () async {
      server.offline = true;
      final lunch = await row('Lunch');
      final moves = await engine.deleteMessages([lunch.id]);
      server.offline = false;
      later();
      // Another sender, the background's, takes it and sends it while the
      // Undo is pressed.
      final held = await cache.claimPending(
        by: 'background',
        madeBefore: now,
        staleBefore: now.subtract(CachedImapEngine.claimLapses),
        now: now,
      );
      expect(held, hasLength(1));
      final undoing = engine.undoMoves(moves);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await server.moveMessages('INBOX', [held.single.uid], '[Gmail]/Trash');
      await cache.dropPending([held.single.id]);

      await undoing;

      expect(onServer('INBOX'), contains('Lunch'));
      expect(onServer('[Gmail]/Trash'), isEmpty);
    });
  });

  group('a move with the server out of reach', () {
    test('shows as done, and the folder it goes to has it once it goes',
        () async {
      server.offline = true;
      final moves =
          await engine.moveMessages([(await row('Invoice')).id], '$accountId:Work');
      expect(moves.single.isWaiting, isTrue);
      expect(await shown(), isNot(contains('Invoice')));

      server.offline = false;
      later();
      await engine.sendWaitingChanges();

      expect(onServer('Work'), ['Invoice']);
      expect(await shown('$accountId:Work'), isEmpty,
          reason: 'not opened yet');
      expect([
        for (final m in await engine.loadMessages('$accountId:Work')) m.subject
      ], ['Invoice']);
    });

    test('into another account is not kept: it needs both servers', () async {
      server.offline = true;

      await expectLater(
        engine.moveMessages([(await row('Invoice')).id], 'other-account:INBOX'),
        throwsA(anything),
      );
      expect(await engine.changesWaiting(), isEmpty);
    });
  });

  group('a mark with the server out of reach', () {
    test('read shows read, counts so, and goes later', () async {
      final drawings = await row('Drawings');
      final unread = (await engine.cachedFolders(accountId))
          .firstWhere((f) => f.path == 'INBOX')
          .unreadCount;
      server.offline = true;

      await engine.setMessagesRead([drawings.id], true);

      expect((await row('Drawings')).isRead, isTrue);
      expect(serverCopy('INBOX', 'Drawings').isRead, isFalse);
      expect(
        (await engine.cachedFolders(accountId))
            .firstWhere((f) => f.path == 'INBOX')
            .unreadCount,
        unread - 1,
      );
      server.offline = false;
      // A sync meanwhile finds it unread on the server, and it still shows
      // read.
      await engine.loadMessages(inbox);
      expect((await row('Drawings')).isRead, isTrue);

      later();
      await engine.sendWaitingChanges();
      expect(serverCopy('INBOX', 'Drawings').isRead, isTrue);
      expect((await row('Drawings')).isRead, isTrue);
    });

    test('flagged shows in Flagged before the server knows', () async {
      final invoice = await row('Invoice');
      server.offline = true;

      await engine.setMessagesFlagged([invoice.id], true);

      expect((await row('Invoice')).isFlagged, isTrue);
      expect(
        [for (final m in await engine.cachedFlagged(accountId)) m.subject],
        ['Invoice'],
      );
    });

    test('a follow up keeps its day', () async {
      final invoice = await row('Invoice');
      final due = DateTime(2026, 11, 20);
      server.offline = true;

      await engine.setFollowUp([invoice.id], due: due);

      final kept = (await cache.readPending()).single;
      expect((kept.kind, kept.wanted, kept.due), (PendingKind.followUp, true, due));
      server.offline = false;
      later();
      await engine.sendWaitingChanges();
      expect(serverCopy('INBOX', 'Invoice').isFlagged, isTrue);
    });
  });

  group('the order changes are made in', () {
    test('a later change waits behind one that could not go', () async {
      // Read, then moved: sent with the mark failing and the move going,
      // the mark went afterwards to a number the message no longer had,
      // and it reached Work unread.
      final drawings = await row('Drawings');
      server.offline = true;
      await engine.setMessagesRead([drawings.id], true);
      await engine.moveMessages([drawings.id], '$accountId:Work');
      server.offline = false;
      server.storesFailWith = const ServerUnreachable('Timed out.');
      later();

      final first = await engine.sendWaitingChanges();

      expect((first.sent, first.waiting), (0, 2));
      expect(onServer('INBOX'), contains('Drawings'), reason: 'not moved');
      server.storesFailWith = null;
      later();
      final second = await engine.sendWaitingChanges();
      expect(second.sent, 2);
      expect(onServer('Work'), ['Drawings']);
      expect(serverCopy('Work', 'Drawings').isRead, isTrue);
    });

    test('a change made while others wait waits behind them, even with the '
        'server back', () async {
      server.offline = true;
      await engine.deleteMessages([(await row('Lunch')).id]);
      server.offline = false;

      await engine.setMessagesRead([(await row('Invoice')).id], true);

      expect(serverCopy('INBOX', 'Invoice').isRead, isFalse,
          reason: 'not ahead of the delete');
      expect((await row('Invoice')).isRead, isTrue);
      later();
      final sent = await engine.sendWaitingChanges();
      expect(sent.sent, 2);
      expect(serverCopy('INBOX', 'Invoice').isRead, isTrue);
      expect(onServer('[Gmail]/Trash'), ['Lunch']);
    });

    test('marks and deletes of one folder go in as few requests as allow',
        () async {
      server.offline = true;
      final all = await engine.cachedMessages(inbox);
      await engine.deleteMessages([for (final m in all) m.id]);
      server.offline = false;
      later();
      server.calls.clear();

      await engine.sendWaitingChanges();

      expect(server.calls.where((c) => c.startsWith('UID MOVE')), hasLength(1));
    });
  });

  group('what supersedes a change waiting', () {
    test('Mark all read drops the marks waiting for its folder', () async {
      server.offline = true;
      await engine.setMessagesRead([(await row('Lunch')).id], false);
      server.offline = false;

      await engine.markAllRead(inbox);

      expect(await engine.changesWaiting(), isEmpty);
      expect((await row('Lunch')).isRead, isTrue);
    });

    test('Empty drops every change waiting for its folder', () async {
      await engine.loadMessages('$accountId:Work');
      server.offline = true;
      await engine.moveMessages([(await row('Lunch')).id], '$accountId:Work');
      server.offline = false;
      later();
      await engine.sendWaitingChanges();
      final work = '$accountId:Work';
      server.offline = true;
      await engine.setMessagesFlagged(
          [(await engine.loadMessages(work)).single.id], true);
      server.offline = false;

      await engine.emptyFolder(work);

      expect(await engine.changesWaiting(), isEmpty);
    });
  });

  // Not junk with the server out of reach, then Empty Junk: the server
  // still had the message there, and it went for good with the rest, while
  // the move that would have saved it was dropped.
  group('a folder emptied or deleted while mail moved out of it waits', () {
    final notSyncedYet = isA<ConnectionFailed>().having(
        (e) => e.message, 'message', contains('has not synced yet'));
    late String trash;

    /// Two in Trash, listed, and one of them moved back to the Inbox with
    /// the server out of reach, which is answering again now.
    Future<void> rescueOneFromTrash() async {
      server.folder('[Gmail]/Trash')
        ..deliver(subject: 'Old receipt')
        ..deliver(subject: 'Rescued');
      trash = '$accountId:[Gmail]/Trash';
      final binned = await engine.loadMessages(trash);
      server.offline = true;
      final moves = await engine.moveMessages(
          [binned.firstWhere((m) => m.subject == 'Rescued').id], inbox);
      expect(moves.single.isWaiting, isTrue);
      server.offline = false;
    }

    test('Empty sends the move first, even one still held for its Undo, '
        'and the message is where it was moved to', () async {
      await rescueOneFromTrash();

      await engine.emptyFolder(trash);

      expect(onServer('[Gmail]/Trash'), isEmpty);
      expect(onServer('INBOX'), contains('Rescued'));
      expect(await engine.changesWaiting(), isEmpty);
    });

    test('Empty sends that account\'s changes alone: another\'s stays held '
        'for its Undo', () async {
      final other = (await engine.addAccount(
        displayName: 'Other',
        emailAddress: 'other@example.com',
        provider: MailProvider.gmail,
        secret: 'efghefghefghefgh',
      ))
          .id;
      await engine.loadFolders(other);
      final lunch = (await engine.loadMessages('$other:INBOX'))
          .firstWhere((m) => m.subject == 'Lunch');
      await rescueOneFromTrash();
      server.offline = true;
      await engine.deleteMessages([lunch.id]);
      server.offline = false;

      await engine.emptyFolder(trash);

      expect(onServer('INBOX'), contains('Rescued'));
      expect(await engine.changesWaiting(), {other: 1});
    });

    test('Empty with the move still not going is refused, and nothing is '
        'deleted or dropped', () async {
      await rescueOneFromTrash();
      server.movesFailWith = const ServerUnreachable('Timed out.');

      await expectLater(engine.emptyFolder(trash), throwsA(notSyncedYet));

      expect(onServer('[Gmail]/Trash'), ['Old receipt', 'Rescued']);
      expect(await shown(trash), ['Old receipt']);
      expect((await cache.readPending()).single.kind, PendingKind.move);
    });

    test('Empty while another sender has the move in hand is refused, and '
        'the move is not sent twice', () async {
      await rescueOneFromTrash();
      later();
      // The background's, part way through sending it.
      await cache.claimPending(
        by: 'background',
        madeBefore: now,
        staleBefore: now.subtract(CachedImapEngine.claimLapses),
        now: now,
      );
      server.calls.clear();

      await expectLater(engine.emptyFolder(trash), throwsA(notSyncedYet));

      expect(server.calls.where((c) => c.startsWith('UID MOVE')), isEmpty);
      expect(onServer('[Gmail]/Trash'), ['Old receipt', 'Rescued']);
      expect(await engine.changesWaiting(), {accountId: 1});
    });

    test('Delete folder sends a move out of it first', () async {
      server.folder('Work')
        ..deliver(subject: 'Plans')
        ..deliver(subject: 'Rescued');
      final work = await engine.loadMessages('$accountId:Work');
      server.offline = true;
      await engine.moveMessages(
          [work.firstWhere((m) => m.subject == 'Rescued').id], inbox);
      server.offline = false;

      await engine.deleteFolder('$accountId:Work');

      expect(server.folders.keys, isNot(contains('Work')));
      expect(onServer('INBOX'), contains('Rescued'));
      expect(await engine.changesWaiting(), isEmpty);
    });

    test('Delete folder with a move out of a folder in it still not going '
        'is refused, and nothing is deleted or dropped', () async {
      server.folder('Work/2025').deliver(subject: 'Rescued');
      final old = await engine.loadMessages('$accountId:Work/2025');
      server.offline = true;
      await engine.moveMessages([old.single.id], inbox);
      server.offline = false;
      server.movesFailWith = const ServerUnreachable('Timed out.');

      await expectLater(
        engine.deleteFolder('$accountId:Work'),
        throwsA(notSyncedYet),
      );

      expect(server.folders.keys, containsAll(['Work', 'Work/2025']));
      expect(onServer('Work/2025'), ['Rescued']);
      expect((await cache.readPending()).single.kind, PendingKind.move);
    });
  });

  group('a change the server refuses', () {
    test('is said at once when the server is there to refuse it', () async {
      server.refuseMovesFrom.add('INBOX');

      await expectLater(
        engine.moveMessages([(await row('Lunch')).id], '$accountId:Work'),
        throwsA(isA<StateError>()),
      );
      expect(await engine.changesWaiting(), isEmpty);
      expect(await shown(), contains('Lunch'));
    });

    test('kept for later, is given up on, said once, and the message comes '
        'back', () async {
      server.offline = true;
      await engine.moveMessages([(await row('Lunch')).id], '$accountId:Work');
      server.offline = false;
      server.refuseMovesFrom.add('INBOX');
      later();

      final sent = await engine.sendWaitingChanges();

      expect((sent.sent, sent.waiting, sent.failed), (0, 0, 1));
      expect(await shown(), contains('Lunch'));
      final failed = await engine.takeFailedChanges();
      expect(failed.single.kind, PendingKind.move);
      expect(failed.single.subject, 'Lunch');
      expect(failed.single.fromFolderId, inbox);
      expect(failed.single.toFolderId, '$accountId:Work');
      expect(failed.single.reason, contains('would not move'));
      expect(await engine.takeFailedChanges(), isEmpty, reason: 'said once');
    });

    test('kept three days with no answer, is given up on', () async {
      server.offline = true;
      await engine.deleteMessages([(await row('Lunch')).id]);
      later(CachedImapEngine.waitAtMost + const Duration(minutes: 1));

      final sent = await engine.sendWaitingChanges();

      expect(sent.failed, 1);
      expect(await shown(), contains('Lunch'));
      expect((await engine.takeFailedChanges()).single.reason,
          contains('3 days'));
    });
  });

  test('a folder renumbered before a sync has seen it: the server is asked, '
      'and the right message goes', () async {
    // Sent first thing on reconnecting, before any sync: the cache still
    // has the old numbers, and Invoice's is Drawings' now.
    server.offline = true;
    await engine.deleteMessages([(await row('Invoice')).id]);
    server.offline = false;
    server.folder('INBOX')
      ..delete(1)
      ..rebuild();
    later();

    await engine.sendWaitingChanges();

    expect(onServer('[Gmail]/Trash'), ['Invoice']);
    expect(onServer('INBOX'), ['Drawings']);
  });

  test('a renumbered folder does not hide the message that took the number',
      () async {
    server.offline = true;
    await engine.deleteMessages([(await row('Invoice')).id]);
    server.offline = false;
    server.folder('INBOX')
      ..delete(1)
      ..rebuild();

    // The Inbox synced, and numbered afresh: Drawings has Invoice's number.
    await engine.loadMessages(inbox);

    expect(await shown(), contains('Drawings'));
  });

  test('a folder whose numbers were dealt out afresh is found again by '
      'Message-ID, and the right message goes', () async {
    server.offline = true;
    await engine.deleteMessages([(await row('Lunch')).id]);
    server.offline = false;
    // The server rebuilds the Inbox: new UIDVALIDITY, every message given
    // a new number, Lunch's old one now another message's.
    server.folder('INBOX').rebuild();
    await engine.loadMessages(inbox);
    later();

    await engine.sendWaitingChanges();

    expect(onServer('[Gmail]/Trash'), ['Lunch']);
    expect(onServer('INBOX'), ['Invoice', 'Drawings']);
  });

  group('snoozed with the server out of reach', () {
    test('is not let go while its move waits, and comes back after it went',
        () async {
      server.offline = true;
      final moves = await engine.snooze(
        [(await row('Lunch')).id],
        now.add(const Duration(hours: 1)),
      );
      expect(moves.single.isWaiting, isTrue);
      final due = now.add(const Duration(hours: 2));

      expect(await engine.wakeSnoozed(now: due), 0);
      expect(await cache.readSnoozed(), hasLength(1),
          reason: 'not taken for one moved out of Snoozed by hand');

      server.offline = false;
      later();
      await engine.sendWaitingChanges();
      expect(onServer(CachedImapEngine.snoozedFolderName), ['Lunch']);
      expect(await engine.wakeSnoozed(now: due), 1);
      expect(onServer('INBOX'), contains('Lunch'));
    });
  });

  test('kept for later, a delete or a read takes the message\'s '
      'notification down', () async {
    // A Delete pressed in the shade with no signal is done, as far as the
    // shade is concerned: its notification goes, as it does online.
    final handled = <bool Function(String)>[];
    final withNotifications = CachedImapEngine(
      accountStore: accounts,
      credentialStore: secrets,
      cache: cache,
      // The folders as last listed, which the app keeps on the phone.
      folderLists: engine.folderLists,
      transportFactory: (_, _) => server,
      onMessagesHandled: handled.add,
      clock: () => now,
    );
    final lunch = await row('Lunch');
    final invoice = await row('Invoice');
    server.offline = true;

    await withNotifications.deleteMessages([lunch.id]);
    await withNotifications.setRead(invoice.id, true);

    expect(handled, hasLength(2));
    expect(handled[0](lunch.id), isTrue);
    expect(handled[1](invoice.id), isTrue);
  });
}
