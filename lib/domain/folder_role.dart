/// The job a folder does, independent of what the server calls it.
///
/// IMAP servers name special folders inconsistently (Gmail puts them under
/// `[Gmail]`, others use `INBOX.Sent`, and so on), so the UI never matches on
/// name. Special-use flags from the server map onto this, and the sample data
/// sets it directly.
enum FolderRole {
  inbox,
  drafts,
  sent,
  deleted,
  junk,
  archive,
  outbox,

  /// Not a server folder: the merged view across every account.
  unifiedInbox,

  /// An ordinary folder or Gmail label the user made.
  user;

  bool get isSystem => this != user && this != unifiedInbox;

  /// Order system folders the way Outlook does, rather than alphabetically.
  /// User folders sort by name after all system ones.
  int get sortOrder => switch (this) {
        FolderRole.inbox => 0,
        FolderRole.drafts => 1,
        FolderRole.sent => 2,
        FolderRole.deleted => 3,
        FolderRole.junk => 4,
        FolderRole.archive => 5,
        FolderRole.outbox => 6,
        FolderRole.unifiedInbox => -1,
        FolderRole.user => 100,
      };
}
