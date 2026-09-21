import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
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

  group('deleting a message', () {
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
  Future<void> deleteMessages(List<String> messageIds) async {
    for (final list in stored.values) {
      list.removeWhere((m) => messageIds.contains(m.id));
    }
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
    return fromServer[folderId] ?? stored[folderId] ?? const [];
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
