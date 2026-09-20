import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/draft.dart';
import '../../domain/display_settings.dart';
import '../../domain/mail_message.dart';
import '../../state/display_providers.dart';
import '../../state/message_providers.dart';
import '../../state/sync_now.dart';
import '../../state/providers.dart';
import '../../state/quick_steps.dart';
import '../../state/search_providers.dart';
import '../compose/open_compose.dart';
import '../settings/settings_screen.dart';
import '../messages/message_actions.dart';
import '../quick_steps/quick_steps_screen.dart';

/// Outlook's command bar, across the top of the three-pane layout.
///
/// Only there. On a phone these actions live where the thumb is: swipes on the
/// list, buttons in the reading pane, the compose button bottom-right. A
/// tablet in landscape has a wide empty strip at the top and a hand that is
/// nowhere near the bottom of the screen, which is the case a ribbon is for.
///
/// Everything after the first group needs a message to act on and is disabled
/// without one, rather than hidden. A bar whose buttons come and go as you
/// click around the list is harder to aim at than one that greys out.
class Ribbon extends ConsumerStatefulWidget {
  const Ribbon({super.key});

  @override
  ConsumerState<Ribbon> createState() => _RibbonState();
}

class _RibbonState extends ConsumerState<Ribbon> {
  bool _syncing = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = ref.watch(selectedMessageProvider);
    final listId = ref.watch(effectiveSelectedFolderIdProvider);
    final pane = ref.watch(displayProvider).readingPane;

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Wider than the screen, the ribbon scrolls sideways rather than
          // clipping its last buttons; when it fits, the Spacer still pushes
          // the view buttons to the right. IntrinsicWidth is what lets a
          // Row hold a Spacer inside a horizontal scroll view.
          SizedBox(
            height: 48,
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: IntrinsicWidth(child: _buttons(listId, message, pane)),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  Widget _buttons(
    String? listId,
    MailMessage? message,
    ReadingPanePosition pane,
  ) {
    // Parameters promote; the build method's local would not reach here.
    final has = message != null && listId != null;
    return Row(
      children: [
        const SizedBox(width: 4),
        _Button(
          icon: Icons.sync,
          label: 'Sync',
          busy: _syncing,
          onPressed: _syncing ? null : () => _sync(listId),
        ),
        _Button(
          icon: Icons.edit_outlined,
          label: 'New email',
          onPressed: () =>
              openCompose(context, ref, kind: ComposeKind.newMessage),
        ),
        const _Separator(),
        _Button(
          icon: Icons.delete_outline,
          label: 'Delete',
          onPressed: has
              ? () => MessageActions(ref, listId).delete(context, [message])
              : null,
        ),
        _Button(
          icon: Icons.reply,
          label: 'Reply',
          onPressed: has ? () => _compose(ComposeKind.reply, message) : null,
        ),
        _Button(
          icon: Icons.reply_all,
          label: 'Reply all',
          onPressed: has ? () => _compose(ComposeKind.replyAll, message) : null,
        ),
        _Button(
          icon: Icons.forward,
          label: 'Forward',
          onPressed: has ? () => _compose(ComposeKind.forward, message) : null,
        ),
        const _Separator(),
        _QuickStepsButton(enabled: has, message: message, listId: listId),
        _Button(
          icon: Icons.drive_file_move_outline,
          label: 'Move',
          onPressed: has
              ? () => MessageActions(
                  ref,
                  listId,
                ).moveWithPrompt(context, [message])
              : null,
        ),
        _Button(
          // The icon and the label say what pressing it will do, not
          // what the message currently is. A button labelled with the
          // present state reads as a status light.
          icon: message?.isRead ?? false
              ? Icons.mark_email_unread_outlined
              : Icons.mark_email_read_outlined,
          label: message?.isRead ?? false ? 'Unread' : 'Read',
          onPressed: has
              ? () => ref
                    .read(messagesProvider(listId).notifier)
                    .setRead(message.id, !message.isRead)
              : null,
        ),
        const Spacer(),
        const _Separator(),
        _Button(
          // Cycles right, bottom, off. The label names where the pane
          // is now, so the button is readable at a glance as well as
          // usable without looking.
          icon: pane.icon,
          label: 'Pane ${pane.label.toLowerCase()}',
          onPressed: () =>
              ref.read(displayProvider.notifier).setReadingPane(pane.next),
        ),
        const _Separator(),
        _Button(
          icon: Icons.search,
          label: 'Search',
          onPressed: () =>
              ref.read(searchFocusRequestsProvider.notifier).request(),
        ),
        const _Separator(),
        // The folder pane has Settings at its foot, but the pane can
        // be hidden, and a tablet's hand is up here anyway.
        _Button(
          icon: Icons.settings_outlined,
          label: 'Settings',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Future<void> _compose(ComposeKind kind, MailMessage original) =>
      openCompose(context, ref, kind: kind, original: original);

  /// Check now, rather than waiting for the next background pass.
  ///
  /// Refreshes the folder counts as well as the list: someone pressing this
  /// wants the whole view to be current, and a list that updated while the
  /// tree's unread counts did not looks broken.
  Future<void> _sync(String? listId) async {
    setState(() => _syncing = true);
    try {
      await syncNow(ref, listId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Could not sync: $e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }
}

/// Quick Steps, as a menu rather than a single action: there is no one Quick
/// Step to run, and a button that ran the first one would be a trap.
class _QuickStepsButton extends ConsumerWidget {
  const _QuickStepsButton({
    required this.enabled,
    required this.message,
    required this.listId,
  });

  final bool enabled;
  final MailMessage? message;
  final String? listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final steps = ref.watch(quickStepsProvider);
    final folderIndex = ref.watch(folderIndexProvider);

    return MenuAnchor(
      menuChildren: [
        for (final step in steps)
          MenuItemButton(
            leadingIcon: Icon(iconForQuickStep(step)),
            onPressed: () => _run(context, ref, step),
            child: Text(
              '${step.name}   ${describeQuickStep(step, folderIndex)}',
            ),
          ),
        if (steps.isNotEmpty) const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Icons.tune),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const QuickStepsScreen()),
          ),
          child: Text(steps.isEmpty ? 'Set up Quick Steps' : 'Manage'),
        ),
      ],
      builder: (context, controller, _) => _Button(
        icon: Icons.bolt_outlined,
        label: 'Quick Steps',
        // Openable with nothing selected only when there is nothing set up
        // yet, so the menu can still offer the way to set them up.
        onPressed: enabled || steps.isEmpty
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
      ),
    );
  }

  Future<void> _run(BuildContext context, WidgetRef ref, step) async {
    final target = message;
    final list = listId;
    if (target == null || list == null) return;
    try {
      await runQuickStep(
        step: step,
        notifier: ref.read(messagesProvider(list).notifier),
        message: target,
        onMoved: (folderId) =>
            ref.read(recentMoveTargetsProvider.notifier).record(folderId),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('${step.name} applied')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Could not apply it: $e')));
      }
    }
  }
}

/// Icon over label, which is what makes a ribbon readable at a glance and is
/// why Outlook has looked like this for twenty years.
class _Button extends StatelessWidget {
  const _Button({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    final colour = enabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurface.withValues(alpha: 0.38);

    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 20,
                width: 20,
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(2),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon, size: 20, color: colour),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(color: colour),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) => VerticalDivider(
    width: 9,
    indent: 8,
    endIndent: 8,
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
  );
}
