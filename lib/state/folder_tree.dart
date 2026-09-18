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
    this.isCollapsed,
    this.folderCount = 0,
  });

  final String title;
  final String? subtitle;
  final String? accountId;
  final int? accentColor;

  /// Whether this account's folders are folded away, or null for a heading
  /// that cannot be folded at all.
  ///
  /// Favourites is the null case. Its rows are copies of folders that also
  /// appear under their own account, so folding it away hides nothing — the
  /// originals are still there — and the chevron would promise something it
  /// does not do.
  final bool? isCollapsed;

  /// How many folders are folded away, shown only while collapsed. Without it
  /// a collapsed account looks like an account with no folders, which is what
  /// a broken sync looks like too.
  final int folderCount;

  bool get canCollapse => isCollapsed != null;

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
    this.isHidden = false,
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

  /// A hidden folder, shown only because "show hidden" is on. The tree dims
  /// it and marks it, so it is obvious which rows will disappear again.
  final bool isHidden;

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
    this.collapsedAccountIds = const {},
    this.hiddenIds = const {},
    this.showHidden = false,
    this.orderOverrides = const {},
    this.searchQuery = '',
    this.showUnifiedInbox = true,
  });

  final List<Account> accounts;
  final Map<String, List<MailFolder>> foldersByAccount;
  final Set<String> expandedIds;
  final Set<String> favoriteIds;

  /// Accounts folded down to just their heading.
  ///
  /// Distinct from [hiddenIds] on purpose. Hiding is a decision about a folder
  /// you do not want to see again; collapsing is about how much room a mailbox
  /// takes up right now, and the heading stays put so it is obvious the
  /// mailbox is still there and one tap brings it back.
  final Set<String> collapsedAccountIds;

  /// Folders the user has put out of the way. Hiding one hides everything
  /// under it too: leaving the children behind would float them up to a depth
  /// they do not belong at, which reads as the tree being broken.
  final Set<String> hiddenIds;

  /// Reveal them anyway, dimmed. Deliberately not persisted: this is the way
  /// back to something you hid, not a second preference to remember. Coming
  /// back tomorrow to find everything you hid on screen would defeat it.
  final bool showHidden;

  /// Local reordering of user folders, by id. IMAP has no folder order, so
  /// this never reaches the server; it overrides [MailFolder.sortIndex].
  final Map<String, int> orderOverrides;
  final String searchQuery;
  final bool showUnifiedInbox;
}

const kUnifiedInboxId = 'unified:inbox';

/// Whether this folder may be put out of the way.
///
/// Everything except an Inbox. Hiding the thing the app opens on would leave
/// someone staring at an empty tree with no obvious way back, and the point of
/// hiding is to clear away the folders a provider invents, not the one you
/// actually read. The unified Inbox is not a real folder and has nothing to
/// hide.
bool canHideFolder(MailFolder folder) =>
    folder.role != FolderRole.inbox && folder.role != FolderRole.unifiedInbox;

/// Whether [folder] is hidden, directly or because something above it is.
///
/// Walks up the parent chain, so hiding a folder takes its whole subtree with
/// it. Leaving children behind would float them to a depth they do not belong
/// at, which reads as the tree being broken rather than as a setting.
bool isFolderHidden(
  MailFolder folder,
  Set<String> hiddenIds,
  Map<String, MailFolder> byId,
) {
  if (hiddenIds.isEmpty) return false;
  MailFolder? cursor = folder;
  // Bounded by the depth of the tree, and defensive against a parent chain
  // that somehow loops: a cycle here would hang the whole UI.
  for (var depth = 0; cursor != null && depth < 64; depth++) {
    if (hiddenIds.contains(cursor.id)) return true;
    final parentId = cursor.parentId;
    cursor = parentId == null ? null : byId[parentId];
  }
  return false;
}

/// How many folders are hidden right now, counting only the ones the user
/// actually chose. A subtree of twenty under one hidden parent is one thing
/// hidden, and saying "21 hidden" would be a lie about what unhiding undoes.
int countHiddenFolders(
  Map<String, List<MailFolder>> foldersByAccount,
  Set<String> hiddenIds,
) {
  var n = 0;
  for (final folders in foldersByAccount.values) {
    for (final f in folders) {
      if (hiddenIds.contains(f.id)) n++;
    }
  }
  return n;
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
    final isCollapsed = input.collapsedAccountIds.contains(account.id);
    rows.add(
      SectionHeaderRow(
        title: account.displayName,
        subtitle: account.emailAddress,
        accountId: account.id,
        accentColor: account.colorValue,
        isCollapsed: isCollapsed,
        folderCount: folders.length,
      ),
    );
    // The heading stays, the folders go. Dropping the heading as well would
    // leave no way to bring the mailbox back short of Settings.
    if (isCollapsed) continue;
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
      hiddenIds: input.hiddenIds,
      showHidden: input.showHidden,
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
  required Set<String> hiddenIds,
  required bool showHidden,
  bool underHidden = false,
}) {
  for (final folder in childrenOf[parentId] ?? const <MailFolder>[]) {
    // Inherited rather than looked up: the walk is already coming down the
    // tree, so a parent's hidden-ness is known without climbing back up.
    final hidden = underHidden || hiddenIds.contains(folder.id);
    if (hidden && !showHidden) continue;

    final hasChildren = childrenOf.containsKey(folder.id);
    final isExpanded = expandedIds.contains(folder.id);
    rows.add(
      FolderRow(
        folder: folder,
        depth: depth,
        hasChildren: hasChildren,
        isExpanded: isExpanded,
        accentColor: accentColor,
        isHidden: hidden,
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
        hiddenIds: hiddenIds,
        showHidden: showHidden,
        underHidden: hidden,
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
  final byId = _indexById(input.foldersByAccount);
  for (final account in input.accounts) {
    final folders = input.foldersByAccount[account.id] ?? const <MailFolder>[];
    final matches = folders
        .where((f) =>
            (f.displayName.toLowerCase().contains(query) ||
                f.name.toLowerCase().contains(query)) &&
            (input.showHidden || !isFolderHidden(f, input.hiddenIds, byId)))
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
  final byId = _indexById(input.foldersByAccount);
  for (final account in input.accounts) {
    final folders = input.foldersByAccount[account.id] ?? const <MailFolder>[];
    final favorites = folders
        .where((f) =>
            input.favoriteIds.contains(f.id) &&
            // Hidden means hidden, in Favourites too. One rule, wherever a
            // folder could otherwise appear, is what makes it explainable.
            (input.showHidden ||
                !isFolderHidden(f, input.hiddenIds, byId)))
        .toList()
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

/// Every folder across every account, by id. Needed to walk a parent chain,
/// which the flat per-account lists cannot do on their own.
Map<String, MailFolder> _indexById(
  Map<String, List<MailFolder>> foldersByAccount,
) =>
    {
      for (final folders in foldersByAccount.values)
        for (final f in folders) f.id: f,
    };
