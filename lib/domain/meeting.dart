import 'package:flutter/foundation.dart';

import 'mail_message.dart';

/// A meeting being set up: what goes on the calendar, and who is asked.
///
/// The account's own calendar keeps the event and sends the invitations, so
/// nothing here outlives the screen's Send: the server collects the answers
/// and every client the account has shows them on the event. What is here
/// is what the person typed, on the device's own clock.
@immutable
class MeetingDraft {
  const MeetingDraft({
    required this.accountId,
    required this.title,
    this.attendees = const [],
    required this.start,
    required this.end,
    this.allDay = false,
    this.location = '',
    this.notes = '',
    this.timeZone,
    this.online = false,
  });

  /// Whose calendar it goes on, and who the invitations come from.
  final String accountId;

  final String title;

  /// Everyone invited. Empty is allowed: the event still goes on the
  /// calendar, with nobody to tell.
  final List<MailAddress> attendees;

  /// On the device's clock. For a whole day, [start] is the first day and
  /// [end] the last, both at midnight, so a meeting on one day has the two
  /// equal; a calendar that wants the day after is given it on the wire.
  final DateTime start;
  final DateTime end;
  final bool allDay;

  final String location;

  /// Plain text. The calendars take it as the event's body.
  final String notes;

  /// The device's zone by its IANA name, "Asia/Jerusalem": what the times
  /// are in, and what a calendar server is told beside them. Null where the
  /// device would not say; the times then go as UTC, which every calendar
  /// reads and shows on its own clock the same.
  final String? timeZone;

  /// Held online as well, with a link to join it: Teams or Google Meet, as
  /// the account's calendar offers (see `MailEngine.onlineMeetingsFor`).
  /// The calendar makes the link and puts it on the invitation.
  final bool online;

  bool get hasAttendees => attendees.isNotEmpty;

  /// What stops this being created, as a sentence, or null when nothing
  /// does.
  String? get problem {
    if (title.trim().isEmpty) return 'Give the meeting a title.';
    if (allDay) {
      if (end.isBefore(start)) return 'The last day cannot be before the first.';
    } else if (!end.isAfter(start)) {
      return 'The meeting has to end after it starts.';
    }
    return null;
  }

  bool get isValid => problem == null;

  /// The times a calendar server is told, and the zone they are in: on the
  /// device's clock where it named its zone, in UTC otherwise. A whole day
  /// is dates, which no zone moves, so those stay as they are.
  ({DateTime start, DateTime end, String timeZone}) get asSent =>
      timeZone == null && !allDay
          ? (start: start.toUtc(), end: end.toUtc(), timeZone: 'UTC')
          : (start: start, end: end, timeZone: timeZone ?? 'UTC');
}

/// Where an account's calendar holds a meeting online, which is what the
/// screen's switch is labelled with.
enum OnlineMeetingKind {
  teams('Teams meeting', 'a Teams link'),
  skype('Skype meeting', 'a Skype link'),
  googleMeet('Google Meet', 'a Google Meet link'),
  other('Online meeting', 'an online meeting link');

  const OnlineMeetingKind(this.label, this.link);

  /// The switch's label.
  final String label;

  /// What went out with the invitation, for the message that says so.
  final String link;
}

/// What creating a meeting left behind.
@immutable
class CreatedMeeting {
  const CreatedMeeting({this.id, this.joinUrl});

  /// The event's id on the calendar, or null where the calendar did not
  /// say.
  final String? id;

  /// Where to join it online, when it was held online and the calendar
  /// said where. Null otherwise.
  final String? joinUrl;
}

/// The day after [day]'s date, at midnight: where a whole-day event ends
/// on every calendar's wire, which count the end as exclusive.
///
/// Built from the parts rather than by adding a day, which adds 24 hours
/// and lands at 23:00 or 01:00 on the day the clocks change.
DateTime dayAfter(DateTime day) => day.isUtc
    ? DateTime.utc(day.year, day.month, day.day + 1)
    : DateTime(day.year, day.month, day.day + 1);
