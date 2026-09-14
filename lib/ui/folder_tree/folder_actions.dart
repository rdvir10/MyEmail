import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/mail_engine.dart';
import '../../domain/mail_folder.dart';
import '../../state/folder_tree.dart';
import '../../state/providers.dart';

/// The long-press menu for a folder: an Outlook-style bottom sheet whose
/// entries are exactly the operations the provider allows on that folder.
///
/// Gating on [FolderCapabilities] here, rather than showing everything and
/// failing later, is the whole point of carrying the flags: a Gmail system
/// folder offers Favourite and Mark all read and nothing else, and the unified
/// Inbox offers nothing at all, so the sheet is not shown for it.
Future<void> showFolderActionsSheet(
  BuildContext context,
  WidgetRef ref,
  MailFolder folder,
) async {
  final isFavorite = ref.read(favoriteFoldersProvider).contains(folder.id);
  final actions = _availableActions(folder, isFavorite: isFavorite);
  if (actions.isEmpty) return;

  // isScrollControlled lifts the default cap of 9/16 of the screen height,
  // which a seven-entry menu exceeds on a phone. The sheet scrolls instead of
  // silently clipping its last entries.
  final chosen = await showModalBottomSheet<_FolderAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _FolderActionsSheet(folder: folder, actions: actions),
  );
  if (chosen == null || !context.mounted) return;

  final folders = ref.read(foldersProvider.notifier);
  switch (chosen) {
    case _FolderAction.favorite:
      ref.read(favoriteFoldersProvider.notifier).toggle(folder.id);
    case _FolderAction.markAllRead:
      await _guarded(context, () => folders.markAllRead(folder.id));
    case _FolderAction.rename:
      await _promptForName(
        context,
        title: 'Rename folder',
        initialValue: folder.name,
        confirmLabel: 'Rename',
        onSubmit: (name) => folders.rename(folder.id, name),
      );
    case _FolderAction.newSubfolder:
      await _promptForName(
        context,
        title: 'New folder in ${folder.name}',
        confirmLabel: 'Create',
        onSubmit: (name) => folders.create(
          accountId: folder.accountId,
          name: name,
          parentId: folder.id,
        ),
      );
    case _FolderAction.move:
      final target = await showModalBottomSheet<_MoveTarget>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _MoveFolderSheet(folder: folder),
      );
      if (target == null || !context.mounted) return;
      await _guarded(context, () => folders.move(folder.id, target.parentId));
    case _FolderAction.empty:
      final ok = await _confirm(
        context,
        title: 'Empty ${folder.name}?',
        body: 'All ${folder.totalCount} messages will be permanently deleted.',
        confirmLabel: 'Empty',
      );
      if (ok && context.mounted) {
        await _guarded(context, () => folders.empty(folder.id));
      }
    case _FolderAction.delete:
      final descendants = _descendantCount(ref, folder);
      final ok = await _confirm(
        context,
        title: 'Delete ${folder.name}?',
        body: descendants == 0
            ? 'The folder and its messages will be deleted.'
            : 'The folder, its $descendants subfolder'
                '${descendants == 1 ? '' : 's'} and all their messages will '
                'be deleted.',
        confirmLabel: 'Delete',
      );
      if (ok && context.mounted) {
        await _guarded(context, () => folders.delete(folder.id));
      }
  }
}

enum _FolderAction {
  newSubfolder('New subfolder', Icons.create_new_folder_outlined),
  rename('Rename', Icons.drive_file_rename_outline),
  move('Move to…', Icons.drive_file_move_outline),
  favorite('Add to Favourites', Icons.star_outline),
  markAllRead('Mark all as read', Icons.mark_email_read_outlined),
  empty('Empty folder', Icons.delete_sweep_outlined),
  delete('Delete', Icons.delete_outline);

  const _FolderAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

List<_FolderAction> _availableActions(
  MailFolder folder, {
  required bool isFavorite,
}) {
  final c = folder.capabilities;
  return [
    if (c.canCreateChild) _FolderAction.newSubfolder,
    if (c.canRename) _FolderAction.rename,
    if (c.canMove) _FolderAction.move,
    if (c.canFavorite) _FolderAction.favorite,
    if (c.canMarkAllRead && folder.unreadCount > 0) _FolderAction.markAllRead,
    if (c.canEmpty && folder.totalCount > 0) _FolderAction.empty,
    if (c.canDelete) _FolderAction.delete,
  ];
}

int _descendantCount(WidgetRef ref, MailFolder folder) {
  final prefix = '${folder.path}/';
  final list =
      ref.read(foldersProvider).value?[folder.accountId] ?? const <MailFolder>[];
  return list.where((f) => f.path.startsWith(prefix)).length;
}

/// Run an engine operation, reporting anything unexpected in a snackbar.
/// Capability checks upstream should make failures rare; when one happens the
/// user still needs to know the action did not take.
Future<void> _guarded(
  BuildContext context,
  Future<void> Function() operation,
) async {
  try {
    await operation();
  } on FolderOperationNotSupported catch (e) {
    if (context.mounted) _snack(context, 'That is not allowed here (${e.operation}).');
  } catch (e) {
    if (context.mounted) _snack(context, 'Something went wrong: $e');
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _FolderActionsSheet extends StatelessWidget {
  const _FolderActionsSheet({required this.folder, required this.actions});

  final MailFolder folder;
  final List<_FolderAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = displayPath(folder);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(folder.name, style: theme.textTheme.titleMedium),
                    if (path != folder.name)
                      Text(
                        path,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(),
              for (final action in actions)
                ListTile(
                  leading: Icon(
                    action.icon,
                    color: action == _FolderAction.delete
                        ? theme.colorScheme.error
                        : null,
                  ),
                  title: Text(action.label),
                  onTap: () => Navigator.of(context).pop(action),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ask for a folder name, run [onSubmit] with it, and keep the dialog open
/// with an inline message if the name collides. A conflict is an ordinary
/// thing to happen while typing a name, so it must not bounce the user out to
/// a snackbar and make them start over.
Future<void> _promptForName(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required Future<void> Function(String name) onSubmit,
  String initialValue = '',
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _NameDialog(
      title: title,
      confirmLabel: confirmLabel,
      initialValue: initialValue,
      onSubmit: onSubmit,
    ),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.confirmLabel,
    required this.initialValue,
    required this.onSubmit,
  });

  final String title;
  final String confirmLabel;
  final String initialValue;
  final Future<void> Function(String name) onSubmit;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    // Select the existing name so typing replaces it.
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialValue.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return 'Enter a name.';
    if (name.contains('/')) return 'A name cannot contain "/".';
    return null;
  }

  Future<void> _submit() async {
    final name = _controller.text.trim();
    final problem = _validate(name);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (name == widget.initialValue) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(name);
      if (mounted) Navigator.of(context).pop();
    } on FolderNameConflict {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'A folder called "$name" already exists here.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not save: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        enabled: !_busy,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'Folder name',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final theme = Theme.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// A destination for a folder move. [parentId] null means the account root.
class _MoveTarget {
  const _MoveTarget(this.parentId);

  final String? parentId;
}

/// Pick where a folder should live. Only folders in the same account that can
/// take children are offered, minus the folder itself, its own subtree, and
/// wherever it already is.
///
/// This is the folder-level move. The message-level "Move to" sheet with its
/// remembered recent destinations is milestone 4 and will share this list.
class _MoveFolderSheet extends ConsumerWidget {
  const _MoveFolderSheet({required this.folder});

  final MailFolder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final all =
        ref.watch(foldersProvider).value?[folder.accountId] ?? const [];
    final subtree = '${folder.path}/';
    final candidates = all
        .where((f) =>
            f.capabilities.canCreateChild &&
            f.id != folder.id &&
            f.id != folder.parentId &&
            !f.path.startsWith(subtree))
        .toList()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Move ${folder.name} to',
                style: theme.textTheme.titleMedium),
          ),
          const Divider(),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (folder.parentId != null)
                  ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: const Text('Top level'),
                    onTap: () =>
                        Navigator.of(context).pop(const _MoveTarget(null)),
                  ),
                for (final f in candidates)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(f.name),
                    subtitle: f.parentId == null ? null : Text(displayPath(f)),
                    onTap: () => Navigator.of(context).pop(_MoveTarget(f.id)),
                  ),
                if (candidates.isEmpty && folder.parentId == null)
                  const ListTile(
                    title: Text('Nowhere else to put it.'),
                    enabled: false,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
