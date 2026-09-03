import '../domain/account.dart';
import '../domain/mail_folder.dart';

/// Everything the UI is allowed to know about talking to mail.
///
/// The real implementation (enough_mail over IMAP) arrives in milestone 3. Until
/// then [SampleMailEngine] backs the same interface so the folder tree can be
/// built and previewed in a browser. Keeping this seam is also what the tests
/// run against, so it stays after the browser preview lapses.
abstract class MailEngine {
  Future<List<Account>> loadAccounts();

  /// Every folder for one account, flat. The tree is derived from parent ids.
  Future<List<MailFolder>> loadFolders(String accountId);

  /// Rename a folder in place. Fails if the folder's capabilities forbid it.
  Future<MailFolder> renameFolder(String folderId, String newName);

  /// Reparent a folder, which on IMAP is a RENAME across the delimiter.
  /// A null [newParentId] moves it to the account root.
  Future<MailFolder> moveFolder(String folderId, String? newParentId);

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
