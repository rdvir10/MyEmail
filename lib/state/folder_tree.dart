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
    this.accentColor,
    this.inFavorites = false,
    this.flat = false,
    this.subtitle,
  });

  final MailFolder folder;

  /// Indent level. Favourites and search results are always flat, so this is 0
  /// there regardless of where the folder really sits.
  final int depth;
  final bool hasChildren;
  final bool isExpanded;

  /// The owning account's colour. Null for synthetic rows such as the unified
  /// Inbox, which the UI paints in the theme's primary colour instead; the
  /// state layer has no business knowing theme colours.
  final int? accentColor;
  final bool inFavorites;

  /// True for rows shown out of their tree position (Favourites, search
  /// results). Reordering by dropping before or after such a row would be
  /// meaningless, so only "drop into" applies there.
  final bool flat;

  /// Secondary line under the name: the full path in search results (so two
  /// folders called "2026" can be told apart) or the account name in
  /// Favourites when more than one account is present.
  final String? subtitle;

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
    this.orderOverrides = const {},
    this.searchQuery = '',
    this.showUnifiedInbox = true,
  });

  final List<Account> accounts;
  final Map<String, List<MailFolder>> foldersByAccount;
  final Set<String> expandedIds;
  final Set<String> favoriteIds;

  /// Local reordering of user folders, by id. IMAP has no folder order, so
  /// this never reaches the server; it overrides [MailFolder.sortIndex].
  final Map<String, int> orderOverrides;
  final String searchQuery;
  final bool showUnifiedInbox;
}

const kUnifiedInboxId = 'unified:inbox';

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

/// Flatten accounts and folders into the rows to render.
///
/// Ordering within an account is Outlook's, not alphabetical: system folders
/// first in a fixed order, then user folders. Sorting user folders by their
/// effective sort index keeps any manual arrangement, which is local-only
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
      ),
    );
  }

  final favorites = _favoriteRows(input);
  if (favorites.isNotEmpty) {
    rows.add(const SectionHeaderRow(title: 'Favourites', subtitle: null));
    rows.addAll(favorites);
  }

  final compare = folderComparator(input.orderOverrides);
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
    // Group once per account so the walk below is linear in the number of
    // folders. Scanning the whole list at every node is quadratic, and this
    // runs on every keystroke and every expand toggle.
    final childrenOf = <String?, List<MailFolder>>{};
    for (final f in folders) {
      (childrenOf[f.parentId] ??= []).add(f);
    }
    for (final list in childrenOf.values) {
      list.sort(compare);
    }
    _appendSubtree(
      rows: rows,
      childrenOf: childrenOf,
      parentId: null,
      depth: 0,
      expandedIds: input.expandedIds,
      accentColor: account.colorValue,
    );
  }

  return rows;
}

void _appendSubtree({
  required List<TreeRow> rows,
  required Map<String?, List<MailFolder>> childrenOf,
  required String? parentId,
  required int depth,
  required Set<String> expandedIds,
  required int accentColor,
}) {
  for (final folder in childrenOf[parentId] ?? const <MailFolder>[]) {
    final hasChildren = childrenOf.containsKey(folder.id);
    final isExpanded = expandedIds.contains(folder.id);
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
        childrenOf: childrenOf,
        parentId: folder.id,
        depth: depth + 1,
        expandedIds: expandedIds,
        accentColor: accentColor,
      );
    }
  }
}

/// Search ignores hierarchy and expand state: every match is shown flat, with
/// its full path as a subtitle. Hiding a match because its parent happens to be
/// collapsed would make the search box feel broken.
///
/// Matching is on the folder's shown name (and its server name, so "trash"
/// still finds Deleted), not its path, as in Outlook. A query like
/// "receipts 2026" finds nothing; that is deliberate, so that the results are
/// predictable from what is visible in the tree.
List<TreeRow> _buildSearchRows(FolderTreeInput input, String query) {
  final rows = <TreeRow>[];
  final compare = folderComparator(input.orderOverrides);
  for (final account in input.accounts) {
    final folders = input.foldersByAccount[account.id] ?? const <MailFolder>[];
    final matches = folders
        .where((f) =>
            f.displayName.toLowerCase().contains(query) ||
            f.name.toLowerCase().contains(query))
        .toList()
      ..sort(compare);
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
          flat: true,
          // Only a nested folder needs its path shown; for a root folder the
          // path is just the name again.
          subtitle: folder.parentId == null ? null : displayPath(folder),
        ),
      );
    }
  }
  return rows;
}

List<FolderRow> _favoriteRows(FolderTreeInput input) {
  final rows = <FolderRow>[];
  final compare = folderComparator(input.orderOverrides);
  for (final account in input.accounts) {
    final folders = input.foldersByAccount[account.id] ?? const <MailFolder>[];
    final favorites =
        folders.where((f) => input.favoriteIds.contains(f.id)).toList()
          ..sort(compare);
    for (final folder in favorites) {
      rows.add(
        FolderRow(
          folder: folder,
          depth: 0,
          hasChildren: false,
          isExpanded: false,
          accentColor: account.colorValue,
          inFavorites: true,
          flat: true,
          subtitle: input.accounts.length > 1 ? account.displayName : null,
        ),
      );
    }
  }
  return rows;
}

/// A folder's effective position among its siblings: the local override if
/// the user has rearranged, otherwise whatever the engine supplied.
int effectiveSortIndex(MailFolder f, Map<String, int> overrides) =>
    overrides[f.id] ?? f.sortIndex;

/// System folders in Outlook's fixed order, then user folders by effective
/// sort index, then by name as a tiebreak.
Comparator<MailFolder> folderComparator(Map<String, int> overrides) {
  return (a, b) {
    final byRole = a.role.sortOrder.compareTo(b.role.sortOrder);
    if (byRole != 0) return byRole;
    if (a.role == FolderRole.user && b.role == FolderRole.user) {
      final byIndex = effectiveSortIndex(a, overrides)
          .compareTo(effectiveSortIndex(b, overrides));
      if (byIndex != 0) return byIndex;
    }
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  };
}

/// The children of [parentId] in display order. Used by drag and drop to
/// work out where a dropped folder lands among its new siblings.
List<MailFolder> sortedChildren(
  List<MailFolder> folders,
  String? parentId,
  Map<String, int> overrides,
) {
  return folders.where((f) => f.parentId == parentId).toList()
    ..sort(folderComparator(overrides));
}

/// A folder's path as the user should see it. Gmail's `[Gmail]/` prefix is an
/// implementation detail and is never shown.
String displayPath(MailFolder folder) =>
    folder.path.replaceFirst('[Gmail]/', '').replaceAll('/', ' › ');
