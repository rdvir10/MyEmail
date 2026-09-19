import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/widget/home_screen_surface.dart';
import '../../domain/mail_folder.dart';
import '../../state/folder_tree.dart' show kUnifiedInboxId;
import '../../state/providers.dart';
import '../../state/widget_providers.dart';

/// Choosing which mailbox a newly placed home-screen widget counts.
///
/// Android opens the app for this, handing over the id of the widget that was
/// just dropped on the home screen. Until [finishWidgetSetup] is called the
/// placement is cancelled, so backing out of this screen leaves no
/// half-configured widget behind — which is why there is no Cancel button
/// doing anything clever: the back gesture is already correct.
class MailboxWidgetSetup extends ConsumerWidget {
  const MailboxWidgetSetup({super.key, required this.appWidgetId});

  final String appWidgetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountsProvider).value ?? const [];
    final folders = ref.watch(foldersProvider);

    Future<void> choose(String folderId) async {
      await ref.read(mailboxWidgetsProvider).setUp(
            appWidgetId: appWidgetId,
            folderId: folderId,
            engine: ref.read(mailEngineProvider),
          );
      await finishWidgetSetup();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Choose a mailbox')),
      body: folders.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not read your folders.\n$e',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
        data: (byAccount) {
          if (accounts.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Add an account first, then place the widget again.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            );
          }
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'The widget shows how many messages this mailbox holds, and '
                  'how many arrived since you last had MyEmail open.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              // Only worth offering with more than one account: with one, it
              // is the same list under a vaguer name.
              if (accounts.length > 1)
                ListTile(
                  leading: const Icon(Icons.all_inbox_outlined),
                  title: const Text('All inboxes'),
                  subtitle: const Text('Every account added together'),
                  onTap: () => choose(kUnifiedInboxId),
                ),
              for (final account in accounts) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    account.displayName,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Color(account.colorValue),
                    ),
                  ),
                ),
                for (final folder in byAccount[account.id] ?? const <MailFolder>[])
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(folder.displayName),
                    trailing: Text(
                      '${folder.totalCount}',
                      style: theme.textTheme.bodySmall,
                    ),
                    onTap: () => choose(folder.id),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}
