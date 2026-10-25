import 'package:flutter/foundation.dart';

import 'calendar_event.dart';
import 'calendar_invite.dart' show InviteResponse;
import 'mail_message.dart' show MailAddress;

/// What an edit changes on an event already on a calendar: whatever is
/// null stays as it is, so the calendar is sent only what was changed. A
/// change of the people alone is sent as that alone, which Exchange takes
/// as a reason to write to the people added or taken off and nobody else.
@immutable
class EventChange {
  const EventChange({
    this.title,
    this.start,
    this.end,
    this.allDay,
    this.location,
    this.notes,
    this.keptBelow,
    this.attendees,
    this.timeZone,
  });

  final String? title;

  /// Local time, as [CalendarEvent.start] is: for a whole day, the first
  /// day at midnight, and [end] the day after the last. Given together,
  /// with [allDay]: a calendar wants a meeting's times as a pair.
  final DateTime? start;
  final DateTime? end;
  final bool? allDay;
  final String? location;

  /// Plain text, as the notes were written on the screen.
  final String? notes;

  /// What goes back under new [notes] unchanged: Exchange's Teams block
  /// (see [EventNotes.keptBelow]).
  final String? keptBelow;

  /// Everyone on it after the change: the attendees as they now stand, not
  /// those added.
  final List<MailAddress>? attendees;

  /// The device's zone by its IANA name, which the new times are on; null
  /// where the device would not say, and the times then go as UTC.
  final String? timeZone;

  bool get isEmpty =>
      title == null &&
      start == null &&
      end == null &&
      allDay == null &&
      location == null &&
      notes == null &&
      attendees == null;

  /// Only who is on it changes.
  bool get onlyPeople =>
      attendees != null &&
      title == null &&
      !movesIt &&
      location == null &&
      notes == null;

  /// Whether the times change.
  bool get movesIt => start != null && end != null;

  EventChange copyWith({DateTime? start, DateTime? end}) => EventChange(
        title: title,
        start: start ?? this.start,
        end: end ?? this.end,
        allDay: allDay,
        location: location,
        notes: notes,
        keptBelow: keptBelow,
        attendees: attendees,
        timeZone: timeZone,
      );

  /// What changes between [before] and the screen's [title], [start] and
  /// the rest: only what differs. [notesBefore] is what the notes were as
  /// the screen opened, which the event itself holds only the start of.
  static EventChange between(
    CalendarEvent before, {
    required EventNotes notesBefore,
    required String title,
    required DateTime start,
    required DateTime end,
    required bool allDay,
    required String location,
    required String notes,
    required List<MailAddress> attendees,
    String? timeZone,
  }) {
    String key(MailAddress a) => a.email.trim().toLowerCase();
    final had = [
      for (final a in before.attendees)
        if (a.response != EventResponse.organizer) key(a.address),
    ]..sort();
    final now = [for (final a in attendees) key(a)]..sort();
    final timesChanged =
        start != before.start || end != before.end || allDay != before.allDay;
    final notesChanged = notes.trim() != notesBefore.text.trim();
    return EventChange(
      title: title.trim() == before.title.trim() ? null : title.trim(),
      start: timesChanged ? start : null,
      end: timesChanged ? end : null,
      allDay: timesChanged ? allDay : null,
      location:
          location.trim() == before.location.trim() ? null : location.trim(),
      notes: notesChanged ? notes.trim() : null,
      keptBelow: notesChanged ? notesBefore.keptBelow : null,
      attendees: listEquals(had, now) ? null : attendees,
      timeZone: timeZone,
    );
  }
}

/// An event's notes as the calendar holds them, read for editing: the
/// text, and for a Teams meeting on Exchange, the Teams block below it,
/// which goes back unchanged under any new notes (a body sent without it,
/// or with it rewritten, loses the meeting).
@immutable
class EventNotes {
  const EventNotes({required this.text, this.keptBelow});

  final String text;

  /// The HTML kept under the notes on a change: Exchange's Teams block.
  final String? keptBelow;
}

/// A meeting on a calendar being changed on the meeting screen: Edit on
/// its sheet. [wholeSeries] for every meeting of the series it is one of,
/// which keep their days: only the time of day and the length move.
@immutable
class EventEdit {
  const EventEdit({
    required this.event,
    required this.notes,
    this.wholeSeries = false,
  });

  final CalendarEvent event;
  final EventNotes notes;
  final bool wholeSeries;
}

/// When a series starts and ends: its first meeting's times, in UTC, a
/// whole day's as its date at midnight UTC.
typedef SeriesTimes = ({DateTime start, DateTime end, bool allDay});

/// [change], meant for one meeting of a series, for every meeting of it:
/// the series keeps its days, and takes the new time of day and length
/// from its own first day. Where [change] does not move the meeting, it is
/// as it was.
EventChange forSeries(EventChange change, SeriesTimes series) {
  if (!change.movesIt) return change;
  final start = change.start!, end = change.end!;
  final first = series.allDay
      ? DateTime(series.start.year, series.start.month, series.start.day)
      : series.start.toLocal();
  if (change.allDay ?? series.allDay) {
    final days = DateTime(end.year, end.month, end.day)
        .difference(DateTime(start.year, start.month, start.day))
        .inDays;
    final from = DateTime(first.year, first.month, first.day);
    return change.copyWith(
      start: from,
      end: DateTime(from.year, from.month, from.day + (days < 1 ? 1 : days)),
    );
  }
  final from = DateTime(
      first.year, first.month, first.day, start.hour, start.minute);
  return change.copyWith(start: from, end: from.add(end.difference(start)));
}

/// The answer a calendar keeps for [response].
EventResponse eventResponseFor(InviteResponse response) => switch (response) {
      InviteResponse.accepted => EventResponse.accepted,
      InviteResponse.tentative => EventResponse.tentative,
      InviteResponse.declined => EventResponse.declined,
    };

/// Whose meeting [event] is, for what may be done with it: the account's
/// own (organised by it, or with nobody else on it, an appointment), or
/// someone else's it was invited to.
bool isOwnEvent(CalendarEvent event) =>
    event.isOrganizer ||
    event.response == EventResponse.organizer ||
    (event.organizer == null && event.attendees.isEmpty);

/// Everyone on [event] but the account at [ownEmail]: the organiser, then
/// the attendees, each once. Who a message about the meeting goes to.
List<MailAddress> everyoneOn(CalendarEvent event, String ownEmail) {
  final seen = {ownEmail.trim().toLowerCase()};
  return [
    for (final a in [
      ?event.organizer,
      for (final attendee in event.attendees) attendee.address,
    ])
      if (seen.add(a.email.trim().toLowerCase())) a,
  ];
}

/// Whether anyone besides the account is on [event], so a change or a
/// cancellation tells them.
bool hasOthers(CalendarEvent event, String ownEmail) =>
    everyoneOn(event, ownEmail).isNotEmpty;

/// The people on [event] who have not answered it yet, but the account:
/// for a reminder to them.
List<MailAddress> notAnswered(CalendarEvent event, String ownEmail) {
  final own = ownEmail.trim().toLowerCase();
  return [
    for (final a in event.attendees)
      if ((a.response == EventResponse.notResponded ||
              a.response == EventResponse.none) &&
          a.address.email.trim().toLowerCase() != own)
        a.address,
  ];
}
