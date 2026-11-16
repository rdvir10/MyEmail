import '../../domain/calendar_event.dart';
import '../../domain/meeting.dart' show Reminder;
import '../../domain/meeting_repeat.dart';

/// What a meeting's sheet asks of a calendar beyond the meeting the views
/// already read. Not part of `MailEngine`: an engine with calendars has it
/// (the app's, and the sample one the tests use), and the sheet asks
/// nothing of one that has not.

/// An engine that reads how a series repeats (calendar idea #44). The
/// views read each meeting of a series on its own, and a meeting carries
/// only its series' id: how the series repeats is the series' own, asked
/// for as the sheet opens.
abstract interface class ReadsMeetingRepeat {
  /// How the series [event] is one meeting of repeats, as its calendar
  /// keeps it; null for a meeting on its own, a series no longer there, or
  /// one that repeats in a way the app does not say. Throws as
  /// `MailEngine.respondToEvent` does.
  Future<MeetingRepeat?> meetingRepeat(CalendarEvent event);
}

/// An engine that changes the account's own copy of someone else's meeting
/// (calendar idea #45): when it reminds of it, and how it shows the
/// account. Outlook and Google keep both for each person on a meeting, and
/// a change to them is told to nobody.
abstract interface class ChangesOwnCopy {
  /// Change [event], a meeting someone else organised, on the account's
  /// own calendar alone: its [reminder], how it shows the account
  /// ([showAs]), or both; for [wholeSeries], every meeting of its series.
  /// Nobody is told. Refused with an [ArgumentError] for a meeting of the
  /// account's own, which Edit changes, telling everyone on it. Throws as
  /// `MailEngine.respondToEvent` does.
  Future<void> changeOwnCopy(
    CalendarEvent event, {
    Reminder? reminder,
    EventShowAs? showAs,
    bool wholeSeries = false,
  });
}
