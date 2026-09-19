import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/widget/home_screen_surface.dart';
import '../../data/widget/widget_state_store.dart';
import '../../domain/account.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mailbox_counts.dart';
import '../../state/folder_tree.dart';
import '../../state/providers.dart';
import '../../state/widget_providers.dart';

/// Setting up one home-screen widget, in three steps: whose mail, which
/// folder, and how it should look.
///
/// Three screens rather than one long form, because the first answer decides
/// what the second one can be. Android opens this by itself when a widget is
/// dropped on the home screen, and the Settings screen opens it again to
/// change one that is already there — the same flow either way, so there is
/// only one of it to get right.
///
/// Until the last step is finished nothing is written down. Backing out
/// leaves no half-configured widget behind, which is also what Android does
/// with the placement itself.
class MailboxWidgetSetup extends ConsumerWidget {
  const MailboxWidgetSetup({
    super.key,
    required this.appWidgetId,
    this.existing,
    this.onDone,
  });

  /// Every screen in this flow is pushed under this name, so finishing can
  /// pop the lot in one go without counting how many steps were taken.
  static const routeName = 'widget-setup';

  /// Push the flow, from a fresh placement or from the settings screen.
  static Future<void> open(
    BuildContext context, {
    required String appWidgetId,
    WidgetMailbox? existing,
    VoidCallback? onDone,
  }) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: routeName),
          builder: (_) => MailboxWidgetSetup(
            appWidgetId: appWidgetId,
            existing: existing,
            onDone: onDone,
          ),
        ),
      );

  /// Leave the flow, back to whatever pushed it.
  static void close(BuildContext context) => Navigator.of(context)
      .popUntil((route) => route.settings.name != routeName);

  final String appWidgetId;

  /// What this widget already shows, when it is being changed rather than
  /// placed. Null on a fresh placement.
  final WidgetMailbox? existing;

  /// What to do once it is set up. Null means the Android placement dance:
  /// tell Android the widget is configured, which closes the app.
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountsProvider).value ?? const [];
    final folders = ref.watch(foldersProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Choose a mailbox')),
      body: folders.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Problem('Could not read your folders.\n$e'),
        data: (byAccount) {
          if (accounts.isEmpty) {
            return const _Problem(
              'Add an account first, then place the widget again.',
            );
          }
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'The widget shows how many messages a mailbox holds, and '
                  'how many arrived since you last had MyEmail open.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              // Only worth offering with more than one account: with one, it
              // is the same folder under a vaguer name.
              if (accounts.length > 1)
                ListTile(
                  leading: const Icon(Icons.all_inbox_outlined),
                  title: const Text('All inboxes'),
                  subtitle: const Text('Every account added together'),
                  onTap: () => _choose(context, kUnifiedInboxId),
                ),
              for (final account in accounts)
                ListTile(
                  leading: Icon(Icons.account_circle,
                      color: Color(account.colorValue)),
                  title: Text(account.displayName),
                  subtitle: Text(account.emailAddress),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(name: routeName),
                      builder: (_) => _FolderStep(
                        account: account,
                        folders: byAccount[account.id] ?? const [],
                        onPick: (folderId) => _choose(context, folderId),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _choose(BuildContext context, String folderId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: routeName),
        builder: (_) => _AppearanceStep(
          appWidgetId: appWidgetId,
          mailbox: (existing ?? WidgetMailbox(folderId: folderId))
              .copyWith(folderId: folderId),
          onDone: onDone,
        ),
      ),
    );
  }
}

/// Step two: which folder, as a tree rather than a list.
///
/// Built by the same code as the folder pane in the app, so a folder sits
/// where it sits there: nested under its parent, in the same order, closed
/// until opened. A flat list of forty rows with `[Gmail]/All Mail` among
/// them is not a tree, however alphabetical it is.
class _FolderStep extends StatefulWidget {
  const _FolderStep({
    required this.account,
    required this.folders,
    required this.onPick,
  });

  final Account account;
  final List<MailFolder> folders;
  final void Function(String folderId) onPick;

  @override
  State<_FolderStep> createState() => _FolderStepState();
}

class _FolderStepState extends State<_FolderStep> {
  final _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final rows = buildTreeRows(
      FolderTreeInput(
        accounts: [widget.account],
        foldersByAccount: {widget.account.id: widget.folders},
        expandedIds: _expanded,
        // No favourites section and no unified row: this is a plain tree of
        // one account, and a folder appearing twice in a picker is a way to
        // choose the wrong one.
        favoriteIds: const {},
        showUnifiedInbox: false,
        // Hidden folders are hidden from the message list, not from someone
        // deliberately looking for a folder to count.
        showHidden: true,
      ),
    ).whereType<FolderRow>().toList();

    return Scaffold(
      appBar: AppBar(title: Text(widget.account.displayName)),
      body: ListView.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final row = rows[i];
          return ListTile(
            contentPadding: EdgeInsets.only(left: 16.0 + row.depth * 20, right: 8),
            leading: row.hasChildren
                ? IconButton(
                    tooltip: row.isExpanded ? 'Close' : 'Open',
                    icon: Icon(row.isExpanded
                        ? Icons.expand_more
                        : Icons.chevron_right),
                    onPressed: () => setState(() {
                      if (!_expanded.remove(row.folder.id)) {
                        _expanded.add(row.folder.id);
                      }
                    }),
                  )
                // Kept in the same column as the arrows, so the names of
                // folders with children and folders without still line up.
                : const SizedBox(width: 48),
            title: Text(row.folder.displayName),
            trailing: Text(
              '${row.folder.totalCount}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            onTap: () => widget.onPick(row.folder.id),
          );
        },
      ),
    );
  }
}

/// Step three: what the widget counts, and what it is called.
class _AppearanceStep extends ConsumerStatefulWidget {
  const _AppearanceStep({
    required this.appWidgetId,
    required this.mailbox,
    this.onDone,
  });

  final String appWidgetId;
  final WidgetMailbox mailbox;
  final VoidCallback? onDone;

  @override
  ConsumerState<_AppearanceStep> createState() => _AppearanceStepState();
}

class _AppearanceStepState extends ConsumerState<_AppearanceStep> {
  late WidgetCount _counts = widget.mailbox.counts;
  late final _name = TextEditingController(text: widget.mailbox.label ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    setState(() => _saving = true);
    final typed = _name.text.trim();
    await ref.read(mailboxWidgetsProvider).setUp(
          appWidgetId: widget.appWidgetId,
          mailbox: widget.mailbox.copyWith(
            counts: _counts,
            label: typed.isEmpty ? null : typed,
            clearLabel: typed.isEmpty,
          ),
          engine: ref.read(mailEngineProvider),
        );
    if (widget.onDone != null) {
      widget.onDone!();
      return;
    }
    await finishWidgetSetup();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('How it should look')),
      body: ListView(
        children: [
          const _Heading('The lower number'),
          RadioGroup<WidgetCount>(
            groupValue: _counts,
            onChanged: (v) => v == null ? null : setState(() => _counts = v),
            child: Column(
              children: [
                for (final option in WidgetCount.values)
                  RadioListTile<WidgetCount>(
                    value: option,
                    title: Text(option.label),
                    subtitle: Text(option.description),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'The red badge in the top corner always counts what arrived '
              'since you last looked, read or not.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const Divider(height: 1),
          const _Heading('What to call it'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _name,
              textInputAction: TextInputAction.done,
              maxLength: 24,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Name under the icon',
                hintText: 'Leave empty for the folder and account',
              ),
              onSubmitted: (_) => _finish(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Text(
              'One cell is about ten characters wide, so "Hadco" reads and '
              '"Hadco Inbox unread" does not.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            child: FilledButton(
              onPressed: _saving ? null : _finish,
              child: Text(_saving ? 'Saving…' : 'Done'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
}
