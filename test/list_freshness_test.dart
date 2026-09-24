import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';

/// Mail that is already on the device is shown before the server is asked.
///
/// Opening a folder used to wait on a full sync: new mail, every flag, every
/// deletion. On a Microsoft account that is a dozen separate requests, and
/// until the last of them came back the screen held a spinner over messages
/// the app already had. The same wait happened after every delete and on
/// every return to the app.
void main() {
  const folder = 'acct-1:INBOX';

  MailMessage message(String id) => MailMessage(
        id: '$folder#$id',
        accountId: 'acct-1',
        folderId: folder,
        uid: id.codeUnitAt(0),
        subject: 'Message $id',
        preview: '',
        from: const MailAddress(email: 'dana@example.com', name: 'Dana'),
        to: const [],
        date: DateTime(2026, 9, 21, 9),
        isRead: true,
      );

  ProviderContainer containerFor(MailEngine engine) {
    final c = ProviderContainer(overrides: [
      mailEngineProvider.overrideWithValue(engine),
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  group('opening a folder', () {
    test('shows what is stored without waiting for the server', () async {
      final engine = _GatedEngine()
        ..stored[folder] = [message('a'), message('b')]
        ..fromServer[folder] = [message('a'), message('b'), message('c')]
        ..hold(folder);

      final c = containerFor(engine);
      final shown = await c
          .read(messagesProvider(folder).future)
          .timeout(const Duration(seconds: 5));

      expect(shown.map((m) => m.subject), ['Message a', 'Message b']);
      expect(engine.waiting(folder), isTrue,
          reason: 'the sync is still running behind the list');
    });

    test('corrects the list when the server has more to say', () async {
      final engine = _GatedEngine()
        ..stored[folder] = [message('a'), message('b')]
        ..fromServer[folder] = [message('a'), message('b'), message('c')]
        ..hold(folder);

      final c = containerFor(engine);
      await c.read(messagesProvider(folder).future);

      final corrected = Completer<List<MailMessage>>();
      c.listen<AsyncValue<List<MailMessage>>>(messagesProvider(folder), (_, n) {
        final value = n.value;
        if (value != null && value.length == 3 && !corrected.isCompleted) {
          corrected.complete(value);
        }
      });
      engine.release(folder);

      final after = await corrected.future.timeout(const Duration(seconds: 5));
      expect(after.map((m) => m.subject).last, 'Message c');
    });

    test('corrects a subject changed elsewhere', () async {
      // Same ids, same flags, new subject and preview: a draft edited in
      // Outlook on another device. The refresh took that for "no change".
      MailMessage edited(String id) => MailMessage(
            id: '$folder#$id',
            accountId: 'acct-1',
            folderId: folder,
            uid: id.codeUnitAt(0),
            subject: 'Revised $id',
            preview: 'New first line',
            from: const MailAddress(email: 'dana@example.com', name: 'Dana'),
            to: const [],
            date: DateTime(2026, 9, 21, 9),
            isRead: true,
          );
      final engine = _GatedEngine()
        ..stored[folder] = [message('a'), message('b')]
        ..fromServer[folder] = [edited('a'), message('b')]
        ..hold(folder);

      final c = containerFor(engine);
      await c.read(messagesProvider(folder).future);
      engine.release(folder);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final shown = c.read(messagesProvider(folder)).value!;
      expect(shown.map((m) => m.subject), ['Revised a', 'Message b']);
      expect(shown.first.preview, 'New first line');
    });

    test('a folder with nothing stored waits rather than showing empty',
        () async {
      // The first visit to a folder has nothing to show early, so there is
      // nothing to be gained by drawing an empty list and filling it in.
      final engine = _GatedEngine()
        ..fromServer[folder] = [message('a')]
        ..hold(folder);

      final c = containerFor(engine);
      var settled = false;
      unawaited(c.read(messagesProvider(folder).future).then((_) {
        settled = true;
      }));
      await Future<void>.delayed(Duration.zero);

      expect(settled, isFalse);

      engine.release(folder);
      final shown = await c
          .read(messagesProvider(folder).future)
          .timeout(const Duration(seconds: 5));
      expect(shown, hasLength(1));
    });

    test('a message deleted while the sync runs does not come back',
        () async {
      // The sync read the folder before the delete reached it, so its answer
      // still has the message in it. Writing that over the top would put a
      // deleted row back on screen a second after it went.
      final engine = _GatedEngine()
        ..stored[folder] = [message('a'), message('b')]
        ..fromServer[folder] = [message('a'), message('b')]
        ..hold(folder);

      final c = containerFor(engine);
      final gone = (await c.read(messagesProvider(folder).future)).first.id;
      await c.read(messagesProvider(folder).notifier).delete([gone]);
      engine.release(folder);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        c.read(messagesProvider(folder)).value!.map((m) => m.id),
        isNot(contains(gone)),
      );
    });

    test('a sync that fails leaves the stored list alone', () async {
      final engine = _GatedEngine()
        ..stored[folder] = [message('a'), message('b')]
        ..refuse.add(folder);

      final c = containerFor(engine);
      final shown = await c.read(messagesProvider(folder).future);
      await Future<void>.delayed(Duration.zero);

      expect(shown, hasLength(2));
      expect(c.read(messagesProvider(folder)).value, hasLength(2),
          reason: 'offline is not a reason to empty the screen');
    });
  });

  group('the unified Inbox with one account failing', () {
    // Every account's Inbox was loaded with one Future.wait, so one account
    // whose sign-in had expired took the others down with it.
    const good = 'acct-personal:INBOX';
    const bad = 'acct-side:INBOX';

    MailMessage inboxMessage(String folderId, int uid) => MailMessage(
          id: MailMessage.idFor(folderId, uid),
          accountId: folderId.split(':').first,
          folderId: folderId,
          uid: uid,
          subject: 'Message $uid',
          preview: '',
          from: const MailAddress(email: 'dana@example.com'),
          to: const [],
          date: DateTime(2026, 9, 21, uid),
        );

    Future<ProviderContainer> unified(_GatedEngine engine) async {
      final c = containerFor(engine);
      await c.read(foldersProvider.future);
      c.listen(messagesProvider(kUnifiedInboxId), (_, _) {});
      return c;
    }

    test('a refresh still brings the others their new mail', () async {
      final engine = _GatedEngine()
        ..stored[good] = [inboxMessage(good, 1)]
        ..stored[bad] = [inboxMessage(bad, 2)]
        ..fromServer[good] = [inboxMessage(good, 3), inboxMessage(good, 1)]
        ..broken.add(bad);
      final c = await unified(engine);

      await c.read(messagesProvider(kUnifiedInboxId).future);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final shown = c.read(messagesProvider(kUnifiedInboxId)).value!;
      expect(shown.map((m) => m.id), [
        MailMessage.idFor(good, 3),
        MailMessage.idFor(bad, 2),
        MailMessage.idFor(good, 1),
      ], reason: 'the failing account keeps what it had stored');
    });

    test('a first open shows the accounts that answered', () async {
      final engine = _GatedEngine()
        ..fromServer[good] = [inboxMessage(good, 1)]
        ..broken.add(bad);
      final c = await unified(engine);

      final shown = await c.read(messagesProvider(kUnifiedInboxId).future);

      expect(shown.map((m) => m.id), [MailMessage.idFor(good, 1)]);
    });

    test('with every account failing, it is still an error', () async {
      final engine = _GatedEngine()..broken.addAll([good, bad]);
      final c = await unified(engine);

      await expectLater(
        c.read(messagesProvider(kUnifiedInboxId).future),
        throwsA(isA<StateError>()),
      );
    });

    test('paging goes on for the others and does not call it the end',
        () async {
      final engine = _GatedEngine()
        ..stored[good] = [inboxMessage(good, 1)]
        ..stored[bad] = [inboxMessage(bad, 2)];
      final c = await unified(engine);
      await c.read(messagesProvider(kUnifiedInboxId).future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      engine
        ..fromServer[good] = [inboxMessage(good, 1), inboxMessage(good, 0)]
        ..broken.add(bad);

      await c.read(messagesProvider(kUnifiedInboxId).notifier).loadMore();

      expect(
        c.read(messagesProvider(kUnifiedInboxId)).value!.map((m) => m.id),
        contains(MailMessage.idFor(good, 0)),
      );

      engine.fromServer[good] = [inboxMessage(good, 1), inboxMessage(good, 0)];
      await c.read(messagesProvider(kUnifiedInboxId).notifier).loadMore();
      expect(c.read(listDepthProvider(kUnifiedInboxId)).exhausted, isFalse,
          reason: 'the failing account may well have more');
    });
  });

  group('opening the app', () {
    test('the tree shows the folders it already knows', () async {
      // Nothing can be chosen until there are folders, and nothing is shown
      // until something is chosen: the phone sat on "Select a folder" for as
      // long as a work mailbox took to list itself.
      final engine = _StoredFoldersEngine()..gate = Completer<void>();
      final c = containerFor(engine);

      final folders = await c
          .read(foldersProvider.future)
          .timeout(const Duration(seconds: 5));

      expect(folders.values.expand((f) => f), isNotEmpty);
      expect(engine.gate!.isCompleted, isFalse,
          reason: 'the listing is still running behind the tree');
      engine.gate!.complete();
    });

    // The listing behind the tree started before the change and finishes
    // after it. Taken as the latest word, it put the old tree back: the
    // folder under its old name, or a deleted one back and failing.
    group('a listing already on its way cannot undo', () {
      Future<(ProviderContainer, _StoredFoldersEngine, Completer<void>)>
          launch() async {
        final engine = _StoredFoldersEngine()..gate = Completer<void>();
        final c = containerFor(engine);
        c.listen(foldersProvider, (_, _) {});
        await c.read(foldersProvider.future);
        final held = engine.gate!;
        engine.gate = null; // only the listing from the launch is held
        return (c, engine, held);
      }

      List<String> paths(ProviderContainer c) => [
            for (final list in c.read(foldersProvider).value!.values)
              for (final f in list) f.path,
          ];

      test('a rename', () async {
        final (c, _, held) = await launch();

        await c
            .read(foldersProvider.notifier)
            .rename('acct-personal:Finance', 'Money');
        held.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(paths(c), contains('Money'));
        expect(paths(c), isNot(contains('Finance')));
      });

      test('a delete', () async {
        final (c, _, held) = await launch();

        await c
            .read(foldersProvider.notifier)
            .delete('acct-personal:Finance/Banking');
        held.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(paths(c), isNot(contains('Finance/Banking')));
        expect(paths(c), contains('Finance'));
      });
    });

    test('with nothing stored it waits for the server', () async {
      final engine = _StoredFoldersEngine()
        ..gate = Completer<void>()
        ..hasStored = false;
      final c = containerFor(engine);
      var settled = false;
      unawaited(c.read(foldersProvider.future).then((_) => settled = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(settled, isFalse);

      engine.gate!.complete();
      final folders = await c
          .read(foldersProvider.future)
          .timeout(const Duration(seconds: 5));
      expect(folders.values.expand((f) => f), isNotEmpty);
    });
  });

  group('deleting a message', () {
    test('shows it in a Trash list opened earlier', () async {
      // Only the engine knows where a delete sends a message. The list of
      // Deleted Items opened before it lacked the message until pulled,
      // while the folder's count had already gone up.
      final c = containerFor(SampleMailEngine());
      final accounts = await c.read(accountsProvider.future);
      final folders = (await c.read(foldersProvider.future))[accounts.first.id]!;
      final inbox = folders.firstWhere((f) => f.role == FolderRole.inbox).id;
      final trash = folders.firstWhere((f) => f.role == FolderRole.deleted).id;
      c.listen(messagesProvider(trash), (_, _) {});
      await c.read(messagesProvider(trash).future);
      final shown = await c.read(messagesProvider(inbox).future);

      final moves = await c
          .read(messagesProvider(inbox).notifier)
          .delete([shown.first.id]);

      final landed = moves.single.movedIds.single;
      final inTrash = await c.read(messagesProvider(trash).future);
      expect(inTrash.map((m) => m.id), contains(landed));
    });

    test('does not wait on the folder counts', () async {
      // Refreshing an account is another folder listing over the network.
      // Awaiting it here is what made a delete take seconds to finish.
      final engine = _CountingEngine();
      final c = containerFor(engine);
      final accounts = await c.read(accountsProvider.future);
      final folders = await c.read(foldersProvider.future);
      final inbox = folders[accounts.first.id]!
          .firstWhere((f) => f.role == FolderRole.inbox)
          .id;
      final shown = await c.read(messagesProvider(inbox).future);

      engine.holdFolders();
      await c
          .read(messagesProvider(inbox).notifier)
          .delete([shown.first.id]).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the delete waited for the folder counts'),
      );

      expect(
        c.read(messagesProvider(inbox)).value!.map((m) => m.id),
        isNot(contains(shown.first.id)),
      );
      engine.releaseFolders();
    });
  });
}

/// A mail engine whose cache and whose server can be told apart, and whose
/// server can be made to answer when the test says so.
class _GatedEngine extends SampleMailEngine {
  final Map<String, List<MailMessage>> stored = {};
  final Map<String, List<MailMessage>> fromServer = {};
  final Map<String, Completer<void>> _gates = {};

  /// Folders whose sync fails, as it does with no network.
  final Set<String> refuse = {};

  /// Folders whose account fails outright, as one whose sign-in has
  /// expired does. The engine passes that on rather than falling back.
  final Set<String> broken = {};

  void hold(String folderId) => _gates[folderId] = Completer<void>();

  bool waiting(String folderId) => _gates[folderId]?.isCompleted == false;

  void release(String folderId) => _gates[folderId]?.complete();

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      // A copy: the list a test holds must not change under it when the
      // cache does.
      List.of(stored[folderId] ?? const []);

  /// Removed from the cache only. What the server would say is left as it
  /// was, which is the point: a sync already in flight read the folder
  /// before the delete reached it.
  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    for (final list in stored.values) {
      list.removeWhere((m) => messageIds.contains(m.id));
    }
    return const [];
  }

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    await _gates[folderId]?.future;
    if (refuse.contains(folderId)) {
      throw const ConnectionFailed('No network.');
    }
    if (broken.contains(folderId)) throw StateError('Sign in again.');
    return fromServer[folderId] ?? stored[folderId] ?? const [];
  }
}

/// An account whose folders were listed once before, so the tree has
/// something to show while the server is asked again.
class _StoredFoldersEngine extends SampleMailEngine {
  Completer<void>? gate;
  bool hasStored = true;

  @override
  Future<List<MailFolder>> cachedFolders(String accountId) async =>
      hasStored ? super.loadFolders(accountId) : const [];

  /// The tree as it stood when the listing was asked for, handed over when
  /// the gate opens: a slow server answers with what it saw back then.
  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    final held = gate;
    final seen = await super.loadFolders(accountId);
    await held?.future;
    return seen;
  }
}

/// The sample engine with its folder listing held open on request.
class _CountingEngine extends SampleMailEngine {
  Completer<void>? _gate;

  void holdFolders() => _gate = Completer<void>();

  void releaseFolders() {
    if (_gate?.isCompleted == false) _gate!.complete();
    _gate = null;
  }

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    await _gate?.future;
    return super.loadFolders(accountId);
  }
}
