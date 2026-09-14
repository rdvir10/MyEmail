import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/data/mail_engine.dart';
import 'package:mailtree/data/sample/sample_mail_engine.dart';
import 'package:mailtree/domain/account.dart';
import 'package:mailtree/domain/mail_folder.dart';
import 'package:mailtree/domain/mail_message.dart';
import 'package:mailtree/state/folder_tree.dart';
import 'package:mailtree/state/providers.dart';

ProviderContainer _container({MailEngine? engine}) {
  final container = ProviderContainer(
    overrides: [
      if (engine != null) mailEngineProvider.overrideWithValue(engine),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// One account, with its folder list reversed so INBOX is *last*. Anything
/// that picks a default by list position instead of by role fails on this.
class _SingleAccountReversedEngine implements MailEngine {
  final _inner = SampleMailEngine();

  @override
  Future<List<Account>> loadAccounts() async =>
      (await _inner.loadAccounts()).take(1).toList();

  @override
  Future<Account> addAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required String secret,
  }) =>
      _inner.addAccount(
        displayName: displayName,
        emailAddress: emailAddress,
        provider: provider,
        secret: secret,
      );

  @override
  Future<void> removeAccount(String accountId) =>
      _inner.removeAccount(accountId);

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async =>
      (await _inner.loadFolders(accountId)).reversed.toList();

  @override
  Future<FolderRename> renameFolder(String folderId, String newName) =>
      _inner.renameFolder(folderId, newName);

  @override
  Future<FolderRename> moveFolder(String folderId, String? newParentId) =>
      _inner.moveFolder(folderId, newParentId);

  @override
  Future<void> deleteFolder(String folderId) => _inner.deleteFolder(folderId);

  @override
  Future<MailFolder> createFolder({
    required String accountId,
    required String name,
    String? parentId,
  }) =>
      _inner.createFolder(accountId: accountId, name: name, parentId: parentId);

  @override
  Future<void> markAllRead(String folderId) => _inner.markAllRead(folderId);

  @override
  Future<void> emptyFolder(String folderId) => _inner.emptyFolder(folderId);

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) =>
      _inner.loadMessages(folderId, offset: offset, limit: limit);

  @override
  Future<MailBody> loadMessageBody(String messageId) =>
      _inner.loadMessageBody(messageId);
}

void main() {
  group('default selection', () {
    test('several accounts default to the unified inbox', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      expect(c.read(effectiveSelectedFolderIdProvider), kUnifiedInboxId);
    });

    test('a single account defaults to its Inbox by role, not position',
        () async {
      final c = _container(engine: _SingleAccountReversedEngine());
      await c.read(foldersProvider.future);
      expect(c.read(effectiveSelectedFolderIdProvider), 'acct-personal:INBOX');
      expect(c.read(folderIndexProvider).containsKey(kUnifiedInboxId), isFalse,
          reason: 'no unified inbox for one account');
    });

    test('an explicit choice wins over the default', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      c.read(selectedFolderIdProvider.notifier).select('acct-personal:Travel');
      expect(c.read(effectiveSelectedFolderIdProvider), 'acct-personal:Travel');
    });
  });

  group('mutations reach the tree', () {
    test('rename shows up in the rows', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      await c.read(foldersProvider.notifier).rename(
            'acct-personal:Travel',
            'Trips',
          );
      final names = c
          .read(treeRowsProvider)
          .whereType<FolderRow>()
          .map((r) => r.folder.name);
      expect(names, contains('Trips'));
      expect(names, isNot(contains('Travel')));
    });

    test('create appears under an auto-expanded parent', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      await c.read(foldersProvider.notifier).create(
            accountId: 'acct-personal',
            name: 'Insurance',
            parentId: 'acct-personal:Finance',
          );
      expect(c.read(expandedFoldersProvider), contains('acct-personal:Finance'));
      final names = c
          .read(treeRowsProvider)
          .whereType<FolderRow>()
          .map((r) => r.folder.name);
      expect(names, contains('Insurance'));
    });

    test('a name conflict surfaces as FolderNameConflict', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      expect(
        () => c.read(foldersProvider.notifier).create(
              accountId: 'acct-personal',
              name: 'Travel',
            ),
        throwsA(isA<FolderNameConflict>()),
      );
    });
  });

  group('id remapping across rename and delete', () {
    test('expand, favourite and selection follow a renamed subtree', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      c.read(expandedFoldersProvider.notifier).expand('acct-personal:Finance');
      c
          .read(favoriteFoldersProvider.notifier)
          .toggle('acct-personal:Finance/Receipts/2026');
      c
          .read(selectedFolderIdProvider.notifier)
          .select('acct-personal:Finance/Receipts');

      await c.read(foldersProvider.notifier).rename(
            'acct-personal:Finance',
            'Money',
          );

      expect(c.read(expandedFoldersProvider), contains('acct-personal:Money'));
      expect(
        c.read(favoriteFoldersProvider),
        contains('acct-personal:Money/Receipts/2026'),
      );
      expect(
        c.read(effectiveSelectedFolderIdProvider),
        'acct-personal:Money/Receipts',
      );
      // And the tree still shows Receipts under the expanded, renamed parent.
      final names = c
          .read(treeRowsProvider)
          .whereType<FolderRow>()
          .map((r) => r.folder.name);
      expect(names, contains('Receipts'));
    });

    test('deleting the selected subtree falls back to the default', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      c
          .read(selectedFolderIdProvider.notifier)
          .select('acct-personal:Finance/Receipts');
      c
          .read(favoriteFoldersProvider.notifier)
          .toggle('acct-personal:Finance/Receipts/2026');

      await c.read(foldersProvider.notifier).delete('acct-personal:Finance');

      expect(c.read(effectiveSelectedFolderIdProvider), kUnifiedInboxId);
      expect(c.read(favoriteFoldersProvider), isEmpty,
          reason: 'a favourite inside the deleted subtree is dropped');
      expect(
        c.read(folderIndexProvider).containsKey('acct-personal:Finance'),
        isFalse,
      );
    });
  });
}
