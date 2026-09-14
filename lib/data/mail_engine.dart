import '../domain/account.dart';
import '../domain/mail_folder.dart';
import '../domain/mail_message.dart';

/// Everything the UI is allowed to know about talking to mail.
///
/// The real implementation (enough_mail over IMAP) arrives in milestone 3. Until
/// then [SampleMailEngine] backs the same interface so the folder tree can be
/// built and previewed in a browser. Keeping this seam is also what the tests
/// run against, so it stays after the browser preview lapses.
///
/// Folder identity: a [MailFolder.id] is `<accountId>:<path>`, so renaming or
/// moving a folder changes its id and the ids of every descendant, exactly as
/// it does on IMAP where the path is the only identity a folder has. Callers
/// holding folder ids (expand state, favourites, selection) remap them via the
/// [FolderRename] returned from [renameFolder] and [moveFolder].
abstract class MailEngine {
  Future<List<Account>> loadAccounts();

  /// Check the credentials against the server, then remember the account and
  /// its secret. Throws [AuthenticationFailed] if the server refuses the
  /// login and [ConnectionFailed] if it cannot be reached.
  Future<Account> addAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required String secret,
  });

  /// Forget the account and its secret. Local caches for it go too.
  Future<void> removeAccount(String accountId);

  /// Every folder for one account, flat. The tree is derived from parent ids.
  Future<List<MailFolder>> loadFolders(String accountId);

  /// Rename a folder in place. The whole subtree's paths and ids change.
  Future<FolderRename> renameFolder(String folderId, String newName);

  /// Reparent a folder, which on IMAP is a RENAME across the delimiter.
  /// A null [newParentId] moves it to the account root.
  Future<FolderRename> moveFolder(String folderId, String? newParentId);

  Future<void> deleteFolder(String folderId);

  Future<MailFolder> createFolder({
    required String accountId,
    required String name,
    String? parentId,
  });

  Future<void> markAllRead(String folderId);

  /// Permanently remove everything in the folder. Only valid where
  /// `capabilities.canEmpty` is set, which in practice means Trash and Junk.
  Future<void> emptyFolder(String folderId);

  /// Messages in one folder, newest first. [offset] and [limit] page through
  /// it; the list never loads a whole folder at once.
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  });

  /// The body of one message, fetched when it is opened.
  Future<MailBody> loadMessageBody(String messageId);

  /// Set or clear \Seen. The folder's unread count follows on next load.
  Future<void> setRead(String messageId, bool isRead);

  /// Set or clear \Flagged.
  Future<void> setFlagged(String messageId, bool isFlagged);

  /// Move messages into [toFolderId]. Every message must come from the same
  /// account as the destination; IMAP cannot move between mailboxes.
  Future<void> moveMessages(List<String> messageIds, String toFolderId);

  /// Delete messages the way the provider expects: into Trash from anywhere
  /// else, and permanently when already in Trash.
  Future<void> deleteMessages(List<String> messageIds);

  /// Search the server for [query] within [scope], newest first.
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
  });
}

/// Where a search looks.
///
/// [folder] is one folder; [account] is every folder of one account;
/// [everywhere] is every account. Folders that only duplicate mail (Gmail's
/// All Mail) or hold none of the user's own (Spam, Trash) are skipped in the
/// wider scopes, or every hit would appear two or three times.
class SearchScope {
  const SearchScope.folder(String this.folderId)
      : accountId = null,
        isEverywhere = false;

  const SearchScope.account(String this.accountId)
      : folderId = null,
        isEverywhere = false;

  const SearchScope.everywhere()
      : folderId = null,
        accountId = null,
        isEverywhere = true;

  final String? folderId;
  final String? accountId;
  final bool isEverywhere;

  @override
  bool operator ==(Object other) =>
      other is SearchScope &&
      other.folderId == folderId &&
      other.accountId == accountId &&
      other.isEverywhere == isEverywhere;

  @override
  int get hashCode => Object.hash(folderId, accountId, isEverywhere);
}

/// The outcome of a rename or move: the folder as it now is, plus the id
/// prefix change that applies to it and every descendant.
class FolderRename {
  const FolderRename({
    required this.folder,
    required this.oldId,
    required this.newId,
  });

  final MailFolder folder;
  final String oldId;
  final String newId;

  /// Translate an id that may point at the renamed folder or something under
  /// it. Ids elsewhere in the tree come back unchanged.
  String remap(String id) {
    if (id == oldId) return newId;
    if (id.startsWith('$oldId/')) return newId + id.substring(oldId.length);
    return id;
  }
}

/// Raised when the UI asks for something the provider will not allow. Reaching
/// this means a capability check was missed upstream, so it is a bug rather
/// than a condition to show the user.
class FolderOperationNotSupported implements Exception {
  const FolderOperationNotSupported(this.folderId, this.operation);

  final String folderId;
  final String operation;

  @override
  String toString() =>
      'FolderOperationNotSupported: cannot $operation on $folderId';
}

/// The server refused the credentials. Shown to the user as-is.
class AuthenticationFailed implements Exception {
  const AuthenticationFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The server could not be reached at all: no network, wrong host, TLS.
class ConnectionFailed implements Exception {
  const ConnectionFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A create or rename would collide with an existing sibling. Unlike
/// [FolderOperationNotSupported] this is a normal user-facing condition: the
/// UI shows it and asks for a different name.
class FolderNameConflict implements Exception {
  const FolderNameConflict(this.accountId, this.path);

  final String accountId;
  final String path;

  @override
  String toString() => 'FolderNameConflict: "$path" already exists';
}
