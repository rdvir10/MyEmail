import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_folder.dart';
import '../../domain/text_direction.dart' show firstStrongDirection;
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
  const FolderHeading({super.key, this.nameStyle, this.leastScale});

  /// The folder name's style; the owner line under it is always small.
  final TextStyle? nameStyle;

  /// How small the two lines may be drawn to fit the width, before they
  /// end in "…" instead; null for as small as it takes. The phone's top
  /// bar, which the calendar's button shares (calendar idea #98): a phone
  /// 360 wide at a large text size drew an account's address at half its
  /// size. Only where nothing asks the heading's width ahead of laying it
  /// out, as the bar over a tablet's list does: it takes a [LayoutBuilder].
  final double? leastScale;

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
    return _Fitted(
      leastScale: leastScale,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Each line reads the way its first letter does, so a Hebrew
          // name cut short ends in "…" on its left, at its own end, not
          // before its first word (#98).
          Text(
            folder?.displayName ?? 'MyEmail',
            textDirection:
                firstStrongDirection(folder?.displayName ?? 'MyEmail'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: nameStyle,
          ),
          if (owner != null && owner.isNotEmpty)
            Text(
              owner,
              textDirection: firstStrongDirection(owner),
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

/// [child] scaled down to fit, as [FolderHeading] says, and no further than
/// [leastScale] for the width where there is one.
class _Fitted extends StatelessWidget {
  const _Fitted({required this.leastScale, required this.child});

  final double? leastScale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget fitted(Widget child) => FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: child,
        );
    final least = leastScale;
    if (least == null) return fitted(child);
    // Laid out no wider than would fit drawn at [least], so a longer line
    // ends in "…" there rather than being drawn any smaller.
    return LayoutBuilder(
      builder: (context, constraints) => fitted(ConstrainedBox(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth / least),
        child: child,
      )),
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
