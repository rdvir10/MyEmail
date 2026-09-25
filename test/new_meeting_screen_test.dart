import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
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

  ProviderContainer container({MicrosoftOAuth? oauth}) {
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider.overrideWithValue(calendar),
      if (oauth != null) microsoftOAuthProvider.overrideWithValue(oauth),
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
  }) async {
    final c = container(oauth: oauth);
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
    testWidgets('names the administrator when only they can allow it',
        (tester) async {
      engine = _NeedsConsent(needsAdministrator: true);
      await pumpScreen(tester, accountId: 'acct-ms');
      await type(tester, 'meeting-title', 'Q3 review');

      await send(tester);

      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(find.textContaining('administrator'), findsOneWidget);
      expect(find.text('Allow the calendar'), findsNothing);
      expect(engine.meetings, isEmpty);
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
  Future<void> createMeeting(MeetingDraft meeting) async =>
      throw const CalendarUnavailable('No calendar can be reached.');
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
  }) async {
    signedInAgain = true;
  }

  @override
  Future<void> createMeeting(MeetingDraft meeting) {
    if (!signedInAgain) {
      throw SignInNeedsConsent(
        'The app has not been allowed the calendar.',
        needsAdministrator: needsAdministrator,
      );
    }
    return super.createMeeting(meeting);
  }
}
