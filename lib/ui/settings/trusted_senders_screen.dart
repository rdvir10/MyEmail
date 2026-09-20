import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/trusted_senders.dart';
import '../../state/trusted_senders.dart';

/// Who is allowed to load pictures without being asked, and a way to take
/// it back.
///
/// A list of exceptions nobody can see is a security hole with a friendly
/// name, so every entry made from the "Images are blocked" bar shows up
/// here, with the domain ones marked as the wider thing they are.
class TrustedSendersScreen extends ConsumerWidget {
  const TrustedSendersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final entries = sortedTrustEntries(ref.watch(trustedSendersProvider));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Senders you trust'),
        centerTitle: false,
      ),
      body: entries.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Nobody yet.\n\nWhen a message says its pictures are '
                'blocked, the menu beside Show images offers to trust that '
                'sender, or everyone at their domain. Those choices land '
                'here.',
                style: theme.textTheme.bodyMedium,
              ),
            )
          : ListView(
              children: [
                for (final entry in entries)
                  ListTile(
                    key: ValueKey(entry),
                    leading: Icon(
                      entry.startsWith('@')
                          ? Icons.domain_outlined
                          : Icons.person_outline,
                    ),
                    title: Text(describeTrustEntry(entry)),
                    trailing: IconButton(
                      tooltip: 'Stop trusting',
                      icon: const Icon(Icons.close),
                      onPressed: () =>
                          ref.read(trustedSendersProvider.notifier).forget(entry),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: Text(
                    'Their pictures are fetched as the message opens, which '
                    'tells them it was read. Everyone else is still asked '
                    'about.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
    );
  }
}
