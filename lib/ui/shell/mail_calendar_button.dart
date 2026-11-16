import 'package:flutter/material.dart';

import '../calendar/calendar_screen.dart' show CalendarScreen;
import '../calendar/meeting_ticker.dart';

/// The calendar, one tap from the mail where there is no ribbon to carry
/// it: the phone's top bar, and the bar over a tablet's list held upright
/// (calendar idea #98). A calendar with today's date in it, as the phone's
/// own calendar app has, beside Search. It opens the calendar as the folder
/// list's Calendar does, which stays, and Back comes back to the mail as it
/// was.
///
/// The date is the time as the meetings see it, looked at again with the
/// next meeting's "in 13 min" ([MeetingTicker]), so it turns over within
/// one of those after midnight, and at once on coming back to the app.
class MailCalendarButton extends StatelessWidget {
  const MailCalendarButton({super.key, this.compact = false});

  /// The smaller buttons of the bar over a tablet's list.
  final bool compact;

  @override
  Widget build(BuildContext context) => MeetingTicker(
        builder: (context, ref, now) => IconButton(
          key: const ValueKey('mail-calendar'),
          tooltip: 'Calendar',
          visualDensity: compact ? VisualDensity.compact : null,
          icon: _DayIcon(day: now.day, size: compact ? 20 : 24),
          onPressed: () => CalendarScreen.open(context),
        ),
      );
}

/// A calendar's outline with [day] in its body, in the icons' own colour.
class _DayIcon extends StatelessWidget {
  const _DayIcon({required this.day, required this.size});

  final int day;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          Icon(Icons.calendar_today_outlined, size: size),
          // In the body, under the band at the top: 10 to 21 of the
          // outline's 24.
          Positioned(
            left: 0,
            right: 0,
            top: size * 10 / 24,
            bottom: size * 3 / 24,
            child: Center(
              // Part of the picture: the button is named Calendar, and an
              // icon keeps its size whatever the text size.
              child: ExcludeSemantics(
                child: Text(
                  '$day',
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    color: IconTheme.of(context).color,
                    fontSize: size * 0.42,
                    fontWeight: FontWeight.w700,
                    height: 1,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
