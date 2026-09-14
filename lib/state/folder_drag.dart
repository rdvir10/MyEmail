import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/folder_role.dart';
import '../domain/mail_folder.dart';
import '../domain/mail_message.dart';
import 'folder_tree.dart';
import 'providers.dart';

/// The payload carried by a folder being dragged in the tree.
class DraggedFolder {
  const DraggedFolder(this.folder);

  final MailFolder folder;
}

/// The payload carried by messages dragged from the list onto a folder.
class DraggedMessages {
  const DraggedMessages(this.messages);

  final List<MailMessage> messages;
}

/// Whether [messages] may be dropped onto [target]: the folder has to accept
/// messages, belong to the same account, and not already hold them.
bool canDropMessagesOn(List<MailMessage> messages, MailFolder target) {
  if (messages.isEmpty) return false;
  if (!target.capabilities.canAcceptMessages) return false;
  final accountId = messages.first.accountId;
  if (messages.any((m) => m.accountId != accountId)) return false;
  if (target.accountId != accountId) return false;
  return messages.any((m) => m.folderId != target.id);
}

/// Where on a target row a drop lands.
///
/// [before] and [after] reorder among siblings (and reparent to the target's
/// parent if the folder came from elsewhere); [into] nests under the target.
enum DropZone { before, into, after }

/// Decide what dropping [dragged] at [fraction] (0 = top edge, 1 = bottom
/// edge) of [target]'s row would do, or null if that drop is not allowed.
///
/// The rules mirror the capability flags so that a drop the server would
/// reject is refused visually, before anything is sent:
///
///  * Only same-account drops; folders do not move between mailboxes.
///  * A folder cannot be dropped on itself or anything inside it.
///  * Nesting needs the target to accept children (Gmail's system folders
///    do not), and nesting into the current parent is a no-op, so refused.
///  * Reordering is between user folders only; system folders keep Outlook's
///    fixed order, so "before Inbox" has no meaning.
///  * Rows shown out of place (Favourites, search results) only take "into".
DropZone? resolveDropZone({
  required MailFolder dragged,
  required MailFolder target,
  required double fraction,
  bool flat = false,
}) {
  if (!dragged.capabilities.canMove) return null;
  if (dragged.accountId != target.accountId) return null;
  if (target.id == dragged.id) return null;
  if (target.path.startsWith('${dragged.path}/')) return null;

  final zone = flat
      ? DropZone.into
      : fraction < 0.25
          ? DropZone.before
          : fraction > 0.75
              ? DropZone.after
              : DropZone.into;

  switch (zone) {
    case DropZone.into:
      if (!target.capabilities.canCreateChild) return null;
      if (target.id == dragged.parentId) return null;
      return zone;
    case DropZone.before:
    case DropZone.after:
      if (target.role != FolderRole.user) return null;
      return zone;
  }
}

/// Whether [dragged] may be dropped on an account header to move it to the
/// top level of that account.
bool canDropOnRoot(MailFolder dragged, String accountId) =>
    dragged.capabilities.canMove &&
    dragged.accountId == accountId &&
    dragged.parentId != null;

/// Carry out a drop: reparent through the engine if the parent changes, then
/// record the new sibling order locally.
///
/// [target] is null for a drop on the account header, meaning the root.
Future<void> performFolderDrop(
  WidgetRef ref, {
  required MailFolder dragged,
  required MailFolder? target,
  required String accountId,
  required DropZone zone,
}) async {
  final newParentId = switch (zone) {
    DropZone.into => target?.id,
    DropZone.before || DropZone.after => target?.parentId,
  };

  var movedId = dragged.id;
  if (newParentId != dragged.parentId) {
    // The folder's id changes with its path, so take the new one from the
    // rename result rather than assuming.
    final result =
        await ref.read(foldersProvider.notifier).move(dragged.id, newParentId);
    movedId = result.newId;
  }

  // Order among the new siblings. Only user folders are orderable; system
  // folders are excluded so their fixed order is never written as overrides.
  final all = ref.read(foldersProvider).value?[accountId] ?? const [];
  final overrides = ref.read(folderOrderProvider);
  final siblings = sortedChildren(all, newParentId, overrides)
      .where((f) => f.role == FolderRole.user)
      .map((f) => f.id)
      .toList()
    ..remove(movedId);

  final int index;
  if (target == null || zone == DropZone.into) {
    index = siblings.length;
  } else {
    final at = siblings.indexOf(target.id);
    index = at < 0
        ? siblings.length
        : zone == DropZone.before
            ? at
            : at + 1;
  }
  siblings.insert(index, movedId);
  ref.read(folderOrderProvider.notifier).setOrder(siblings);
}
