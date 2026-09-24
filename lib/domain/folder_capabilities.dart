import 'account.dart';
import 'folder_role.dart';

/// What a given folder actually permits, which varies by provider.
///
/// The tree reads these rather than assuming, because IMAP is far more
/// restrictive than an Outlook-style UI implies:
///
///  * IMAP has no notion of folder ordering, so any manual reorder is local
///    UI state and never reaches the server.
///  * "Nesting" a folder is a RENAME across the hierarchy delimiter, which the
///    server may refuse.
///  * Gmail's `[Gmail]` special folders cannot be renamed, moved or deleted at
///    all, and Gmail is the only provider in round one.
///
/// Offering a gesture that the server will reject is worse than not offering
/// it, so disabled capabilities hide the affordance instead of failing later.
class FolderCapabilities {
  const FolderCapabilities({
    this.canRename = false,
    this.canMove = false,
    this.canDelete = false,
    this.canCreateChild = false,
    this.canEmpty = false,
    this.canMarkAllRead = true,
    this.canFavorite = true,
    this.canAcceptMessages = true,
  });

  /// An ordinary user folder or Gmail label: every structural edit is allowed.
  /// "Empty" is not: bulk-deleting the contents of an ordinary folder is a
  /// Trash and Junk affordance in Outlook, and offering it on a Gmail label
  /// invites a very expensive mis-tap.
  const FolderCapabilities.userFolder()
      : canRename = true,
        canMove = true,
        canDelete = true,
        canCreateChild = true,
        canEmpty = false,
        canMarkAllRead = true,
        canFavorite = true,
        canAcceptMessages = true;

  /// A server-defined special folder. Gmail refuses structural changes to
  /// these, and the Inbox cannot be removed on any provider.
  ///
  /// [canCreateChild] is the one edit that can be open: it changes what is
  /// under the folder, not the folder itself.
  const FolderCapabilities.systemFolder({
    this.canEmpty = false,
    this.canAcceptMessages = true,
    this.canCreateChild = false,
  })  : canRename = false,
        canMove = false,
        canDelete = false,
        canMarkAllRead = true,
        canFavorite = true;

  /// The unified Inbox is synthetic: it has no server folder behind it, so
  /// nothing structural applies and messages cannot be dropped onto it.
  const FolderCapabilities.synthetic()
      : canRename = false,
        canMove = false,
        canDelete = false,
        canCreateChild = false,
        canEmpty = false,
        canMarkAllRead = false,
        canFavorite = false,
        canAcceptMessages = false;

  final bool canRename;
  final bool canMove;
  final bool canDelete;
  final bool canCreateChild;

  /// "Empty folder" — only meaningful for Trash and Junk.
  final bool canEmpty;
  final bool canMarkAllRead;
  final bool canFavorite;

  /// Whether a message may be dropped onto this folder.
  final bool canAcceptMessages;

  /// Whether the long-press menu would have anything structural to show.
  bool get hasAnyStructuralAction =>
      canRename || canMove || canDelete || canCreateChild || canEmpty;

  /// What this provider allows for a folder in this role.
  factory FolderCapabilities.forProvider(
    MailProvider provider,
    FolderRole role,
  ) =>
      switch (provider) {
        MailProvider.gmail => FolderCapabilities.forGmail(role),
        MailProvider.outlook => FolderCapabilities.forOutlook(role),
      };

  /// Outlook.com, where the special folders are ordinary folders wearing
  /// special-use flags.
  ///
  /// The difference that matters is Archive. On Gmail, "All Mail" is every
  /// message the account holds and archiving is the act of removing the Inbox
  /// label, so dropping a message on it does nothing. On Outlook, Archive is
  /// a folder you move mail into, and it is one of the most-used targets
  /// there. Sharing Gmail's mapping would have quietly refused the drop.
  ///
  /// Drafts and Sent likewise accept messages here: Outlook has no objection
  /// to an APPEND, which is how a draft written on this device shows up on
  /// the web.
  ///
  /// Structural edits stay closed. The special folders can technically be
  /// renamed on Exchange, but doing so from here would move them out from
  /// under their special-use flag and leave the account with a Sent folder
  /// the app no longer recognises.
  ///
  /// Folders inside them are another matter. Inbox and Archive take
  /// subfolders on Outlook, and people use them: offering neither "New
  /// subfolder" nor a drop onto them, while a drop beside an existing Inbox
  /// subfolder moved the folder into the Inbox anyway, was only confusing.
  factory FolderCapabilities.forOutlook(FolderRole role) => switch (role) {
        FolderRole.unifiedInbox => const FolderCapabilities.synthetic(),
        FolderRole.user => const FolderCapabilities.userFolder(),
        FolderRole.deleted =>
          const FolderCapabilities.systemFolder(canEmpty: true),
        FolderRole.junk =>
          const FolderCapabilities.systemFolder(canEmpty: true),
        FolderRole.archive =>
          const FolderCapabilities.systemFolder(canCreateChild: true),
        FolderRole.drafts => const FolderCapabilities.systemFolder(),
        FolderRole.sent => const FolderCapabilities.systemFolder(),
        FolderRole.inbox =>
          const FolderCapabilities.systemFolder(canCreateChild: true),
        // Nothing on the server backs an Outbox; it is the app's own queue.
        FolderRole.outbox =>
          const FolderCapabilities.systemFolder(canAcceptMessages: false),
      };

  /// Gmail, which is the more restrictive of the two.
  factory FolderCapabilities.forGmail(FolderRole role) => switch (role) {
        FolderRole.unifiedInbox => const FolderCapabilities.synthetic(),
        FolderRole.user => const FolderCapabilities.userFolder(),
        FolderRole.deleted =>
          const FolderCapabilities.systemFolder(canEmpty: true),
        FolderRole.junk =>
          const FolderCapabilities.systemFolder(canEmpty: true),
        // Gmail's Drafts, Sent, All Mail and Inbox reject arbitrary appends or
        // structural edits.
        FolderRole.drafts =>
          const FolderCapabilities.systemFolder(canAcceptMessages: false),
        FolderRole.sent =>
          const FolderCapabilities.systemFolder(canAcceptMessages: false),
        FolderRole.outbox =>
          const FolderCapabilities.systemFolder(canAcceptMessages: false),
        FolderRole.inbox => const FolderCapabilities.systemFolder(),
        // Gmail's "All Mail" is every message the account holds. Archiving is
        // an action (remove the Inbox label), not a move into this folder, so
        // dropping a message here would be a no-op. It stays browsable only.
        FolderRole.archive =>
          const FolderCapabilities.systemFolder(canAcceptMessages: false),
      };
}
