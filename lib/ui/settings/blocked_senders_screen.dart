import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/sender_blocks.dart';
import '../../domain/trusted_senders.dart' show sortedTrustEntries;
import '../../state/sender_blocks.dart';

/// The senders whose new mail goes to Junk as it arrives, and the ones
/// never sent there, as Outlook's Blocked Senders and Safe Senders lists.
/// Entries come from a message's menu (Block sender, Never block sender,
/// Not junk) or are typed here: an address, or a domain for everyone at it.
class BlockedSendersScreen extends ConsumerWidget {
  const BlockedSendersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final blocks = ref.watch(senderBlocksProvider);
    final notifier = ref.read(senderBlocksProvider.notifier);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    Widget section(
      String heading,
      String key,
      Set<String> entries,
      String empty,
      void Function(String entry) add,
    ) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(heading, style: theme.textTheme.titleSmall),
            ),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(empty, style: muted),
              ),
            for (final entry in sortedTrustEntries(entries))
              ListTile(
                key: ValueKey('$key:$entry'),
                leading: Icon(
                  entry.startsWith('@')
                      ? Icons.domain_outlined
                      : Icons.person_outline,
                ),
                title: Text(describeSenderEntry(entry)),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                  onPressed: () => notifier.forget(entry),
                ),
              ),
            _AddEntry(key: ValueKey('add-$key'), onAdd: add),
          ],
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Blocked senders'),
        centerTitle: false,
      ),
      body: ListView(
        children: [
          section(
            'Blocked',
            'blocked',
            blocks.blocked,
            'Nobody. Block sender, in a message\'s menu, adds them here.',
            notifier.block,
          ),
          const Divider(height: 24),
          section(
            'Never blocked',
            'safe',
            blocks.safe,
            'Nobody. Not junk, in the Junk folder, adds the sender here.',
            notifier.neverBlock,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Text(
              'New mail from a blocked sender goes from the Inbox to Junk as '
              'it arrives, on this phone and in the background; mail already '
              'there stays. Someone never blocked is not moved, even when '
              'everyone at their domain is blocked. The mail server\'s own '
              'junk filter is not changed.',
              style: muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// A field to type an address or a domain into, and Add.
class _AddEntry extends StatefulWidget {
  const _AddEntry({super.key, required this.onAdd});

  final void Function(String entry) onAdd;

  @override
  State<_AddEntry> createState() => _AddEntryState();
}

class _AddEntryState extends State<_AddEntry> {
  final _text = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _add() {
    final entry = SenderBlocks.entryFrom(_text.text);
    if (entry == null) {
      setState(() => _problem = 'An address, or a domain such as example.com');
      return;
    }
    widget.onAdd(entry);
    _text.clear();
    setState(() => _problem = null);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: 'Address or domain',
                  errorText: _problem,
                  isDense: true,
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            TextButton(onPressed: _add, child: const Text('Add')),
          ],
        ),
      );
}
