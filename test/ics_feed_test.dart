import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/ics_feed.dart';
import 'package:myemail/domain/internet_calendar.dart';

/// Calendars from links (calendar ideas #28): an .ics feed read into its
/// events, the repeating ones laid out over the stretch asked for.
void main() {
  String feed(List<String> events, {String name = 'Holidays in Israel'}) => [
        'BEGIN:VCALENDAR',
        'PRODID:-//Google Inc//Google Calendar 70.9054//EN',
        'VERSION:2.0',
        'X-WR-CALNAME:$name',
        for (final e in events) ...['BEGIN:VEVENT', ...e.split('\n'), 'END:VEVENT'],
        'END:VCALENDAR',
      ].join('\r\n');

  List<CalendarEvent> between(String text, DateTime from, DateTime to) =>
      IcsFeed.parse(text).between(from, to, accountId: 'internet:h');

  test("a holiday feed's whole days, read only and free", () {
    final text = feed([
      'DTSTART;VALUE=DATE:20261025\nDTEND;VALUE=DATE:20261026\n'
          'UID:a@google.com\nSUMMARY:Sukkot (Day 5)\nTRANSP:TRANSPARENT\n'
          'DESCRIPTION:Observance\\nTo hide observances\\, go to Google Calen\n'
          ' dar',
      'DTSTART;VALUE=DATE:20261227\nDTEND;VALUE=DATE:20261229\n'
          'UID:b@google.com\nSUMMARY:Hanukkah',
    ]);
    final parsed = IcsFeed.parse(text);
    expect(parsed.name, 'Holidays in Israel');
    final found = between(text, DateTime(2026, 10, 1), DateTime(2027, 1, 1));
    expect([for (final e in found) e.title], ['Sukkot (Day 5)', 'Hanukkah']);
    final sukkot = found.first;
    expect(sukkot.allDay, isTrue);
    expect(sukkot.start, DateTime(2026, 10, 25));
    expect(sukkot.end, DateTime(2026, 10, 26));
    expect(sukkot.readOnly, isTrue);
    expect(sukkot.showAs, EventShowAs.free);
    expect(sukkot.accountId, 'internet:h');
    expect(sukkot.preview,
        'Observance\nTo hide observances, go to Google Calendar');
    expect(found.last.end, DateTime(2026, 12, 29), reason: 'two days');
    expect(between(text, DateTime(2026, 11, 1), DateTime(2026, 12, 1)),
        isEmpty);
  });

  test('times in UTC, on a named clock, and floating', () {
    final text = feed([
      'UID:u\nSUMMARY:In UTC\nDTSTART:20261028T100000Z\nDTEND:20261028T110000Z',
      'UID:z\nSUMMARY:In New York\n'
          'DTSTART;TZID=America/New_York:20261028T090000\n'
          'DTEND;TZID=America/New_York:20261028T100000',
      'UID:w\nSUMMARY:Windows name\n'
          'DTSTART;TZID="Eastern Standard Time":20261028T120000\n'
          'DURATION:PT45M',
    ]);
    final found = {
      for (final e in between(text, DateTime(2026, 10, 27), DateTime(2026, 10, 30)))
        e.title: e,
    };
    expect(found['In UTC']!.start.toUtc(), DateTime.utc(2026, 10, 28, 10));
    // New York is four hours behind UTC until November.
    expect(found['In New York']!.start.toUtc(), DateTime.utc(2026, 10, 28, 13));
    expect(found['In New York']!.end.difference(found['In New York']!.start),
        const Duration(hours: 1));
    expect(found['Windows name']!.start.toUtc(), DateTime.utc(2026, 10, 28, 16));
    expect(found['Windows name']!.end.difference(found['Windows name']!.start),
        const Duration(minutes: 45));
  });

  test('every week on two days, ten times', () {
    final text = feed([
      'UID:r\nSUMMARY:Practice\nDTSTART:20261005T150000Z\n'
          'DTEND:20261005T160000Z\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10',
    ]);
    final found = between(text, DateTime(2026, 10, 1), DateTime(2027, 1, 1));
    expect(found, hasLength(10));
    expect([for (final e in found.take(3)) e.start.toUtc().day], [5, 7, 12]);
    expect(found.last.start.toUtc(), DateTime.utc(2026, 11, 4, 15));
    expect({for (final e in found) e.id}, hasLength(10),
        reason: 'each its own');
  });

  test('the second Tuesday, and the last Friday, of each month', () {
    final text = feed([
      'UID:t\nSUMMARY:Board\nDTSTART:20260113T090000Z\n'
          'RRULE:FREQ=MONTHLY;BYDAY=2TU',
      'UID:f\nSUMMARY:Drinks\nDTSTART:20260130T170000Z\n'
          'RRULE:FREQ=MONTHLY;BYDAY=-1FR;UNTIL=20260430T235959Z',
    ]);
    final found = between(text, DateTime(2026, 1, 1), DateTime(2026, 7, 1));
    expect(
        [for (final e in found.where((e) => e.title == 'Board')) e.start.toUtc().day],
        [13, 10, 10, 14, 12, 9]);
    expect(
        [for (final e in found.where((e) => e.title == 'Drinks')) e.start.toUtc().day],
        [30, 27, 27, 24]);
  });

  test('every other day until an end, with a day left out and one moved', () {
    final text = feed([
      'UID:d\nSUMMARY:Run\nDTSTART:20261001T060000Z\nDTEND:20261001T070000Z\n'
          'RRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20261009T060000Z\n'
          'EXDATE:20261005T060000Z',
      'UID:d\nSUMMARY:Run (late)\nRECURRENCE-ID:20261007T060000Z\n'
          'DTSTART:20261007T080000Z\nDTEND:20261007T090000Z',
    ]);
    final found = between(text, DateTime(2026, 9, 1), DateTime(2026, 11, 1));
    expect([for (final e in found) (e.start.toUtc().day, e.title)], [
      (1, 'Run'),
      (3, 'Run'),
      (7, 'Run (late)'),
      (9, 'Run'),
    ]);
  });

  test('every year on its day, and a series begun years ago', () {
    final text = feed([
      'UID:b\nSUMMARY:Birthday\nDTSTART;VALUE=DATE:19900315\n'
          'RRULE:FREQ=YEARLY',
      'UID:s\nSUMMARY:Stand-up\nDTSTART:20000103T080000Z\n'
          'DTEND:20000103T081500Z\nRRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR',
    ]);
    final found = between(text, DateTime(2026, 3, 14), DateTime(2026, 3, 17));
    expect(found.where((e) => e.title == 'Birthday').single.start,
        DateTime(2026, 3, 15));
    // The 14th is a Saturday, the 15th a Sunday: Monday the 16th.
    expect(
        [for (final e in found.where((e) => e.title == 'Stand-up')) e.start.toUtc()],
        [DateTime.utc(2026, 3, 16, 8)]);
  });

  test('a cancelled one, and the lines of a reminder inside one, left out', () {
    final text = feed([
      'UID:c\nSUMMARY:Off\nSTATUS:CANCELLED\nDTSTART:20261028T100000Z',
      'UID:a\nSUMMARY:On\nDTSTART:20261028T110000Z\nDTEND:20261028T120000Z\n'
          'BEGIN:VALARM\nACTION:DISPLAY\nDESCRIPTION:Reminder\n'
          'TRIGGER:-PT15M\nEND:VALARM\nLOCATION:Room 2\\, upstairs',
    ]);
    final found = between(text, DateTime(2026, 10, 28), DateTime(2026, 10, 29));
    expect(found.single.title, 'On');
    expect(found.single.location, 'Room 2, upstairs');
    expect(found.single.preview, isEmpty, reason: "the reminder's is not its own");
  });

  group('a link as pasted', () {
    test('webcal is https', () {
      expect(feedUrlOf(' webcal://example.com/team.ics '),
          'https://example.com/team.ics');
      expect(feedUrlOf('https://example.com/a.ics'), 'https://example.com/a.ics');
      expect(feedUrlOf('not a link'), isNull);
      expect(feedUrlOf('mailto:a@example.com'), isNull);
    });

    test("Google's holidays for a country", () {
      expect(
          holidayFeedUrl('en.jewish'),
          'https://calendar.google.com/calendar/ical/'
          'en.jewish%23holiday%40group.v.calendar.google.com/public/basic.ics');
      expect(holidayCalendars.map((h) => h.country), contains('Israel'));
    });

    test('kept as text, and read back', () {
      const c = InternetCalendar(
        id: 'x1',
        name: 'Holidays in Israel',
        url: 'https://example.com/il.ics',
        colour: 0xFF8E24AA,
      );
      expect(InternetCalendar.listFrom(InternetCalendar.listToText([c])), [c]);
      expect(c.accountId, 'internet:x1');
      expect(isInternetAccount(c.accountId), isTrue);
      expect(InternetCalendar.listFrom('nonsense'), isEmpty);
    });
  });
}
