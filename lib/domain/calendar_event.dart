import 'package:flutter/foundation.dart';

import 'mail_message.dart' show MailAddress;

/// How an event shows on the calendar it is on: Outlook's Show As.
enum EventShowAs { free, tentative, busy, outOfOffice, workingElsewhere }

/// An answer to a meeting: the account's own, or one attendee's.
enum EventResponse { none, organizer, accepted, tentative, declined, notResponded }

/// Someone a meeting is with, and what they answered.
@immutable
class EventAttendee {
  const EventAttendee(
    this.address, {
    this.response = EventResponse.none,
    this.optional = false,
  });

  final MailAddress address;
  final EventResponse response;
  final bool optional;

  @override
  bool operator ==(Object other) =>
      other is EventAttendee &&
      other.address == address &&
      other.response == response &&
      other.optional == optional;

  @override
  int get hashCode => Object.hash(address, response, optional);
}

/// One event on an account's calendar, as the calendar view shows it: an
/// occurrence, a recurring meeting's each one on its own. Read from the
/// account's calendar when the view asks, never kept.
@immutable
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.accountId,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.location = '',
    this.organizer,
    this.attendees = const [],
    this.joinUrl,
    this.webLink,
    this.showAs = EventShowAs.busy,
    this.response = EventResponse.none,
    this.isOrganizer = false,
    this.cancelled = false,
    this.reminderMinutes,
    this.preview = '',
  });

  /// The calendar's own id for this occurrence.
  final String id;
  final String accountId;
  final String title;

  /// Local time. For a whole day, the first day at midnight, and [end] the
  /// day after the last, as calendars count it.
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String location;
  final MailAddress? organizer;
  final List<EventAttendee> attendees;

  /// Where to join it online: Teams, Meet, Zoom.
  final String? joinUrl;

  /// The event in Outlook on the web or Google Calendar.
  final String? webLink;
  final EventShowAs showAs;

  /// The account's own answer.
  final EventResponse response;
  final bool isOrganizer;

  /// Cancelled by its organiser and still on the calendar.
  final bool cancelled;

  /// Minutes before it starts that the calendar reminds, or null for none.
  final int? reminderMinutes;

  /// The first lines of what it says.
  final String preview;

  /// Whether any of it falls on [day], a date at midnight.
  bool fallsOn(DateTime day) {
    final from = DateTime(day.year, day.month, day.day);
    final to = DateTime(day.year, day.month, day.day + 1);
    // Something that ends as the day starts was the day before; something
    // with no length at all is on the day it is at.
    return start.isBefore(to) &&
        (end.isAfter(from) || (end == start && !start.isBefore(from)));
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarEvent &&
      other.id == id &&
      other.accountId == accountId &&
      other.title == title &&
      other.start == start &&
      other.end == end &&
      other.allDay == allDay &&
      other.location == location &&
      other.organizer == organizer &&
      listEquals(other.attendees, attendees) &&
      other.joinUrl == joinUrl &&
      other.webLink == webLink &&
      other.showAs == showAs &&
      other.response == response &&
      other.isOrganizer == isOrganizer &&
      other.cancelled == cancelled &&
      other.reminderMinutes == reminderMinutes &&
      other.preview == preview;

  @override
  int get hashCode => Object.hash(
        id,
        accountId,
        title,
        start,
        end,
        allDay,
        location,
        organizer,
        Object.hashAll(attendees),
        joinUrl,
        webLink,
        showAs,
        response,
        isOrganizer,
        cancelled,
        reminderMinutes,
        preview,
      );

  @override
  String toString() => 'CalendarEvent($title, $start)';
}

/// [events] on [day]: the whole-day ones first, then by when they start.
List<CalendarEvent> eventsOn(DateTime day, Iterable<CalendarEvent> events) =>
    [
      for (final e in events)
        if (e.fallsOn(day)) e,
    ]..sort((a, b) {
        if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
        final byStart = a.start.compareTo(b.start);
        return byStart != 0 ? byStart : a.end.compareTo(b.end);
      });

/// Where a timed event sits across a day's width: its column among those
/// it overlaps, and how many columns that group has.
typedef DaySlot = ({CalendarEvent event, int column, int columns});

/// [events] (timed, on one day) laid out as Outlook's day view does: those
/// that overlap side by side, each group as wide as it needs to be.
List<DaySlot> layOutDay(List<CalendarEvent> events) {
  final timed = [
    for (final e in events)
      if (!e.allDay) e,
  ]..sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : b.end.compareTo(a.end);
    });
  final slots = <DaySlot>[];
  var group = <({CalendarEvent event, int column})>[];
  var groupEnd = DateTime.fromMillisecondsSinceEpoch(0);
  // A short event still takes a short block on screen: a quarter hour.
  DateTime endOf(CalendarEvent e) {
    final shortest = e.start.add(const Duration(minutes: 15));
    return e.end.isAfter(shortest) ? e.end : shortest;
  }

  void close() {
    final columns = group.fold(0, (n, g) => g.column + 1 > n ? g.column + 1 : n);
    for (final g in group) {
      slots.add((event: g.event, column: g.column, columns: columns));
    }
    group = [];
  }

  final columnEnds = <DateTime>[];
  for (final e in timed) {
    if (group.isNotEmpty && !e.start.isBefore(groupEnd)) {
      close();
      columnEnds.clear();
    }
    var column = columnEnds.indexWhere((end) => !e.start.isBefore(end));
    if (column < 0) {
      column = columnEnds.length;
      columnEnds.add(endOf(e));
    } else {
      columnEnds[column] = endOf(e);
    }
    group.add((event: e, column: column));
    if (endOf(e).isAfter(groupEnd)) groupEnd = endOf(e);
  }
  if (group.isNotEmpty) close();
  return slots;
}
