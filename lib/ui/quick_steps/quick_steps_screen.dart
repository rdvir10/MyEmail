import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/account.dart';
import '../../domain/quick_step.dart';
import '../../state/folder_tree.dart';
import '../../state/providers.dart';
import '../../state/quick_steps.dart';

/// Manage Quick Steps: add, edit, reorder, delete.
class QuickStepsScreen extends ConsumerWidget {
  const QuickStepsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final steps = ref.watch(quickStepsProvider);
    final index = ref.watch(folderIndexProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Quick Steps'), centerTitle: false),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
      body: steps.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Quick Steps apply several actions to a message in one tap.\n'
                  'For example: mark as read, then move to Archive.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: steps.length,
              // onReorderItem, not onReorder: it hands back an index already
              // adjusted for the removed row, so the notifier does not have
              // to second-guess it.
              onReorderItem: (from, to) =>
                  ref.read(quickStepsProvider.notifier).reorder(from, to),
              itemBuilder: (context, i) {
                final step = steps[i];
                return ListTile(
                  key: ValueKey(step.id),
                  leading: Icon(iconForQuickStep(step)),
                  title: Text(step.name),
                  subtitle: Text(describeQuickStep(step, index)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: () =>
                        ref.read(quickStepsProvider.notifier).remove(step.id),
                  ),
                  onTap: () => _edit(context, ref, step),
                );
              },
            ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    QuickStep? existing,
  ) async {
    final result = await Navigator.of(context).push<QuickStep>(
      MaterialPageRoute(builder: (_) => _EditQuickStepScreen(step: existing)),
    );
    if (result == null) return;
    final notifier = ref.read(quickStepsProvider.notifier);
    existing == null ? notifier.add(result) : notifier.update(result);
  }
}

/// "Mark as read, then Move to Archive" — what the step will actually do,
/// with anything unreachable after a move or delete left out.
String describeQuickStep(QuickStep step, Map<String, dynamic> folderIndex) {
  return [
    for (final a in step.effectiveActions)
      a.type.needsFolder
          ? '${a.type.label} ${folderIndex[a.folderId]?.displayName ?? '(missing folder)'}'
          : a.type.label,
  ].join(', then ');
}

/// Derived from what the step ends up doing. Deliberately not a stored icon
/// code point: a non-const IconData defeats Flutter's icon tree-shaking and
/// would drag the whole Material font into the APK.
IconData iconForQuickStep(QuickStep step) {
  final last = step.effectiveActions.last.type;
  return switch (last) {
    QuickStepActionType.moveTo => Icons.drive_file_move_outline,
    QuickStepActionType.delete => Icons.delete_outline,
    QuickStepActionType.flag || QuickStepActionType.unflag => Icons.flag_outlined,
    _ => Icons.bolt_outlined,
  };
}

class _EditQuickStepScreen extends ConsumerStatefulWidget {
  const _EditQuickStepScreen({this.step});

  final QuickStep? step;

  @override
  ConsumerState<_EditQuickStepScreen> createState() =>
      _EditQuickStepScreenState();
}

class _EditQuickStepScreenState extends ConsumerState<_EditQuickStepScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.step?.name ?? '');
  late List<QuickStepAction> _actions =
      List.of(widget.step?.actions ?? const []);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give it a name.');
      return;
    }
    if (_actions.isEmpty) {
      setState(() => _error = 'Add at least one action.');
      return;
    }
    final step = QuickStep(
      id: widget.step?.id ?? QuickSteps.newId(),
      name: name,
      actions: _actions,
    );
    Navigator.of(context).pop(step);
  }

  Future<void> _addAction() async {
    final type = await showModalBottomSheet<QuickStepActionType>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in QuickStepActionType.values)
                ListTile(
                  title: Text(t.label),
                  onTap: () => Navigator.of(context).pop(t),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (type == null || !mounted) return;

    String? folderId;
    if (type.needsFolder) {
      folderId = await _pickFolder();
      if (folderId == null || !mounted) return;
    }
    setState(() {
      _actions = [..._actions, QuickStepAction(type, folderId: folderId)];
      _error = null;
    });
  }

  Future<String?> _pickFolder() async {
    final folders = ref.read(foldersProvider).value ?? const {};
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    final names = {for (final a in accounts) a.id: a.displayName};
    final order = {for (final (i, a) in accounts.indexed) a.id: i};
    // By account, then by path, and each row says whose it is: with two
    // Microsoft accounts every Inbox and Archive came twice, unlabelled.
    final options = [
      for (final list in folders.values)
        for (final f in list)
          if (f.capabilities.canAcceptMessages) f,
    ]..sort((a, b) {
        final byAccount =
            (order[a.accountId] ?? 0).compareTo(order[b.accountId] ?? 0);
        if (byAccount != 0) return byAccount;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });

    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final f in options)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(f.displayName),
                  subtitle: Text(
                    accounts.length < 2
                        ? displayPath(f)
                        : '${names[f.accountId] ?? f.accountId} · '
                            '${displayPath(f)}',
                  ),
                  onTap: () => Navigator.of(context).pop(f.id),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = ref.watch(folderIndexProvider);
    final terminalAt = _actions.indexWhere((a) => a.type.isTerminal);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.step == null ? 'New Quick Step' : 'Edit Quick Step'),
        centerTitle: false,
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _name,
            autofocus: widget.step == null,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: 'File and mark read',
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 24),
          Text('Actions', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final (i, a) in _actions.indexed)
            ListTile(
              key: ValueKey('$i:${a.type}:${a.folderId}'),
              dense: true,
              leading: Text('${i + 1}.'),
              title: Text(
                a.type.needsFolder
                    ? '${a.type.label} ${index[a.folderId]?.displayName ?? '(missing folder)'}'
                    : a.type.label,
              ),
              subtitle: terminalAt >= 0 && i > terminalAt
                  ? Text(
                      'Never runs: the message has already left the list.',
                      style: TextStyle(color: theme.colorScheme.error),
                    )
                  : null,
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Remove',
                onPressed: () => setState(() {
                  _actions = [..._actions]..removeAt(i);
                }),
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addAction,
            icon: const Icon(Icons.add),
            label: const Text('Add action'),
          ),
        ],
      ),
    );
  }
}
