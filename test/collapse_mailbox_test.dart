import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_capabilities.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/state/folder_tree.dart';

/// Folding a whole mailbox away in the tree.
///
/// The same gesture as collapsing a folder, one level up. Someone with three
/// accounts and a deep tree spends most of their time in one of them, and the
/// other two are two screens of scrolling in the way.
void main() {
  Account account(String id, String name) => Account(
        id: id,
        displayName: name,
        emailAddress: '$id@example.com',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.appPassword,
        colorValue: 0xFF0F6CBD,
      );

  MailFolder folder(String accountId, String name, FolderRole role) =>
      MailFolder.at(
        accountId: accountId,
        path: name,
        role: role,
        capabilities: const FolderCapabilities.systemFolder(),
      );

  FolderTreeInput input({Set<String> collapsed = const {}}) => FolderTreeInput(
        accounts: [account('a', 'Personal'), account('b', 'Work')],
        foldersByAccount: {
          'a': [
            folder('a', 'INBOX', FolderRole.inbox),
            folder('a', 'Sent', FolderRole.sent),
          ],
          'b': [
            folder('b', 'INBOX', FolderRole.inbox),
            folder('b', 'Sent', FolderRole.sent),
            folder('b', 'Archive', FolderRole.archive),
          ],
        },
        expandedIds: const {},
        favoriteIds: const {},
        collapsedAccountIds: collapsed,
      );

  List<FolderRow> foldersOf(List<TreeRow> rows, String accountId) => [
        for (final r in rows)
          if (r is FolderRow && r.folder.accountId == accountId) r,
      ];

  SectionHeaderRow headerFor(List<TreeRow> rows, String accountId) =>
      rows.whereType<SectionHeaderRow>().firstWhere(
            (h) => h.accountId == accountId,
          );

  test('nothing collapsed shows every folder', () {
    final rows = buildTreeRows(input());

    expect(foldersOf(rows, 'a'), hasLength(2));
    expect(foldersOf(rows, 'b'), hasLength(3));
  });

  test('a collapsed mailbox contributes no folder rows', () {
    final rows = buildTreeRows(input(collapsed: {'b'}));

    expect(foldersOf(rows, 'b'), isEmpty);
  });

  test('collapsing one mailbox leaves the others alone', () {
    // The obvious way to get this wrong is to skip the rest of the loop
    // rather than the rest of this account.
    final rows = buildTreeRows(input(collapsed: {'a'}));

    expect(foldersOf(rows, 'a'), isEmpty);
    expect(foldersOf(rows, 'b'), hasLength(3));
  });

  test('the heading stays, so there is a way back', () {
    // Dropping the heading too would leave the mailbox with nothing on screen
    // to tap, and the only route back would be through Settings.
    final rows = buildTreeRows(input(collapsed: {'b'}));

    final header = headerFor(rows, 'b');
    expect(header.title, 'Work');
    expect(header.isCollapsed, isTrue);
  });

  test('a collapsed heading says how many folders are folded away', () {
    // Otherwise it looks exactly like an account whose folders failed to
    // load, which is a real thing that happens when a sync fails.
    final rows = buildTreeRows(input(collapsed: {'b'}));

    expect(headerFor(rows, 'b').folderCount, 3);
  });

  test('an expanded account reports itself as not collapsed', () {
    final rows = buildTreeRows(input());

    expect(headerFor(rows, 'a').isCollapsed, isFalse);
    expect(headerFor(rows, 'a').canCollapse, isTrue);
  });

  test('Favourites cannot be collapsed', () {
    // Its rows are copies of folders that also appear under their account, so
    // folding it away hides nothing and the chevron would be a lie.
    final rows = buildTreeRows(
      FolderTreeInput(
        accounts: [account('a', 'Personal')],
        foldersByAccount: {
          'a': [folder('a', 'INBOX', FolderRole.inbox)],
        },
        expandedIds: const {},
        favoriteIds: {MailFolder.idFor('a', 'INBOX')},
      ),
    );

    final favourites = rows.whereType<SectionHeaderRow>().firstWhere(
          (h) => h.accountId == null,
        );
    expect(favourites.canCollapse, isFalse);
    expect(favourites.isCollapsed, isNull);
  });

  test('collapsing does not change what the unified Inbox counts', () {
    // Collapsing is about screen space. Quietly dropping an account out of
    // the unified Inbox would make it a filter instead.
    final open = buildTreeRows(input());
    final shut = buildTreeRows(input(collapsed: {'a', 'b'}));

    MailFolder unified(List<TreeRow> rows) => rows
        .whereType<FolderRow>()
        .firstWhere((r) => r.folder.role == FolderRole.unifiedInbox)
        .folder;

    expect(unified(shut).totalCount, unified(open).totalCount);
  });
}
