import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/mail_message.dart';

/// An invitation read out of its text, and the answer written back.
void main() {
  const request = 'BEGIN:VCALENDAR\r\n'
      'PRODID:-//Microsoft Corporation//Outlook 16.0 MIMEDIR//EN\r\n'
      'VERSION:2.0\r\n'
      'METHOD:REQUEST\r\n'
      'BEGIN:VEVENT\r\n'
      'ORGANIZER;CN="Levi, Dana":mailto:dana@example.com\r\n'
      'ATTENDEE;CN=Ron Dvir;ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:ron@example.com\r\n'
      'ATTENDEE;CN=Sam;RSVP=TRUE:mailto:sam@example.com\r\n'
      'DESCRIPTION:Numbers for Q3\\, then lunch.\\nBring the deck.\r\n'
      'UID:040000008200E00074C5B7101A82E00800000000ABCDEF\r\n'
      'SUMMARY:Q3 review\\; planning\r\n'
      'DTSTART;TZID=Eastern Standard Time:20260921T130000\r\n'
      'DTEND;TZID=Eastern Standard Time:20260921T140000\r\n'
      'LOCATION:Room 4, or https://example.com/meet/abc which is a very long li\r\n'
      ' nk that the sender folded across two lines\r\n'
      'SEQUENCE:2\r\n'
      'DTSTAMP:20260920T150000Z\r\n'
      'END:VEVENT\r\n'
      'END:VCALENDAR\r\n';

  group('reading an invitation', () {
    test('the when, where, who and what', () {
      final i = CalendarInvite.parse(request)!;

      expect(i.method, 'REQUEST');
      expect(i.isRequest, isTrue);
      expect(i.uid, '040000008200E00074C5B7101A82E00800000000ABCDEF');
      expect(i.summary, 'Q3 review; planning');
      expect(i.start, DateTime(2026, 9, 21, 13));
      expect(i.end, DateTime(2026, 9, 21, 14));
      expect(i.timeZone, 'Eastern Standard Time');
      expect(i.isAllDay, isFalse);
      expect(i.organizer!.email, 'dana@example.com');
      expect(i.organizer!.name, 'Levi, Dana',
          reason: 'a quoted parameter with a colon and a comma in it');
      expect(i.attendees.map((a) => a.email), ['ron@example.com', 'sam@example.com']);
      expect(i.description, 'Numbers for Q3, then lunch.\nBring the deck.');
      expect(i.location, contains('folded across two lines'),
          reason: 'folded lines are joined');
      expect(i.sequence, 2);
      expect(i.dtStamp, DateTime.utc(2026, 9, 20, 15));
    });

    test('a whole-day event and a UTC time', () {
      final day = CalendarInvite.parse(
        'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nSUMMARY:Holiday\n'
        'DTSTART;VALUE=DATE:20261225\nDTEND;VALUE=DATE:20261226\n'
        'END:VEVENT\nEND:VCALENDAR',
      )!;
      expect(day.isAllDay, isTrue);
      expect(day.start, DateTime(2026, 12, 25));
      expect(day.method, 'PUBLISH', reason: 'no METHOD means published');

      final utc = CalendarInvite.parse(
        'BEGIN:VCALENDAR\nMETHOD:CANCEL\nBEGIN:VEVENT\nUID:y\nSUMMARY:Gone\n'
        'DTSTART:20260921T170000Z\nEND:VEVENT\nEND:VCALENDAR',
      )!;
      expect(utc.start.isUtc, isTrue);
      expect(utc.start, DateTime.utc(2026, 9, 21, 17));
      expect(utc.isCancellation, isTrue);
    });

    test('text with no event in it is not an invitation', () {
      expect(CalendarInvite.parse('BEGIN:VCALENDAR\nEND:VCALENDAR'), isNull);
      expect(CalendarInvite.parse('hello'), isNull);
    });
  });

  group('answering', () {
    test('is a REPLY with the same UID and the attendee\'s answer', () {
      final i = CalendarInvite.parse(request)!;

      final reply = iMipReply(
        i,
        attendee: const MailAddress(email: 'ron@example.com', name: 'Ron Dvir'),
        response: InviteResponse.accepted,
        now: DateTime.utc(2026, 9, 20, 16, 30),
      );

      expect(reply, contains('METHOD:REPLY'));
      expect(reply, contains('UID:040000008200E00074C5B7101A82E00800000000ABCDEF'));
      expect(reply, contains('ATTENDEE;CN=Ron Dvir;PARTSTAT=ACCEPTED:mailto:ron@example.com'));
      expect(reply, contains('ORGANIZER:mailto:dana@example.com'));
      expect(reply, contains('DTSTAMP:20260920T163000Z'));
      expect(reply, contains('SEQUENCE:2'));
      expect(reply, contains('SUMMARY:Q3 review\\; planning'));
      expect(reply.split('\r\n').every((l) => l.length <= 75), isTrue,
          reason: 'folded to the RFC line length');
      expect(inviteReplySubject(i, InviteResponse.declined), 'Declined: Q3 review; planning');
    });
  });

  // What Exchange sends: the zone by its Windows name, defined beside the
  // event, and a reminder inside the event with a DESCRIPTION of its own.
  String exchange({String extra = ''}) => 'BEGIN:VCALENDAR\r\n'
      'METHOD:REQUEST\r\n'
      'BEGIN:VTIMEZONE\r\n'
      'TZID:Eastern Standard Time\r\n'
      'BEGIN:STANDARD\r\n'
      'DTSTART:16010101T020000\r\n'
      'TZOFFSETFROM:-0400\r\n'
      'TZOFFSETTO:-0500\r\n'
      'RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11\r\n'
      'END:STANDARD\r\n'
      'BEGIN:DAYLIGHT\r\n'
      'DTSTART:16010101T020000\r\n'
      'TZOFFSETFROM:-0500\r\n'
      'TZOFFSETTO:-0400\r\n'
      'RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3\r\n'
      'END:DAYLIGHT\r\n'
      'END:VTIMEZONE\r\n'
      'BEGIN:VEVENT\r\n'
      'UID:series-1\r\n'
      'SUMMARY:Weekly\r\n'
      'DESCRIPTION:Agenda: numbers. Join: https://teams.example/meet/1\r\n'
      'DTSTART;TZID=Eastern Standard Time:20260921T130000\r\n'
      'DTEND;TZID=Eastern Standard Time:20260921T140000\r\n'
      '$extra'
      'BEGIN:VALARM\r\n'
      'DESCRIPTION:REMINDER\r\n'
      'TRIGGER;RELATED=START:-PT15M\r\n'
      'ACTION:DISPLAY\r\n'
      'END:VALARM\r\n'
      'END:VEVENT\r\n'
      'END:VCALENDAR\r\n';

  group('what Exchange and Teams send', () {
    test("the reminder's text is not the meeting's", () {
      // Every Teams invitation opened in the calendar as "REMINDER", with
      // the agenda and the join link gone.
      final i = CalendarInvite.parse(exchange())!;
      expect(i.description, 'Agenda: numbers. Join: https://teams.example/meet/1');
    });

    test('a time in another zone is the right instant', () {
      // 13:00 in New York in September is 17:00 UTC: 20:00 in Israel. It
      // was taken for 13:00 on the phone's own clock.
      final i = CalendarInvite.parse(exchange())!;
      expect(i.start, DateTime.utc(2026, 9, 21, 17));
      expect(i.end, DateTime.utc(2026, 9, 21, 18));
      expect(i.timeIsKnown, isTrue);
    });

    test('and winter time is winter time', () {
      final i = CalendarInvite.parse(exchange().replaceAll('20260921', '20261215'))!;
      expect(i.start, DateTime.utc(2026, 12, 15, 18));
    });

    test('the answer carries the same instant', () {
      final reply = iMipReply(
        CalendarInvite.parse(exchange())!,
        attendee: const MailAddress(email: 'ron@example.com'),
        response: InviteResponse.accepted,
      );
      expect(reply, contains('DTSTART:20260921T170000Z'));
    });

    test('a zone named but not defined is said to be unknown', () {
      // Then the time is as written and the answer echoes it, rather than
      // guessing it is the phone's own zone.
      final i = CalendarInvite.parse(request)!;
      expect(i.timeIsKnown, isFalse);
      final reply = iMipReply(
        i,
        attendee: const MailAddress(email: 'ron@example.com'),
        response: InviteResponse.accepted,
      );
      expect(reply,
          contains('DTSTART;TZID=Eastern Standard Time:20260921T130000'));
    });
  });

  group('what Google sends', () {
    const google = 'BEGIN:VCALENDAR\r\n'
        'METHOD:REQUEST\r\n'
        'BEGIN:VTIMEZONE\r\n'
        'TZID:Europe/London\r\n'
        'BEGIN:DAYLIGHT\r\n'
        'TZOFFSETFROM:+0000\r\n'
        'TZOFFSETTO:+0100\r\n'
        'TZNAME:BST\r\n'
        'DTSTART:19700329T010000\r\n'
        'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r\n'
        'END:DAYLIGHT\r\n'
        'BEGIN:STANDARD\r\n'
        'TZOFFSETFROM:+0100\r\n'
        'TZOFFSETTO:+0000\r\n'
        'TZNAME:GMT\r\n'
        'DTSTART:19701025T020000\r\n'
        'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\n'
        'END:STANDARD\r\n'
        'END:VTIMEZONE\r\n'
        'BEGIN:VEVENT\r\n'
        'DTSTART;TZID=Europe/London:20260929T090000\r\n'
        'UID:abc@google.com\r\n'
        'RECURRENCE-ID;TZID=Europe/London:20260929T100000\r\n'
        'SUMMARY:Stand-up (moved)\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n';

    test('the last Sunday rule works, and so does the zone', () {
      final i = CalendarInvite.parse(google)!;
      expect(i.start, DateTime.utc(2026, 9, 29, 8), reason: 'BST, one hour');

      // Summer time began on the last Sunday of March 2026, the 29th.
      DateTime at(String day) => CalendarInvite.parse(
              google.replaceFirst('20260929T090000', '${day}T120000'))!
          .start;
      expect(at('20260328'), DateTime.utc(2026, 3, 28, 12));
      expect(at('20260329'), DateTime.utc(2026, 3, 29, 11));
    });

    test('an answer to one occurrence says which one', () {
      // Without RECURRENCE-ID the organiser's calendar applied a decline to
      // every week of the series.
      final i = CalendarInvite.parse(google)!;
      final reply = iMipReply(
        i,
        attendee: const MailAddress(email: 'ron@example.com'),
        response: InviteResponse.declined,
      );
      expect(reply, contains('RECURRENCE-ID:20260929T090000Z'));
      expect(reply, contains('UID:abc@google.com'));
    });

    test('and an answer to the whole series says none', () {
      final reply = iMipReply(
        CalendarInvite.parse(exchange())!,
        attendee: const MailAddress(email: 'ron@example.com'),
        response: InviteResponse.declined,
      );
      expect(reply, isNot(contains('RECURRENCE-ID')));
    });
  });
}
