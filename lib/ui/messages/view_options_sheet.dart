import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/display_settings.dart';
import '../../domain/message_sort.dart';
import '../../state/display_providers.dart';
import '../settings/view_settings_screen.dart';

/// What the list looks like and what order it is in, from wherever the
/// list is.
///
/// A sheet rather than a menu: it holds a choice of three, a direction, a
/// switch and a row of densities, and a popup menu of radio items reads
/// as a list of commands that do not look like they belong together.
/// Everything here is also under Settings, View — this is the short way.
Future<void> showViewOptions(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _ViewOptions(),
    );

class _ViewOptions extends ConsumerWidget {
  const _ViewOptions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final display = ref.watch(displayProvider);
    final notifier = ref.read(displayProvider.notifier);

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Heading('Sort by', theme: theme),
            for (final field in MessageSortField.values)
              RadioListTile<MessageSortField>(
                dense: true,
                value: field,
                // ignore: deprecated_member_use
                groupValue: display.sortField,
                title: Text(field.label),
                // ignore: deprecated_member_use
                onChanged: (chosen) {
                  if (chosen != null) notifier.setSortField(chosen);
                },
              ),
            SwitchListTile(
              dense: true,
              title: Text(
                display.sortField.directionLabel(ascending: display.sortAscending),
              ),
              subtitle: Text(
                'Off: ${display.sortField.directionLabel(ascending: !display.sortAscending).toLowerCase()}',
              ),
              value: display.sortAscending,
              onChanged: notifier.setSortAscending,
            ),
            const Divider(height: 1),
            _Heading('Show', theme: theme),
            SwitchListTile(
              dense: true,
              title: const Text('Conversations'),
              subtitle: const Text('Group a thread into one row'),
              value: display.conversations,
              onChanged: notifier.setConversations,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SegmentedButton<ListDensity>(
                showSelectedIcon: false,
                segments: [
                  for (final d in ListDensity.values)
                    ButtonSegment(value: d, label: Text(d.label)),
                ],
                selected: {display.density},
                onSelectionChanged: (chosen) =>
                    notifier.setDensity(chosen.first),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('All view settings…'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ViewSettingsScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          text,
          style: theme.textTheme.labelLarge
              ?.copyWith(color: theme.colorScheme.primary),
        ),
      );
}
