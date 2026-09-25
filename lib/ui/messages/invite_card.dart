import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/calendar_invite.dart';
import '../../domain/mail_message.dart';
import '../../state/calendar_providers.dart';
import '../../state/providers.dart';
import 'date_format.dart';

/// The invitation inside a message, under its header: what, when, where,
/// who is asking, and the three answers. Cancellations say so instead.
///
/// Answering sends the reply the organizer's calendar reads, through the
/// account the invitation came to; "Add to calendar" hands the event to
/// the device's calendar app, which is where it is kept.
class InviteCard extends ConsumerStatefulWidget {
  const InviteCard({super.key, required this.message, required this.invite});

  final MailMessage message;
  final CalendarInvite invite;

  @override
  ConsumerState<InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends ConsumerState<InviteCard> {
  bool _busy = false;

  Future<void> _respond(InviteResponse response) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(mailEngineProvider)
          .respondToInvite(widget.message.id, widget.invite, response);
      ref
          .read(inviteResponsesProvider.notifier)
          .record(widget.message.id, response);
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(duration: kBottomMessage, 
          content: Text('${response.word}. The organiser has been told.'),
        ));
    } catch (e) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text('Could not reply: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addToCalendar() async {
    final i = widget.invite;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await ref.read(deviceCalendarProvider).insertEvent(
          title: i.summary,
          description: i.description,
          location: i.location,
          start: i.start,
          end: i.end,
          allDay: i.isAllDay,
        );
    if (!ok) {
      messenger?.showSnackBar(
        const SnackBar(duration: kBottomMessage, content: Text('No calendar app to add it to.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final i = widget.invite;
    final answered = ref.watch(inviteResponsesProvider)[widget.message.id];
    final calendar = ref.watch(calendarAvailableProvider).value ?? false;

    final heading = i.isCancellation
        ? 'Cancelled'
        : i.isRequest
            ? (i.sequence > 0 ? 'Invitation, updated' : 'Invitation')
            : 'Event';

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 12, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: i.isCancellation
            ? scheme.errorContainer.withValues(alpha: 0.5)
            : scheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                i.isCancellation ? Icons.event_busy : Icons.event,
                size: 20,
                color: i.isCancellation ? scheme.error : scheme.primary,
              ),
              const SizedBox(width: 8),
              Text(heading, style: theme.textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 6),
          Text(i.summary, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          _line(
            theme,
            Icons.schedule,
            describeWhen(
              i,
              use24h: MediaQuery.alwaysUse24HourFormatOf(context),
            ),
          ),
          if (i.location != null && i.location!.trim().isNotEmpty)
            _line(theme, Icons.place_outlined, i.location!),
          if (i.organizer != null)
            _line(theme, Icons.person_outline,
                'Organiser: ${i.organizer!.display}'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (answered != null)
                Chip(
                  avatar: const Icon(Icons.check, size: 16),
                  label: Text('You ${answered.word.toLowerCase()}'),
                )
              else if (i.isRequest) ...[
                FilledButton(
                  onPressed: _busy ? null : () => _respond(InviteResponse.accepted),
                  child: const Text('Accept'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _respond(InviteResponse.tentative),
                  child: const Text('Tentative'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _respond(InviteResponse.declined),
                  child: const Text('Decline'),
                ),
              ],
              // Not for a time in a zone that could not be worked out: it
              // would go in at the right hour of the wrong day's clock.
              if (calendar && !i.isCancellation && i.timeIsKnown)
                TextButton.icon(
                  onPressed: _addToCalendar,
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: const Text('Add to calendar'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _line(ThemeData theme, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
          ],
        ),
      );
}

/// "Mon 21 Sep 2026, 13:00–14:00 (Eastern Standard Time)", or the day
/// alone for a whole-day event.
///
/// Times are written the way the phone's clock is set ([use24h]).
String describeWhen(CalendarInvite i, {bool use24h = true}) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String clock(DateTime t) => formatClock(t, use24h: use24h);
  final s = i.start.isUtc ? i.start.toLocal() : i.start;
  final day = '${days[s.weekday - 1]} ${s.day} ${months[s.month - 1]} ${s.year}';
  if (i.isAllDay) return '$day, all day';
  final e = i.end == null ? null : (i.end!.isUtc ? i.end!.toLocal() : i.end!);
  var when = '$day, ${clock(s)}';
  if (e != null) {
    when += e.year == s.year && e.month == s.month && e.day == s.day
        ? '–${clock(e)}'
        : ' to ${days[e.weekday - 1]} ${e.day} ${months[e.month - 1]}, ${clock(e)}';
  }
  // A named zone the device could not apply: the time is the sender's.
  if (i.timeZone != null && !i.start.isUtc) when += ' (${i.timeZone})';
  return when;
}
