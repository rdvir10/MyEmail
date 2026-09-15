import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/imap/imap_mapping.dart';
import '../../domain/mail_message.dart';
import '../../state/message_providers.dart';
import '../../state/notification_providers.dart';
import '../../state/pane_widths.dart';
import '../../state/providers.dart';
import '../../domain/draft.dart';
import '../accounts/add_account_screen.dart';
import '../compose/open_compose.dart';
import '../folder_tree/folder_tree_panel.dart';
import '../messages/message_list_pane.dart';
import '../messages/reading_pane.dart';

/// Three shapes, chosen on width alone so rotating a tablet moves between
/// them without any state being rebuilt:
///
///  * phone (< 600): folder tree in a slide-out drawer, message list as the
///    body, a message opens as its own screen;
///  * medium (600–1199): tree pane and message list side by side, a message
///    still opens as its own screen;
///  * wide (>= 1200, a tablet in landscape): tree, list and reading pane.
///
/// 600dp is Material's own threshold for a list-detail layout, and the
/// reason it is not higher: a Pixel Tablet in portrait is 800dp wide, so an
/// 840dp breakpoint handed an 11-inch tablet the phone's modal drawer.
///
/// There is deliberately no logic here about which folder to show first: that
/// is derived in [effectiveSelectedFolderIdProvider], so nothing has to be
/// listening at the right moment for the default to take.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  static const double mediumBreakpoint = 600;
  static const double wideBreakpoint = 1200;
  static const double treePaneWidth = 300;
  static const double listPaneWidth = 380;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// The message a notification tap asked for, still waiting for its folder
  /// to load. Cleared as soon as it has been shown.
  String? _pendingMessageId;

  @override
  void initState() {
    super.initState();
    // After the first frame: the notifier may have to talk to the platform,
    // and selecting a folder during a build is a provider modification while
    // the tree is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openLaunchMessage());
  }

  /// A tap on a new-mail notification launched the app. Select that message's
  /// folder and remember which message to open once the list arrives.
  Future<void> _openLaunchMessage() async {
    final payload =
        await ref.read(mailNotifierProvider).takeLaunchPayload();
    if (payload == null || !mounted) return;
    final String folderId;
    try {
      (folderId, _) = splitMessageId(payload);
    } on ArgumentError {
      return; // Not a message id. Opening the app was the whole effect.
    } on FormatException {
      return;
    }
    ref.read(selectedFolderIdProvider.notifier).select(folderId);
    ref.read(selectedMessageIdProvider.notifier).select(payload);
    setState(() => _pendingMessageId = payload);
  }

  /// On the phone and medium layouts a message is its own screen, so the
  /// selection alone is not enough: something has to push it. The wide layout
  /// needs none of this, because its reading pane follows the selection.
  void _pushPendingIfResolved(double width) {
    final pending = _pendingMessageId;
    if (pending == null || width >= AppShell.wideBreakpoint) {
      if (pending != null) _pendingMessageId = null;
      return;
    }
    final message = ref.watch(selectedMessageProvider);
    if (message == null || message.id != pending) return;
    _pendingMessageId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pushMessage(context, message);
    });
  }

  @override
  Widget build(BuildContext context) {
    // First run: nothing configured yet, so the only sensible screen is the
    // one that adds an account.
    final accounts = ref.watch(accountsProvider);
    if (accounts.hasValue && accounts.value!.isEmpty) {
      return const AddAccountScreen(isFirstAccount: true);
    }

    final width = MediaQuery.sizeOf(context).width;
    _pushPendingIfResolved(width);

    if (width >= AppShell.wideBreakpoint) return const _WideLayout();
    if (width >= AppShell.mediumBreakpoint) return const _MediumLayout();
    return const _NarrowLayout();
  }
}

// -----------------------------------------------------------------------------

class _NarrowLayout extends ConsumerWidget {
  const _NarrowLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(effectiveSelectedFolderIdProvider);
    final folder =
        selectedId == null ? null : ref.watch(folderIndexProvider)[selectedId];

    return Scaffold(
      appBar: AppBar(
        title: Text(folder?.displayName ?? 'MailTree'),
        centerTitle: false,
      ),
      drawer: Drawer(
        child: SafeArea(
          // Builder gives a context below the Scaffold, so the drawer can be
          // closed through the Scaffold's own API rather than by popping
          // whatever happens to be on the navigator.
          child: Builder(
            builder: (drawerContext) => FolderTreePanel(
              onFolderSelected: (_) =>
                  Scaffold.of(drawerContext).closeDrawer(),
            ),
          ),
        ),
      ),
      body: MessageListPane(onOpen: (m) => _pushMessage(context, m)),
      floatingActionButton: const _ComposeButton(),
    );
  }
}

class _MediumLayout extends ConsumerWidget {
  const _MediumLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final panes = ref
                .watch(paneWidthsProvider)
                .fitted(constraints.maxWidth, hasReadingPane: false);
            final notifier = ref.read(paneWidthsProvider.notifier);
            return Row(
              children: [
                _TreePane(width: panes.tree),
                PaneDivider(
                  onDrag: notifier.dragTree,
                  onReset: notifier.reset,
                  label: 'Folder pane width',
                ),
                Expanded(
                  child: Column(
                    children: [
                      const _FolderTitleBar(),
                      Expanded(
                        child: MessageListPane(
                          onOpen: (m) => _pushMessage(context, m),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      floatingActionButton: const _ComposeButton(),
    );
  }
}

class _WideLayout extends ConsumerWidget {
  const _WideLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(selectedMessageProvider);

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final panes = ref
                .watch(paneWidthsProvider)
                .fitted(constraints.maxWidth, hasReadingPane: true);
            final notifier = ref.read(paneWidthsProvider.notifier);
            return Row(
              children: [
                _TreePane(width: panes.tree),
                PaneDivider(
                  onDrag: notifier.dragTree,
                  onReset: notifier.reset,
                  label: 'Folder pane width',
                ),
                SizedBox(
                  width: panes.list,
                  child: Column(
                    children: [
                      const _FolderTitleBar(),
                      // Opening a message on the wide layout only changes which
                      // one the reading pane shows; there is nothing to push.
                      Expanded(child: MessageListPane(onOpen: (_) {})),
                    ],
                  ),
                ),
                PaneDivider(
                  onDrag: notifier.dragList,
                  onReset: notifier.reset,
                  label: 'Message list width',
                ),
                Expanded(
                  child: open == null
                      ? const _NothingOpen()
                      : ReadingPane(key: ValueKey(open.id), message: open),
                ),
              ],
            );
          },
        ),
      ),
      floatingActionButton: const _ComposeButton(),
    );
  }
}

/// What the reading pane shows before anything is chosen. On a tablet this is
/// a third of the screen, so it names the folder in view rather than leaving
/// the largest pane blank.
class _NothingOpen extends ConsumerWidget {
  const _NothingOpen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selectedId = ref.watch(effectiveSelectedFolderIdProvider);
    final folder =
        selectedId == null ? null : ref.watch(folderIndexProvider)[selectedId];
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.drafts_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            folder == null
                ? 'Select a message to read'
                : 'Select a message in ${folder.displayName}',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// The draggable edge between two panes.
///
/// It looks like the one-pixel divider it replaces but takes a wider slice of
/// the screen for the gesture, because a one-pixel drag target is unusable
/// with a finger and this is the layout a tablet is held in. Double-tapping
/// puts the panes back, since a divider has no undo.
class PaneDivider extends StatefulWidget {
  const PaneDivider({
    super.key,
    required this.onDrag,
    required this.onReset,
    required this.label,
  });

  final void Function(double delta) onDrag;
  final VoidCallback onReset;
  final String label;

  static const double hitWidth = 12;

  @override
  State<PaneDivider> createState() => _PaneDividerState();
}

class _PaneDividerState extends State<PaneDivider> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragStart: (_) => setState(() => _active = true),
        onHorizontalDragEnd: (_) => setState(() => _active = false),
        onDoubleTap: widget.onReset,
        child: Semantics(
          label: widget.label,
          child: SizedBox(
            width: PaneDivider.hitWidth,
            child: Center(
              child: Container(
                width: _active ? 3 : 1,
                color: _active
                    ? scheme.primary
                    : scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------

class _TreePane extends StatelessWidget {
  const _TreePane({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: const FolderTreePanel(),
      ),
    );
  }
}

/// The selected folder's name above the message list, where the phone's app
/// bar would otherwise show it.
class _FolderTitleBar extends ConsumerWidget {
  const _FolderTitleBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selectedId = ref.watch(effectiveSelectedFolderIdProvider);
    final folder =
        selectedId == null ? null : ref.watch(folderIndexProvider)[selectedId];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  folder?.displayName ?? '',
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (folder != null && folder.unreadCount > 0)
                Text(
                  '${folder.unreadCount} unread',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// A message as its own screen, for the phone and medium layouts.
class MessageScreen extends StatelessWidget {
  const MessageScreen({super.key, required this.message});

  final MailMessage message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(message.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
        centerTitle: false,
      ),
      body: ReadingPane(message: message),
    );
  }
}

void _pushMessage(BuildContext context, MailMessage message) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => MessageScreen(message: message)),
  );
}

/// New message, on every layout. Outlook puts it bottom-right and so does
/// every mail app; putting it anywhere else would be novelty for its own sake.
class _ComposeButton extends ConsumerWidget {
  const _ComposeButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FloatingActionButton(
      tooltip: 'New message',
      onPressed: () =>
          openCompose(context, ref, kind: ComposeKind.newMessage),
      child: const Icon(Icons.edit_outlined),
    );
  }
}
