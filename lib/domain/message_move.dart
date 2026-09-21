/// Where a batch of messages went, and where they were, which is everything
/// needed to put them back.
///
/// A move and a delete are the same operation to a mail server: deleting
/// puts the message in Trash, and both are undone by moving it the other
/// way. The one case that cannot be undone is a delete with nowhere to put
/// the message — already in Trash, or an account with no Trash at all —
/// where the message is gone for good and [movedIds] is empty.
///
/// The ids here are the ones the messages have *now*. A server reissues them
/// on a move: Graph hands back a new id outright, and IMAP gives the message
/// a new UID in its new folder. The ids the caller passed in stopped meaning
/// anything the moment the move went through.
class MessageMove {
  const MessageMove({
    required this.fromFolderId,
    required this.toFolderId,
    required this.movedIds,
  });

  /// The folder they came out of, and where undo puts them back.
  final String fromFolderId;

  /// The folder they are in now.
  final String toFolderId;

  /// What they are called there. Empty when the server would not say, which
  /// is an IMAP server without UIDPLUS, or a delete that was permanent.
  final List<String> movedIds;

  /// Whether this can be put back.
  bool get canUndo => movedIds.isNotEmpty && fromFolderId != toFolderId;

  @override
  String toString() =>
      'MessageMove(${movedIds.length} from $fromFolderId to $toFolderId)';
}

/// Whether a whole batch can be put back.
///
/// Every message must be accounted for. A batch that half moved and half was
/// deleted for good would come back half its size, and an Undo that quietly
/// does less than it says is worse than no Undo at all.
bool canUndoAll(List<MessageMove> moves, int messageCount) =>
    moves.isNotEmpty &&
    moves.every((m) => m.canUndo) &&
    moves.fold(0, (n, m) => n + m.movedIds.length) == messageCount;
