import '../../domain/account.dart';
import '../../domain/folder_capabilities.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../mail_engine.dart';

/// In-memory stand-in for the real IMAP engine, used for layout work and tests.
///
/// The shape deliberately mirrors real Gmail rather than being convenient:
/// system folders live under `[Gmail]` and refuse structural edits, user labels
/// nest several levels deep, and counts are uneven. Sample data that is tidier
/// than reality hides exactly the layout bugs this is meant to catch.
class SampleMailEngine implements MailEngine {
  SampleMailEngine() {
    for (final account in _accounts) {
      _folders[account.id] = _buildFolders(account.id);
    }
  }

  static const _accounts = <Account>[
    Account(
      id: 'acct-personal',
      displayName: 'Personal',
      emailAddress: 'rdvir10@gmail.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFF0F6CBD,
    ),
    Account(
      id: 'acct-side',
      displayName: 'Projects',
      emailAddress: 'projects.rdvir@gmail.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFF107C41,
    ),
  ];

  final Map<String, List<MailFolder>> _folders = {};

  @override
  Future<List<Account>> loadAccounts() async {
    await _latency();
    return List.unmodifiable(_accounts);
  }

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    await _latency();
    return List.unmodifiable(_folders[accountId] ?? const []);
  }

  @override
  Future<MailFolder> renameFolder(String folderId, String newName) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canRename) {
      throw FolderOperationNotSupported(folderId, 'rename');
    }
    final segments = folder.path.split('/')..removeLast();
    final newPath = [...segments, newName].join('/');
    return _replace(folder.copyWith(name: newName, path: newPath));
  }

  @override
  Future<MailFolder> moveFolder(String folderId, String? newParentId) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canMove) {
      throw FolderOperationNotSupported(folderId, 'move');
    }
    if (newParentId != null && _isDescendant(newParentId, folderId)) {
      throw FolderOperationNotSupported(folderId, 'move into own descendant');
    }
    final parentPath = newParentId == null ? null : _require(newParentId).path;
    final newPath =
        parentPath == null ? folder.name : '$parentPath/${folder.name}';
    return _replace(
      folder.copyWith(
        path: newPath,
        parentId: newParentId,
        clearParent: newParentId == null,
      ),
    );
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canDelete) {
      throw FolderOperationNotSupported(folderId, 'delete');
    }
    final list = _folders[folder.accountId]!;
    // Deleting a folder takes its subtree with it.
    final doomed = <String>{folderId};
    bool grew = true;
    while (grew) {
      grew = false;
      for (final f in list) {
        if (f.parentId != null &&
            doomed.contains(f.parentId) &&
            doomed.add(f.id)) {
          grew = true;
        }
      }
    }
    list.removeWhere((f) => doomed.contains(f.id));
  }

  @override
  Future<MailFolder> createFolder({
    required String accountId,
    required String name,
    String? parentId,
  }) async {
    await _latency();
    if (parentId != null && !_require(parentId).capabilities.canCreateChild) {
      throw FolderOperationNotSupported(parentId, 'create child in');
    }
    final parentPath = parentId == null ? null : _require(parentId).path;
    final path = parentPath == null ? name : '$parentPath/$name';
    final folder = MailFolder(
      id: '$accountId:$path',
      accountId: accountId,
      name: name,
      path: path,
      role: FolderRole.user,
      capabilities: const FolderCapabilities.userFolder(),
      parentId: parentId,
      sortIndex: _folders[accountId]!.length,
    );
    _folders[accountId]!.add(folder);
    return folder;
  }

  @override
  Future<void> markAllRead(String folderId) async {
    await _latency();
    final folder = _require(folderId);
    _replace(folder.copyWith(unreadCount: 0));
  }

  @override
  Future<void> emptyFolder(String folderId) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canEmpty) {
      throw FolderOperationNotSupported(folderId, 'empty');
    }
    _replace(folder.copyWith(unreadCount: 0, totalCount: 0));
  }

  // ---------------------------------------------------------------------------

  MailFolder _require(String folderId) {
    for (final list in _folders.values) {
      for (final f in list) {
        if (f.id == folderId) return f;
      }
    }
    throw StateError('No such folder: $folderId');
  }

  MailFolder _replace(MailFolder updated) {
    final list = _folders[updated.accountId]!;
    final i = list.indexWhere((f) => f.id == updated.id);
    list[i] = updated;
    return updated;
  }

  bool _isDescendant(String candidateId, String ancestorId) {
    String? cursor = candidateId;
    while (cursor != null) {
      if (cursor == ancestorId) return true;
      cursor = _require(cursor).parentId;
    }
    return false;
  }

  /// A small delay so the UI meets the same async edges it will hit against a
  /// real server, rather than resolving synchronously and hiding loading state.
  Future<void> _latency() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  static List<MailFolder> _buildFolders(String accountId) {
    final specs = accountId == 'acct-personal'
        ? _personalSpecs
        : _projectsSpecs;
    return specs
        .map(
          (s) => MailFolder(
            id: '$accountId:${s.path}',
            accountId: accountId,
            name: s.path.split('/').last,
            path: s.path,
            role: s.role,
            capabilities: FolderCapabilities.forGmail(s.role),
            parentId: s.parent == null ? null : '$accountId:${s.parent}',
            unreadCount: s.unread,
            totalCount: s.total,
            sortIndex: specs.indexOf(s),
          ),
        )
        .toList();
  }

  static const _personalSpecs = <_Spec>[
    _Spec('INBOX', FolderRole.inbox, unread: 14, total: 2310),
    _Spec('[Gmail]/Drafts', FolderRole.drafts, unread: 0, total: 3),
    _Spec('[Gmail]/Sent Mail', FolderRole.sent, unread: 0, total: 1876),
    _Spec('[Gmail]/Trash', FolderRole.deleted, unread: 0, total: 41),
    _Spec('[Gmail]/Spam', FolderRole.junk, unread: 0, total: 128),
    _Spec('[Gmail]/All Mail', FolderRole.archive, unread: 0, total: 9422),
    _Spec('Family', FolderRole.user, unread: 2, total: 311),
    _Spec('Family/Photos', FolderRole.user, parent: 'Family', total: 88),
    _Spec('Family/School', FolderRole.user, parent: 'Family', unread: 1, total: 46),
    _Spec('Finance', FolderRole.user, unread: 5, total: 640),
    _Spec('Finance/Banking', FolderRole.user, parent: 'Finance', total: 209),
    _Spec('Finance/Receipts', FolderRole.user, parent: 'Finance', unread: 5, total: 402),
    _Spec('Finance/Receipts/2026', FolderRole.user,
        parent: 'Finance/Receipts', unread: 5, total: 96),
    _Spec('Travel', FolderRole.user, total: 74),
    _Spec('Newsletters', FolderRole.user, unread: 231, total: 4180),
  ];

  static const _projectsSpecs = <_Spec>[
    _Spec('INBOX', FolderRole.inbox, unread: 3, total: 412),
    _Spec('[Gmail]/Drafts', FolderRole.drafts, unread: 0, total: 1),
    _Spec('[Gmail]/Sent Mail', FolderRole.sent, unread: 0, total: 233),
    _Spec('[Gmail]/Trash', FolderRole.deleted, unread: 0, total: 8),
    _Spec('[Gmail]/Spam', FolderRole.junk, unread: 0, total: 19),
    _Spec('[Gmail]/All Mail', FolderRole.archive, unread: 0, total: 1104),
    _Spec('Clients', FolderRole.user, unread: 1, total: 180),
    _Spec('Clients/Acme', FolderRole.user, parent: 'Clients', unread: 1, total: 92),
    _Spec('Clients/Globex', FolderRole.user, parent: 'Clients', total: 88),
    _Spec('Invoices', FolderRole.user, total: 57),
  ];
}

class _Spec {
  const _Spec(
    this.path,
    this.role, {
    this.parent,
    this.unread = 0,
    this.total = 0,
  });

  final String path;
  final FolderRole role;
  final String? parent;
  final int unread;
  final int total;
}
