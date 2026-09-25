import 'dart:convert';
import 'dart:typed_data';

import '../domain/account.dart';
import '../domain/error_report.dart';
import 'auth/oauth_token.dart';
import '../domain/draft.dart';
import '../domain/address_suggestions.dart';
import '../domain/calendar_invite.dart';
import '../domain/mail_attachment.dart';
import '../domain/mail_folder.dart';
import '../domain/mail_message.dart';
import '../domain/message_move.dart';

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

  /// Same, for a provider that signs in with OAuth rather than a password.
  ///
  /// Separate from [addAccount] because the two take genuinely different
  /// things: a password is a value that works forever, a token is a pair with
  /// an expiry that has to be refreshed. Folding them into one call would
  /// mean a parameter that is a password sometimes and a serialised token
  /// other times, which is exactly the sort of thing that goes wrong quietly.
  ///
  /// [signedInAs] is the address the sign-in itself named, where the provider
  /// says (Google does, in its ID token). It must be the address the account
  /// is added as: signing in as one mailbox while typing another's address
  /// made an account that showed one mailbox under another's name.
  Future<Account> addOAuthAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required OAuthToken token,
    String? signedInAs,
  });

  /// Change the name and colour an account is shown under.
  ///
  /// Local only: neither is anything the mail server knows about, so this
  /// never opens a connection and works offline.
  Future<Account> updateAccount({
    required String accountId,
    String? displayName,
    int? colorValue,

    /// The name on mail sent from this account. Empty clears it, which puts
    /// the account back to sending under its folder-list name.
    String? senderName,
  });

  /// Replace the app password an account signs in with, keeping the account.
  ///
  /// The point of this over removing and re-adding: the account id stays the
  /// same, so every cached folder, message and body stays where it is. An app
  /// password that has been revoked is otherwise only fixable by throwing the
  /// mailbox's whole local copy away and downloading it again.
  ///
  /// Proved against the server first. Storing a secret that does not work
  /// would replace a broken sign-in with a differently broken one.
  Future<void> updateAppPassword({
    required String accountId,
    required String secret,
  });

  /// The same, for an account that signs in with OAuth — or one that is
  /// moving to it: an account added with an app password signs in with the
  /// token from here on, keeping everything cached under it.
  ///
  /// [signedInAs] as in [addOAuthAccount]: the sign-in must be for this
  /// account's address.
  Future<void> updateOAuthToken({
    required String accountId,
    required OAuthToken token,
    String? signedInAs,
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
  ///
  /// Talks to the server: new mail, changed flags and deletions are all
  /// taken account of before this answers. Use [cachedMessages] for what is
  /// already known, which is the same list a moment earlier.
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  });

  /// The folder list as it was last seen, with no network at all.
  ///
  /// Empty for an account whose folders have never been listed. Shown while
  /// [loadFolders] runs, because a tree that was right a minute ago beats an
  /// empty screen saying "Select a folder" for the two seconds a work
  /// mailbox takes to list itself.
  Future<List<MailFolder>> cachedFolders(String accountId);

  /// What is already stored for a folder, with no network at all.
  ///
  /// The list is shown from this first and corrected when [loadMessages]
  /// comes back. Mail that is on the screen is mail that was on the screen
  /// a minute ago; making someone watch a spinner while the server is asked
  /// to confirm it is time spent showing nothing.
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  });

  /// One message from the cache, by id, with no network at all.
  ///
  /// Null when it is not cached, which for a message that just arrived and
  /// was announced in a notification it will be. For answering a
  /// notification's buttons, where there is a message id and nothing else.
  Future<MailMessage?> cachedMessage(String messageId);

  /// The body of one message, fetched when it is opened.
  Future<MailBody> loadMessageBody(String messageId);

  /// Everyone the cached mail has been to or from, each address once, with
  /// how often it appeared. For suggesting recipients as they are typed.
  Future<List<AddressSuggestion>> recentAddresses();

  /// What is attached to a message. Cheap: no file is downloaded.
  Future<List<MailAttachment>> listAttachments(String messageId);

  /// The bytes of one attachment, by the id [listAttachments] gave it.
  Future<Uint8List> fetchAttachment(String messageId, String attachmentId);

  /// The message as it arrived: RFC 822 text, headers and all. For saving
  /// as an `.eml`, or attaching one message to another.
  ///
  /// One character per byte, the way the wire has it. Back to bytes with
  /// [rawMessageBytes], never with UTF-8: that turned every byte of a
  /// message sent in 8-bit, Hebrew from Thunderbird say, into two, and the
  /// `.eml` arrived garbled.
  Future<String> rawMessage(String messageId);

  /// Answer the invitation in a message: on the calendar where the server
  /// has one (Microsoft), and as the mail reply every calendar server
  /// reads otherwise, sent from the account the invitation came to.
  Future<void> respondToInvite(
    String messageId,
    CalendarInvite invite,
    InviteResponse response,
  );

  /// Set or clear \Seen. The folder's unread count follows on next load.
  Future<void> setRead(String messageId, bool isRead);

  /// Set or clear \Flagged.
  Future<void> setFlagged(String messageId, bool isFlagged);

  /// Move messages into [toFolderId]. Every message must come from the same
  /// account as the destination; IMAP cannot move between mailboxes.
  ///
  /// Answers with what moved where, one entry per source folder, so the
  /// caller can offer to put it back. See [MessageMove] for why the ids in
  /// it are not the ids that went in.
  Future<List<MessageMove>> moveMessages(
    List<String> messageIds,
    String toFolderId,
  );

  /// Delete messages the way the provider expects: into Trash from anywhere
  /// else, and permanently when already in Trash.
  ///
  /// Answers the same way [moveMessages] does. A delete that was permanent
  /// has nothing to put back and says so with an empty entry.
  Future<List<MessageMove>> deleteMessages(List<String> messageIds);

  /// Put back what [moveMessages] or [deleteMessages] reported.
  ///
  /// Uses the ids the server gave where it gave any. Where it did not, the
  /// destination is synced and searched for the `Message-ID` of each message
  /// instead, which is slower but works against a server that moves mail
  /// without saying where it put it.
  Future<void> undoMoves(List<MessageMove> moves);

  /// Search the server for [query] within [scope], newest first.
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
  });

  /// Send the draft (over SMTP for Gmail, through Graph for Microsoft), see
  /// that Sent has a copy, and mark what it replied to or forwarded, the
  /// messages it carries as attachments included. A mark that cannot be made
  /// is logged, never thrown: the message has gone either way.
  ///
  /// Throws [SendFailed] when the server refuses, [AuthenticationFailed] when
  /// it refuses the login, and [ConnectionFailed] when it cannot be reached.
  Future<void> sendDraft(Draft draft);

  /// Put [draft] in the Drafts folder, replacing the copy it was opened from.
  ///
  /// Server-side rather than local, so the half-written message is on the
  /// phone, on the web and in every other client, which is the only version
  /// of this feature worth having. Returns the new message id, or null where
  /// the draft was saved but where it landed is not known. Throws
  /// [SendFailed] where the account has no Drafts folder to put it in.
  Future<String?> saveDraft(Draft draft);

  /// Remove a copy [saveDraft] put in Drafts, for good rather than into
  /// Trash: it was only ever a safety copy. Best-effort.
  Future<void> discardDraft(String savedAs);
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
class AuthenticationFailed implements Exception, NeedsSignIn, ReadableError {
  const AuthenticationFailed(this.message);

  /// Always false: a refused password or token is something the person can
  /// replace themselves. The one case that needs an administrator comes from
  /// Microsoft's consent rules and has its own type.
  @override
  bool get needsAdministrator => false;

  @override
  final String message;

  @override
  String toString() => message;
}

/// The server could not be reached at all: no network, wrong host, TLS.
class ConnectionFailed implements Exception, Retryable, ReadableError {
  const ConnectionFailed(this.message);

  @override
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

/// [MailEngine.rawMessage]'s text as the bytes it stands for.
///
/// A character past 0xFF means the text was never one character per byte,
/// written out by the app itself say, and then it is UTF-8.
Uint8List rawMessageBytes(String raw) {
  for (final unit in raw.codeUnits) {
    if (unit > 0xFF) return Uint8List.fromList(utf8.encode(raw));
  }
  return Uint8List.fromList(latin1.encode(raw));
}
