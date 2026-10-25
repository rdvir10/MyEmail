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
/// account's calendar when the view asks, and kept on the device until the
/// next read (see `CacheStore.keepCalendar`), so the view opens at once.
@immutable
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.accountId,
    this.calendarId = mainCalendar,
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
    this.seriesId,
    this.isPrivate = false,
    this.timeZone,
    this.readOnly = false,
    this.categories = const [],
    this.colour,
  });

  /// The calendar's own id for this occurrence.
  final String id;
  final String accountId;

  /// Which of the account's calendars it is on: [mainCalendar] for the
  /// one every account has, Outlook's Calendar and Google's primary.
  /// Google's ids are a calendar's own, so a change to an event names it.
  final String calendarId;

  /// [calendarId] for the account's main calendar.
  static const mainCalendar = '';
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

  /// The series this is one meeting of, by the calendar's id for the
  /// series (Graph's seriesMasterId, Google's recurringEventId), or null
  /// for a meeting on its own. A change can be made to this one or to the
  /// series.
  final String? seriesId;

  /// Kept to the account: others see only that the time is taken.
  final bool isPrivate;

  /// The zone it was set in, as the calendar names it: an IANA name from
  /// Google, Windows' name from Exchange ("Eastern Standard Time"). Null
  /// where it does not say.
  final String? timeZone;

  /// On a calendar the account only reads: Google's holidays and
  /// birthdays, one shared to it to look at, a calendar from a link. Its
  /// sheet answers, changes and removes nothing.
  final bool readOnly;

  /// Outlook's categories, by name, as the meeting has them.
  final List<String> categories;

  /// The event's own colour, ARGB: its first category's in Outlook, the
  /// one picked for it in Google Calendar. Null for its calendar's.
  final int? colour;

  CalendarEvent copyWith({
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? title,
    String? location,
    List<EventAttendee>? attendees,
    EventResponse? response,
  }) =>
      CalendarEvent(
        id: id,
        accountId: accountId,
        calendarId: calendarId,
        title: title ?? this.title,
        start: start ?? this.start,
        end: end ?? this.end,
        allDay: allDay ?? this.allDay,
        location: location ?? this.location,
        organizer: organizer,
        attendees: attendees ?? this.attendees,
        joinUrl: joinUrl,
        webLink: webLink,
        showAs: showAs,
        response: response ?? this.response,
        isOrganizer: isOrganizer,
        cancelled: cancelled,
        reminderMinutes: reminderMinutes,
        preview: preview,
        seriesId: seriesId,
        isPrivate: isPrivate,
        timeZone: timeZone,
        readOnly: readOnly,
        categories: categories,
        colour: colour,
      );

  /// The account said no and the calendar kept it all the same, as
  /// Google's does; Outlook takes a declined meeting off itself.
  bool get declined => response == EventResponse.declined;

  /// Whether any of it falls on [day], a date at midnight.
  bool fallsOn(DateTime day) {
    final from = DateTime(day.year, day.month, day.day);
    final to = DateTime(day.year, day.month, day.day + 1);
    // Something that ends as the day starts was the day before; something
    // with no length at all is on the day it is at.
    return start.isBefore(to) &&
        (end.isAfter(from) || (end == start && !start.isBefore(from)));
  }

  /// As kept on the device: see [CalendarEvent.fromJson]. A whole day's
  /// times are its dates, which mean the same day wherever the phone is; a
  /// timed event's are instants, in UTC.
  Map<String, Object?> toJson() {
    String at(DateTime t) => allDay
        ? '${t.year.toString().padLeft(4, '0')}-'
            '${t.month.toString().padLeft(2, '0')}-'
            '${t.day.toString().padLeft(2, '0')}'
        : t.toUtc().toIso8601String();
    Map<String, Object?> address(MailAddress a) => {
          'email': a.email,
          if (a.name != null) 'name': a.name,
        };
    return {
      'id': id,
      'accountId': accountId,
      if (calendarId != mainCalendar) 'calendarId': calendarId,
      'title': title,
      'start': at(start),
      'end': at(end),
      if (allDay) 'allDay': true,
      if (location.isNotEmpty) 'location': location,
      if (organizer != null) 'organizer': address(organizer!),
      if (attendees.isNotEmpty)
        'attendees': [
          for (final a in attendees)
            {
              ...address(a.address),
              if (a.response != EventResponse.none) 'response': a.response.name,
              if (a.optional) 'optional': true,
            },
        ],
      if (joinUrl != null) 'joinUrl': joinUrl,
      if (webLink != null) 'webLink': webLink,
      if (showAs != EventShowAs.busy) 'showAs': showAs.name,
      if (response != EventResponse.none) 'response': response.name,
      if (isOrganizer) 'isOrganizer': true,
      if (cancelled) 'cancelled': true,
      if (reminderMinutes != null) 'reminderMinutes': reminderMinutes,
      if (preview.isNotEmpty) 'preview': preview,
      if (seriesId != null) 'seriesId': seriesId,
      if (isPrivate) 'isPrivate': true,
      if (timeZone != null) 'timeZone': timeZone,
      if (readOnly) 'readOnly': true,
      if (categories.isNotEmpty) 'categories': categories,
      if (colour != null) 'colour': colour,
    };
  }

  /// What [toJson] wrote, or null for anything that is not one: a kept
  /// row the app cannot read is passed over, never thrown.
  static CalendarEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], accountId = json['accountId'];
    if (id is! String || accountId is! String) return null;
    final allDay = json['allDay'] == true;
    DateTime? at(Object? value) {
      if (value is! String) return null;
      final t = DateTime.tryParse(value);
      if (t == null) return null;
      return allDay ? DateTime(t.year, t.month, t.day) : t.toLocal();
    }

    final start = at(json['start']), end = at(json['end']);
    if (start == null || end == null) return null;
    MailAddress? address(Object? v) {
      if (v is! Map || v['email'] is! String) return null;
      final name = v['name'];
      return MailAddress(
        email: v['email'] as String,
        name: name is String ? name : null,
      );
    }

    T named<T extends Enum>(List<T> values, Object? name, T otherwise) =>
        values.where((v) => v.name == name).firstOrNull ?? otherwise;
    String? text(Object? v) => v is String ? v : null;
    final attendees = json['attendees'];
    final minutes = json['reminderMinutes'];
    final categories = json['categories'];
    final colour = json['colour'];
    return CalendarEvent(
      id: id,
      accountId: accountId,
      calendarId: text(json['calendarId']) ?? mainCalendar,
      title: text(json['title']) ?? '',
      start: start,
      end: end.isBefore(start) ? start : end,
      allDay: allDay,
      location: text(json['location']) ?? '',
      organizer: address(json['organizer']),
      attendees: [
        for (final a in attendees is List ? attendees : const [])
          if (address(a) case final who?)
            EventAttendee(
              who,
              response: named(EventResponse.values, (a as Map)['response'],
                  EventResponse.none),
              optional: a['optional'] == true,
            ),
      ],
      joinUrl: text(json['joinUrl']),
      webLink: text(json['webLink']),
      showAs: named(EventShowAs.values, json['showAs'], EventShowAs.busy),
      response:
          named(EventResponse.values, json['response'], EventResponse.none),
      isOrganizer: json['isOrganizer'] == true,
      cancelled: json['cancelled'] == true,
      reminderMinutes: minutes is num ? minutes.toInt() : null,
      preview: text(json['preview']) ?? '',
      seriesId: text(json['seriesId']),
      isPrivate: json['isPrivate'] == true,
      timeZone: text(json['timeZone']),
      readOnly: json['readOnly'] == true,
      categories: [
        for (final c in categories is List ? categories : const [])
          if (c is String) c,
      ],
      colour: colour is int ? colour : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarEvent &&
      other.id == id &&
      other.accountId == accountId &&
      other.calendarId == calendarId &&
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
      other.preview == preview &&
      other.seriesId == seriesId &&
      other.isPrivate == isPrivate &&
      other.timeZone == timeZone &&
      other.readOnly == readOnly &&
      listEquals(other.categories, categories) &&
      other.colour == colour;

  @override
  int get hashCode => Object.hashAll([
        id,
        accountId,
        calendarId,
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
        seriesId,
        isPrivate,
        timeZone,
        readOnly,
        Object.hashAll(categories),
        colour,
      ]);

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
