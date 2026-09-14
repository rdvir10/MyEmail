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

  /// An ordinary user folder or Gmail label: everything is allowed.
  const FolderCapabilities.userFolder()
      : canRename = true,
        canMove = true,
        canDelete = true,
        canCreateChild = true,
        canEmpty = true,
        canMarkAllRead = true,
        canFavorite = true,
        canAcceptMessages = true;

  /// A server-defined special folder. Gmail refuses structural changes to
  /// these, and the Inbox cannot be removed on any provider.
  const FolderCapabilities.systemFolder({
    this.canEmpty = false,
    this.canAcceptMessages = true,
  })  : canRename = false,
        canMove = false,
        canDelete = false,
        canCreateChild = false,
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

  /// Defaults for Gmail, which is the only provider in round one and also the
  /// most restrictive one we expect to meet.
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
