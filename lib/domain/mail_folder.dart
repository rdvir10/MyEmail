import 'package:flutter/foundation.dart';

import 'folder_capabilities.dart';
import 'folder_role.dart';

/// One folder, held flat. The tree is derived from [parentId] rather than
/// stored as nested objects, so a folder can be looked up, moved or renamed
/// without rebuilding a nested structure.
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

  /// Trash and Junk show a total rather than an unread count, matching Outlook.
  bool get showsTotalInsteadOfUnread =>
      role == FolderRole.deleted || role == FolderRole.junk;

  int get badgeCount => showsTotalInsteadOfUnread ? totalCount : unreadCount;

  MailFolder copyWith({
    String? name,
    String? path,
    String? parentId,
    bool clearParent = false,
    int? unreadCount,
    int? totalCount,
    int? sortIndex,
    FolderCapabilities? capabilities,
  }) {
    return MailFolder(
      id: id,
      accountId: accountId,
      name: name ?? this.name,
      path: path ?? this.path,
      role: role,
      capabilities: capabilities ?? this.capabilities,
      parentId: clearParent ? null : (parentId ?? this.parentId),
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
