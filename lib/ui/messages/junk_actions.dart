import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/folder_role.dart';
import '../../domain/mail_message.dart';
import '../../domain/sender_blocks.dart';
import '../../domain/trusted_senders.dart' show trustDomain;
import '../../state/providers.dart';
import '../../state/sender_blocks.dart';
import '../common/bottom_message.dart';
import 'message_actions.dart';

/// Outlook's Block menu, done by the app: Block Sender, Never Block Sender,
/// Never Block Sender's Domain, and Not Junk in the Junk folder. The lists
/// are the app's own (see [SenderBlocks]); Microsoft's call for reporting
/// junk is still in preview, so Exchange's and Gmail's own filters are left
/// as they are.

/// Whether [message] is in its account's Junk folder.
bool isInJunk(WidgetRef ref, MailMessage message) =>
    ref.read(folderIndexProvider)[message.folderId]?.role == FolderRole.junk;

/// Block [message]'s sender: this message goes to Junk now, and their new
/// mail as it arrives. Undo takes both back.
Future<void> blockSender(
  BuildContext context,
  WidgetRef ref,
  String listId,
  MailMessage message,
) async {
  final blocks = ref.read(senderBlocksProvider.notifier);
  final before = ref.read(senderBlocksProvider);
  final email = message.from.email;
  blocks.block(email);
  final moved = await MessageActions(ref, listId).junk(
    context,
    [message],
    said: 'Blocked. Mail from $email goes to Junk.',
    alsoUndo: () => blocks.restore(before),
  );
  // Blocked all the same where the message could not move: what is asked
  // is about the mail to come.
  if (!moved && context.mounted) {
    _tell(context, 'Mail from $email will go to Junk.',
        undo: () => blocks.restore(before));
  }
}

/// Not Junk: [messages] back to the Inbox, and their senders never blocked
/// from now on. Undo takes both back.
Future<void> notJunk(
  BuildContext context,
  WidgetRef ref,
  String listId,
  List<MailMessage> messages,
) async {
  if (messages.isEmpty) return;
  final blocks = ref.read(senderBlocksProvider.notifier);
  final before = ref.read(senderBlocksProvider);
  for (final m in messages) {
    blocks.neverBlock(m.from.email);
  }
  final who = {for (final m in messages) m.from.email.toLowerCase()};
  await MessageActions(ref, listId).toInbox(
    context,
    messages,
    said: who.length == 1
        ? 'Moved to Inbox. ${who.single} will not be blocked.'
        : '${messages.length} moved to Inbox. Their senders will not be '
            'blocked.',
    alsoUndo: () => blocks.restore(before),
  );
}

/// Never Block Sender, or with [domain] Never Block Sender's Domain.
void neverBlock(
  BuildContext context,
  WidgetRef ref,
  MailMessage message, {
  bool domain = false,
}) {
  final email = message.from.email;
  final entry = domain ? trustDomain(email) : email;
  if (entry == null) return;
  final blocks = ref.read(senderBlocksProvider.notifier);
  final before = ref.read(senderBlocksProvider);
  blocks.neverBlock(entry);
  _tell(
    context,
    '${describeSenderEntry(entry)} will not be blocked.',
    undo: () => blocks.restore(before),
  );
}

/// Unblock Sender: off the block list, where they were on it by name.
void unblockSender(BuildContext context, WidgetRef ref, MailMessage message) {
  final email = message.from.email;
  final blocks = ref.read(senderBlocksProvider.notifier);
  final before = ref.read(senderBlocksProvider);
  blocks.forget(email);
  final domain = trustDomain(email);
  final still = domain != null && ref.read(senderBlocksProvider).blocks(email);
  _tell(
    context,
    still
        ? '$email unblocked, but everyone at ${domain.substring(1)} still is.'
        : '$email unblocked.',
    undo: () => blocks.restore(before),
  );
}

void _tell(BuildContext context, String text, {VoidCallback? undo}) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: kBottomMessage,
      persist: false,
      content: Text(text),
      action: undo == null
          ? null
          : SnackBarAction(label: 'Undo', onPressed: undo),
    ));
}
