import 'dart:math';

import '../../domain/account.dart';
import '../../domain/folder_capabilities.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../mail_engine.dart';
import 'sample_messages.dart';

/// In-memory stand-in for the real IMAP engine, used for layout work and tests.
///
/// The shape deliberately mirrors real Gmail rather than being convenient:
/// system folders live under `[Gmail]` and refuse structural edits, user labels
/// nest several levels deep, and counts are uneven. Sample data that is tidier
/// than reality hides exactly the layout bugs this is meant to catch.
///
/// Behaviour also mirrors IMAP where it matters for the UI: renaming or moving
/// a folder rewrites the path (and therefore the id) of its whole subtree, and
/// a name that collides with a sibling is refused.
class SampleMailEngine implements MailEngine {
  SampleMailEngine() {
    for (final account in _accounts) {
      _folders[account.id] = _buildFolders(account.id, _specsFor(account.id));
    }
  }

  final List<Account> _accounts = List.of(_seedAccounts);

  static const _palette = [0xFF0F6CBD, 0xFF107C41, 0xFFB4009E, 0xFFCA5010];

  @override
  Future<Account> addAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required String secret,
  }) async {
    await _latency();
    // The sample engine cannot check a password, but it can behave like a
    // server that refuses an empty one, so the screen's error path is real.
    if (secret.trim().isEmpty) {
      throw const AuthenticationFailed('The server refused the password.');
    }
    if (_accounts.any((a) => a.emailAddress == emailAddress)) {
      throw AuthenticationFailed('$emailAddress is already set up.');
    }
    final account = Account(
      id: 'acct-${_accounts.length + 1}',
      displayName: displayName,
      emailAddress: emailAddress,
      provider: provider,
      authMethod: AuthMethod.appPassword,
      colorValue: _palette[_accounts.length % _palette.length],
    );
    _accounts.add(account);
    _folders[account.id] = _buildFolders(account.id, _freshAccountSpecs);
    return account;
  }

  @override
  Future<void> removeAccount(String accountId) async {
    await _latency();
    _accounts.removeWhere((a) => a.id == accountId);
    _folders.remove(accountId);
    _messages.removeWhere((key, _) => key.startsWith('$accountId:'));
  }

  static const _seedAccounts = <Account>[
    Account(
      id: 'acct-personal',
      displayName: 'Personal',
      emailAddress: 'personal@example.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFF0F6CBD,
    ),
    Account(
      id: 'acct-side',
      displayName: 'Projects',
      emailAddress: 'projects@example.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFF107C41,
    ),
  ];

  final Map<String, List<MailFolder>> _folders = {};

  /// Generated lazily per folder and then held, so flags changed later
  /// (milestone 4) stick for the rest of the run.
  final Map<String, List<MailMessage>> _messages = {};

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    await _latency();
    final all = _messages.putIfAbsent(
      folderId,
      () => generateSampleMessages(_require(folderId)),
    );
    if (offset >= all.length) return const [];
    return List.unmodifiable(all.sublist(offset, min(all.length, offset + limit)));
  }

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    await _latency();
    final folderId = messageId.substring(0, messageId.lastIndexOf('#'));
    final message = _messages[folderId]?.firstWhere(
      (m) => m.id == messageId,
      orElse: () => throw StateError('No such message: $messageId'),
    );
    if (message == null) throw StateError('No such message: $messageId');
    return generateSampleBody(message);
  }

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
  Future<FolderRename> renameFolder(String folderId, String newName) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canRename) {
      throw FolderOperationNotSupported(folderId, 'rename');
    }
    final segments = folder.path.split('/')..removeLast();
    final newPath = [...segments, newName].join('/');
    return _relocate(folder, newPath: newPath, newParentId: folder.parentId);
  }

  @override
  Future<FolderRename> moveFolder(String folderId, String? newParentId) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canMove) {
      throw FolderOperationNotSupported(folderId, 'move');
    }
    if (newParentId != null && _isDescendant(newParentId, folderId)) {
      throw FolderOperationNotSupported(folderId, 'move into own descendant');
    }
    if (newParentId != null &&
        !_require(newParentId).capabilities.canCreateChild) {
      throw FolderOperationNotSupported(newParentId, 'nest under');
    }
    final parentPath = newParentId == null ? null : _require(newParentId).path;
    final newPath =
        parentPath == null ? folder.name : '$parentPath/${folder.name}';
    return _relocate(folder, newPath: newPath, newParentId: newParentId);
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canDelete) {
      throw FolderOperationNotSupported(folderId, 'delete');
    }
    // Deleting a folder takes its subtree with it.
    final prefix = '${folder.path}/';
    _folders[folder.accountId]!
        .removeWhere((f) => f.id == folderId || f.path.startsWith(prefix));
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
    _assertNoConflict(accountId, path);
    final folder = MailFolder.at(
      accountId: accountId,
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
    _replace(_require(folderId).copyWith(unreadCount: 0));
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

  /// Move [folder] to [newPath], carrying every descendant along and rewriting
  /// their paths, ids and parent links. This is what RENAME does on IMAP.
  FolderRename _relocate(
    MailFolder folder, {
    required String newPath,
    required String? newParentId,
  }) {
    final accountId = folder.accountId;
    final oldPath = folder.path;
    final oldId = folder.id;
    final newId = MailFolder.idFor(accountId, newPath);

    if (newPath == oldPath) {
      return FolderRename(folder: folder, oldId: oldId, newId: newId);
    }
    _assertNoConflict(accountId, newPath, excludingId: oldId);

    final mapping = FolderRename(folder: folder, oldId: oldId, newId: newId);
    final childPrefix = '$oldPath/';
    late MailFolder moved;

    _folders[accountId] = [
      for (final f in _folders[accountId]!)
        if (f.id == oldId)
          moved = f.withPath(newPath, parentId: newParentId)
        else if (f.path.startsWith(childPrefix))
          f.withPath(
            newPath + f.path.substring(oldPath.length),
            parentId: f.parentId == null ? null : mapping.remap(f.parentId!),
          )
        else
          f,
    ];

    return FolderRename(folder: moved, oldId: oldId, newId: newId);
  }

  /// Gmail label names are case-insensitive, so "travel" and "Travel" would
  /// collide on the server. Match the stricter rule locally.
  void _assertNoConflict(String accountId, String path, {String? excludingId}) {
    final wanted = path.toLowerCase();
    for (final f in _folders[accountId] ?? const <MailFolder>[]) {
      if (f.id != excludingId && f.path.toLowerCase() == wanted) {
        throw FolderNameConflict(accountId, path);
      }
    }
  }

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

  static List<_Spec> _specsFor(String accountId) => switch (accountId) {
        'acct-personal' => _personalSpecs,
        'acct-side' => _projectsSpecs,
        _ => _freshAccountSpecs,
      };

  static List<MailFolder> _buildFolders(String accountId, List<_Spec> specs) {
    return [
      for (final (i, s) in specs.indexed)
        MailFolder.at(
          accountId: accountId,
          path: s.path,
          role: s.role,
          capabilities: FolderCapabilities.forGmail(s.role),
          parentId:
              s.parent == null ? null : MailFolder.idFor(accountId, s.parent!),
          unreadCount: s.unread,
          totalCount: s.total,
          sortIndex: i,
        ),
    ];
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

  /// What a just-added Gmail account looks like before anything arrives.
  static const _freshAccountSpecs = <_Spec>[
    _Spec('INBOX', FolderRole.inbox),
    _Spec('[Gmail]/Drafts', FolderRole.drafts),
    _Spec('[Gmail]/Sent Mail', FolderRole.sent),
    _Spec('[Gmail]/Trash', FolderRole.deleted),
    _Spec('[Gmail]/Spam', FolderRole.junk),
    _Spec('[Gmail]/All Mail', FolderRole.archive),
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
