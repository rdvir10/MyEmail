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
}
