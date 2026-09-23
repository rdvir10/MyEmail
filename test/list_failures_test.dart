import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_capabilities.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';

import 'fakes/fake_imap_transport.dart';

/// What the lists do when the server says no, or says it late.
void main() {
  late _Gated engine;
  late ProviderContainer c;

  setUp(() {
    engine = _Gated();
    c = ProviderContainer(overrides: [
      mailEngineProvider.overrideWithValue(engine),
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
    ]);
    addTearDown(c.dispose);
  });

  Future<(String, List<String>)> anInbox() async {
    final account = (await engine.loadAccounts()).first;
    final inbox = (await engine.loadFolders(account.id))
        .firstWhere((f) => f.role == FolderRole.inbox);
    final list = await c.read(messagesProvider(inbox.id).future);
    return (inbox.id, [for (final m in list) m.id]);
  }

  List<String> shown(String folderId) =>
      [for (final m in c.read(messagesProvider(folderId)).value!) m.id];

  group('a delete that fails', () {
    test('brings back its own rows, not one another delete took', () async {
      // Two swipes on a bad connection. Restoring the list as it was before
      // the first brought the second's row back, already in Trash.
      final (folder, ids) = await anInbox();
      final a = ids[0];
      final b = ids[1];
      engine.held = a;

      final first = c.read(messagesProvider(folder).notifier).delete([a]);
      await c.read(messagesProvider(folder).notifier).delete([b]);
      engine.gate.complete();

      await expectLater(first, throwsA(isA<ConnectionFailed>()));
      expect(shown(folder), contains(a));
      expect(shown(folder), isNot(contains(b)));
    });

    test('and a flag that fails puts back only its own flag', () async {
      final (folder, ids) = await anInbox();
      final a = ids[0];
      final b = ids[1];
      engine.held = a;

      final flag =
          c.read(messagesProvider(folder).notifier).setFlagged(a, true);
      await c.read(messagesProvider(folder).notifier).delete([b]);
      engine.gate.complete();

      await expectLater(flag, throwsA(isA<ConnectionFailed>()));
      expect(shown(folder), isNot(contains(b)));
      expect(
        c.read(messagesProvider(folder)).value!.firstWhere((m) => m.id == a)
            .isFlagged,
        isFalse,
      );
    });

    test('part way keeps gone what went, and brings back the rest', () async {
      final (folder, ids) = await anInbox();
      engine.partly = ids[0];

      await expectLater(
        c.read(messagesProvider(folder).notifier).delete([ids[0], ids[1]]),
        throwsA(isA<PartialMove>()),
      );

      expect(shown(folder), isNot(contains(ids[0])));
      expect(shown(folder), contains(ids[1]));
    });
  });

  group('the folder tree', () {
    test('two accounts refreshing at once both keep their new counts',
        () async {
      // Each wrote back the tree as it was before its own wait, with the
      // other account's old counts in it.
      final accounts = await engine.loadAccounts();
      final a = accounts[0].id;
      final b = accounts[1].id;
      await c.read(foldersProvider.future);
      engine
        ..fresh[a] = [_folder(a, 'A-fresh')]
        ..fresh[b] = [_folder(b, 'B-fresh')]
        ..folderGate[a] = Completer<void>();

      final slow = c.read(foldersProvider.notifier).refreshAccount(a);
      await c.read(foldersProvider.notifier).refreshAccount(b);
      engine.folderGate[a]!.complete();
      await slow;

      final tree = c.read(foldersProvider).value!;
      expect(tree[a]!.single.path, 'A-fresh');
      expect(tree[b]!.single.path, 'B-fresh');
    });
  });

  test('an account whose sign-in expired keeps its cached folders', () async {
    // It emptied a second after launch, with its mail gone from the
    // unified Inbox and the open folder with it.
    final server = FakeImapTransport()..folder('INBOX', role: FolderRole.inbox);
    final imap = CachedImapEngine(
      accountStore: MemoryAccountStore(),
      credentialStore: MemoryCredentialStore(),
      cache: MemoryCacheStore(),
      transportFactory: (_, _) => server,
    );
    final account = await imap.addAccount(
      displayName: 'P',
      emailAddress: 'p@example.com',
      provider: MailProvider.gmail,
      secret: 'abcdabcdabcdabcd',
    );
    server.failWith = const AuthenticationFailed('Sign in again.');
    final tree = ProviderContainer(overrides: [
      mailEngineProvider.overrideWithValue(imap),
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
    ]);
    addTearDown(tree.dispose);

    await tree.read(foldersProvider.future);
    await pumpEventQueue();

    expect(tree.read(foldersProvider).value![account.id], isNotEmpty);
    expect(tree.read(folderLoadErrorsProvider), contains(account.id));
  });
}

MailFolder _folder(String accountId, String path) => MailFolder.at(
      accountId: accountId,
      path: path,
      role: FolderRole.user,
      capabilities: FolderCapabilities.forGmail(FolderRole.user),
    );

/// The sample engine, with a message whose delete or flag waits and then
/// fails, a delete that goes only part way, and folder listings on hold.
class _Gated extends SampleMailEngine {
  String? held;
  final gate = Completer<void>();
  String? partly;
  final fresh = <String, List<MailFolder>>{};
  final folderGate = <String, Completer<void>>{};

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    if (messageIds.contains(held)) {
      await gate.future;
      throw const ConnectionFailed('offline');
    }
    if (partly != null && messageIds.contains(partly)) {
      final done = await super.deleteMessages([partly!]);
      throw PartialMove(done: done, moved: [partly!], cause: 'the rest failed');
    }
    return super.deleteMessages(messageIds);
  }

  @override
  Future<void> setFlagged(String messageId, bool isFlagged) async {
    if (messageId == held) {
      await gate.future;
      throw const ConnectionFailed('offline');
    }
    return super.setFlagged(messageId, isFlagged);
  }

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    await folderGate[accountId]?.future;
    return fresh[accountId] ?? super.loadFolders(accountId);
  }
}
