import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/contacts/device_contacts.dart';
import '../../domain/calendar_event.dart';
import '../../domain/calendar_finding.dart';
import '../../domain/draft.dart';
import '../../domain/mail_message.dart';
import '../../state/calendar_view_providers.dart';
import '../../state/contact_providers.dart';
import '../../state/sync_providers.dart' show syncSettingsProvider;
import '../calendar/calendar_screen.dart' show CalendarScreen;
import '../calendar/calendar_search_screen.dart';
import '../compose/open_compose.dart';
import 'date_format.dart';

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
    case _OpenMeeting(:final event):
      await CalendarScreen.open(context, day: event.start, event: event);
    case _AllMeetings():
      await CalendarSearchScreen.open(context, query: person.email);
    case _CopyAddress():
      await Clipboard.setData(ClipboardData(text: person.email));
      say('Address copied.');
    case _Vip(:final vip):
      await ref.read(syncSettingsProvider.notifier).setVip(person.email, vip);
      say(vip ? '${person.display} is a VIP.' : '${person.display} is no '
          'longer a VIP.');
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

final class _OpenMeeting extends _PersonAction {
  const _OpenMeeting(this.event);

  final CalendarEvent event;
}

final class _AllMeetings extends _PersonAction {
  const _AllMeetings();
}

final class _Vip extends _PersonAction {
  const _Vip(this.vip);

  final bool vip;
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
          // Outlook's contact card: the meetings you have with them.
          _MeetingsWith(person: person, choose: choose),
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('Copy address'),
            onTap: () => choose(const _CopyAddress()),
          ),
          // Outlook's VIPs: whose mail is worth a notification, even on an
          // account set to tell of nobody else's.
          if (ref
                  .watch(syncSettingsProvider)
                  .value
                  ?.vips
                  .contains(person.email.trim().toLowerCase()) ??
              false)
            ListTile(
              key: const ValueKey('person-vip-off'),
              leading: const Icon(Icons.star),
              title: const Text('Remove from VIPs'),
              onTap: () => choose(const _Vip(false)),
            )
          else
            ListTile(
              key: const ValueKey('person-vip-on'),
              leading: const Icon(Icons.star_outline),
              title: const Text('Add to VIPs'),
              onTap: () => choose(const _Vip(true)),
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

/// The next meeting with [person] and the last, from a year either way of
/// every calendar, and All meetings, the calendar searched for them.
/// Nothing where there is no calendar, or no meeting with them.
class _MeetingsWith extends ConsumerWidget {
  const _MeetingsWith({required this.person, required this.choose});

  final MailAddress person;
  final void Function(_PersonAction action) choose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(calendarAccountsProvider).isEmpty) {
      return const SizedBox.shrink();
    }
    final now = DateTime.now();
    final load = ref.watch(calendarEventsProvider(searchSpan(now))).value;
    final found = meetingsWith(load?.events ?? const [], person.email, now);
    if (found.next == null && found.last == null) {
      return const SizedBox.shrink();
    }
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String when(CalendarEvent e) => e.allDay
        ? formatDay(e.start)
        : '${formatDay(e.start)}, ${formatClock(e.start, use24h: use24h)}';
    String title(CalendarEvent e) =>
        e.title.trim().isEmpty ? '(No title)' : e.title.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (found.next case final next?)
          ListTile(
            key: const ValueKey('person-next-meeting'),
            leading: const Icon(Icons.event_outlined),
            title: Text('Next: ${title(next)}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(when(next)),
            onTap: () => choose(_OpenMeeting(next)),
          ),
        if (found.last case final last?)
          ListTile(
            key: const ValueKey('person-last-meeting'),
            leading: const Icon(Icons.history),
            title: Text('Last: ${title(last)}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(when(last)),
            onTap: () => choose(_OpenMeeting(last)),
          ),
        ListTile(
          key: const ValueKey('person-all-meetings'),
          leading: const Icon(Icons.manage_search),
          title: const Text('All meetings with them'),
          onTap: () => choose(const _AllMeetings()),
        ),
      ],
    );
  }
}
