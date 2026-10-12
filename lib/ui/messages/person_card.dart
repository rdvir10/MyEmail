import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/contacts/device_contacts.dart';
import '../../domain/draft.dart';
import '../../domain/mail_message.dart';
import '../../state/contact_providers.dart';
import '../compose/open_compose.dart';

/// The card for one person on a message, the sender or anyone it went to:
/// who they are, whether the phone's contacts have them, and what can be
/// done about them. Add to contacts, or Open contact for someone already
/// there; New email; Copy address.
///
/// Adding is the contacts app's own new-contact screen with the name and
/// address filled in: Ron picks the account that keeps it and saves, and
/// the app writes nothing to the address book itself.
///
/// The card only chooses. What it chose is done here once it has closed,
/// from the screen it was opened on, as the folder menu does: a new message
/// opened from inside the card would close with it. [accountId] is the
/// account a new message goes from, the one the message came to.
Future<void> showPersonCard(
  BuildContext context,
  WidgetRef ref,
  MailAddress person, {
  required String accountId,
}) async {
  final contacts = ref.read(deviceContactsProvider);
  final chosen = await showModalBottomSheet<_PersonAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => PersonCard(person: person),
  );
  if (chosen == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(text)));
  switch (chosen) {
    case _AddContact():
      if (!await contacts.add(name: person.name?.trim(), email: person.email)) {
        say('No contacts app to add them to.');
      }
    case _OpenContact(:final contact):
      if (!await contacts.open(contact)) say('No contacts app to open them in.');
    case _NewEmail():
      await openCompose(
        context,
        ref,
        kind: ComposeKind.newMessage,
        accountId: accountId,
        to: [person],
      );
    case _CopyAddress():
      await Clipboard.setData(ClipboardData(text: person.email));
      say('Address copied.');
  }
}

/// What the card closed with.
sealed class _PersonAction {
  const _PersonAction();
}

final class _AddContact extends _PersonAction {
  const _AddContact();
}

final class _OpenContact extends _PersonAction {
  const _OpenContact(this.contact);

  final DeviceContact contact;
}

final class _NewEmail extends _PersonAction {
  const _NewEmail();
}

final class _CopyAddress extends _PersonAction {
  const _CopyAddress();
}

/// The card itself; see [showPersonCard].
class PersonCard extends ConsumerWidget {
  const PersonCard({super.key, required this.person});

  final MailAddress person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = person.name?.trim() ?? '';
    // Whether the phone's contacts have them: a moment's look, and nothing
    // to say where they may not be read.
    final found = ref.watch(deviceContactProvider(person.email));
    final looking = found.isLoading;
    final contact = looking ? null : found.value;
    final filedAs = contact?.name?.trim() ?? '';
    void choose(_PersonAction action) => Navigator.of(context).pop(action);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: Text(_initial(person)),
            ),
            title: Text(
              name.isEmpty ? person.email : name,
              style: theme.textTheme.titleMedium,
            ),
            // The address on its own line, selectable, and never cut short:
            // it is what the card is about.
            subtitle: name.isEmpty ? null : SelectableText(person.email),
          ),
          if (contact != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      // Filed under another name, which is worth knowing
                      // before opening it: "Dana Levi" for "Levi, Dana".
                      filedAs.isEmpty || filedAs == name
                          ? 'In your contacts'
                          : 'In your contacts as $filedAs',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          if (looking)
            const ListTile(
              enabled: false,
              leading: SizedBox(
                width: 24,
                height: 24,
                child: Padding(
                  padding: EdgeInsets.all(3),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              title: Text('Checking your contacts…'),
            )
          else if (contact != null)
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Open contact'),
              onTap: () => choose(_OpenContact(contact)),
            )
          else
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_outlined),
              title: const Text('Add to contacts'),
              onTap: () => choose(const _AddContact()),
            ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('New email'),
            onTap: () => choose(const _NewEmail()),
          ),
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('Copy address'),
            onTap: () => choose(const _CopyAddress()),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  static String _initial(MailAddress a) {
    final d = a.display.trim();
    return d.isEmpty ? '?' : d.characters.first.toUpperCase();
  }
}
