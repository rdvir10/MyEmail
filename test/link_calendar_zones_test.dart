import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/calendar_files.dart';
import 'package:myemail/domain/ics_feed.dart';
import 'package:myemail/domain/time_zones.dart' show wallClockIn;

/// Calendars from links, as the second review of batch h3 found them: a
/// series in a zone only the file's own VTIMEZONE defines repeats on that
/// zone's clock, by its rules; and an end date that does not exist still
/// ends the series near it, as it always did.
void main() {
  /// A calendar whose one event is a series in [zone], a zone the file
  /// names and defines itself, from [start] to [end] on its clock.
  String linked(String zone, String start, String end, String rule) =>
      'BEGIN:VCALENDAR\r\n$zone'
      'BEGIN:VEVENT\r\nUID:x\r\nSUMMARY:Board\r\n'
      'DTSTART;TZID="Customized Time Zone":$start\r\n'
      'DTEND;TZID="Customized Time Zone":$end\r\n'
      'RRULE:$rule\r\n'
      'END:VEVENT\r\nEND:VCALENDAR\r\n';

  String zone({
    required String standard,
    required String daylight,
    required String toStandard,
    required String toDaylight,
    required String standardRule,
    required String daylightRule,
  }) =>
      'BEGIN:VTIMEZONE\r\nTZID:Customized Time Zone\r\n'
      'BEGIN:STANDARD\r\nDTSTART:$toStandard\r\nRRULE:$standardRule\r\n'
      'TZOFFSETFROM:$daylight\r\nTZOFFSETTO:$standard\r\nEND:STANDARD\r\n'
      'BEGIN:DAYLIGHT\r\nDTSTART:$toDaylight\r\nRRULE:$daylightRule\r\n'
      'TZOFFSETFROM:$standard\r\nTZOFFSETTO:$daylight\r\nEND:DAYLIGHT\r\n'
      'END:VTIMEZONE\r\n';

  /// The United States' eastern rules under a made-up name, as an Outlook
  /// export writes them.
  final eastern = zone(
    standard: '-0500',
    daylight: '-0400',
    toStandard: '16011104T020000',
    toDaylight: '16010311T020000',
    standardRule: 'FREQ=YEARLY;BYDAY=1SU;BYMONTH=11',
    daylightRule: 'FREQ=YEARLY;BYDAY=2SU;BYMONTH=3',
  );

  List<DateTime> shown(String text) => [
        for (final e in IcsFeed.parse(text).between(
          DateTime.utc(2026, 11, 1),
          DateTime.utc(2027, 12, 31),
          accountId: 'internet:x',
        ))
          e.start.toUtc(),
      ];

  test('a weekly Tuesday 20:00 west of UTC is Wednesday 01:00 UTC in '
      'winter and 00:00 in summer, its first meeting there', () {
    final at = shown(linked(eastern, '20261201T200000', '20261201T210000',
        'FREQ=WEEKLY;BYDAY=TU;COUNT=20'));
    expect(at, hasLength(20));
    expect(at.first, DateTime.utc(2026, 12, 2, 1), reason: 'Tue 1 Dec 20:00');
    expect(at[1], DateTime.utc(2026, 12, 9, 1));
    for (final a in at) {
      expect(a.weekday, DateTime.wednesday, reason: '$a: a Tuesday evening');
    }
    // Tuesday 16 March 2027 is after the clocks went forward on the 14th.
    expect(at, contains(DateTime.utc(2027, 3, 17, 0)));
    expect(at, isNot(contains(DateTime.utc(2027, 3, 17, 1))));
    expect(at, contains(DateTime.utc(2027, 3, 10, 1)),
        reason: 'the week before, still in winter');
  });

  test("a zone with real rules under a made-up name keeps its clock's hour "
      'on both sides of its clock change', () {
    // The United Kingdom's rules, named as nothing the phone knows.
    final british = zone(
      standard: '+0000',
      daylight: '+0100',
      toStandard: '19701025T020000',
      toDaylight: '19700329T010000',
      standardRule: 'FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10',
      daylightRule: 'FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3',
    );
    final at = shown(linked(british, '20261203T100000', '20261203T110000',
        'FREQ=WEEKLY;BYDAY=TH;UNTIL=20270701T090000Z'));
    expect(at, isNotEmpty);
    expect(at.first, DateTime.utc(2026, 12, 3, 10));
    for (final a in at) {
      final london = wallClockIn(a, 'Europe/London');
      expect((london.weekday, london.hour, london.minute),
          (DateTime.thursday, 10, 0), reason: '$a');
    }
    expect(at, contains(DateTime.utc(2027, 4, 1, 9)), reason: 'summer');
  });

  test('east of UTC, an early meeting is the day before in UTC, and its '
      'days are still its own', () {
    final sydney = zone(
      standard: '+1000',
      daylight: '+1100',
      toStandard: '19700405T030000',
      toDaylight: '19701004T020000',
      standardRule: 'FREQ=YEARLY;BYDAY=1SU;BYMONTH=4',
      daylightRule: 'FREQ=YEARLY;BYDAY=1SU;BYMONTH=10',
    );
    // Monday 7 December 2026, 07:00 at +11:00, is Sunday 20:00 UTC.
    final at = shown(linked(sydney, '20261207T070000', '20261207T080000',
        'FREQ=WEEKLY;BYDAY=MO;COUNT=30'));
    expect(at, hasLength(30));
    expect(at.first, DateTime.utc(2026, 12, 6, 20));
    for (final a in at) {
      final there = wallClockIn(a, 'Australia/Sydney');
      expect((there.weekday, there.hour), (DateTime.monday, 7), reason: '$a');
    }
    // From 4 April 2027, at +10:00: Sunday 21:00 UTC.
    expect(at, contains(DateTime.utc(2027, 4, 4, 21)));
  });

  test('the file screen takes such a series on its own day', () {
    final event = CalendarFile.read(linked(eastern, '20261201T200000',
            '20261201T210000', 'FREQ=WEEKLY;BYDAY=TU;COUNT=20'))!
        .events
        .single;
    expect(event.ownDay, DateTime(2026, 12, 1),
        reason: 'Tuesday on its own clock, not Wednesday in UTC');
    expect(event.zoneUnknown, isFalse);
  });

  test('an end date that does not exist ends the series near it, as before',
      () {
    final feed = IcsFeed.parse('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u\r\n'
        'SUMMARY:S\r\nDTSTART:20261201T120000Z\r\nDTEND:20261201T130000Z\r\n'
        'RRULE:FREQ=WEEKLY;UNTIL=20270631T000000Z\r\nEND:VEVENT\r\n'
        'END:VCALENDAR');
    final at = [
      for (final e in feed.between(DateTime.utc(2026, 11, 1),
          DateTime.utc(2028, 1, 1), accountId: 'internet:x'))
        e.start.toUtc(),
    ];
    expect(at, isNotEmpty);
    expect(at.last.isBefore(DateTime.utc(2027, 7, 2)), isTrue,
        reason: 'last ${at.last}');
    expect(at.last.isAfter(DateTime.utc(2027, 6, 20)), isTrue);
  });
}
