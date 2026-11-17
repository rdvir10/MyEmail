import 'package:flutter/foundation.dart';

import 'calendar_event.dart';
import 'calendar_invite.dart' show InviteResponse;
import 'error_report.dart' show ReadableError;
import 'mail_message.dart' show MailAddress;
import 'meeting.dart' show Reminder;
import 'recurrence.dart';
import 'series_repeat.dart';
import 'time_zones.dart';

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
    this.optional,
    this.timeZone,
    this.reminder,
    this.showAs,
    this.isPrivate,
    this.repeat,
  });

  final String? title;

  /// Local time, as [CalendarEvent.start] is: for a whole day, the first
  /// day at midnight, and [end] the day after the last. Given together,
  /// with [allDay]: a calendar wants a meeting's times as a pair. Where
  /// [timeZone] is given they are that zone's wall clock, which is what a
  /// calendar is sent beside it: the phone's own, or for a series changed
  /// whole, the series' own (see [forSeries]).
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

  /// Who of [attendees] is optional after the change, by address in lower
  /// case (calendar idea #56): Edit says, with the people. Null keeps each
  /// person as the event has them and asks anyone new as required, as
  /// Invite people does.
  final Set<String>? optional;

  /// The device's zone by its IANA name, which the new times are on; null
  /// where the device would not say, and the times then go as UTC.
  final String? timeZone;

  /// When the calendar reminds of it, how it shows, and whether it is kept
  /// to the account.
  final Reminder? reminder;
  final EventShowAs? showAs;
  final bool? isPrivate;

  /// How it repeats from now on (calendar idea #55): a series' new days,
  /// how often it comes or when it ends, or a meeting on its own made a
  /// series, from its own day. Null leaves it as it is. A series given one
  /// starts again from its first day the repeat falls on: see [forSeries].
  final Recurrence? repeat;

  bool get isEmpty =>
      title == null &&
      start == null &&
      end == null &&
      allDay == null &&
      location == null &&
      notes == null &&
      attendees == null &&
      reminder == null &&
      showAs == null &&
      isPrivate == null &&
      repeat == null;

  /// Only who is on it changes.
  bool get onlyPeople =>
      attendees != null &&
      title == null &&
      !movesIt &&
      location == null &&
      notes == null &&
      reminder == null &&
      showAs == null &&
      isPrivate == null &&
      repeat == null;

  /// Whether the times change.
  bool get movesIt => start != null && end != null;

  EventChange copyWith({
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? timeZone,
    Recurrence? repeat,
  }) =>
      EventChange(
        title: title,
        start: start ?? this.start,
        end: end ?? this.end,
        allDay: allDay ?? this.allDay,
        location: location,
        notes: notes,
        keptBelow: keptBelow,
        attendees: attendees,
        optional: optional,
        timeZone: timeZone ?? this.timeZone,
        reminder: reminder,
        showAs: showAs,
        isPrivate: isPrivate,
        repeat: repeat ?? this.repeat,
      );

  /// What changes between [before] and the screen's [title], [start] and
  /// the rest: only what differs. [notesBefore] is what the notes were as
  /// the screen opened, which the event itself holds only the start of.
  /// [optional] is who of [attendees] the screen has as optional: a change
  /// of that alone is a change of the people. [repeat], where the screen
  /// changed how it repeats, goes as it is.
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
    Set<String>? optional,
    String? timeZone,
    Reminder? reminder,
    EventShowAs? showAs,
    bool? isPrivate,
    Recurrence? repeat,
  }) {
    String key(MailAddress a) => a.email.trim().toLowerCase();
    // Not said: each as the event has them.
    final optionalNow = optional ??
        {
          for (final a in before.attendees)
            if (a.optional) key(a.address),
        };
    // Each person as "address" or "address optional", so that one made
    // optional, or required, is a change of the people too.
    String entry(String email, bool isOptional) =>
        isOptional ? '$email optional' : email;
    final had = [
      for (final a in before.attendees)
        if (a.response != EventResponse.organizer)
          entry(key(a.address), a.optional),
    ]..sort();
    final now = [
      for (final a in attendees) entry(key(a), optionalNow.contains(key(a))),
    ]..sort();
    final peopleChanged = !listEquals(had, now);
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
      attendees: peopleChanged ? attendees : null,
      optional: peopleChanged
          ? {
              for (final a in attendees)
                if (optionalNow.contains(key(a))) key(a),
            }
          : null,
      timeZone: timeZone,
      reminder: reminder == null ||
              reminder.minutes == before.reminderMinutes
          ? null
          : reminder,
      showAs: showAs == null || showAs == before.showAs ? null : showAs,
      isPrivate:
          isPrivate == null || isPrivate == before.isPrivate ? null : isPrivate,
      repeat: repeat,
    );
  }
}

/// An event's notes as the calendar holds them, read for editing: the
/// text, and for a Teams meeting on Exchange, the Teams block below it,
/// which goes back unchanged under any new notes (a body sent without it,
/// or with it rewritten, loses the meeting). Read in the same ask, a
/// series' repeat, for Edit's Repeat.
@immutable
class EventNotes {
  const EventNotes({
    required this.text,
    this.keptBelow,
    this.html,
    this.repeat,
  });

  final String text;

  /// The HTML kept under the notes on a change: Exchange's Teams block.
  final String? keptBelow;

  /// The notes as the page the calendar holds writes them, above any Teams
  /// block, where they are HTML: what a meeting's sheet shows, the address
  /// of each link written as words among it. Null where they are plain
  /// text. Not for a change: [text] is what Edit writes.
  final String? html;

  /// How the event repeats, where it is a series' master, read as the
  /// notes were (calendar idea #55): what Edit's Repeat starts from for
  /// every meeting of a series. Null for a meeting on its own, or one
  /// meeting of a series.
  final SeriesRepeat? repeat;
}

/// A meeting on a calendar being changed on the meeting screen: Edit on
/// its sheet. [wholeSeries] for every meeting of the series it is one of,
/// which keep their days unless Repeat is changed (#55): otherwise only
/// the time of day and the length move.
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
///
/// With a new [EventChange.repeat] (#55) the series starts again from the
/// first day on or after its own that the repeat falls on (a weekly series
/// moved from Tuesday to Wednesday starts on the Wednesday after its first
/// Tuesday; every other week, see [firstDayOf] and [weekStart]), at the new
/// time where the change moves it and at its own otherwise: a calendar
/// takes a series' repeat from its first meeting.
///
/// [zone] is the series' own, by its IANA name, where it is known (see
/// [ownZoneOf]): everything is then worked out and written on its clock,
/// never the phone's, so a series set in Jerusalem stays Jerusalem's when
/// changed on a phone in New York, and its guests keep their hour through
/// both countries' clock changes. A new time picked on the phone's clock
/// is the moment picked, on the meeting opened, read on the series' clock
/// (03:00 in New York on 17 November is 10:00 in Jerusalem, every week).
/// Where the zone is not known, the phone's, as it always was.
///
/// A time picked that falls on another day on the series' clock than the
/// meeting [opened] did (Tuesday 23:00 in Jerusalem is 16:00 in New York;
/// 18:00 there is Wednesday 01:00 in Jerusalem) moves the day with it: the
/// series' first day, and a week's days, one on or back, so the meetings
/// stay on the day Ron sees them. That needs the series' repeat, which
/// Edit hands on in [change]; a series that repeats by its dates (monthly,
/// yearly), or whose repeat is not known, is refused ([SeriesDayMoved]).
EventChange forSeries(
  EventChange change,
  SeriesTimes series, {
  String? zone,
  int weekStart = DateTime.sunday,
  DateTime? opened,
}) {
  var repeat = change.repeat;
  if (!change.movesIt && repeat == null) return change;
  final timed = !(change.allDay ?? series.allDay);
  if (zone != null && timed) {
    // The series' first meeting on its own clock, and the time of day:
    // its own, or the one picked, read there.
    final own = series.allDay
        ? DateTime(series.start.year, series.start.month, series.start.day)
        : wallClockIn(series.start, zone);
    final at = change.movesIt ? wallClockIn(change.start!, zone) : own;
    final length = change.movesIt
        ? change.end!.difference(change.start!)
        : series.allDay
            ? const Duration(hours: 1)
            : series.end.difference(series.start);
    final shift = change.movesIt && opened != null
        ? dayShiftOn(zone, opened, change.start!)
        : 0;
    if (shift != 0) {
      final moved = repeat == null
          ? null
          : shiftedRepeat(repeat, shift, own, weekStart: weekStart);
      if (moved == null) throw SeriesDayMoved(zone);
      repeat = moved;
    }
    final firstDay = DateTime(own.year, own.month, own.day + shift);
    final day = repeat == null
        ? firstDay
        : firstDayOf(repeat, firstDay, weekStart: weekStart);
    final from = DateTime(day.year, day.month, day.day, at.hour, at.minute);
    return change.copyWith(
      start: from,
      end: _wallPlus(from, length),
      allDay: false,
      timeZone: writtenZone(zone),
      repeat: repeat,
    );
  }
  final first = series.allDay
      ? DateTime(series.start.year, series.start.month, series.start.day)
      : series.start.toLocal();
  final last = series.allDay
      ? DateTime(series.end.year, series.end.month, series.end.day)
      : series.end.toLocal();
  // The series' own times where the change does not move it.
  final start = change.movesIt ? change.start! : first;
  final end = change.movesIt ? change.end! : last;
  final allDay = change.allDay ?? series.allDay;
  final day = repeat == null
      ? DateTime(first.year, first.month, first.day)
      : firstDayOf(repeat, first, weekStart: weekStart);
  if (allDay) {
    final days = DateTime(end.year, end.month, end.day)
        .difference(DateTime(start.year, start.month, start.day))
        .inDays;
    return change.copyWith(
      start: day,
      end: DateTime(day.year, day.month, day.day + (days < 1 ? 1 : days)),
      allDay: allDay,
      // Dates, which no zone moves; named as the series' own where known.
      timeZone: zone == null ? null : writtenZone(zone),
    );
  }
  final from =
      DateTime(day.year, day.month, day.day, start.hour, start.minute);
  return change.copyWith(
    start: from,
    end: from.add(end.difference(start)),
    allDay: allDay,
  );
}

/// [zone] as a calendar is sent it: UTC as "UTC", which both Graph and
/// Google take (the app has always sent it so where the phone named no
/// zone), rather than the database's own Etc/UTC.
String writtenZone(String zone) =>
    zone == 'Etc/UTC' || zone == 'Etc/UCT' || zone == 'UCT' ? 'UTC' : zone;

/// How many days [picked], a time picked on the phone's clock for the
/// meeting at [opened], moves that meeting on [zone]'s clock: one back,
/// none, or one on, as midnight there falls between them.
int dayShiftOn(String zone, DateTime opened, DateTime picked) {
  final a = wallClockIn(opened, zone), b = wallClockIn(picked, zone);
  return DateTime.utc(b.year, b.month, b.day)
      .difference(DateTime.utc(a.year, a.month, a.day))
      .inDays;
}

/// [repeat], of a series whose first meeting is on [first], with its days
/// moved [days] on (or back): a week's days, and its last day. Null for
/// one that repeats by its dates, monthly or yearly, where a day on would
/// be another date of the month; and for one every other week on two days
/// or more, where a day moved crosses the start of the calendar's counting
/// week ([weekStart]: Sunday for Outlook, Monday for Google). Friday and
/// Saturday every 2 weeks become Saturday and Sunday, and Outlook counts
/// that Sunday in the next week: no one pattern holds the meetings as they
/// were. One day alone moves whole, and is carried.
Recurrence? shiftedRepeat(
  Recurrence repeat,
  int days,
  DateTime first, {
  int weekStart = DateTime.sunday,
}) {
  if (days == 0) return repeat;
  int move(int weekday) => (weekday - 1 + days) % 7 + 1;
  if (repeat.kind == RepeatKind.weekly && repeat.interval > 1) {
    final week = repeat.daysFrom(first);
    // Where each day sits in its counting week, 0 to 6: moved outside it,
    // it is in another week.
    final crosses = week.any((d) {
      final at = (d - weekStart) % 7 + days;
      return at < 0 || at > 6;
    });
    if (week.length > 1 && crosses) return null;
  }
  final until = repeat.until;
  final last = until == null
      ? null
      : DateTime(until.year, until.month, until.day + days);
  return switch (repeat.kind) {
    RepeatKind.daily => Recurrence(RepeatKind.daily,
        interval: repeat.interval, until: last, count: repeat.count),
    RepeatKind.weekly || RepeatKind.workDays => Recurrence(repeat.kind,
        interval: repeat.interval,
        days: {for (final d in repeat.daysFrom(first)) move(d)},
        until: last,
        count: repeat.count),
    _ => null,
  };
}

/// What stops a time picked for every meeting of a series being saved, in
/// a sentence, or null: it falls on another day on the series' own clock
/// ([zone]'s) than the meeting [opened] did, and [repeat], the series',
/// cannot move with it (see [forSeries]).
String? seriesTimeProblem({
  required String zone,
  required DateTime opened,
  required DateTime picked,
  required Recurrence? repeat,
  int weekStart = DateTime.sunday,
}) {
  final shift = dayShiftOn(zone, opened, picked);
  if (shift == 0) return null;
  if (repeat != null &&
      shiftedRepeat(repeat, shift, wallClockIn(opened, zone),
              weekStart: weekStart) !=
          null) {
    return null;
  }
  return SeriesDayMoved(zone).message;
}

/// A time picked for every meeting of a series that falls on another day
/// on the series' own clock, where the series repeats by its dates or its
/// repeat is not known: refused, with what to do instead.
class SeriesDayMoved implements Exception, ReadableError {
  const SeriesDayMoved(this.zone);

  /// The series' zone, by its IANA name.
  final String zone;

  @override
  String get message =>
      'The time you picked falls on another day on the series\' own clock '
      '(${placeOf(zone)} time). Pick a time that does not, or change one '
      'meeting.';

  @override
  String toString() => message;
}

/// [wall], a wall clock, [length] on, as a wall clock: worked out in UTC,
/// so the phone's own clock changes play no part.
DateTime _wallPlus(DateTime wall, Duration length) {
  final u = DateTime.utc(wall.year, wall.month, wall.day, wall.hour,
          wall.minute, wall.second)
      .add(length);
  return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second);
}

/// [change], to a meeting on its own given a repeat (#55), on [before]'s
/// own clock, [zone]: its times, as changed or as they are, as that zone's
/// wall clock, so the series it becomes is written in the zone it was set
/// in, from its own day there. A whole day's dates stay as they are.
EventChange inOwnZone(
  EventChange change,
  CalendarEvent before,
  String zone,
) {
  if (change.allDay ?? before.allDay) {
    return change.copyWith(timeZone: writtenZone(zone));
  }
  final start = change.start ?? before.start;
  final end = change.end ?? before.end;
  return change.copyWith(
    start: wallClockIn(start, zone),
    end: wallClockIn(end, zone),
    allDay: false,
    timeZone: writtenZone(zone),
  );
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

