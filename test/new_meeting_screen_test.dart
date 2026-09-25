import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/google_oauth.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/meeting.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/accounts/google_sign_in_screen.dart';
import 'package:myemail/ui/accounts/microsoft_sign_in_screen.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';
import 'package:myemail/ui/messages/date_format.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fakes/fake_webview.dart';

/// Setting up a meeting: the screen, where the meeting goes from it, and
/// the ways in.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late SampleMailEngine engine;
  late FakeDeviceCalendar calendar;

  setUp(() {
    engine = SampleMailEngine();
    calendar = FakeDeviceCalendar(timeZone: 'Asia/Jerusalem');
  });

  /// [google] and [openInBrowser] stand in for the app's Google sign-in
  /// where a test reaches it.
  ProviderContainer container({
    MicrosoftOAuth? oauth,
    GoogleOAuth? google,
    Future<bool> Function(Uri)? openInBrowser,
  }) {
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider.overrideWithValue(calendar),
      if (oauth != null) microsoftOAuthProvider.overrideWithValue(oauth),
      if (google != null) ...[
        googleClientIdProvider.overrideWithValue(google.clientId),
        googleOAuthProvider.overrideWithValue(google),
      ],
      if (openInBrowser != null)
        openInBrowserProvider.overrideWithValue(openInBrowser),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  /// The screen on its own, pushed over a plain page so that closing it
  /// has somewhere to go back to, opened for [accountId] and starting at
  /// nine on 1 October 2026.
  Future<ProviderContainer> pumpScreen(
    WidgetTester tester, {
    String accountId = 'acct-personal',
    String title = '',
    MicrosoftOAuth? oauth,
    GoogleOAuth? google,
    Future<bool> Function(Uri)? openInBrowser,
  }) async {
    final c = container(
      oauth: oauth,
      google: google,
      openInBrowser: openInBrowser,
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NewMeetingScreen(
                    accountId: accountId,
                    title: title,
                    start: DateTime(2026, 10, 1, 9),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return c;
  }

  /// The text field under [key], or the one carrying it.
  Finder field(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
        matchRoot: true,
      );

  Future<void> type(WidgetTester tester, String key, String text) =>
      tester.enterText(field(key), text);

  Future<void> send(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
  }

  /// Pick [day] of the month on show in the open date picker.
  Future<void> pickDay(WidgetTester tester, String buttonKey, String day) async {
    await tester.tap(find.byKey(ValueKey(buttonKey)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(day));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  group('the screen', () {
    testWidgets('has From first, then what, who and when, ending an hour on',
        (tester) async {
      await pumpScreen(tester);

      expect(find.text('New meeting'), findsOneWidget);
      // Two sample accounts, so From is a choice.
      expect(find.byKey(const ValueKey('meeting-from-account')), findsOneWidget);
      expect(find.text('personal@example.com'), findsOneWidget);
      for (final label in ['Title', 'Attendees', 'Start', 'End', 'All day', 'Location']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Notes'), findsOneWidget, reason: 'the hint');
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('From'), lessThan(top('Title')));
      expect(top('Title'), lessThan(top('Attendees')));
      expect(top('Attendees'), lessThan(top('Start')));
      expect(top('Start'), lessThan(top('End')));
      expect(find.text(formatDay(DateTime(2026, 10, 1))), findsNWidgets(2));
      expect(find.text('9:00 AM'), findsOneWidget);
      expect(find.text('10:00 AM'), findsOneWidget);
    });

    testWidgets('the end follows the start, keeping the length', (tester) async {
      await pumpScreen(tester);

      await pickDay(tester, 'start-date', '15');

      expect(find.text(formatDay(DateTime(2026, 10, 15))), findsNWidgets(2));
      expect(find.text('9:00 AM'), findsOneWidget);
      expect(find.text('10:00 AM'), findsOneWidget);
    });

    testWidgets('needs a title, and an end after the start', (tester) async {
      await pumpScreen(tester);

      await send(tester);
      expect(find.text('Give the meeting a title.'), findsOneWidget);
      expect(engine.meetings, isEmpty);

      await type(tester, 'meeting-title', 'Q3 review');
      // The start moved to the 15th, the end back to the 1st.
      await pickDay(tester, 'start-date', '15');
      await pickDay(tester, 'end-date', '1');
      await send(tester);

      expect(find.text('The meeting has to end after it starts.'), findsOneWidget);
      expect(find.text('Give the meeting a title.'), findsNothing);
      expect(engine.meetings, isEmpty);
    });

    testWidgets('an address with a typo is caught before anything is sent',
        (tester) async {
      await pumpScreen(tester);
      await type(tester, 'meeting-title', 'Q3 review');
      await type(tester, 'meeting-attendees', 'dana@');

      await send(tester);

      expect(find.text('One of the addresses does not look right.'), findsOneWidget);
      expect(engine.meetings, isEmpty);
    });

    testWidgets('Send puts it on the calendar and says the invitation went',
        (tester) async {
      await pumpScreen(tester);
      await type(tester, 'meeting-title', 'Q3 review');
      await type(tester, 'meeting-attendees',
          'Dana Levi <dana@example.com>, sam@example.com');
      await type(tester, 'meeting-location', 'Room 4');
      await type(tester, 'meeting-notes', 'Bring the numbers.');

      await send(tester);

      final m = engine.meetings.single;
      expect(m.accountId, 'acct-personal');
      expect(m.title, 'Q3 review');
      expect(m.attendees.map((a) => a.email), ['dana@example.com', 'sam@example.com']);
      expect(m.attendees.first.name, 'Dana Levi');
      expect(m.start, DateTime(2026, 10, 1, 9));
      expect(m.end, DateTime(2026, 10, 1, 10));
      expect(m.allDay, isFalse);
      expect(m.location, 'Room 4');
      expect(m.notes, 'Bring the numbers.');
      expect(m.timeZone, 'Asia/Jerusalem', reason: 'the device named its zone');
      expect(find.byType(NewMeetingScreen), findsNothing);
      expect(find.text('Invitation sent'), findsOneWidget);
    });

    testWidgets('with nobody invited it is added, not sent', (tester) async {
      await pumpScreen(tester);
      await type(tester, 'meeting-title', 'Dentist');

      await send(tester);

      expect(engine.meetings.single.hasAttendees, isFalse);
      expect(find.text('Added to your calendar'), findsOneWidget);
    });

    testWidgets('the account is chosen from the header', (tester) async {
      await pumpScreen(tester);
      await type(tester, 'meeting-title', 'Q3 review');

      await tester.tap(find.byKey(const ValueKey('meeting-from-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('projects@example.com').last);
      await tester.pumpAndSettle();
      await send(tester);

      expect(engine.meetings.single.accountId, 'acct-side');
    });

    testWidgets('a whole day is dates alone', (tester) async {
      await pumpScreen(tester);
      await type(tester, 'meeting-title', 'Offsite');

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('start-time')), findsNothing);
      expect(find.byKey(const ValueKey('end-time')), findsNothing);
      await send(tester);

      final m = engine.meetings.single;
      expect(m.allDay, isTrue);
      expect(m.start, DateTime(2026, 10, 1));
      expect(m.end, DateTime(2026, 10, 1));
    });

    testWidgets('backing out asks only once something has been typed',
        (tester) async {
      await pumpScreen(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(NewMeetingScreen), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await type(tester, 'meeting-title', 'Q3 review');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard this meeting?'), findsOneWidget);

      await tester.tap(find.text('Keep writing'));
      await tester.pumpAndSettle();
      expect(find.byType(NewMeetingScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(NewMeetingScreen), findsNothing);
      expect(engine.meetings, isEmpty);
    });
  });

  group('held online', () {
    /// Pick [email] in the From dropdown.
    Future<void> chooseFrom(WidgetTester tester, String email) async {
      await tester.tap(find.byKey(const ValueKey('meeting-from-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(email).last);
      await tester.pumpAndSettle();
    }

    final online = find.byKey(const ValueKey('meeting-online'));
    final kindMenu = find.byKey(const ValueKey('meeting-online-kind'));

    /// Choose [label] from the menu of kinds. Its label is in the tree
    /// twice while the menu is open: the closed menu's, and the menu's.
    Future<void> chooseKind(WidgetTester tester, String label) async {
      await tester.tap(kindMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    testWidgets('no switch for an account whose calendar holds none',
        (tester) async {
      // The sample accounts sign in with app passwords.
      await pumpScreen(tester);

      expect(find.text('Online'), findsNothing);
      expect(online, findsNothing);
    });

    testWidgets('the switch is labelled for where the account holds them, '
        'and follows From', (tester) async {
      engine = _EachKind();
      await pumpScreen(tester, accountId: 'acct-ms');
      expect(find.text('Online'), findsOneWidget);
      expect(online, findsOneWidget);
      expect(find.text('Teams meeting'), findsOneWidget);

      await chooseFrom(tester, 'ron@gmail.com');
      expect(find.text('Google Meet'), findsOneWidget);
      expect(find.text('Teams meeting'), findsNothing);

      await chooseFrom(tester, 'old@gmail.com');
      expect(find.text('Online'), findsNothing);
      expect(online, findsNothing);
    });

    testWidgets('on, the meeting is held online and the message says so',
        (tester) async {
      engine = _EachKind();
      await pumpScreen(tester, accountId: 'acct-ms');
      await type(tester, 'meeting-title', 'Q3 review');
      await type(tester, 'meeting-attendees', 'dana@example.com');
      await tester.tap(online);
      await tester.pumpAndSettle();

      await send(tester);

      expect(engine.meetings.single.online, OnlineMeetingKind.teams);
      expect(find.byType(NewMeetingScreen), findsNothing);
      expect(find.text('Invitation sent, with a Teams link'), findsOneWidget);
    });

    testWidgets('with nobody invited it is added, link and all',
        (tester) async {
      engine = _EachKind();
      await pumpScreen(tester, accountId: 'acct-g');
      await type(tester, 'meeting-title', 'Planning');
      await tester.tap(online);
      await tester.pumpAndSettle();

      await send(tester);

      expect(engine.meetings.single.online, OnlineMeetingKind.googleMeet);
      expect(find.text('Added to your calendar, with a Google Meet link'),
          findsOneWidget);
    });

    testWidgets('off, the meeting is not held online', (tester) async {
      engine = _EachKind();
      await pumpScreen(tester, accountId: 'acct-ms');
      await type(tester, 'meeting-title', 'Q3 review');
      await type(tester, 'meeting-attendees', 'dana@example.com');

      await send(tester);

      expect(engine.meetings.single.online, isNull);
      expect(find.text('Invitation sent'), findsOneWidget);
    });

    testWidgets('what was asked for stays asked for across accounts that '
        'can, and goes unasked from one that cannot', (tester) async {
      engine = _EachKind();
      await pumpScreen(tester, accountId: 'acct-ms');
      await type(tester, 'meeting-title', 'Q3 review');
      await tester.tap(online);
      await tester.pumpAndSettle();

      // To an account whose calendar holds them elsewhere: still asked for,
      // under the new name.
      await chooseFrom(tester, 'ron@gmail.com');
      expect(tester.widget<Switch>(online).value, isTrue);
      expect(find.text('Google Meet'), findsOneWidget);

      // To one whose calendar holds none: no switch, and no link asked for
      // behind it.
      await chooseFrom(tester, 'old@gmail.com');
      expect(online, findsNothing);
      await send(tester);

      expect(engine.meetings.single.accountId, 'acct-p');
      expect(engine.meetings.single.online, isNull);
      expect(find.text('Added to your calendar'), findsOneWidget);
    });

    testWidgets('a Microsoft account with a Gmail account beside it has a '
        'choice, Teams first, and choosing Google Meet asks for it',
        (tester) async {
      engine = _EachKind();
      await pumpScreen(tester, accountId: 'acct-ms');
      await type(tester, 'meeting-title', 'Q3 review');
      await type(tester, 'meeting-attendees', 'dana@example.com');
      expect(kindMenu, findsOneWidget);
      expect(
        tester.widget<DropdownButton<OnlineMeetingKind>>(kindMenu).value,
        OnlineMeetingKind.teams,
      );
      expect(tester.widget<Switch>(online).value, isFalse);

      await chooseKind(tester, 'Google Meet');
      expect(tester.widget<Switch>(online).value, isTrue,
          reason: 'choosing a kind is asking for a link');

      await send(tester);

      expect(engine.meetings.single.online, OnlineMeetingKind.googleMeet);
      expect(find.text('Invitation sent, with a Google Meet link'),
          findsOneWidget);
    });

    testWidgets('the kind chosen is kept through a change of From where the '
        'account can hold it too', (tester) async {
      engine = _EachKind();
      await pumpScreen(tester, accountId: 'acct-ms');
      await chooseKind(tester, 'Google Meet');

      await chooseFrom(tester, 'ron@gmail.com');
      expect(kindMenu, findsNothing, reason: 'one kind is no choice');
      expect(find.text('Google Meet'), findsOneWidget);

      await chooseFrom(tester, 'ron@contoso.com');
      expect(
        tester.widget<DropdownButton<OnlineMeetingKind>>(kindMenu).value,
        OnlineMeetingKind.googleMeet,
      );
      expect(tester.widget<Switch>(online).value, isTrue);
    });

    testWidgets('with no Gmail account in the app there is no choice',
        (tester) async {
      engine = _MicrosoftAlone();
      await pumpScreen(tester, accountId: 'acct-ms');

      expect(kindMenu, findsNothing);
      expect(find.text('Teams meeting'), findsOneWidget);
      expect(find.text('Google Meet'), findsNothing);
    });
  });

  group('Google Meet from a Microsoft account, before the Gmail account '
      'has allowed Meet', () {
    const clientId = '1234-abcd.apps.googleusercontent.com';

    /// A Google that redeems any code for a token naming [email].
    GoogleOAuth google(String email) => GoogleOAuth(
          clientId: clientId,
          httpClient: http_testing.MockClient((request) async {
            final form = Uri.splitQueryString(request.body);
            if (form['grant_type'] != 'authorization_code') {
              return http.Response('{"error":"invalid_grant"}', 400);
            }
            final claims = base64Url
                .encode(utf8.encode(jsonEncode({'sub': '1', 'email': email})))
                .replaceAll('=', '');
            return http.Response(
              jsonEncode({
                'access_token': 'ya29.${form['code']}',
                'refresh_token': '1//r',
                'expires_in': 3600,
                'id_token': 'h.$claims.s',
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }),
        );

    /// What the browser does when the person is done: it follows the
    /// redirect to the loopback address the request named, over a real
    /// socket, which is what the app listens on. As google_sign_in_ui_test
    /// has it.
    Future<void> comeBack(WidgetTester tester, Uri request) async {
      final q = request.queryParameters;
      final back = Uri.parse(q['redirect_uri']!).replace(
        queryParameters: {'code': 'c-1', 'state': q['state']!},
      );
      await tester.runAsync(() async {
        final socket = await Socket.connect(back.host, back.port);
        socket.write('GET ${back.path}?${back.query} HTTP/1.1\r\n'
            'Host: ${back.host}\r\nConnection: close\r\n\r\n');
        await socket.flush();
        await socket.first.timeout(const Duration(seconds: 5));
        socket.destroy();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    }

    testWidgets('names the Gmail account, offers its sign-in with Google '
        'asking for Meet, and sends after it', (tester) async {
      final consent = _MeetNeedsConsent();
      engine = consent;
      final opened = <Uri>[];
      await pumpScreen(
        tester,
        accountId: 'acct-ms',
        google: google('ron@gmail.com'),
        openInBrowser: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      await type(tester, 'meeting-title', 'Q3 review');
      await type(tester, 'meeting-attendees', 'dana@example.com');
      await tester.tap(find.byKey(const ValueKey('meeting-online-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google Meet').last);
      await tester.pumpAndSettle();

      await send(tester);

      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(find.textContaining('make Meet links with ron@gmail.com'),
          findsOneWidget);
      expect(find.text('Allow the calendar'), findsNothing);
      expect(consent.meetings, isEmpty);

      await tester.tap(find.text('Sign in with Google'));
      // Not pumpAndSettle: the sign-in screen shows a spinner for as long
      // as it waits for the browser, and a spinner never settles.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(GoogleSignInScreen), findsOneWidget);
      final asked = opened.single.queryParameters;
      expect(asked['login_hint'], 'ron@gmail.com');
      expect(asked['scope'], contains('meetings.space.created'));
      expect(asked['scope'], contains('https://mail.google.com/'),
          reason: 'the mail stays beside the new permission');

      await comeBack(tester, opened.single);
      await tester.pumpAndSettle();

      expect(consent.signedInAccount, 'acct-g',
          reason: 'the Gmail account, not the meeting\'s');
      expect(consent.meetings.single.online, OnlineMeetingKind.googleMeet);
      expect(find.byType(NewMeetingScreen), findsNothing);
      expect(find.text('Invitation sent, with a Google Meet link'),
          findsOneWidget);
    });
  });

  group('an account whose calendar the app cannot reach', () {
    testWidgets('hands the meeting to the calendar app, attendees and all',
        (tester) async {
      engine = _NoCalendar();
      await pumpScreen(tester);
      await type(tester, 'meeting-title', 'Q3 review');
      await type(tester, 'meeting-attendees', 'dana@example.com, sam@example.com');
      await type(tester, 'meeting-location', 'Room 4');

      await send(tester);

      final e = calendar.inserted.single;
      expect(e.title, 'Q3 review');
      expect(e.attendees, ['dana@example.com', 'sam@example.com']);
      expect(e.location, 'Room 4');
      expect(e.start, DateTime(2026, 10, 1, 9));
      expect(e.end, DateTime(2026, 10, 1, 10));
      expect(e.allDay, isFalse);
      expect(find.byType(NewMeetingScreen), findsNothing);
      expect(find.textContaining('Handed to your calendar app'), findsOneWidget);
    });

    testWidgets('a whole day handed over ends the day after, as the '
        'calendar provider counts it', (tester) async {
      engine = _NoCalendar();
      await pumpScreen(tester);
      await type(tester, 'meeting-title', 'Offsite');
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      await send(tester);

      final e = calendar.inserted.single;
      expect(e.allDay, isTrue);
      expect(e.start, DateTime(2026, 10, 1));
      expect(e.end, DateTime(2026, 10, 2));
    });

    testWidgets('and says so when there is no calendar app either',
        (tester) async {
      engine = _NoCalendar();
      calendar = FakeDeviceCalendar(supported: false);
      await pumpScreen(tester);
      await type(tester, 'meeting-title', 'Q3 review');

      await send(tester);

      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(find.textContaining('no calendar app'), findsOneWidget);
    });
  });

  group('a Microsoft account that has not allowed the calendar', () {
    testWidgets('names the administrator when only they can allow it, and '
        'offers the sign-in that asks them', (tester) async {
      // The sign-in cannot succeed then, but Microsoft's page is where the
      // request to the administrator is made ("Request approval"), which
      // is how the mail permissions were granted the first time. Without
      // the button there was no way to ask.
      final web = FakeWebViewPlatform.install();
      engine = _NeedsConsent(needsAdministrator: true);
      final oauth = MicrosoftOAuth(
        clientId: 'test-client',
        authority: 'https://login.example/common/oauth2/v2.0',
        httpClient: http_testing.MockClient(
          (_) async => http.Response('{}', 500),
        ),
      );
      await pumpScreen(tester, accountId: 'acct-ms', oauth: oauth);
      await type(tester, 'meeting-title', 'Q3 review');

      await send(tester);

      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(find.textContaining("only the organisation's administrator"),
          findsOneWidget);
      expect(find.textContaining('send them the request'), findsOneWidget);
      expect(find.text('Allow the calendar'), findsNothing);
      expect(engine.meetings, isEmpty);

      await tester.tap(find.text('Ask the administrator'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(MicrosoftSignInScreen), findsOneWidget);
      expect(
        web.loadedUrls.last.queryParameters['scope'],
        contains('Calendars.ReadWrite'),
        reason: 'the page asks for the calendar, which is what is requested',
      );
    });

    testWidgets('otherwise offers the sign-in that asks, and sends after it',
        (tester) async {
      final web = FakeWebViewPlatform.install();
      final consent = _NeedsConsent(needsAdministrator: false);
      engine = consent;
      final oauth = MicrosoftOAuth(
        clientId: 'test-client',
        authority: 'https://login.example/common/oauth2/v2.0',
        httpClient: http_testing.MockClient((request) async => http.Response(
              jsonEncode({
                'access_token': 'access',
                'refresh_token': 'refresh',
                'expires_in': 3600,
              }),
              200,
              headers: const {'content-type': 'application/json'},
            )),
      );
      await pumpScreen(tester, accountId: 'acct-ms', oauth: oauth);
      await type(tester, 'meeting-title', 'Q3 review');
      await type(tester, 'meeting-attendees', 'dana@example.com');

      await send(tester);
      expect(find.textContaining('Sign in again to allow it'), findsOneWidget);
      expect(consent.meetings, isEmpty);

      await tester.tap(find.text('Allow the calendar'));
      // Not pumpAndSettle: the sign-in page never reports it has finished
      // loading here, so its progress bar would run for ever.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(MicrosoftSignInScreen), findsOneWidget);
      final asked = web.loadedUrls.last;
      expect(asked.queryParameters['scope'], contains('Calendars.ReadWrite'));
      expect(asked.queryParameters['scope'], contains('Mail.ReadWrite'),
          reason: 'the mail consent stays beside the new one');
      expect(asked.queryParameters['login_hint'], 'ron@contoso.com');

      // Microsoft sends the browser back with a code.
      await web.navigationHandler!(NavigationRequest(
        url: '${MicrosoftOAuth.redirectUri}?code=the-code'
            '&state=${asked.queryParameters['state']}',
        isMainFrame: true,
      ));
      await tester.pumpAndSettle();

      expect(consent.signedInAgain, isTrue);
      expect(consent.meetings.single.title, 'Q3 review');
      expect(find.byType(NewMeetingScreen), findsNothing);
      expect(find.text('Invitation sent'), findsOneWidget);
    });
  });

  group('the ways in', () {
    Future<ProviderContainer> pumpShell(
      WidgetTester tester, {
      Size size = const Size(1400, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = container();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('the ribbon has New meeting, from the folder\'s account',
        (tester) async {
      final c = await pumpShell(tester);
      c.read(selectedFolderIdProvider.notifier).select('acct-side:INBOX');
      await tester.pumpAndSettle();

      await tester.tap(find.text('New meeting'));
      await tester.pumpAndSettle();

      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(find.text('projects@example.com'), findsOneWidget);
    });

    testWidgets('the phone has a small button above New message',
        (tester) async {
      await pumpShell(tester, size: const Size(400, 800));
      final meeting = find.byTooltip('New meeting');
      final message = find.byTooltip('New message');
      expect(meeting, findsOneWidget);
      expect(tester.getBottomLeft(meeting).dy,
          lessThan(tester.getTopLeft(message).dy));

      await tester.tap(meeting);
      await tester.pumpAndSettle();

      expect(find.byType(NewMeetingScreen), findsOneWidget);
    });

    testWidgets('Create calendar event from a message opens it filled in',
        (tester) async {
      final c = await pumpShell(tester);
      final open = c.read(selectedMessageProvider)!;
      final account = c
          .read(accountsProvider)
          .value!
          .firstWhere((a) => a.id == open.accountId);

      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create calendar event…'));
      await tester.pumpAndSettle();

      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(tester.widget<TextField>(field('meeting-title')).controller!.text,
          open.subject);
      final notes =
          tester.widget<TextField>(find.byKey(const ValueKey('meeting-notes')));
      expect(notes.controller!.text, contains('From: ${open.from.display}'));
      expect(find.text(account.emailAddress), findsOneWidget,
          reason: 'from the account the message came to');
      expect(calendar.inserted, isEmpty,
          reason: 'the calendar app is no longer the first stop');
    });
  });
}

/// An engine for an account whose calendar cannot be reached: a Gmail
/// account with an app password, as the real engine answers for one.
class _NoCalendar extends SampleMailEngine {
  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) async =>
      throw const CalendarUnavailable('No calendar can be reached.');
}

/// An engine with an account of each kind, so From can move between them:
/// a Microsoft one, whose calendar holds meetings on Teams; a Google one,
/// with Meet; and one with an app password, whose calendar holds none.
class _EachKind extends SampleMailEngine {
  static const accounts = [
    Account(
      id: 'acct-ms',
      displayName: 'Work',
      emailAddress: 'ron@contoso.com',
      provider: MailProvider.outlook,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF0F6CBD,
    ),
    Account(
      id: 'acct-g',
      displayName: 'Personal',
      emailAddress: 'ron@gmail.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF107C41,
    ),
    Account(
      id: 'acct-p',
      displayName: 'Old',
      emailAddress: 'old@gmail.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFFB4009E,
    ),
  ];

  @override
  Future<List<Account>> loadAccounts() async => accounts;
}

/// An engine with a Microsoft account alone: Teams, and no Gmail account
/// to make a Meet link.
class _MicrosoftAlone extends SampleMailEngine {
  @override
  Future<List<Account>> loadAccounts() async => [_EachKind.accounts.first];
}

/// An engine with an account of each kind whose Gmail account has not yet
/// allowed the app to make Meet links: a meeting on Google Meet from the
/// Microsoft account is refused until that account signs in again.
class _MeetNeedsConsent extends SampleMailEngine {
  String? signedInAccount;

  @override
  Future<List<Account>> loadAccounts() async => _EachKind.accounts;

  @override
  Future<void> updateOAuthToken({
    required String accountId,
    required OAuthToken token,
    String? signedInAs,
  }) async {
    signedInAccount = accountId;
  }

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) {
    if (meeting.online == OnlineMeetingKind.googleMeet &&
        signedInAccount == null) {
      throw const MeetLinkNeedsConsent(
        accountId: 'acct-g',
        emailAddress: 'ron@gmail.com',
        message: 'Not allowed Meet.',
      );
    }
    return super.createMeeting(meeting);
  }
}

/// An engine with one Microsoft account whose calendar Microsoft has not
/// allowed the app: a meeting is refused for want of consent until a
/// sign-in again, after which it goes through.
class _NeedsConsent extends SampleMailEngine {
  _NeedsConsent({required this.needsAdministrator});

  final bool needsAdministrator;
  bool signedInAgain = false;

  static const account = Account(
    id: 'acct-ms',
    displayName: 'Work',
    emailAddress: 'ron@contoso.com',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF0F6CBD,
  );

  @override
  Future<List<Account>> loadAccounts() async => const [account];

  @override
  Future<void> updateOAuthToken({
    required String accountId,
    required OAuthToken token,
    String? signedInAs,
  }) async {
    signedInAgain = true;
  }

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) {
    if (!signedInAgain) {
      throw SignInNeedsConsent(
        'The app has not been allowed the calendar.',
        needsAdministrator: needsAdministrator,
      );
    }
    return super.createMeeting(meeting);
  }
}
