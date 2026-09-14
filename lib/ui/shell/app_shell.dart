import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../folder_tree/folder_tree_panel.dart';
import '../messages/message_list_pane.dart';
import '../messages/reading_pane.dart';

/// Three shapes, chosen on width alone so rotating a tablet moves between
/// them without any state being rebuilt:
///
///  * phone (< 840): folder tree in a slide-out drawer, message list as the
///    body, a message opens as its own screen;
///  * medium (840–1199): tree pane and message list side by side, a message
///    still opens as its own screen;
///  * wide (>= 1200, a tablet in landscape): tree, list and reading pane.
///
/// There is deliberately no logic here about which folder to show first: that
/// is derived in [effectiveSelectedFolderIdProvider], so nothing has to be
/// listening at the right moment for the default to take.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  static const double mediumBreakpoint = 840;
  static const double wideBreakpoint = 1200;
  static const double treePaneWidth = 300;
  static const double listPaneWidth = 380;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= wideBreakpoint) return const _WideLayout();
    if (width >= mediumBreakpoint) return const _MediumLayout();
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
    );
  }
}

class _MediumLayout extends StatelessWidget {
  const _MediumLayout();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            const _TreePane(),
            const VerticalDivider(width: 1),
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
        ),
      ),
    );
  }
}

class _WideLayout extends ConsumerWidget {
  const _WideLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(selectedMessageProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            const _TreePane(),
            const VerticalDivider(width: 1),
            SizedBox(
              width: AppShell.listPaneWidth,
              child: Column(
                children: [
                  const _FolderTitleBar(),
                  // Opening a message on the wide layout only changes which
                  // one the reading pane shows; there is nothing to push.
                  Expanded(child: MessageListPane(onOpen: (_) {})),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: open == null
                  ? Center(
                      child: Text(
                        'Select a message to read',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ReadingPane(key: ValueKey(open.id), message: open),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------

class _TreePane extends StatelessWidget {
  const _TreePane();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppShell.treePaneWidth,
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
