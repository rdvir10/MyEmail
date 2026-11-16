import '../../domain/calendar_event.dart';
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
