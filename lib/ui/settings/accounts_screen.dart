import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/account.dart';
import '../../state/providers.dart';
import 'edit_account_screen.dart';
import '../accounts/add_account_screen.dart';

/// The accounts that are set up, and the only way to remove one.
///
/// Removing was reachable from nowhere until this screen existed: the engine
/// could do it and the notifier could do it, but nothing in the app called
/// either, so a mistyped address was permanent.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Accounts'), centerTitle: false),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AddAccountScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: switch (accounts) {
        AsyncError(:final error) => Center(child: Text('$error')),
        AsyncData(value: final list) when list.isEmpty => const Center(
            child: Text('No accounts yet.'),
          ),
        AsyncData(value: final list) => ListView(
            children: [
              for (final account in list)
                ListTile(
                  leading: CircleAvatar(
                    radius: 14,
                    backgroundColor: Color(account.colorValue),
                    child: Text(
                      _initial(account),
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: Colors.white),
                    ),
                  ),
                  title: Text(account.displayName),
                  subtitle: Text(account.emailAddress),
                  // The row itself opens the editor, and Remove stays an
                  // explicit button: a list where tapping a row might delete
                  // the account is one nobody taps with confidence.
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => EditAccountScreen(account: account),
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => EditAccountScreen(account: account),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _remove(context, ref, account),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 88),
            ],
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  static String _initial(Account account) {
    final source = account.displayName.trim().isEmpty
        ? account.emailAddress
        : account.displayName;
    return source.isEmpty ? '?' : source.characters.first.toUpperCase();
  }

  /// Removing takes the cached mail and the stored app password with it, so
  /// the dialog says so. Nothing is deleted on the server.
  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    Account account,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${account.emailAddress}?'),
        content: const Text(
          'Its app password and everything cached on this device go too. '
          'Nothing is deleted from the mail server, and you can add the '
          'account again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(accountsProvider.notifier).remove(account.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('${account.emailAddress} removed')),
        );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not remove it: $e')));
    }
  }
}
