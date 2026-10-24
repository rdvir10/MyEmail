import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/row_format.dart';
import '../../state/row_formats.dart';

/// Settings, View, Conditional formatting: Outlook's rules that colour the
/// rows of the message list, by sender, by subject, or for mail sent to you
/// alone.
class RowFormatsScreen extends ConsumerWidget {
  const RowFormatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final rules = ref.watch(rowFormatsProvider);
    final notifier = ref.read(rowFormatsProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conditional formatting'),
        centerTitle: false,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add rule'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'A message that matches a rule has its sender and subject drawn '
              "in the rule's colour, in every list. The first rule a message "
              'matches is the one it gets, so put the one that matters most '
              'at the top.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          if (rules.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No rules yet. Add rule makes one: mail from hadco.com in '
                'blue, say, or mail sent only to you in bold.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          for (final (i, rule) in rules.indexed)
            ListTile(
              key: ValueKey(rule.id),
              title: Text(
                rule.summary,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: rule.colour.on(theme.brightness),
                  fontWeight: rule.bold ? FontWeight.w700 : null,
                ),
              ),
              subtitle: Text(
                '${rule.colour.label}${rule.bold ? ', bold' : ''}',
              ),
              onTap: () => _edit(context, ref, rule),
              trailing: PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (choice) => switch (choice) {
                  'up' => notifier.move(rule.id, -1),
                  'down' => notifier.move(rule.id, 1),
                  'delete' => notifier.remove(rule.id),
                  _ => _edit(context, ref, rule),
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  if (i > 0)
                    const PopupMenuItem(value: 'up', child: Text('Move up')),
                  if (i < rules.length - 1)
                    const PopupMenuItem(
                      value: 'down',
                      child: Text('Move down'),
                    ),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, RowFormat? rule) async {
    final saved = await showDialog<RowFormat>(
      context: context,
      builder: (_) => _RuleEditor(rule: rule),
    );
    if (saved != null) ref.read(rowFormatsProvider.notifier).save(saved);
  }
}

/// One rule, new or changed: what it looks for, and how a match is drawn.
class _RuleEditor extends StatefulWidget {
  const _RuleEditor({this.rule});

  final RowFormat? rule;

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late RowCondition _condition = widget.rule?.condition ?? RowCondition.from;
  late final _text = TextEditingController(text: widget.rule?.text ?? '');
  late RowColour _colour = widget.rule?.colour ?? RowColour.blue;
  late bool _bold = widget.rule?.bold ?? false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _ready => !_condition.needsText || _text.text.trim().isNotEmpty;

  void _save() {
    if (!_ready) return;
    Navigator.of(context).pop(RowFormat(
      id: widget.rule?.id ?? 'rule-${DateTime.now().microsecondsSinceEpoch}',
      condition: _condition,
      text: _condition.needsText ? _text.text.trim() : '',
      colour: _colour,
      bold: _bold,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.rule == null ? 'New rule' : 'Edit rule'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<RowCondition>(
              initialValue: _condition,
              decoration: const InputDecoration(labelText: 'Match'),
              items: [
                for (final c in RowCondition.values)
                  DropdownMenuItem(value: c, child: Text(c.label)),
              ],
              onChanged: (c) => setState(() => _condition = c ?? _condition),
            ),
            if (_condition.needsText) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                autofocus: widget.rule == null,
                decoration: InputDecoration(
                  labelText: 'Words to look for',
                  helperText: _condition.hint,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Text(_condition.hint, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            Text('Colour', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in RowColour.values)
                  ChoiceChip(
                    label: Text(c.label),
                    avatar: CircleAvatar(
                      backgroundColor: c.on(theme.brightness),
                      radius: 7,
                    ),
                    selected: c == _colour,
                    onSelected: (_) => setState(() => _colour = c),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Bold'),
              value: _bold,
              onChanged: (v) => setState(() => _bold = v),
            ),
            Text(
              'Crystal R   Re: Quote for the new line',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _colour.on(theme.brightness),
                fontWeight: _bold ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _ready ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
