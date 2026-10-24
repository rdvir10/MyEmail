import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/contact_group.dart';
import '../../state/compose_providers.dart'
    show addressesLookValid, formatAddresses, parseAddresses;
import '../../state/contact_groups.dart';
import '../compose/header_fields.dart';

/// Settings, View, Contact groups: several people under one name, typed
/// into To like one person, as Outlook's contact groups are.
class ContactGroupsScreen extends ConsumerWidget {
  const ContactGroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final groups = ref.watch(contactGroupsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Contact groups'), centerTitle: false),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add),
        label: const Text('New group'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              "Type a group's name in To, Cc or Bcc and choose it: everyone in "
              'it goes in. Kept on this device and in the settings backup, '
              "not in an account's address book.",
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No groups yet. New group makes one: the site team, say, or '
                'everyone at home.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          for (final group in groups)
            ListTile(
              key: ValueKey(group.id),
              leading: const Icon(Icons.group_outlined),
              title: Text(group.name),
              subtitle: Text(
                '${group.members.length} '
                '${group.members.length == 1 ? 'person' : 'people'}: '
                '${group.members.map((m) => m.display).join(', ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _edit(context, group),
              trailing: IconButton(
                tooltip: 'Delete group',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(context, ref, group),
              ),
            ),
        ],
      ),
    );
  }

  void _edit(BuildContext context, ContactGroup? group) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ContactGroupEditor(group: group),
        ),
      );

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    ContactGroup group,
  ) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Delete ${group.name}?'),
        content: const Text(
          'The group goes; the people in it, and mail to them, stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (go == true) ref.read(contactGroupsProvider.notifier).remove(group.id);
  }
}

/// One group's name and the people in it, the people chosen as recipients
/// are, with suggestions as they are typed.
class ContactGroupEditor extends ConsumerStatefulWidget {
  const ContactGroupEditor({super.key, this.group});

  /// The group being changed, or null for a new one.
  final ContactGroup? group;

  @override
  ConsumerState<ContactGroupEditor> createState() => _ContactGroupEditorState();
}

class _ContactGroupEditorState extends ConsumerState<ContactGroupEditor> {
  late final _name = TextEditingController(text: widget.group?.name ?? '');
  late final _members = TextEditingController(
    text: widget.group == null ? '' : formatAddresses(widget.group!.members),
  );
  final _membersFocus = FocusNode();
  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    _members.dispose();
    _membersFocus.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final members = parseAddresses(_members.text);
    final problem = name.isEmpty
        ? 'Give the group a name.'
        : members.isEmpty
            ? 'Add at least one person.'
            : !addressesLookValid(members)
                ? 'One of the addresses does not look right.'
                : null;
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    // Each person once, however often they were typed.
    final seen = <String>{};
    final once = [
      for (final m in members)
        if (seen.add(m.email.toLowerCase())) m,
    ];
    ref.read(contactGroupsProvider.notifier).save(ContactGroup(
          id: widget.group?.id ??
              DateTime.now().microsecondsSinceEpoch.toRadixString(36),
          name: name,
          members: once,
        ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group == null ? 'New group' : 'Edit group'),
        centerTitle: false,
        actions: [
          TextButton(
            key: const ValueKey('save-group'),
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        children: [
          HeaderField(
            label: 'Name',
            controller: _name,
            enabled: true,
            autofocus: widget.group == null,
          ),
          RecipientField(
            label: 'People',
            controller: _members,
            focusNode: _membersFocus,
            enabled: true,
          ),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                _problem!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Text(
              'Type names or addresses, with commas between, and choose from '
              'what is suggested.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
