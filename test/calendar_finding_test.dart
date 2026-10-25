import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_finding.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;

/// Finding in the calendar (calendar ideas #34, #36, #37), from the events
/// alone.
void main() {
  final now = DateTime(2026, 10, 26, 9);
  const dana = MailAddress(email: 'Dana@Example.com', name: 'Dana Levi');
  const yossi = MailAddress(email: 'yossi@example.com', name: 'Yossi Cohen');

  CalendarEvent event(
    String id,
    DateTime start, {
    String title = 'Weekly sync',
    String location = '',
    MailAddress? organizer,
    List<MailAddress> people = const [],
    EventResponse response = EventResponse.accepted,
    EventShowAs showAs = EventShowAs.busy,
    bool allDay = false,
    Duration length = const Duration(hours: 1),
  }) =>
      CalendarEvent(
        id: id,
        accountId: 'hadco',
        title: title,
        start: start,
        end: start.add(length),
        location: location,
        organizer: organizer,
        attendees: [for (final p in people) EventAttendee(p)],
        response: response,
        showAs: showAs,
        allDay: allDay,
      );

  group('searching the calendar (#36)', () {
    final events = [
      event('a', DateTime(2026, 10, 28, 10), title: 'Budget review',
          location: 'Room 4', people: [dana]),
      event('b', DateTime(2026, 9, 1, 10), title: 'Budget kickoff'),
      event('c', DateTime(2026, 11, 3, 14), title: 'Lunch',
          location: 'Café Noir'),
      event('d', DateTime(2026, 8, 1, 10), title: 'Budget planning'),
    ];

    test('every word, in the title, the place or the people', () {
      expect([for (final e in searchEvents(events, 'budget', now).coming) e.id],
          ['a']);
      expect([for (final e in searchEvents(events, 'budget', now).past) e.id],
          ['b', 'd'], reason: 'the latest first');
      expect(searchEvents(events, 'café', now).coming.single.id, 'c');
      expect(searchEvents(events, 'dana room', now).coming.single.id, 'a');
      expect(searchEvents(events, 'DANA@EXAMPLE', now).coming.single.id, 'a');
      expect(searchEvents(events, 'budget lunch', now).coming, isEmpty);
      expect(searchEvents(events, '   ', now).coming, isEmpty);
    });

    test('a year back and a year ahead', () {
      final span = searchSpan(now);
      expect(span.start, DateTime(2025, 10, 26));
      expect(span.end, DateTime(2027, 10, 27));
    });
  });

  group('meetings with someone (#37)', () {
    test('the next and the last, organiser or invited', () {
      final found = meetingsWith([
        event('past', DateTime(2026, 10, 19, 10), people: [dana]),
        event('older', DateTime(2026, 10, 5, 10), organizer: dana),
        event('next', DateTime(2026, 10, 28, 10), organizer: dana),
        event('later', DateTime(2026, 11, 2, 10), people: [dana]),
        event('declined', DateTime(2026, 10, 27, 10),
            people: [dana], response: EventResponse.declined),
        event('other', DateTime(2026, 10, 26, 15), people: [yossi]),
      ], 'dana@example.com', now);
      expect(found.next?.id, 'next');
      expect(found.last?.id, 'past');
      expect(meetingsWith(const [], 'dana@example.com', now).next, isNull);
    });
  });

  group('clashes on an invitation (#34)', () {
    final start = DateTime(2026, 10, 28, 14);
    final end = DateTime(2026, 10, 28, 15);

    test('what overlaps, not what is free, declined, a whole day, or itself',
        () {
      final clashes = clashesWith([
        event('overlap', DateTime(2026, 10, 28, 14, 30)),
        event('before', DateTime(2026, 10, 28, 13)),
        event('free', DateTime(2026, 10, 28, 14), showAs: EventShowAs.free),
        event('declined', DateTime(2026, 10, 28, 14),
            response: EventResponse.declined),
        event('day', DateTime(2026, 10, 28),
            allDay: true, length: const Duration(days: 1)),
        event('itself', start, title: 'Planning'),
        event('early', DateTime(2026, 10, 28, 13, 30)),
      ], start, end, title: 'Planning');
      expect([for (final e in clashes) e.id], ['early', 'overlap']);
    });
  });
}
