import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/display_settings.dart';
import '../../state/display_providers.dart';

/// Settings, View: where the message being read goes, and how much room each
/// row in the list gets.
class ViewSettingsScreen extends ConsumerWidget {
  const ViewSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final display = ref.watch(displayProvider);
    final notifier = ref.read(displayProvider.notifier);
    final width = MediaQuery.sizeOf(context).width;

    return Scaffold(
      appBar: AppBar(title: const Text('View'), centerTitle: false),
      body: ListView(
        children: [
          const _Heading('Reading pane'),
          RadioGroup<ReadingPanePosition>(
            groupValue: display.readingPane,
            onChanged: (v) => v == null ? null : notifier.setReadingPane(v),
            child: Column(
              children: [
                for (final position in ReadingPanePosition.values)
                  RadioListTile<ReadingPanePosition>(
                    value: position,
                    title: Text(position.label),
                    subtitle: Text(position.description),
                  ),
              ],
            ),
          ),
          // Said here rather than hidden, because someone setting this on a
          // phone would otherwise change it, see nothing happen, and conclude
          // the setting is broken.
          _Note(
            width < 600
                ? 'This screen is too narrow for a reading pane, so a message '
                    'opens on its own either way. The setting applies on a '
                    'tablet, or on a phone held sideways.'
                : 'A pane on the right needs a wide screen, which in practice '
                    'means a tablet in landscape. On anything narrower, '
                    'choose Bottom to get a pane at all.',
            theme: theme,
          ),
          const Divider(height: 1),
          const _Heading('Message list'),
          RadioGroup<ListDensity>(
            groupValue: display.density,
            onChanged: (v) => v == null ? null : notifier.setDensity(v),
            child: Column(
              children: [
                for (final density in ListDensity.values)
                  RadioListTile<ListDensity>(
                    value: density,
                    title: Text(density.label),
                    subtitle: Text(switch (density.previewLines) {
                      0 => 'Two lines, no preview',
                      1 => 'Three lines with a line of preview',
                      final n => 'Three lines with $n lines of preview',
                    }),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// The one-line summary the Settings list shows under "View".
class ViewSummary {
  const ViewSummary();

  String text(WidgetRef ref) {
    final d = ref.watch(displayProvider);
    return 'Reading pane ${d.readingPane.label.toLowerCase()}, '
        '${d.density.label.toLowerCase()} list';
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        text,
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Text(
        text,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
