import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/calendar_event.dart';
import '../../domain/meeting_alerts.dart';
import '../../state/calendar_view_providers.dart';
import '../../state/meeting_alert_providers.dart';
import 'calendar_screen.dart' show showEventDetails;

/// The next meeting, over the mail: "Weekly sync  in 12 min", with Join
/// where it is online, from a quarter of an hour before it until it ends,
/// as Outlook for Android shows one. A tap opens the meeting; a swipe puts
/// it away until the next.
///
/// From the day's meetings as the calendar has them: kept on the device,
/// and read again behind them every quarter of an hour while it is shown.
class NextMeetingBar extends ConsumerStatefulWidget {
  const NextMeetingBar({super.key});

  /// How often the time is looked at again.
  static const tick = Duration(seconds: 30);

  /// How often the day's meetings are read again while it is on screen.
  static const readEvery = Duration(minutes: 15);

  @override
  ConsumerState<NextMeetingBar> createState() => _NextMeetingBarState();
}

class _NextMeetingBarState extends ConsumerState<NextMeetingBar> {
  Timer? _ticking;
  DateTime? _readAt;

  @override
  void initState() {
    super.initState();
    _ticking = Timer.periodic(NextMeetingBar.tick, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticking?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(calendarAccountsProvider);
    if (accounts.isEmpty) return const SizedBox.shrink();
    final now = ref.watch(meetingClockProvider)();
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
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
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
                  TextButton(
                    key: const ValueKey('next-meeting-join'),
                    onPressed: () => joinMeeting(meeting.joinUrl!),
                    child: const Text('Join'),
                  )
                else
                  const SizedBox(height: 40),
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
