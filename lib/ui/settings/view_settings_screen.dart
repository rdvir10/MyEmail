import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/microsoft_oauth.dart' show MicrosoftOAuth;
import '../../data/mail_engine.dart' show PeopleSearchState;
import '../../domain/account.dart';
import '../../domain/display_settings.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../state/contact_providers.dart';
import '../../state/display_providers.dart';
import '../../state/providers.dart' show accountsProvider;
import '../accounts/google_sign_in_screen.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import 'trusted_senders_screen.dart';
import '../../state/trusted_senders.dart';
import '../../state/window_providers.dart';

/// Settings, View: light or dark, how large the text is, where the message
/// being read goes, and how much room each row in the list gets.
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
          const _Heading('Theme'),
          RadioGroup<ThemeChoice>(
            groupValue: display.theme,
            onChanged: (v) => v == null ? null : notifier.setTheme(v),
            child: Column(
              children: [
                for (final choice in ThemeChoice.values)
                  RadioListTile<ThemeChoice>(
                    value: choice,
                    title: Text(choice.label),
                    subtitle: Text(choice.description),
                  ),
              ],
            ),
          ),
          _Note(
            'Messages follow it. In the dark, the colours a message brings '
            'are turned dark as well: light backgrounds darken and dark text '
            'lightens. Pictures are left as they are.',
            theme: theme,
          ),
          const Divider(height: 1),
          const _Heading('Text size'),
          // This screen is drawn at the size being chosen, so picking one
          // shows it straight away, on these very words.
          RadioGroup<TextSize>(
            groupValue: display.textSize,
            onChanged: (v) => v == null ? null : notifier.setTextSize(v),
            child: Column(
              children: [
                for (final size in TextSize.values)
                  RadioListTile<TextSize>(
                    value: size,
                    title: Text(size.label),
                    subtitle: Text(size.description),
                  ),
              ],
            ),
          ),
          _Note(
            'For the lists, the message, and what you write. It is on top '
            "of Android's own font size, so a large size there and Large "
            'here make both larger.',
            theme: theme,
          ),
          const Divider(height: 1),
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
          const _Heading('Folder list'),
          SwitchListTile(
            title: const Text('All Inboxes'),
            subtitle: const Text(
              "A row at the top of the folder list with every account's "
              'Inbox in it.',
            ),
            value: display.showAllInboxes,
            onChanged: notifier.setShowAllInboxes,
          ),
          _Note(
            'Only there with more than one account. A long press on the row '
            'puts it away as well; this is what brings it back.',
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
                        const SnackBar(duration: kBottomMessage, 
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
          const _OnlineAddressBooks(),
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
          Consumer(
            builder: (context, ref, _) {
              final trusted = ref.watch(trustedSendersProvider);
              return ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('Senders you trust'),
                subtitle: Text(
                  trusted.isEmpty
                      ? 'Pictures load without asking for nobody yet'
                      : '${trusted.length} ${trusted.length == 1 ? 'sender loads' : 'senders load'} '
                          'pictures without asking',
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TrustedSendersScreen(),
                  ),
                ),
              );
            },
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
            'On a Microsoft account the threads are the ones Outlook shows. '
            'Elsewhere, grouped by the threading headers where a message has '
            'them, and by subject where it does not. Mail cached before this existed '
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
    final line = [
      // Left unsaid at their defaults.
      if (d.theme != ThemeChoice.system) '${d.theme.label} theme',
      'reading pane ${d.readingPane.label.toLowerCase()}',
      '${d.density.label.toLowerCase()} list',
      if (d.textSize != TextSize.standard)
        '${d.textSize.label.toLowerCase()} text',
      'swipe ${d.swipeRight.label.toLowerCase()} / '
          '${d.swipeLeft.label.toLowerCase()}',
    ].join(', ');
    return '${line[0].toUpperCase()}${line.substring(1)}';
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

/// Each account's own address book online, and whether recipients are
/// searched in it: Microsoft's people and directory for a Microsoft
/// account, Google's contacts for a Gmail one. A row per account, saying
/// how it stands and, where it is not yet allowed, a button that signs in
/// asking for it.
class _OnlineAddressBooks extends ConsumerWidget {
  const _OnlineAddressBooks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    if (accounts.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ListTile(
          title: Text('Suggest recipients from each account online'),
          subtitle: Text(
            "Microsoft's people and directory, and Google's contacts, "
            'searched as you type.',
          ),
        ),
        for (final account in accounts) _OnlineAddressBook(account: account),
        _Note(
          'What you type in To, Cc or Bcc goes to Google or Microsoft to be '
          "looked up, as it does in their own apps. A work account's "
          'organisation may have to approve this first: Allow sends them '
          'the request.',
          theme: theme,
        ),
      ],
    );
  }
}

class _OnlineAddressBook extends ConsumerStatefulWidget {
  const _OnlineAddressBook({required this.account});

  final Account account;

  @override
  ConsumerState<_OnlineAddressBook> createState() => _OnlineAddressBookState();
}

class _OnlineAddressBookState extends ConsumerState<_OnlineAddressBook> {
  bool _busy = false;

  Account get account => widget.account;

  /// A sign-in that asks for the address book beside the mail. The account
  /// keeps everything cached: it is the same sign-in again Settings,
  /// Accounts offers. A Gmail account on an app password moves to Google
  /// sign-in by it, which is the only way its contacts can be reached.
  Future<void> _allow() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      switch (account.provider) {
        case MailProvider.outlook:
          final token = await MicrosoftSignInScreen.show(
            context,
            loginHint: account.emailAddress,
            scopes: [...MicrosoftOAuth.scopes, ...MicrosoftOAuth.peopleScopes],
          );
          if (token == null) return;
          await ref
              .read(accountsProvider.notifier)
              .signInAgain(accountId: account.id, token: token);
        case MailProvider.gmail:
          final result = await GoogleSignInScreen.show(
            context,
            loginHint: account.emailAddress,
          );
          if (result == null) return;
          await ref.read(accountsProvider.notifier).signInAgain(
                accountId: account.id,
                token: result.token,
                signedInAs: result.identity?.email,
              );
      }
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: kBottomMessage,
          content: Text(e is ReadableError ? e.message : '$e'),
        ));
    } finally {
      ref.invalidate(peopleSearchAccessProvider(account.id));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(peopleSearchAccessProvider(account.id));
    final state = access.value?.state;
    final (String line, bool offer) = switch (state) {
      null => ('Checking…', false),
      PeopleSearchState.on => ('Searched as you type.', false),
      PeopleSearchState.needsSignIn => (
          'Not allowed yet. Allow, then sign in to allow it.',
          true,
        ),
      // Microsoft gives the same refusal whether the person or only their
      // organisation can allow it, so the line says both.
      PeopleSearchState.needsAdministrator => (
          'Not allowed yet. Allow, then sign in to allow it. Where your '
              'organisation has to approve it, the sign-in sends them the '
              'request, and once they have it starts on its own.',
          true,
        ),
      PeopleSearchState.notPossible => account.provider == MailProvider.gmail
          ? (
              'Uses an app password, which reaches mail only. Allow signs '
                  'it in with Google instead.',
              true,
            )
          : ('Not possible for this account.', false),
      PeopleSearchState.switchedOff => (
          access.value?.message ?? 'Switched off where the app is registered.',
          false,
        ),
      PeopleSearchState.unknown => (
          'Could not check just now. ${access.value?.message ?? ''}'.trim(),
          false,
        ),
    };
    return ListTile(
      leading: Icon(
        state == PeopleSearchState.on
            ? Icons.cloud_done_outlined
            : Icons.cloud_off_outlined,
      ),
      title: Text(account.emailAddress),
      subtitle: Text(line),
      trailing: _busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : offer
              ? TextButton(onPressed: _allow, child: const Text('Allow'))
              : null,
    );
  }
}
