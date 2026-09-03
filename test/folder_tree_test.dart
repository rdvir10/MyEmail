import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/data/mail_engine.dart';
import 'package:mailtree/data/sample/sample_mail_engine.dart';
import 'package:mailtree/domain/account.dart';
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
      MailFolderDepth depthOf(String name) {
        final row = rows.firstWhere((r) => r.folder.name == name);
        return MailFolderDepth(row.depth, row.hasChildren);
      }

      expect(depthOf('Finance').depth, 0);
      expect(depthOf('Receipts').depth, 1);
      expect(depthOf('2026').depth, 2);
      expect(depthOf('2026').hasChildren, isFalse);
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
      expect(rows.single.searchSubtitle, 'Finance › Receipts › 2026');
    });

    test('hides the Gmail namespace prefix', () async {
      final rows = _folderRows(buildTreeRows(await _input(query: 'sent')));
      expect(rows.first.searchSubtitle, isNot(contains('[Gmail]')));
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

  group('engine operations respect capabilities', () {
    test('renaming a system folder is refused', () async {
      final engine = SampleMailEngine();
      await engine.loadAccounts();
      await engine.loadFolders('acct-personal');
      expect(
        () => engine.renameFolder('acct-personal:[Gmail]/Sent Mail', 'Nope'),
        throwsA(isA<FolderOperationNotSupported>()),
      );
    });

    test('renaming a user folder rewrites its path', () async {
      final engine = SampleMailEngine();
      await engine.loadAccounts();
      await engine.loadFolders('acct-personal');
      final renamed = await engine.renameFolder(
        'acct-personal:Finance/Receipts',
        'Invoices',
      );
      expect(renamed.name, 'Invoices');
      expect(renamed.path, 'Finance/Invoices');
    });

    test('a folder cannot be moved into its own descendant', () async {
      final engine = SampleMailEngine();
      await engine.loadAccounts();
      await engine.loadFolders('acct-personal');
      expect(
        () => engine.moveFolder(
          'acct-personal:Finance',
          'acct-personal:Finance/Receipts',
        ),
        throwsA(isA<FolderOperationNotSupported>()),
      );
    });

    test('deleting a folder removes its whole subtree', () async {
      final engine = SampleMailEngine();
      await engine.loadAccounts();
      await engine.loadFolders('acct-personal');
      await engine.deleteFolder('acct-personal:Finance');
      final left = await engine.loadFolders('acct-personal');
      expect(left.any((f) => f.path.startsWith('Finance')), isFalse);
    });

    test('accounts use app passwords in round one', () async {
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
    });
  });
}

class MailFolderDepth {
  MailFolderDepth(this.depth, this.hasChildren);
  final int depth;
  final bool hasChildren;
}
