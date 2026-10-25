import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../domain/account.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../state/providers.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import '../common/bottom_message.dart';

/// The Microsoft accounts a shared mailbox can be reached through: signed
/// in themselves, not shared mailboxes of their own.
List<Account> sharedMailboxOwners(List<Account> accounts) => [
      for (final a in accounts)
        if (a.provider == MailProvider.outlook &&
            a.authMethod == AuthMethod.oauth &&
            a.sharedVia == null)
          a,
    ];

/// Outlook's Add shared mailbox: a mailbox someone has given your
/// Microsoft account access to, info@ or sales@, added as an account of its
/// own and reached through that account's sign-in. Nothing is signed in for
/// it; the owner's sign-in asks Microsoft for mailboxes shared with it.
class AddSharedMailboxScreen extends ConsumerStatefulWidget {
  const AddSharedMailboxScreen({super.key});

  @override
  ConsumerState<AddSharedMailboxScreen> createState() =>
      _AddSharedMailboxScreenState();
}

class _AddSharedMailboxScreenState
    extends ConsumerState<AddSharedMailboxScreen> {
  final _address = TextEditingController();
  final _name = TextEditingController();
  String? _via;
  bool _busy = false;
  String? _problem;

  /// The last refusal was the sign-in not reaching shared mailboxes, which
  /// a sign-in again that asks for them clears.
  bool _offerAllow = false;

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    super.dispose();
  }

  Account? _owner(List<Account> owners) =>
      owners.where((a) => a.id == _via).firstOrNull ?? owners.firstOrNull;

  Future<void> _add(Account owner) async {
    final address = _address.text.trim();
    if (!address.contains('@') || address.endsWith('@')) {
      setState(() => _problem = 'Type the shared mailbox\'s address.');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _problem = null;
      _offerAllow = false;
    });
    try {
      final name = _name.text.trim();
      await ref.read(accountsProvider.notifier).addSharedMailbox(
            viaAccountId: owner.id,
            emailAddress: address,
            displayName: name.isEmpty ? address.split('@').first : name,
          );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: kBottomMessage,
          persist: false,
          content: Text('$address added.'),
        ));
      navigator.pop();
    } on SignInNeedsConsent catch (e) {
      if (mounted) {
        setState(() {
          _problem = e.needsAdministrator
              ? 'Not allowed yet. Allow, then sign in to ${owner.emailAddress}. '
                  'Where your organisation has to approve it, the sign-in '
                  'sends them the request.'
              : 'Not allowed yet. Allow, then sign in to '
                  '${owner.emailAddress} to allow the app into mailboxes '
                  'shared with it.';
          _offerAllow = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _problem = e is ReadableError ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A sign-in again for the account the mailbox is shared with, asking for
  /// shared mailboxes beside its own mail, then the add again.
  Future<void> _allow(Account owner) async {
    final token = await MicrosoftSignInScreen.show(
      context,
      loginHint: owner.emailAddress,
      scopes: [...MicrosoftOAuth.scopes, ...MicrosoftOAuth.sharedMailboxScopes],
    );
    if (token == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(accountsProvider.notifier)
          .signInAgain(accountId: owner.id, token: token);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _problem = e is ReadableError ? e.message : '$e';
        });
      }
      return;
    }
    if (mounted) await _add(owner);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final owners =
        sharedMailboxOwners(ref.watch(accountsProvider).value ?? const []);
    final owner = _owner(owners);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('Add a shared mailbox'), centerTitle: false),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (owner == null)
                const Text(
                  'A shared mailbox is reached through a Microsoft account '
                  'it is shared with. Add that account first.',
                )
              else ...[
                Text(
                  'A mailbox someone has given your Microsoft account access '
                  'to, such as info@ or sales@. It is added as an account of '
                  'its own, reached through the account it is shared with.',
                  style: muted,
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  key: const ValueKey('shared-via'),
                  initialValue: owner.id,
                  decoration:
                      const InputDecoration(labelText: 'Shared with'),
                  items: [
                    for (final a in owners)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text(a.emailAddress),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (id) => setState(() {
                            _via = id;
                            _problem = null;
                            _offerAllow = false;
                          }),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('shared-address'),
                  controller: _address,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: "The shared mailbox's address",
                  ),
                  onChanged: (_) {
                    if (_problem != null) {
                      setState(() {
                        _problem = null;
                        _offerAllow = false;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('shared-name'),
                  controller: _name,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Name in the folder list',
                    hintText: 'Info, Sales…',
                  ),
                ),
                if (_problem != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _problem!,
                    key: const ValueKey('shared-problem'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 20),
                if (_busy)
                  const Center(child: CircularProgressIndicator())
                else if (_offerAllow)
                  FilledButton(
                    key: const ValueKey('shared-allow'),
                    onPressed: () => _allow(owner),
                    child: const Text('Allow'),
                  )
                else
                  FilledButton(
                    key: const ValueKey('shared-add'),
                    onPressed: () => _add(owner),
                    child: const Text('Add'),
                  ),
                const SizedBox(height: 16),
                Text(
                  'Mail sent from it goes out as the shared mailbox where '
                  'you have been given Send As, or on its behalf with Send '
                  'on Behalf; the administrator sets which.',
                  style: muted,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
