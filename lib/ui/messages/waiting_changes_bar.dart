import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/folder_tree.dart';
import '../../state/providers.dart';
import '../../state/waiting_changes.dart';
import '../common/bottom_message.dart';

/// A line over the list while changes made here wait for their server:
/// how many, for the account the list is of (every account's, for All
/// inboxes and Flagged), and Try now. Nothing at all otherwise.
///
/// So that a delete made on an aeroplane, which shows as done, is not
/// taken for one the server has: the line goes once the server has it.
class WaitingChangesBar extends ConsumerWidget {
  const WaitingChangesBar({super.key, required this.listId});

  /// The list it is over: a folder, or one of the lists of every account.
  final String listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = ref.watch(waitingChangesProvider);
    if (waiting.isEmpty) return const SizedBox.shrink();
    final accountId = isSyntheticList(listId)
        ? null
        : ref.watch(
            folderIndexProvider.select((index) => index[listId]?.accountId),
          );
    final count = accountId == null
        ? waiting.values.fold(0, (sum, n) => sum + n)
        : waiting[accountId] ?? 0;
    if (count == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurfaceVariant;
    return Material(
      key: const ValueKey('waiting-changes-bar'),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
        child: Row(
          children: [
            Icon(Icons.cloud_upload_outlined, size: 18, color: ink),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                count == 1
                    ? '1 change waiting to sync'
                    : '$count changes waiting to sync',
                style: theme.textTheme.bodyMedium?.copyWith(color: ink),
              ),
            ),
            TextButton(
              onPressed: () => _tryNow(context, ref),
              child: const Text('Try now'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _tryNow(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final sent = await ref
        .read(waitingChangesProvider.notifier)
        .send(evenJustMade: true);
    if (sent == null) return;
    final String said;
    if (sent.waiting == 0 && sent.failed == 0) {
      // Another sender may have sent them a moment before.
      said = sent.sent > 1 ? 'All ${sent.sent} synced.' : 'Synced.';
    } else if (sent.sent > 0) {
      said = '${sent.sent} synced. The rest go when the server answers.';
    } else if (sent.waiting > 0) {
      said = 'The server is still not answering. They go when it does.';
    } else {
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(said)));
  }
}
