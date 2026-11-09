import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/calendar/account_calendar.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_invite.dart';

/// Outlook's Do Not Send a Response: an invitation answered on the
/// account's own calendar, with no word to its organiser. A Gmail
/// invitation is on the Google calendar already, put there by Google, so
/// it can be answered there too, where over mail it could not.
void main() {
  const google = Account(
    id: 'acct-g',
    displayName: 'Personal',
    emailAddress: 'ron@gmail.com',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF0F6CBD,
  );
  const microsoft = Account(
    id: 'acct-ms',
    displayName: 'Work',
    emailAddress: 'ron@example.com',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF0F6CBD,
  );
  const appPassword = Account(
    id: 'acct-p',
    displayName: 'Old',
    emailAddress: 'old@gmail.com',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.appPassword,
    colorValue: 0xFFB4009E,
  );

  final invite = CalendarInvite.parse(
    'BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\n'
    'UID:lunch-1\r\nSUMMARY:Lunch\r\n'
    'DTSTART:20261016T160000Z\r\nDTEND:20261016T170000Z\r\n'
    'ORGANIZER:mailto:dana@example.com\r\n'
    'END:VEVENT\r\nEND:VCALENDAR\r\n',
  )!;

  late List<http.Request> sent;

  AccountCalendar calendar(http.Response Function(http.Request) answer) {
    sent = [];
    return AccountCalendar(
      accessToken: (id, {bool force = false, List<String>? scopes}) async =>
          'token',
      accounts: () => const [google, microsoft, appPassword],
      httpClient: http_testing.MockClient((request) async {
        sent.add(request);
        return answer(request);
      }),
      sleep: (_) async {},
    );
  }

  http.Response json(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );

  final googleEvent = {
    'id': 'g-1',
    'status': 'confirmed',
    'start': {'dateTime': '2026-10-16T16:00:00Z'},
    'end': {'dateTime': '2026-10-16T17:00:00Z'},
    'organizer': {'email': 'dana@example.com'},
    'attendees': [
      {'email': 'dana@example.com', 'responseStatus': 'accepted'},
      {'email': 'ron@gmail.com', 'self': true, 'responseStatus': 'needsAction'},
    ],
  };

  group('on a Google calendar', () {
    test('answers the event Google made of it, telling nobody', () async {
      final c = calendar((r) => r.url.queryParameters.containsKey('iCalUID')
          ? json({
              'items': [googleEvent],
            })
          : json(googleEvent));

      final answered =
          await c.answerQuietly(google, invite, InviteResponse.declined);

      expect(answered, isTrue);
      expect(sent.first.url.queryParameters['iCalUID'], 'lunch-1');
      final patch = sent.last;
      expect(patch.method, 'PATCH');
      expect(patch.url.path, endsWith('/calendars/primary/events/g-1'));
      expect(patch.url.queryParameters['sendUpdates'], 'none',
          reason: 'Do not send a response: Google writes to nobody');
      final attendees =
          (jsonDecode(patch.body) as Map)['attendees'] as List<Object?>;
      expect(
        [for (final a in attendees.cast<Map>()) a['responseStatus']],
        ['accepted', 'declined'],
        reason: "only the account's own answer changes",
      );
    });

    test('is false where Google does not have it, and changes nothing',
        () async {
      final c = calendar((_) => json({'items': <Object?>[]}));

      expect(
        await c.answerQuietly(google, invite, InviteResponse.accepted),
        isFalse,
      );
      expect(sent, hasLength(1));
      expect(sent.single.method, 'GET');
    });
  });

  test('on a Microsoft calendar, answers the event the message links to, '
      'with sendResponse false', () async {
    final c = calendar((r) => r.method == 'GET'
        ? json({
            'id': 'e-1',
            'start': {'dateTime': '2026-10-16T16:00:00.0000000'},
            'end': {'dateTime': '2026-10-16T17:00:00.0000000'},
            'type': 'singleInstance',
          })
        : http.Response('', 202));

    final answered = await c.answerQuietly(
      microsoft,
      invite,
      InviteResponse.tentative,
      linkedEventId: 'e-1',
    );

    expect(answered, isTrue);
    final post = sent.last;
    expect(post.method, 'POST');
    expect(post.url.path, endsWith('/events/e-1/tentativelyAccept'));
    expect((jsonDecode(post.body) as Map)['sendResponse'], isFalse);
  });

  test('an app password reaches no calendar to answer on', () async {
    final c = calendar((_) => json({}));
    await expectLater(
      c.answerQuietly(appPassword, invite, InviteResponse.accepted),
      throwsA(isA<CalendarUnavailable>()),
    );
    expect(sent, isEmpty);
  });
}
