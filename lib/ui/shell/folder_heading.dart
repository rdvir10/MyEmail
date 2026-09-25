import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_folder.dart';
import '../../state/providers.dart';

/// The folder the list is showing, from wherever the selection points.
MailFolder? folderOnScreen(WidgetRef ref) {
  final id = ref.watch(effectiveSelectedFolderIdProvider);
  return id == null ? null : ref.watch(folderIndexProvider)[id];
}

/// Which folder the list shows, and whose: "Inbox" over the account's
/// address.
///
/// Four accounts each have an Inbox, and on a phone the tree that would say
/// whose one this is sits in a drawer. The unified Inbox belongs to no one
/// account, and says so.
class FolderHeading extends ConsumerWidget {
  const FolderHeading({super.key, this.nameStyle});

  /// The folder name's style; the owner line under it is always small.
  final TextStyle? nameStyle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final folder = folderOnScreen(ref);
    final accounts = ref.watch(accountsProvider).value ?? const [];
    final owner = folder == null
        ? null
        : folder.isSynthetic
            ? 'All accounts'
            : accounts
                .where((a) => a.id == folder.accountId)
                .firstOrNull
                ?.emailAddress;
    // Scaled down rather than cut off when a large text size makes the two
    // lines taller than the bar they sit in.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            folder?.displayName ?? 'MyEmail',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: nameStyle,
          ),
          if (owner != null && owner.isNotEmpty)
            Text(
              owner,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

/// How many are unread in the folder on screen, as a number beside the
/// title. Nothing at all when there are none.
class FolderUnreadCount extends ConsumerWidget {
  const FolderUnreadCount({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = folderOnScreen(ref)?.unreadCount ?? 0;
    if (unread == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Tooltip(
      message: '$unread unread',
      child: Semantics(
        label: '$unread unread',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '$unread',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
