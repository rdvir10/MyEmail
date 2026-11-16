import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/cache/cache_store.dart' show MemoryCacheStore;
import 'package:myemail/data/calendar/account_calendar.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/ics_feed.dart';
import 'package:myemail/domain/meeting_links.dart';

/// Join for Zoom, Webex and any other meeting link (calendar idea #39):
/// the links to meetings found in a meeting's place and notes, and in an
/// invitation's own lines. Anyone who sends Ron an invitation writes
/// those, so only a known service's link to a meeting is taken, by the
/// host its address names.
void main() {
  const zoom = 'https://us02web.zoom.us/j/81234567890?pwd=bWxYZ2RNa0tQ.1';
  const webex = 'https://hadco.webex.com/meet/dana';
  const teams = 'https://teams.microsoft.com/l/meetup-join/'
      '19%3ameeting_NjQ4ZDk0%40thread.v2/0'
      '?context=%7b%22Tid%22%3a%2272f9%22%2c%22Oid%22%3a%22a1b2%22%7d';
  // A Zoom link as Microsoft Defender's Safe Links wraps it in a work
  // mailbox's invitation.
  const safeZoom = 'https://nam12.safelinks.protection.outlook.com/'
      '?url=https%3A%2F%2Fus02web.zoom.us%2Fj%2F81234567890%3Fpwd%3Dabc'
      '&data=05%7C02%7C&reserved=0';

  group('a link to a meeting', () {
    test("each service's link to join a meeting is found", () {
      for (final link in [
        zoom,
        'https://zoom.us/my/dana.levi',
        'https://hadco.zoom.us/w/91234567890?tk=abc',
        'https://zoomgov.com/j/1612345678',
        'https://hadco.webex.com/hadco/j.php?MTID=m0123456789abcdef',
        webex,
        'https://global.gotomeeting.com/join/123456789',
        'https://gotomeet.me/DanaLevi',
        'https://meet.goto.com/123456789',
        'https://meetings.ringcentral.com/j/1234567890',
        'https://v.ringcentral.com/join/123456789',
        'https://bluejeans.com/123456789/0123',
        'https://whereby.com/dana-room',
        'https://chime.aws/1234567890',
        teams,
        'https://teams.microsoft.com/meet/23456789012?p=AbCdEf',
        'https://teams.live.com/meet/9876543210?p=xyz',
        'https://meet.google.com/abc-defg-hij',
        'https://join.skype.com/AbCdEfGhIj',
        'https://meet.jit.si/HadcoWeekly',
      ]) {
        expect(meetingLinkIn('Join here: $link'), link, reason: link);
      }
    });

    test('their pages that are not a meeting are not taken', () {
      for (final page in [
        'https://zoom.us/pricing',
        'https://zoom.us/download',
        'https://zoom.us/j/',
        'https://www.webex.com/downloads.html',
        'https://help.webex.com/en-us/article/nul0wut',
        'https://teams.microsoft.com/downloads',
        'https://meet.google.com/',
        'https://meet.google.com/new',
        'https://www.ringcentral.com/office/plansandpricing.html',
        'https://www.bluejeans.com/blog',
        'https://whereby.com/information/pricing',
        'https://meet.jit.si/',
      ]) {
        expect(meetingLinkIn('See $page'), isNull, reason: page);
      }
      expect(meetingLinkIn('See https://zoom.us/j/81234567890'),
          'https://zoom.us/j/81234567890',
          reason: 'beside them, a meeting');
    });

    test("a lookalike is nobody's meeting", () {
      for (final fake in [
        'https://zoom.us.example.com/j/81234567890',
        'https://evilzoom.us/j/81234567890',
        'http://zoom.us/j/81234567890',
        // A Cyrillic о, and a Cyrillic ѕ.
        'https://zооm.us/j/81234567890',
        'https://zoom.uѕ/j/81234567890',
        'https://zo%6Fm.us/j/81234567890',
        'https://zoom.us@evil.example/j/81234567890',
        'https://evil.example@zoom.us/j/81234567890',
        'https://zoom.us:8443/j/81234567890',
        'https://teams.microsoft.com.evil.example/l/meetup-join/x/0',
        'https://example.com/j/81234567890',
        'ftp://zoom.us/j/81234567890',
        'https://safelinks.protection.outlook.com.evil.example/'
            '?url=https%3A%2F%2Fzoom.us%2Fj%2F81234567890',
      ]) {
        expect(meetingLinkIn('Join: $fake'), isNull, reason: fake);
      }
      for (final real in [
        'https://zoom.us/j/81234567890',
        'https://ZOOM.US/j/81234567890',
        'https://zoom.us:443/j/81234567890',
      ]) {
        expect(meetingLinkIn('Join: $real'), real, reason: real);
      }
    });

    test('as invitations write them: before a full stop, in brackets, after '
        'their words, broken across lines, in HTML', () {
      expect(meetingLinkIn('Join at https://zoom.us/j/81234567890.'),
          'https://zoom.us/j/81234567890');
      expect(meetingLinkIn('(https://zoom.us/j/81234567890)'),
          'https://zoom.us/j/81234567890');
      expect(
          meetingLinkIn('Zoom: https://zoom.us/j/81234567890?pwd=abc, '
              'passcode 1234'),
          'https://zoom.us/j/81234567890?pwd=abc');
      expect(
          meetingLinkIn('Click here to join the meeting<$teams>\r\n'
              'Meeting ID: 244 810 212 347'),
          teams);
      // Broken inside its brackets.
      expect(
          meetingLinkIn('Join Zoom Meeting<https://us02web.zoom.us/j/'
              '81234567890?pwd=\r\nbWxYZ2RNa0tQ.1>'),
          zoom);
      // Broken where it could not have ended.
      expect(
          meetingLinkIn('https://us02web.zoom.us/j/81234567890?pwd=\n'
              'bWxYZ2RNa0tQ.1\nMeeting ID: 812 3456 7890'),
          zoom);
      // And not where it could have.
      expect(
          meetingLinkIn('https://zoom.us/j/81234567890\n'
              'Meeting ID: 812 3456 7890'),
          'https://zoom.us/j/81234567890');
      expect(
          meetingLinkIn('<a href="https://zoom.us/j/81234567890?pwd=a&amp;'
              'uname=b">Join Zoom Meeting</a>'),
          'https://zoom.us/j/81234567890?pwd=a&uname=b');
      expect(meetingLinkIn('קישור: https://zoom.us/j/81234567890 לפגישה'),
          'https://zoom.us/j/81234567890',
          reason: 'Hebrew either side');
    });

    test('the first of several; one inside Safe Links is known by the link '
        'it holds, and opened as Safe Links gives it', () {
      expect(
          meetingLinkIn('The agenda: https://example.com/agenda. Join '
              '$webex or $zoom'),
          webex);
      expect(meetingLinkIn('Join Zoom Meeting<$safeZoom>'), safeZoom,
          reason: "so Defender's check still runs when it is tapped");
      expect(
          meetingLinkIn('<a href="${safeZoom.replaceAll('&', '&amp;')}">'
              'Join</a>'),
          safeZoom);
      expect(
          meetingLinkIn('https://nam12.safelinks.protection.outlook.com/'
              '?url=https%3A%2F%2Fexample.com%2Fj%2F1&data=x'),
          isNull);
      expect(
          meetingLinkIn('https://nam12.safelinks.protection.outlook.com/'
              '?url=http%3A%2F%2Fzoom.us%2Fj%2F81234567890'),
          isNull,
          reason: 'what it holds is held to the same rules');
    });

    test('a Safe Links wrapper is taken only with one url in it, and one '
        'that joins a meeting', () {
      const wrapper = 'https://nam12.safelinks.protection.outlook.com/';
      const meeting = 'https%3A%2F%2Fzoom.us%2Fj%2F81234567890';
      const elsewhere = 'https%3A%2F%2Fevil.example%2Fsignin';
      // What is opened must be what was checked: Defender may follow the
      // first of two, or a URL= written in capitals.
      for (final two in [
        '$wrapper?url=$elsewhere&url=$meeting&data=x',
        '$wrapper?URL=$elsewhere&url=$meeting&data=x',
        '$wrapper?url=$meeting&Url=$elsewhere&data=x',
        '$wrapper?url=$meeting&url=&data=x',
        '$wrapper?%75rl=$elsewhere&url=$meeting',
        '$wrapper?url=$meeting%20$elsewhere&data=x',
        '$wrapper?url=https%3A%2F%2Fzoom.us%40evil.example%2Fj%2F1',
        '$wrapper?data=x&url_=$meeting',
        '$wrapper?data=x',
      ]) {
        expect(meetingLinkIn('Join Zoom Meeting<$two>'), isNull, reason: two);
      }
      for (final one in [
        '$wrapper?url=$meeting&data=05%7C02&reserved=0',
        '$wrapper?URL=$meeting&data=x',
      ]) {
        expect(meetingLinkIn('Join Zoom Meeting<$one>'), one, reason: one);
      }
      expect(
          CalendarInvite.parse('BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\n'
                  'BEGIN:VEVENT\r\nUID:x\r\nSUMMARY:Call\r\n'
                  'DTSTART:20261117T140000Z\r\n'
                  'DESCRIPTION:Join<$wrapper?url=$elsewhere&url=$meeting>'
                  '\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n')!
              .joinUrl,
          isNull,
          reason: "the invitation's card is held to the same");
    });

    test('first lines that may be cut pass over a link that runs to their '
        'end', () {
      final cut = '${'Agenda ' * 33}https://us02web.zoom.us/j/8123456';
      expect(meetingLinkIn(cut, mayBeCut: true), isNull,
          reason: 'a digit of the meeting may be missing');
      expect(meetingLinkIn(cut), 'https://us02web.zoom.us/j/8123456');
      expect(
          meetingLinkIn('Join https://zoom.us/j/81234567890 ${'x' * 230}',
              mayBeCut: true),
          'https://zoom.us/j/81234567890');
      expect(meetingLinkIn(null), isNull);
      expect(meetingLinkIn(''), isNull);
    });
  });

  group('read from the calendars', () {
    Map<String, Object?> graphEvent({
      String? place,
      String preview = '',
      String? body,
      String? online,
      String zone = 'UTC',
    }) =>
        {
          'id': 'g1',
          'subject': 'Supplier call',
          'start': {
            'dateTime': '2026-11-17T14:00:00.0000000',
            'timeZone': zone,
          },
          'end': {
            'dateTime': '2026-11-17T15:00:00.0000000',
            'timeZone': zone,
          },
          'location': {'displayName': ?place},
          'bodyPreview': preview,
          if (body != null) 'body': {'contentType': 'text', 'content': body},
          if (online != null) 'onlineMeeting': {'joinUrl': online},
        };

    test("Outlook: its own Teams link, exactly as now; then the place, the "
        'first lines and the whole of the notes', () {
      CalendarEvent read(Map<String, Object?> json) =>
          GraphCalendarApi.eventFrom(json, 'hadco')!;
      const own = 'https://teams.microsoft.com/l/x';
      expect(read(graphEvent(place: zoom, online: own)).joinUrl, own,
          reason: 'the meeting the calendar marks keeps its Join as it is');
      expect(read(graphEvent(place: zoom)).joinUrl, zoom);
      expect(
          read(graphEvent(place: 'Room 4', preview: 'Webex: $webex')).joinUrl,
          webex);
      final notes = '${'Agenda point. ' * 20}\r\nJoin Zoom Meeting\r\n$zoom';
      final whole = read(graphEvent(
        place: 'Room 4',
        preview: notes.substring(0, 255),
        body: notes,
      ));
      expect(whole.joinUrl, zoom);
      expect(whole.preview, notes.substring(0, 255).trim(),
          reason: 'the first lines as they were');
      expect(jsonEncode(whole.toJson()), isNot(contains('Join Zoom Meeting')),
          reason: 'the link is kept, never the notes');
      expect(read(graphEvent(place: 'Room 4', preview: 'Lunch')).joinUrl,
          isNull);
      expect(
          read(graphEvent(
            place: 'Room 4',
            body: 'Join Zoom Meeting<$safeZoom>',
          )).joinUrl,
          safeZoom,
          reason: 'a work mailbox gets it through Safe Links, and Join keeps '
              'it so');
    });

    test('Outlook: a read of days asks for the notes as text, a read of '
        'months as it always did', () async {
      final sent = <http.Request>[];
      final api = GraphCalendarApi(
        accessToken: ({bool force = false}) async => 't',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          return http.Response(
              jsonEncode({
                'value': [graphEvent(body: 'Notes.\r\nJoin: $zoom')],
              }),
              200);
        }),
        sleep: (_) async {},
      );
      final from = DateTime.utc(2026, 11, 16), to = DateTime.utc(2026, 11, 23);

      final read =
          await api.events(from, to, accountId: 'hadco', withNotes: true);

      expect(read.single.joinUrl, zoom);
      final fields = sent.single.url.queryParameters[r'$select']!.split(',');
      expect(fields, containsAll(['body', 'bodyPreview', 'onlineMeeting']));
      expect(sent.single.headers['Prefer'],
          'outlook.timezone="UTC", outlook.body-content-type="text"');

      sent.clear();
      await api.events(from, to, accountId: 'hadco');
      expect(
        sent.single.url.queryParameters[r'$select'],
        'subject,start,end,isAllDay,location,organizer,attendees,'
        'onlineMeeting,webLink,showAs,responseStatus,isOrganizer,'
        'isCancelled,isReminderOn,reminderMinutesBeforeStart,bodyPreview,'
        'seriesMasterId,sensitivity,originalStartTimeZone,categories',
        reason: 'as it always was',
      );
      expect(sent.single.headers['Prefer'], 'outlook.timezone="UTC"');
    });

    test('Outlook: should Graph answer the notes in another zone than UTC, '
        'the read is made again without them', () async {
      final sent = <http.Request>[];
      final api = GraphCalendarApi(
        accessToken: ({bool force = false}) async => 't',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          final notes = request.url.queryParameters[r'$select']!
              .split(',')
              .contains('body');
          return http.Response(
              jsonEncode({
                'value': [
                  graphEvent(
                    place: zoom,
                    zone: notes ? 'Eastern Standard Time' : 'UTC',
                  ),
                ],
              }),
              200);
        }),
        sleep: (_) async {},
      );

      final read = await api.events(
          DateTime.utc(2026, 11, 16), DateTime.utc(2026, 11, 23),
          accountId: 'hadco', withNotes: true);

      expect(sent, hasLength(2));
      expect(sent.last.url.queryParameters[r'$select']!.split(','),
          isNot(contains('body')));
      expect(sent.last.headers['Prefer'], 'outlook.timezone="UTC"');
      expect(read.single.start, DateTime.utc(2026, 11, 17, 14).toLocal(),
          reason: 'the times as read in UTC');
      expect(read.single.joinUrl, zoom, reason: 'the place is still read');
    });

    test("the reminders' three days look in the notes; a week's, a month's "
        "and a search's two years do not, and Google's read always has them",
        () async {
      const microsoft = Account(
        id: 'hadco',
        displayName: 'Hadco',
        emailAddress: 'ron@hadco.example',
        provider: MailProvider.outlook,
        authMethod: AuthMethod.oauth,
        colorValue: 0xFF0F6CBD,
      );
      const google = Account(
        id: 'gmail',
        displayName: 'Gmail',
        emailAddress: 'ron@gmail.example',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.oauth,
        colorValue: 0xFF007258,
      );
      final views = <http.Request>[];
      final calendars = AccountCalendar(
        accessToken: (id, {bool force = false, List<String>? scopes}) async =>
            't',
        accounts: () => const [microsoft, google],
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path.endsWith('/calendarView')) views.add(request);
          return http.Response(jsonEncode({'value': []}), 200);
        }),
        sleep: (_) async {},
      );
      bool asksNotes(http.Request r) =>
          r.url.queryParameters[r'$select']!.split(',').contains('body');
      Future<bool> read(DateTime from, DateTime to) async {
        views.clear();
        await calendars.events(microsoft, from, to);
        return asksNotes(views.single);
      }

      // Today to the end of the day after tomorrow, the reminders' read;
      // the bar's and My Day's day.
      final today = DateTime(2026, 10, 24);
      expect(await read(today, DateTime(2026, 10, 27)), isTrue);
      expect(await read(today, DateTime(2026, 10, 25)), isTrue,
          reason: 'one day');
      // A week, Month's six weeks, a search's two years.
      final monday = DateTime(2026, 11, 30);
      for (final to in [
        DateTime(2026, 12, 7),
        DateTime(2027, 1, 11),
        DateTime(2028, 11, 30),
      ]) {
        expect(await read(monday, to), isFalse, reason: '$to');
      }

      expect(AccountCalendar.readsNotes(google, monday, DateTime(2028)),
          isTrue,
          reason: 'its description comes whole with every read');
    });

    test("the reads of days are the say on a link: one they find gone is "
        'not kept by the longer reads, even one asked before them', () async {
      // As the engine keeps each read (CachedImapEngine._readCalendar): a
      // longer read takes on the links kept, then is kept itself.
      final cache = MemoryCacheStore();
      final monday = DateTime(2026, 11, 16), week = DateTime(2026, 11, 23);
      final tuesday = DateTime(2026, 11, 17), thursday = DateTime(2026, 11, 19);
      CalendarEvent call({String? joinUrl}) => CalendarEvent(
            id: 'call',
            accountId: 'hadco',
            title: 'Supplier call',
            start: DateTime(2026, 11, 17, 14),
            end: DateTime(2026, 11, 17, 15),
            location: 'Room 4',
            preview: 'Agenda',
            joinUrl: joinUrl,
          );
      DateTime at(int hour, [int minute = 0]) =>
          DateTime(2026, 11, 15, hour, minute);
      Future<List<CalendarEvent>> kept() async =>
          (await cache.keptCalendar('hadco', monday, week)).events;
      Future<void> days(DateTime asked, {String? joinUrl}) =>
          cache.keepCalendar('hadco', tuesday, thursday,
              [call(joinUrl: joinUrl)],
              readAt: asked);
      Future<List<CalendarEvent>> weekRead() async =>
          withLinksKept([call()], await kept());
      Future<void> keepWeek(List<CalendarEvent> read, DateTime asked) =>
          cache.keepCalendar('hadco', monday, week, read, readAt: asked);

      await days(at(9), joinUrl: zoom);
      await keepWeek(await weekRead(), at(10));
      expect((await kept()).single.joinUrl, zoom,
          reason: 'kept through a week read without the notes');

      // Taken out of the notes, as a read of days sees.
      await days(at(11));
      await keepWeek(await weekRead(), at(12));
      expect((await kept()).single.joinUrl, isNull);

      // Back in, then gone again while a week's read asked at 15:00, its
      // links taken on before, is answered after the read of days at 15:01.
      await days(at(13), joinUrl: zoom);
      final late = await weekRead();
      expect(late.single.joinUrl, zoom);
      await days(at(15, 1));
      await keepWeek(late, at(15));
      expect((await kept()).single.joinUrl, isNull,
          reason: 'an older answer does not undo the newer');
    });

    test('Google: its own Meet link, exactly as now; then the place, then '
        'the whole of the description', () {
      Map<String, Object?> event({
        String? place,
        String? description,
        String? hangout,
      }) =>
          {
            'id': 'e1',
            'summary': 'Supplier call',
            'start': {'dateTime': '2026-11-17T14:00:00Z'},
            'end': {'dateTime': '2026-11-17T15:00:00Z'},
            'location': ?place,
            'description': ?description,
            'hangoutLink': ?hangout,
          };
      CalendarEvent read(Map<String, Object?> json) =>
          GoogleCalendarApi.eventFrom(json, 'gmail')!;
      final long = '${'Agenda. ' * 60}Join Zoom Meeting<br>'
          '<a href="$zoom">$zoom</a>';
      final e = read(event(description: long));
      expect(e.joinUrl, zoom);
      expect(e.preview, endsWith('…'),
          reason: 'its first lines, cut as before');
      expect(e.preview, isNot(contains('zoom.us')));
      expect(read(event(place: zoom, description: webex)).joinUrl, zoom,
          reason: 'the place first');
      expect(
          read(event(hangout: 'https://meet.google.com/abc', place: zoom))
              .joinUrl,
          'https://meet.google.com/abc');
      expect(read(event(description: 'Lunch at noon')).joinUrl, isNull);
    });

    test('a calendar from a link: its place, then its description', () {
      final feed = IcsFeed.parse('BEGIN:VCALENDAR\r\n'
          'BEGIN:VEVENT\r\nUID:w1\r\nSUMMARY:Webinar\r\n'
          'DTSTART:20261117T140000Z\r\nDTEND:20261117T150000Z\r\n'
          'DESCRIPTION:Register first.\\nJoin: $webex\r\n'
          'END:VEVENT\r\n'
          'BEGIN:VEVENT\r\nUID:w2\r\nSUMMARY:Open day\r\n'
          'DTSTART:20261118T090000Z\r\nDTEND:20261118T100000Z\r\n'
          'LOCATION:Hall 2\r\nEND:VEVENT\r\n'
          'END:VCALENDAR\r\n');
      final events = feed.between(
          DateTime.utc(2026, 11, 16), DateTime.utc(2026, 11, 20),
          accountId: 'internet:x');
      expect([for (final e in events) e.joinUrl], [webex, null]);
    });

    test('a read of months keeps the links the reads of days found', () {
      CalendarEvent at(
        String id, {
        String? joinUrl,
        String place = 'Room 4',
        String preview = 'Agenda',
      }) =>
          CalendarEvent(
            id: id,
            accountId: 'hadco',
            title: 'Supplier call',
            start: DateTime(2026, 11, 17, 14),
            end: DateTime(2026, 11, 17, 15),
            location: place,
            preview: preview,
            joinUrl: joinUrl,
          );
      final kept = [
        at('same', joinUrl: zoom),
        at('notes', joinUrl: zoom),
        at('place', joinUrl: zoom),
        at('own', joinUrl: 'https://teams.microsoft.com/l/x'),
      ];
      final read = withLinksKept([
        at('same'),
        at('notes', preview: 'Agenda, moved to Thursday'),
        at('place', place: 'Room 5'),
        at('own', joinUrl: 'https://teams.microsoft.com/l/y'),
        at('new'),
      ], kept);
      expect([for (final e in read) e.joinUrl],
          [zoom, null, null, 'https://teams.microsoft.com/l/y', null]);
    });
  });

  group('a place to find in a maps app (#40)', () {
    test('a place is found as written; one that only names an online '
        'meeting, or is a link, is nowhere to go', () {
      expect(placeToFind('Café Noir, 12 Rothschild Blvd, Tel Aviv'),
          'Café Noir, 12 Rothschild Blvd, Tel Aviv');
      expect(placeToFind('קפה נואר, רוטשילד 12'), 'קפה נואר, רוטשילד 12');
      for (final online in [
        'Microsoft Teams Meeting',
        'Microsoft Teams',
        'microsoft teams meeting ',
        'Google Meet',
        'Zoom Meeting',
        'Zoom: $zoom',
        zoom,
        'https://example.com/where',
        'Online',
        '',
      ]) {
        expect(placeToFind(online), isNull, reason: online);
      }
    });

    test('of a place that has both, the room is what is looked up', () {
      expect(placeToFind('Microsoft Teams Meeting; Room 4, Hadco House'),
          'Room 4, Hadco House');
      expect(placeToFind('Board room - $zoom'), 'Board room');
    });
  });

  // Seen on the tablet (2026-11-16): a meeting whose place was its Zoom
  // link had the whole link, its passcode in it, as its place in the
  // Agenda.
  group('a place on one line, its links named and never written out', () {
    const gov = 'https://www.zoomgov.com/j/1653774483?pwd=AbCdEf123.1';

    test('a link is its service, or its host where the service is not known',
        () {
      expect(placeNamed(gov), 'Zoom');
      expect(placeNamed('https://acme.zoom.us/j/82563765410?pwd=x1&jst=3'),
          'Zoom');
      expect(placeNamed('https://meet.google.com/abc-defg-hij'),
          'Google Meet');
      expect(placeNamed('https://www.example.com/where?key=secret'),
          'example.com');
      expect(placeNamed('www.example.org/room/9'), 'example.org');
    });

    test('the words beside a link stay, and its service is said once', () {
      expect(placeNamed('Board room - $gov'), 'Board room · Zoom');
      expect(placeNamed('Zoom: $gov'), 'Zoom');
      expect(
          placeNamed('Microsoft Teams Meeting; '
              'https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0'),
          'Microsoft Teams Meeting');
      expect(placeNamed('$gov $gov'), 'Zoom');
    });

    test('a place with no link in it is as it is written', () {
      for (final place in [
        'Café Noir, 12 Rothschild Blvd, Tel Aviv',
        'Microsoft Teams Meeting; MTR-CAConf',
        'קפה נואר, רוטשילד 12',
        'Room 4 (2nd floor), Hadco HQ',
        'Dr. Levi - see www for the form',
      ]) {
        expect(placeNamed(place), place);
      }
      expect(placeNamed('  Board room  '), 'Board room');
      expect(placeNamed(''), '');
    });

    test('nothing of a link is left: no passcode, no number, no address',
        () {
      for (final place in [gov, 'Board room - $gov', 'Zoom: $gov', '($gov)']) {
        final named = placeNamed(place);
        for (final part in ['pwd', 'AbCdEf', 'http', '1653774483', '?', '/']) {
          expect(named, isNot(contains(part)), reason: '$place -> $named');
        }
      }
    });

    test('a link inside Safe Links is named for the link it holds', () {
      final wrapped = 'https://nam02.safelinks.protection.outlook.com/'
          '?url=${Uri.encodeQueryComponent(gov)}&data=05';
      expect(placeNamed(wrapped), 'Zoom');
    });

    // What the review of these found: marks left on a name, a www. inside
    // a word taken for a link, a name in other letters shown as %d7…, and
    // a link with nothing to name leaving an empty line.
    test('the full stop, comma or bracket that closed the words around a '
        'link is no part of its name', () {
      expect(placeNamed('Room 4, www.hadco.com, floor 2'),
          'Room 4, floor 2 · hadco.com');
      expect(placeNamed('Conference Room (WWW.HADCO.COM)'),
          'Conference Room · hadco.com');
      expect(placeNamed('https://zoom.us.'), 'Zoom');
      // The comma closed the link; the full stop ends the words, and stays.
      expect(placeNamed('See https://example.com/a?b=1, then come up.'),
          'See then come up. · example.com');
    });

    test('www. inside a word is not a link; a name in other letters is '
        'shown in them; a link with nothing to name is still a line', () {
      expect(placeNamed('Meet at swww.thecafe'), 'Meet at swww.thecafe');
      expect(placeNamed('https://דוגמה.co.il/room'), 'דוגמה.co.il');
      expect(placeNamed('https://?x=1'), 'Link');
    });

    test('a place that is only a link to something else, a map or a '
        'document, can still be opened, as written; a meeting\'s own link, '
        'and a place with somewhere to find, are not opened this way', () {
      const map =
          'https://www.google.com/maps/place/Hadco+Warehouse+5/@32.1,34.8,17z';
      expect(placeNamed(map), 'google.com');
      expect(placeLinkToOpen(map), Uri.parse(map));
      expect(placeLinkToOpen('($map).'), Uri.parse(map));
      expect(placeLinkToOpen('www.example.org/room/9'),
          Uri.parse('https://www.example.org/room/9'));
      final wrapped = 'https://nam02.safelinks.protection.outlook.com/'
          '?url=${Uri.encodeQueryComponent(map)}&data=05';
      expect(placeLinkToOpen(wrapped), Uri.parse(wrapped),
          reason: 'as Safe Links gives it, so Defender still checks it');

      expect(placeLinkToOpen(gov), isNull, reason: 'Join opens that');
      expect(placeLinkToOpen('$gov $map'), Uri.parse(map));
      expect(placeLinkToOpen('Board room'), isNull);
      expect(placeLinkToOpen('ftp://example.com/x'), isNull);
      expect(placeLinkToOpen('https://?x=1'), isNull);
    });

    // The re-read found the one that mattered. A place is written by
    // whoever sends the invitation, and naming it is on the way to every
    // reminder: a link whose host is not text at all threw, and with it
    // went the reminders of every meeting on every account.
    test('a link whose host cannot be read as text never throws, and still '
        'has a name', () {
      for (final place in [
        'https://%ff.example/x',
        'https://caf%E9.example/x',
        'https://%c3/x',
        'Room 4 https://%ff.example/x',
        'https://%/x',
        'https://[::1/x',
        'https://%ff.example/x https://%fe.example/y',
      ]) {
        expect(() => placeNamed(place), returnsNormally, reason: place);
        expect(placeNamed(place), isNotEmpty, reason: place);
        expect(() => placeLinkToOpen(place), returnsNormally, reason: place);
      }
      expect(placeNamed('Room 4 https://%ff.example/x'), startsWith('Room 4'));
    });

    test('a host that mixes alphabets in one name, or holds a mark that '
        'turns the text round, is shown as it came, not as it would read',
        () {
      // A Cyrillic а before the Latin "pple": how a look-alike is made.
      final cyrillicA = String.fromCharCode(0x430);
      final lookalike = placeNamed('https://${cyrillicA}pple.com/x');
      expect(lookalike, isNot(contains(cyrillicA)));
      expect(lookalike, contains('pple.com'));
      // A mark that turns what follows it right to left.
      final turn = String.fromCharCode(0x202e);
      expect(placeNamed('https://moc.elgoog$turn.example/x'),
          isNot(contains(turn)));
      // One alphabet to a name is read: Hebrew, then co.il.
      expect(placeNamed('https://דוגמה.co.il/room'), 'דוגמה.co.il');
    });

    test('a bracket that belongs to a link is kept in what is opened; one '
        'that closed the words around it is not', () {
      const wiki = 'https://en.wikipedia.org/wiki/Foo_(bar)';
      expect(placeLinkToOpen(wiki), Uri.parse(wiki));
      expect(placeLinkToOpen('($wiki)'), Uri.parse(wiki));
      expect(placeLinkToOpen('$wiki.'), Uri.parse(wiki));
    });

    test('only a place that is nothing but the link opens it: with words '
        'beside it the line is not a way to somewhere else', () {
      expect(placeLinkToOpen('Zoom https://elsewhere.example/x'), isNull,
          reason: 'the line would read Zoom and open elsewhere');
      expect(placeLinkToOpen('See https://elsewhere.example/x'), isNull);
      expect(placeLinkToOpen(' https://elsewhere.example/x '),
          Uri.parse('https://elsewhere.example/x'));
    });

    test('a meeting is where its place says; Online with a link to join '
        'and no place; nowhere with neither', () {
      CalendarEvent held(String location, {String? joinUrl}) => CalendarEvent(
            id: 'e',
            accountId: 'a',
            title: 'Budget',
            start: DateTime(2026, 11, 17, 9),
            end: DateTime(2026, 11, 17, 10),
            location: location,
            joinUrl: joinUrl,
          );
      expect(placeLine(held(gov, joinUrl: gov)), 'Zoom');
      expect(placeLine(held('', joinUrl: gov)), 'Online');
      expect(placeLine(held('  ')), isNull);
      expect(placeLine(held(' Board room ')), 'Board room');
    });
  });

  group("an invitation's own lines", () {
    String invitation(String lines) => 'BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\n'
        'BEGIN:VEVENT\r\nUID:abc\r\nSUMMARY:Supplier call\r\n'
        'DTSTART:20261117T140000Z\r\nDTEND:20261117T150000Z\r\n'
        '$lines'
        'END:VEVENT\r\nEND:VCALENDAR\r\n';
    String? join(String lines) =>
        CalendarInvite.parse(invitation(lines))!.joinUrl;

    test("Teams' and Meet's own lines first, then the place, the URL and the "
        'description', () {
      expect(
          join('X-MICROSOFT-SKYPETEAMSMEETINGURL:$teams\r\nLOCATION:$zoom\r\n'),
          teams);
      expect(
          join('X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij\r\n'
              'LOCATION:$zoom\r\n'),
          'https://meet.google.com/abc-defg-hij');
      expect(join('LOCATION:Zoom $zoom\r\nURL:$webex\r\n'), zoom);
      expect(join('LOCATION:Room 4\r\nURL:$webex\r\n'), webex);
      // Outlook's: the link after its words, the line folded at 75.
      final head = teams.substring(0, 40), rest = teams.substring(40);
      expect(
          join('DESCRIPTION:Click here to join the meeting<$head\r\n'
              ' $rest>\\n\r\n'),
          teams);
      expect(join('LOCATION:https://zoom.us.example.com/j/81234567890\r\n'),
          isNull);
      expect(join('LOCATION:Room 4\r\n'), isNull);
    });
  });
}
