import 'package:flutter/foundation.dart';

import 'folder_capabilities.dart';
import 'folder_role.dart';

/// One folder, held flat. The tree is derived from [parentId] rather than
/// stored as nested objects, so a folder can be looked up, moved or renamed
/// without rebuilding a nested structure.
///
/// A folder's [id] is derived from its [path], because on IMAP the path is the
/// only identity a folder has. Renaming or moving therefore produces a *new*
/// folder value with a new id; see [withPath]. There is deliberately no way to
/// change [path] without changing [id] to match.
@immutable
class MailFolder {
  const MailFolder({
    required this.id,
    required this.accountId,
    required this.name,
    required this.path,
    required this.role,
    required this.capabilities,
    this.parentId,
    this.unreadCount = 0,
    this.totalCount = 0,
    this.sortIndex = 0,
  });

  /// Build a folder whose id and name follow from its path.
  MailFolder.at({
    required this.accountId,
    required this.path,
    required this.role,
    required this.capabilities,
    this.parentId,
    this.unreadCount = 0,
    this.totalCount = 0,
    this.sortIndex = 0,
  })  : id = idFor(accountId, path),
        name = nameFor(path);

  static String idFor(String accountId, String path) => '$accountId:$path';

  static String nameFor(String path) => path.split('/').last;

  /// Unique across all accounts: `<accountId>:<path>`.
  final String id;

  /// Empty for synthetic folders that span accounts, such as the unified Inbox.
  final String accountId;

  /// Leaf name as shown in the tree.
  final String name;

  /// Full IMAP path, e.g. `[Gmail]/All Mail` or `Work/Invoices`.
  final String path;

  final FolderRole role;
  final FolderCapabilities capabilities;
  final String? parentId;

  final int unreadCount;
  final int totalCount;

  /// Local-only ordering. IMAP has no folder order, so this never leaves the
  /// device; it exists so the user can arrange their own folders.
  final int sortIndex;

  bool get isSynthetic => accountId.isEmpty;

  /// What the user sees: Outlook's name for a system role, otherwise the
  /// folder's own name. [name] stays the server's leaf name for IMAP use.
  String get displayName => role.displayName ?? name;

  /// Trash and Junk show a total rather than an unread count, matching Outlook.
  bool get showsTotalInsteadOfUnread =>
      role == FolderRole.deleted || role == FolderRole.junk;

  int get badgeCount => showsTotalInsteadOfUnread ? totalCount : unreadCount;

  /// The same folder at a new path, with id and name recomputed to match.
  MailFolder withPath(String newPath, {required String? parentId}) {
    return MailFolder(
      id: idFor(accountId, newPath),
      accountId: accountId,
      name: nameFor(newPath),
      path: newPath,
      role: role,
      capabilities: capabilities,
      parentId: parentId,
      unreadCount: unreadCount,
      totalCount: totalCount,
      sortIndex: sortIndex,
    );
  }

  /// Non-identity fields only. Path changes go through [withPath].
  MailFolder copyWith({
    int? unreadCount,
    int? totalCount,
    int? sortIndex,
    FolderCapabilities? capabilities,
  }) {
    return MailFolder(
      id: id,
      accountId: accountId,
      name: name,
      path: path,
      role: role,
      capabilities: capabilities ?? this.capabilities,
      parentId: parentId,
      unreadCount: unreadCount ?? this.unreadCount,
      totalCount: totalCount ?? this.totalCount,
      sortIndex: sortIndex ?? this.sortIndex,
    );
  }

  @override
  bool operator ==(Object other) => other is MailFolder && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'MailFolder($id, ${role.name})';
}
