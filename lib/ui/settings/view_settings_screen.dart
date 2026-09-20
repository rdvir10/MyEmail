import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/display_settings.dart';
import '../../state/contact_providers.dart';
import '../../state/display_providers.dart';
import '../../state/window_providers.dart';

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
          const _Heading('Writing'),
          Consumer(
            builder: (context, ref, _) {
              final available =
                  ref.watch(windowsAvailableProvider).value ?? false;
              return SwitchListTile(
                title: const Text('Write in a new window'),
                subtitle: Text(
                  available
                      ? 'New messages and replies open beside the mailbox '
                          'rather than on top of it.'
                      : 'Not on this device.',
                ),
                value: available && ref.watch(composeInWindowProvider),
                onChanged: available
                    ? (on) =>
                        ref.read(composeInWindowProvider.notifier).set(on)
                    : null,
              );
            },
          ),
          Consumer(
            builder: (context, ref, _) {
              final allowed = ref.watch(contactsAccessProvider).value ?? false;
              return SwitchListTile(
                title: const Text('Suggest recipients from contacts'),
                subtitle: Text(
                  allowed
                      ? 'People you have mailed are suggested too.'
                      : 'Without this, only people you have already mailed '
                          'are suggested.',
                ),
                value: allowed,
                onChanged: (on) async {
                  if (on) {
                    await ref.read(contactsAccessProvider.notifier).ask();
                    return;
                  }
                  // A permission is Android's to take back, not ours.
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text(
                            'To stop this, turn off Contacts for MyEmail in '
                            'Android Settings.',
                          ),
                        ),
                      );
                  }
                },
              );
            },
          ),
          _Note(
            'Asked for once, the first time you write a message. Nothing is '
            'read from your contacts until you type in a recipient field, '
            'and nothing about them leaves the tablet.',
            theme: theme,
          ),
          const Divider(height: 1),
          const _Heading('Pictures in messages'),
          SwitchListTile(
            title: const Text('Load pictures automatically'),
            subtitle: const Text(
              'Shows a message as its sender built it, without tapping '
              'Show images each time.',
            ),
            value: display.alwaysShowImages,
            onChanged: notifier.setAlwaysShowImages,
          ),
          _Note(
            'What you give up: a picture is fetched from the sender as the '
            'message opens, so they learn when you read it, on what, and '
            'roughly from where. Worth it for mail from shops, where the '
            'pictures are the message; less so for mail you did not ask for.',
            theme: theme,
          ),
          const Divider(height: 1),
          const _Heading('Conversations'),
          SwitchListTile(
            title: const Text('Group into conversations'),
            subtitle: const Text(
              'A reply and the message it answers share one row, which opens '
              'to show the thread.',
            ),
            value: display.conversations,
            onChanged: notifier.setConversations,
          ),
          _Note(
            'Grouped by the threading headers where a message has them, and '
            'by subject where it does not. Mail cached before this existed '
            'has none until its folder next syncs.',
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
          const Divider(height: 1),
          const _Heading('Swipe actions'),
          _SwipeChoice(
            title: 'Swipe right',
            hint: 'Dragging a row from left to right',
            value: display.swipeRight,
            onChanged: notifier.setSwipeRight,
          ),
          _SwipeChoice(
            title: 'Swipe left',
            hint: 'Dragging a row from right to left',
            value: display.swipeLeft,
            onChanged: notifier.setSwipeLeft,
          ),
          _Note(
            'Set a direction to Nothing and rows stop dragging that way, '
            'rather than sliding and springing back as though the swipe had '
            'been missed. Archive needs an Archive folder on the account; '
            'Gmail has none, because archiving there removes a label instead '
            'of moving the message.',
            theme: theme,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// One direction's action, as a dropdown rather than another radio list.
///
/// Two directions times six actions would be twelve radio rows for a setting
/// almost nobody changes twice, and it would bury the density options above
/// it under a wall of choices.
class _SwipeChoice extends StatelessWidget {
  const _SwipeChoice({
    required this.title,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final SwipeAction value;
  final ValueChanged<SwipeAction> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(title),
        subtitle: Text(hint),
        trailing: DropdownButton<SwipeAction>(
          value: value,
          underline: const SizedBox.shrink(),
          onChanged: (v) => v == null ? null : onChanged(v),
          items: [
            for (final action in SwipeAction.values)
              DropdownMenuItem(
                value: action,
                child: Text(action.label),
              ),
          ],
        ),
      );
}

/// The one-line summary the Settings list shows under "View".
class ViewSummary {
  const ViewSummary();

  String text(WidgetRef ref) {
    final d = ref.watch(displayProvider);
    return 'Reading pane ${d.readingPane.label.toLowerCase()}, '
        '${d.density.label.toLowerCase()} list, '
        'swipe ${d.swipeRight.label.toLowerCase()} / '
        '${d.swipeLeft.label.toLowerCase()}';
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
