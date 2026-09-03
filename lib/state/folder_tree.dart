import 'package:flutter/foundation.dart';

import '../domain/account.dart';
import '../domain/folder_capabilities.dart';
import '../domain/folder_role.dart';
import '../domain/mail_folder.dart';

/// One line in the rendered tree.
sealed class TreeRow {
  const TreeRow();

  String get key;
}

/// A non-selectable heading: "Favourites", or an account name.
class SectionHeaderRow extends TreeRow {
  const SectionHeaderRow({
    required this.title,
    required this.subtitle,
    this.accountId,
    this.accentColor,
  });

  final String title;
  final String? subtitle;
  final String? accountId;
  final int? accentColor;

  @override
  String get key => 'header:${accountId ?? title}';
}

/// A selectable folder.
class FolderRow extends TreeRow {
  const FolderRow({
    required this.folder,
    required this.depth,
    required this.hasChildren,
    required this.isExpanded,
    required this.accentColor,
    this.inFavorites = false,
    this.searchSubtitle,
  });

  final MailFolder folder;

  /// Indent level. Favourites and search results are always flat, so this is 0
  /// there regardless of where the folder really sits.
  final int depth;
  final bool hasChildren;
  final bool isExpanded;
  final int accentColor;
  final bool inFavorites;

  /// When searching, the folder's full path is shown beneath the name so that
  /// two folders called "2026" can be told apart.
  final String? searchSubtitle;

  @override
  String get key => inFavorites ? 'fav:${folder.id}' : 'folder:${folder.id}';
}

/// Everything the tree needs in order to render, gathered in one place so the
/// build is a pure function and can be unit tested without a widget.
@immutable
class FolderTreeInput {
  const FolderTreeInput({
    required this.accounts,
    required this.foldersByAccount,
    required this.expandedIds,
    required this.favoriteIds,
    this.searchQuery = '',
    this.showUnifiedInbox = true,
  });

  final List<Account> accounts;
  final Map<String, List<MailFolder>> foldersByAccount;
  final Set<String> expandedIds;
  final Set<String> favoriteIds;
  final String searchQuery;
  final bool showUnifiedInbox;
}

/// The synthetic unified Inbox, summing every account's Inbox.
MailFolder buildUnifiedInbox(Map<String, List<MailFolder>> foldersByAccount) {
  var unread = 0;
  var total = 0;
  for (final folders in foldersByAccount.values) {
    for (final f in folders) {
      if (f.role == FolderRole.inbox) {
        unread += f.unreadCount;
        total += f.totalCount;
      }
    }
  }
  return MailFolder(
    id: kUnifiedInboxId,
    accountId: '',
    name: 'All Inboxes',
    path: '',
    role: FolderRole.unifiedInbox,
    capabilities: const FolderCapabilities.synthetic(),
    unreadCount: unread,
    totalCount: total,
  );
}

const kUnifiedInboxId = 'unified:inbox';

/// Flatten accounts and folders into the rows to render.
///
/// Ordering within an account is Outlook's, not alphabetical: system folders
/// first in a fixed order, then user folders. Sorting user folders by
/// [MailFolder.sortIndex] keeps any manual arrangement, which is local-only
/// because IMAP has no concept of folder order.
List<TreeRow> buildTreeRows(FolderTreeInput input) {
  final query = input.searchQuery.trim().toLowerCase();
  if (query.isNotEmpty) return _buildSearchRows(input, query);

  final rows = <TreeRow>[];

  if (input.showUnifiedInbox && input.accounts.length > 1) {
    rows.add(
      FolderRow(
        folder: buildUnifiedInbox(input.foldersByAccount),
        depth: 0,
        hasChildren: false,
        isExpanded: false,
        accentColor: 0xFF0F6CBD,
      ),
    );
  }

  final favorites = _favoriteRows(input);
  if (favorites.isNotEmpty) {
    rows.add(
      const SectionHeaderRow(title: 'Favourites', subtitle: null),
    );
    rows.addAll(favorites);
  }

  for (final account in input.accounts) {
    final folders = input.foldersByAccount[account.id] ?? const <MailFolder>[];
    if (folders.isEmpty) continue;
    rows.add(
      SectionHeaderRow(
        title: account.displayName,
        subtitle: account.emailAddress,
        accountId: account.id,
        accentColor: account.colorValue,
      ),
    );
    _appendSubtree(
      rows: rows,
      folders: folders,
      parentId: null,
      depth: 0,
      input: input,
      accentColor: account.colorValue,
    );
  }

  return rows;
}

void _appendSubtree({
  required List<TreeRow> rows,
  required List<MailFolder> folders,
  required String? parentId,
  required int depth,
  required FolderTreeInput input,
  required int accentColor,
}) {
  final children = folders.where((f) => f.parentId == parentId).toList()
    ..sort(_compareFolders);

  for (final folder in children) {
    final hasChildren = folders.any((f) => f.parentId == folder.id);
    final isExpanded = input.expandedIds.contains(folder.id);
    rows.add(
      FolderRow(
        folder: folder,
        depth: depth,
        hasChildren: hasChildren,
        isExpanded: isExpanded,
        accentColor: accentColor,
      ),
    );
    if (hasChildren && isExpanded) {
      _appendSubtree(
        rows: rows,
        folders: folders,
        parentId: folder.id,
        depth: depth + 1,
        input: input,
        accentColor: accentColor,
      );
    }
  }
}

/// Search ignores hierarchy and expand state: every match is shown flat, with
/// its full path as a subtitle. Hiding a match because its parent happens to be
/// collapsed would make the search box feel broken.
List<TreeRow> _buildSearchRows(FolderTreeInput input, String query) {
  final rows = <TreeRow>[];
  for (final account in input.accounts) {
    final folders = input.foldersByAccount[account.id] ?? const <MailFolder>[];
    final matches = folders
        .where((f) => f.name.toLowerCase().contains(query))
        .toList()
      ..sort(_compareFolders);
    if (matches.isEmpty) continue;
    rows.add(
      SectionHeaderRow(
        title: account.displayName,
        subtitle: account.emailAddress,
        accountId: account.id,
        accentColor: account.colorValue,
      ),
    );
    for (final folder in matches) {
      rows.add(
        FolderRow(
          folder: folder,
          depth: 0,
          hasChildren: false,
          isExpanded: false,
          accentColor: account.colorValue,
          // A root folder's path is just its own name; repeating it under the
          // name is noise, so only show a path that adds something.
          searchSubtitle: _displayPath(folder) == folder.name
              ? null
              : _displayPath(folder),
        ),
      );
    }
  }
  return rows;
}

List<FolderRow> _favoriteRows(FolderTreeInput input) {
  final rows = <FolderRow>[];
  for (final account in input.accounts) {
    final folders = input.foldersByAccount[account.id] ?? const <MailFolder>[];
    final favorites =
        folders.where((f) => input.favoriteIds.contains(f.id)).toList()
          ..sort(_compareFolders);
    for (final folder in favorites) {
      rows.add(
        FolderRow(
          folder: folder,
          depth: 0,
          hasChildren: false,
          isExpanded: false,
          accentColor: account.colorValue,
          inFavorites: true,
          searchSubtitle: input.accounts.length > 1
              ? account.displayName
              : null,
        ),
      );
    }
  }
  return rows;
}

int _compareFolders(MailFolder a, MailFolder b) {
  final byRole = a.role.sortOrder.compareTo(b.role.sortOrder);
  if (byRole != 0) return byRole;
  if (a.role == FolderRole.user && b.role == FolderRole.user) {
    final byIndex = a.sortIndex.compareTo(b.sortIndex);
    if (byIndex != 0) return byIndex;
  }
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// Gmail's `[Gmail]/` prefix is an implementation detail; never show it.
String _displayPath(MailFolder folder) =>
    folder.path.replaceFirst('[Gmail]/', '').replaceAll('/', ' › ');
