import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/calendar_event.dart';
import '../../domain/meeting_alerts.dart';
import '../../state/calendar_view_providers.dart';
import '../../state/meeting_alert_providers.dart';
import '../common/tap_target.dart';
import 'calendar_screen.dart' show showEventDetails;
import 'meeting_ticker.dart';

/// The next meeting, over the mail: "Weekly sync  in 12 min", with Join
/// where it is online, from a quarter of an hour before it until it ends,
/// as Outlook for Android shows one. A tap opens the meeting; a swipe puts
/// it away until the next.
///
/// From the day's meetings as the calendar has them: kept on the device,
/// and read again behind them every quarter of an hour while it is shown.
class NextMeetingBar extends StatefulWidget {
  const NextMeetingBar({super.key});

  /// How often the day's meetings are read again while it is on screen.
  static const readEvery = Duration(minutes: 15);

  @override
  State<NextMeetingBar> createState() => _NextMeetingBarState();
}

class _NextMeetingBarState extends State<NextMeetingBar> {
  DateTime? _readAt;

  /// The time looked at again every [MeetingTicker.tick], which the
  /// Agenda's "Now" goes by too (#91).
  @override
  Widget build(BuildContext context) => MeetingTicker(builder: _bar);

  Widget _bar(BuildContext context, WidgetRef ref, DateTime now) {
    final accounts = ref.watch(calendarAccountsProvider);
    if (accounts.isEmpty) return const SizedBox.shrink();
    final range = dayRange(now);
    final readAt = _readAt;
    if (readAt == null) {
      _readAt = now;
    } else if (now.difference(readAt) > NextMeetingBar.readEvery) {
      _readAt = now;
      // A meeting made or moved elsewhere since: read again behind the bar.
      scheduleMicrotask(() {
        if (mounted) ref.invalidate(calendarEventsProvider(range));
      });
    }
    final load = ref.watch(calendarEventsProvider(range)).value;
    final meeting = nextMeeting(
      load?.events ?? const [],
      now,
      dismissed: ref.watch(meetingBarDismissedProvider),
    );
    if (meeting == null) return const SizedBox.shrink();
    final account =
        accounts.where((a) => a.id == meeting.accountId).firstOrNull;
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSecondaryContainer;
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    return Dismissible(
      key: ValueKey('next-meeting:${meetingKey(meeting)}'),
      onDismissed: (_) =>
          ref.read(meetingBarDismissedProvider.notifier).dismiss(meeting),
      child: Material(
        color: theme.colorScheme.secondaryContainer,
        child: InkWell(
          key: const ValueKey('next-meeting-bar'),
          onTap: () => showEventDetails(context, ref, meeting, account),
          child: Padding(
            // No room above and below: Join, 48 to tap (#90), is the bar's
            // height, as the 4 each way and its 40 were.
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 28,
                  decoration: BoxDecoration(
                    color: account == null
                        ? theme.colorScheme.primary
                        : Color(account.colorValue),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Icon(Icons.event, size: 18, color: ink),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: _titleOf(meeting),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: '  ${startsText(meeting, now, use24h: use24h)}',
                      ),
                    ]),
                    key: const ValueKey('next-meeting-text'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: ink),
                  ),
                ),
                if (meeting.joinUrl != null)
                  TapTarget(
                    child: TextButton(
                      key: const ValueKey('next-meeting-join'),
                      onPressed: () => joinMeeting(meeting.joinUrl!),
                      child: const Text('Join'),
                    ),
                  )
                else
                  const SizedBox(height: kMinInteractiveDimension),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _titleOf(CalendarEvent e) =>
    e.title.trim().isEmpty ? '(No title)' : e.title.trim();

/// Open [url], a meeting's link, in the app it belongs to: Teams, Meet,
/// Zoom.
Future<void> joinMeeting(String url) async {
  final uri = Uri.tryParse(url);
  if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
}
