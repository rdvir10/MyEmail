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
