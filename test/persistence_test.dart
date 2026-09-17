import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/providers.dart';

ProviderContainer _container(UiStateStore store) {
  final c = ProviderContainer(
    overrides: [uiStateStoreProvider.overrideWithValue(store)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('UI state is written through to the store', () {
    test('expanding a folder is persisted', () async {
      final store = MemoryUiStateStore();
      final c = _container(store);
      c.read(expandedFoldersProvider.notifier).expand('acct-personal:Finance');
      await Future<void>.delayed(Duration.zero);
      expect(store.readIds(UiStateKeys.expanded),
          contains('acct-personal:Finance'));
    });

    test('favourites and selection are persisted', () async {
      final store = MemoryUiStateStore();
      final c = _container(store);
      c.read(favoriteFoldersProvider.notifier).toggle('acct-personal:Travel');
      c.read(selectedFolderIdProvider.notifier).select('acct-personal:Travel');
      await Future<void>.delayed(Duration.zero);
      expect(store.readIds(UiStateKeys.favorites), {'acct-personal:Travel'});
      expect(store.readString(UiStateKeys.selected), 'acct-personal:Travel');
    });

    test('ordering is persisted as a map', () async {
      final store = MemoryUiStateStore();
      final c = _container(store);
      c.read(folderOrderProvider.notifier).setOrder(['b', 'a', 'c']);
      await Future<void>.delayed(Duration.zero);
      expect(store.readOrder(UiStateKeys.order), {'b': 0, 'a': 1, 'c': 2});
    });

    test('clearing the selection removes the key', () async {
      final store = MemoryUiStateStore();
      final c = _container(store);
      c.read(selectedFolderIdProvider.notifier).select('x');
      c.read(selectedFolderIdProvider.notifier).select(null);
      await Future<void>.delayed(Duration.zero);
      expect(store.readString(UiStateKeys.selected), isNull);
    });
  });

  group('UI state is restored from the store', () {
    test('a fresh container starts from what was saved', () async {
      final store = MemoryUiStateStore();
      await store.writeIds(UiStateKeys.expanded, {'acct-personal:Finance'});
      await store.writeIds(UiStateKeys.favorites, {'acct-personal:Travel'});
      await store.writeOrder(UiStateKeys.order, {'acct-personal:Travel': 0});
      await store.writeString(UiStateKeys.selected, 'acct-personal:Travel');

      final c = _container(store);
      expect(c.read(expandedFoldersProvider), {'acct-personal:Finance'});
      expect(c.read(favoriteFoldersProvider), {'acct-personal:Travel'});
      expect(c.read(folderOrderProvider), {'acct-personal:Travel': 0});
      expect(c.read(selectedFolderIdProvider), 'acct-personal:Travel');
    });

    test('the remembered selection is what the tree shows', () async {
      final store = MemoryUiStateStore();
      await store.writeString(UiStateKeys.selected, 'acct-personal:Travel');
      final c = _container(store);
      await c.read(foldersProvider.future);
      expect(c.read(effectiveSelectedFolderIdProvider), 'acct-personal:Travel');

      // The remembered expand state shapes the rows on first build.
      await store.writeIds(UiStateKeys.expanded, {'acct-personal:Finance'});
      final c2 = _container(store);
      await c2.read(foldersProvider.future);
      final names = c2
          .read(treeRowsProvider)
          .whereType<FolderRow>()
          .map((r) => r.folder.name);
      expect(names, contains('Receipts'));
    });

    test('a remembered selection that no longer exists falls back',
        () async {
      final store = MemoryUiStateStore();
      await store.writeString(UiStateKeys.selected, 'acct-personal:Gone');
      final c = _container(store);
      await c.read(foldersProvider.future);
      expect(c.read(effectiveSelectedFolderIdProvider), kUnifiedInboxId);
    });
  });

  group('renames keep the store in step', () {
    test('ids under a renamed folder are rewritten in the store', () async {
      final store = MemoryUiStateStore();
      final c = _container(store);
      await c.read(foldersProvider.future);
      c
          .read(favoriteFoldersProvider.notifier)
          .toggle('acct-personal:Finance/Receipts');
      c.read(expandedFoldersProvider.notifier).expand('acct-personal:Finance');

      await c
          .read(foldersProvider.notifier)
          .rename('acct-personal:Finance', 'Money');
      await Future<void>.delayed(Duration.zero);

      expect(store.readIds(UiStateKeys.favorites),
          {'acct-personal:Money/Receipts'});
      expect(store.readIds(UiStateKeys.expanded), {'acct-personal:Money'});
    });
  });
}
