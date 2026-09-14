import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/data/mail_engine.dart';
import 'package:mailtree/data/sample/sample_mail_engine.dart';
import 'package:mailtree/domain/account.dart';
import 'package:mailtree/domain/folder_capabilities.dart';
import 'package:mailtree/domain/folder_role.dart';
import 'package:mailtree/domain/mail_folder.dart';
import 'package:mailtree/state/folder_tree.dart';

Future<FolderTreeInput> _input({
  Set<String> expanded = const {},
  Set<String> favorites = const {},
  String query = '',
}) async {
  final engine = SampleMailEngine();
  final accounts = await engine.loadAccounts();
  final folders = <String, List<MailFolder>>{};
  for (final a in accounts) {
    folders[a.id] = await engine.loadFolders(a.id);
  }
  return FolderTreeInput(
    accounts: accounts,
    foldersByAccount: folders,
    expandedIds: expanded,
    favoriteIds: favorites,
    searchQuery: query,
  );
}

List<FolderRow> _folderRows(List<TreeRow> rows) =>
    rows.whereType<FolderRow>().toList();

Future<SampleMailEngine> _engine() async {
  final engine = SampleMailEngine();
  await engine.loadAccounts();
  await engine.loadFolders('acct-personal');
  return engine;
}

void main() {
  group('tree structure', () {
    test('collapsed tree hides children', () async {
      final rows = buildTreeRows(await _input());
      final names = _folderRows(rows).map((r) => r.folder.name);
      expect(names, contains('Finance'));
      expect(names, isNot(contains('Receipts')),
          reason: 'children must stay hidden while the parent is collapsed');
    });

    test('expanding a parent reveals only its direct children', () async {
      final input = await _input(expanded: {'acct-personal:Finance'});
      final names = _folderRows(buildTreeRows(input)).map((r) => r.folder.name);
      expect(names, contains('Receipts'));
      expect(names, isNot(contains('2026')),
          reason: 'grandchildren need their own parent expanded too');
    });

    test('depth increases with nesting', () async {
      final input = await _input(
        expanded: {
          'acct-personal:Finance',
          'acct-personal:Finance/Receipts',
        },
      );
      final rows = _folderRows(buildTreeRows(input));
      ({int depth, bool hasChildren}) at(String name) {
        final row = rows.firstWhere((r) => r.folder.name == name);
        return (depth: row.depth, hasChildren: row.hasChildren);
      }

      expect(at('Finance').depth, 0);
      expect(at('Receipts').depth, 1);
      expect(at('2026').depth, 2);
      expect(at('2026').hasChildren, isFalse);
    });

    test('system folders sort before user folders in Outlook order', () async {
      final rows = _folderRows(buildTreeRows(await _input()));
      final personal = rows
          .where((r) => r.folder.accountId == 'acct-personal' && r.depth == 0)
          .map((r) => r.folder.role)
          .toList();
      final firstUser = personal.indexOf(FolderRole.user);
      expect(personal.take(firstUser), everyElement(isNot(FolderRole.user)));
      expect(personal.first, FolderRole.inbox);
    });

    test('unified inbox row carries no account accent', () async {
      final rows = _folderRows(buildTreeRows(await _input()));
      expect(rows.first.folder.id, kUnifiedInboxId);
      expect(rows.first.accentColor, isNull,
          reason: 'theme colour is the UI layer\'s decision');
    });
  });

  group('unified inbox', () {
    test('sums every account inbox', () async {
      final input = await _input();
      final unified = buildUnifiedInbox(input.foldersByAccount);
      // 14 personal + 3 projects
      expect(unified.unreadCount, 17);
      expect(unified.totalCount, 2310 + 412);
    });

    test('appears only with more than one account', () async {
      final input = await _input();
      final single = FolderTreeInput(
        accounts: [input.accounts.first],
        foldersByAccount: {
          input.accounts.first.id:
              input.foldersByAccount[input.accounts.first.id]!,
        },
        expandedIds: const {},
        favoriteIds: const {},
      );
      final rows = _folderRows(buildTreeRows(single));
      expect(rows.any((r) => r.folder.id == kUnifiedInboxId), isFalse);

      final multi = _folderRows(buildTreeRows(input));
      expect(multi.first.folder.id, kUnifiedInboxId);
    });

    test('is synthetic and rejects dropped messages', () async {
      final unified = buildUnifiedInbox((await _input()).foldersByAccount);
      expect(unified.isSynthetic, isTrue);
      expect(unified.capabilities.canAcceptMessages, isFalse);
      expect(unified.capabilities.canRename, isFalse);
    });
  });

  group('search', () {
    test('matches regardless of collapsed parents', () async {
      final rows = _folderRows(buildTreeRows(await _input(query: 'receipts')));
      expect(rows, isNotEmpty);
      expect(rows.first.folder.name, 'Receipts');
      expect(rows.first.depth, 0, reason: 'search results render flat');
    });

    test('shows the full path so duplicates are distinguishable', () async {
      final rows = _folderRows(buildTreeRows(await _input(query: '2026')));
      expect(rows.single.subtitle, 'Finance › Receipts › 2026');
    });

    test('a root folder gets no redundant path subtitle', () async {
      final rows = _folderRows(buildTreeRows(await _input(query: 'travel')));
      expect(rows.single.folder.name, 'Travel');
      expect(rows.single.subtitle, isNull);
    });

    test('hides the Gmail namespace prefix', () async {
      final rows = _folderRows(buildTreeRows(await _input(query: 'sent')));
      expect(rows.first.subtitle, isNot(contains('[Gmail]')));
    });

    test('no matches yields no rows', () async {
      final rows = buildTreeRows(await _input(query: 'zzzz-nothing'));
      expect(rows, isEmpty);
    });
  });

  group('favourites', () {
    test('favourite folders appear flat in their own section', () async {
      final input = await _input(
        favorites: {'acct-personal:Finance/Receipts/2026'},
      );
      final rows = buildTreeRows(input);
      final header = rows.whereType<SectionHeaderRow>().first;
      expect(header.title, 'Favourites');

      final favRow = rows.whereType<FolderRow>().firstWhere(
            (r) => r.inFavorites,
          );
      expect(favRow.folder.name, '2026');
      expect(favRow.depth, 0,
          reason: 'a favourite is shown flat, not at its real depth');
      expect(favRow.subtitle, 'Personal',
          reason: 'with several accounts the owner is shown');
    });

    test('favourite and tree rows have distinct keys', () async {
      final input = await _input(
        favorites: {'acct-personal:Travel'},
      );
      final rows = buildTreeRows(input);
      final keys = rows.map((r) => r.key).toList();
      expect(keys.toSet().length, keys.length,
          reason: 'duplicate keys would break Flutter list diffing');
    });
  });

  group('capabilities', () {
    test('Gmail system folders refuse structural edits', () async {
      final input = await _input();
      final folders = input.foldersByAccount['acct-personal']!;
      final sent = folders.firstWhere((f) => f.role == FolderRole.sent);
      expect(sent.capabilities.canRename, isFalse);
      expect(sent.capabilities.canDelete, isFalse);
      expect(sent.capabilities.canMove, isFalse);
      expect(sent.capabilities.canAcceptMessages, isFalse);
    });

    test('Gmail All Mail is browsable but not a drop target', () async {
      final folders = (await _input()).foldersByAccount['acct-personal']!;
      final allMail = folders.firstWhere((f) => f.role == FolderRole.archive);
      expect(allMail.capabilities.canAcceptMessages, isFalse,
          reason: 'archiving in Gmail is an action, not a move');
      expect(allMail.capabilities.canMarkAllRead, isTrue);
    });

    test('trash and junk can be emptied, inbox cannot', () async {
      final folders = (await _input()).foldersByAccount['acct-personal']!;
      expect(
        folders.firstWhere((f) => f.role == FolderRole.deleted)
            .capabilities.canEmpty,
        isTrue,
      );
      expect(
        folders.firstWhere((f) => f.role == FolderRole.inbox)
            .capabilities.canEmpty,
        isFalse,
      );
    });

    test('user folders allow everything', () async {
      final folders = (await _input()).foldersByAccount['acct-personal']!;
      final travel = folders.firstWhere((f) => f.name == 'Travel');
      expect(travel.capabilities.canRename, isTrue);
      expect(travel.capabilities.canDelete, isTrue);
      expect(travel.capabilities.canCreateChild, isTrue);
    });

    test('trash and junk badge on total, not unread', () async {
      final folders = (await _input()).foldersByAccount['acct-personal']!;
      final trash = folders.firstWhere((f) => f.role == FolderRole.deleted);
      expect(trash.showsTotalInsteadOfUnread, isTrue);
      expect(trash.badgeCount, trash.totalCount);

      final inbox = folders.firstWhere((f) => f.role == FolderRole.inbox);
      expect(inbox.badgeCount, inbox.unreadCount);
    });
  });

  group('engine: rename and move cascade like IMAP RENAME', () {
    test('renaming rewrites the subtree paths, ids and parent links', () async {
      final engine = await _engine();
      final result = await engine.renameFolder('acct-personal:Finance', 'Money');

      expect(result.oldId, 'acct-personal:Finance');
      expect(result.newId, 'acct-personal:Money');
      expect(result.folder.path, 'Money');
      expect(result.folder.name, 'Money');

      final after = await engine.loadFolders('acct-personal');
      expect(after.any((f) => f.path.startsWith('Finance')), isFalse,
          reason: 'nothing may keep the old prefix');

      final receipts = after.firstWhere((f) => f.path == 'Money/Receipts');
      expect(receipts.id, 'acct-personal:Money/Receipts');
      expect(receipts.parentId, 'acct-personal:Money');

      final y2026 = after.firstWhere((f) => f.path == 'Money/Receipts/2026');
      expect(y2026.parentId, 'acct-personal:Money/Receipts');
      expect(y2026.unreadCount, 5, reason: 'counts survive the rename');
    });

    test('moving nests the subtree under the new parent', () async {
      final engine = await _engine();
      final result = await engine.moveFolder(
        'acct-personal:Finance/Receipts',
        'acct-personal:Travel',
      );
      expect(result.folder.path, 'Travel/Receipts');
      expect(result.folder.parentId, 'acct-personal:Travel');

      final after = await engine.loadFolders('acct-personal');
      final y2026 = after.firstWhere((f) => f.name == '2026');
      expect(y2026.path, 'Travel/Receipts/2026');
      expect(y2026.parentId, 'acct-personal:Travel/Receipts');
    });

    test('moving to the root drops the parent', () async {
      final engine = await _engine();
      final result =
          await engine.moveFolder('acct-personal:Finance/Receipts', null);
      expect(result.folder.path, 'Receipts');
      expect(result.folder.parentId, isNull);
    });

    test('FolderRename.remap translates ids inside the subtree only', () {
      const r = FolderRename(
        folder: MailFolder(
          id: 'a:Money',
          accountId: 'a',
          name: 'Money',
          path: 'Money',
          role: FolderRole.user,
          capabilities: _any,
        ),
        oldId: 'a:Finance',
        newId: 'a:Money',
      );
      expect(r.remap('a:Finance'), 'a:Money');
      expect(r.remap('a:Finance/Receipts/2026'), 'a:Money/Receipts/2026');
      expect(r.remap('a:Financelike'), 'a:Financelike',
          reason: 'prefix match must respect the path separator');
      expect(r.remap('a:Travel'), 'a:Travel');
    });
  });

  group('engine: refusals', () {
    test('renaming a system folder is refused', () async {
      final engine = await _engine();
      expect(
        () => engine.renameFolder('acct-personal:[Gmail]/Sent Mail', 'Nope'),
        throwsA(isA<FolderOperationNotSupported>()),
      );
    });

    test('a folder cannot be moved into its own descendant', () async {
      final engine = await _engine();
      expect(
        () => engine.moveFolder(
          'acct-personal:Finance',
          'acct-personal:Finance/Receipts',
        ),
        throwsA(isA<FolderOperationNotSupported>()),
      );
    });

    test('a folder cannot be nested under a system folder', () async {
      final engine = await _engine();
      expect(
        () => engine.moveFolder(
          'acct-personal:Travel',
          'acct-personal:[Gmail]/Sent Mail',
        ),
        throwsA(isA<FolderOperationNotSupported>()),
      );
    });

    test('creating a duplicate name is a conflict, case-insensitively',
        () async {
      final engine = await _engine();
      expect(
        () => engine.createFolder(accountId: 'acct-personal', name: 'travel'),
        throwsA(isA<FolderNameConflict>()),
      );
      expect(
        () => engine.createFolder(
          accountId: 'acct-personal',
          name: 'Receipts',
          parentId: 'acct-personal:Finance',
        ),
        throwsA(isA<FolderNameConflict>()),
      );
    });

    test('renaming onto an existing sibling is a conflict', () async {
      final engine = await _engine();
      expect(
        () => engine.renameFolder('acct-personal:Travel', 'Newsletters'),
        throwsA(isA<FolderNameConflict>()),
      );
    });

    test('a different parent allows the same name', () async {
      final engine = await _engine();
      final created = await engine.createFolder(
        accountId: 'acct-personal',
        name: 'Receipts',
        parentId: 'acct-personal:Travel',
      );
      expect(created.id, 'acct-personal:Travel/Receipts');
    });

    test('deleting a folder removes its whole subtree', () async {
      final engine = await _engine();
      await engine.deleteFolder('acct-personal:Finance');
      final left = await engine.loadFolders('acct-personal');
      expect(left.any((f) => f.path.startsWith('Finance')), isFalse);
    });
  });

  group('sample data', () {
    test('accounts use app passwords and placeholder addresses', () async {
      final accounts = await SampleMailEngine().loadAccounts();
      expect(accounts, hasLength(2));
      expect(
        accounts.every((a) => a.authMethod == AuthMethod.appPassword),
        isTrue,
      );
      expect(
        accounts.every((a) => a.provider == MailProvider.gmail),
        isTrue,
      );
      expect(
        accounts.every((a) => a.emailAddress.endsWith('@example.com')),
        isTrue,
        reason: 'committed sample data must not carry a real address',
      );
    });
  });
}

const _any = FolderCapabilities.userFolder();
