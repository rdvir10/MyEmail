import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/mail_engine.dart';
import '../../domain/calendar_change.dart' show everyoneOn;
import '../../domain/calendar_event.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/mail_message.dart';
import '../../state/providers.dart';
import '../messages/date_format.dart';
import '../shell/app_shell.dart' show MessageScreen;

/// The mail about [event] (#38): messages with its title in their subject,
/// to or from the people on it, newest first. From its account's server,
/// as a search there finds them, the invitation and the answers among them.
final meetingMailProvider = FutureProvider.autoDispose
    .family<List<MailMessage>, CalendarEvent>((ref, event) async {
  final title = event.title.trim();
  if (title.isEmpty) return const [];
  final engine = ref.watch(mailEngineProvider);
  // Waited for, so the search is made once, knowing whose mail it is.
  final accounts = await ref.watch(accountsProvider.future);
  final own = accounts
          .where((a) => a.id == event.accountId)
          .map((a) => a.emailAddress)
          .firstOrNull ??
      '';
  final people = {
    for (final a in everyoneOn(event, own)) a.email.trim().toLowerCase(),
  };
  final found = await engine.searchMessages(
    title,
    SearchScope.account(event.accountId),
    field: SearchField.subject,
    limit: 50,
  );
  bool about(MailMessage m) {
    if (people.isEmpty) return true;
    final on = {
      m.from.email,
      for (final a in m.to) a.email,
      for (final a in m.cc) a.email,
    }.map((e) => e.trim().toLowerCase());
    return on.any(people.contains);
  }

  final seen = <String>{};
  return [
    for (final m in found)
      if (about(m) && seen.add(m.id)) m,
  ]..sort((a, b) => b.date.compareTo(a.date));
});

/// The mail about [event], a sheet over its own: tap one to read it.
Future<void> showMeetingMail(BuildContext context, CalendarEvent event) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _MeetingMail(event: event),
    );

class _MeetingMail extends ConsumerWidget {
  const _MeetingMail({required this.event});

  final CalendarEvent event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final found = ref.watch(meetingMailProvider(event));
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Mail about ${event.title.trim()}',
                  style: theme.textTheme.titleMedium),
            ),
            Flexible(
              child: switch (found) {
                AsyncData(:final value) when value.isEmpty => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('No mail about it was found.',
                        textAlign: TextAlign.center, style: muted),
                  ),
                AsyncData(:final value) => ListView(
                    shrinkWrap: true,
                    children: [
                      for (final m in value)
                        ListTile(
                          key: ValueKey('meeting-mail:${m.id}'),
                          title: Text(
                            m.subject.trim().isEmpty ? '(No subject)' : m.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${m.from.display} · '
                            '${formatMessageDate(m.date, use24h: use24h)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          leading: Icon(m.isMeeting
                              ? Icons.event_note_outlined
                              : Icons.mail_outline),
                          onTap: () {
                            Navigator.of(context).pop();
                            Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => MessageScreen(message: m),
                            ));
                          },
                        ),
                    ],
                  ),
                AsyncError(:final error) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      error is ReadableError
                          ? error.message
                          : 'The search did not work: $error',
                      textAlign: TextAlign.center,
                      style: muted,
                    ),
                  ),
                _ => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              },
            ),
          ],
        ),
      ),
    );
  }
}
