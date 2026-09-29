import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/meeting.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/meeting_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/accounts/google_sign_in_screen.dart';
import 'package:myemail/ui/accounts/microsoft_sign_in_screen.dart';
import 'package:myemail/ui/common/problem_view.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';
import 'package:myemail/ui/messages/date_format.dart';
import 'package:myemail/ui/messages/message_tile.dart';
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

    // The link is made as the switch goes on, not at Send, so that what
    // the invitation says about joining is under the notes while they are
    // written, as Outlook has it.
    group('the link, made as the switch goes on,', () {
      final invite = find.byKey(const ValueKey('meeting-invite-text'));
      const teamsUrl = 'https://teams.microsoft.com/l/meetup-join/sample';
      const meetUrl = 'https://meet.google.com/abc-defg-hij';

      /// [text] in the block under the notes, which is one selectable text
      /// with the whole of what the invitation says.
      Finder saying(String text) =>
          find.descendant(of: invite, matching: find.textContaining(text));

      /// The events the ledger keeps for the next start to delete.
      List<String?> kept(ProviderContainer c) => [
            for (final e in c.read(preparedMeetingLedgerProvider).read())
              e.meeting.eventId,
          ];

      testWidgets('shows the Teams block under the notes for a Microsoft '
          'account, and leaves the notes as they were', (tester) async {
        engine = _EachKind();
        await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-notes', 'Bring the numbers.');

        await tester.tap(online);
        await tester.pumpAndSettle();

        expect(invite, findsOneWidget);
        expect(saying('Meeting ID: 244 810 212 347'), findsOneWidget);
        expect(
          find.descendant(
              of: invite, matching: find.text('Goes with the invitation')),
          findsOneWidget,
        );
        final notes = find.byKey(const ValueKey('meeting-notes'));
        expect(tester.getTopLeft(invite).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(notes).dy));
        // Shown under the notes, not written into them: Exchange drops the
        // Teams meeting from an event whose block comes back changed.
        expect(tester.widget<TextField>(notes).controller!.text,
            'Bring the numbers.');
        final made = engine.preparedMeetings.single;
        expect(made.accountId, 'acct-ms');
        expect(made.kind, OnlineMeetingKind.teams);
        expect(engine.discardedMeetings, isEmpty);
        expect(engine.meetings, isEmpty, reason: 'nothing is sent yet');
      });

      testWidgets('is kept on the ledger while the screen is open',
          (tester) async {
        // An app closed with the screen open leaves an event with nobody on
        // it on the calendar; the next start deletes what the ledger kept.
        engine = _EachKind();
        final c = await pumpScreen(tester, accountId: 'acct-ms');
        expect(kept(c), isEmpty);

        await tester.tap(online);
        await tester.pumpAndSettle();

        final entry =
            c.read(preparedMeetingLedgerProvider).read().single.meeting;
        expect(entry.accountId, 'acct-ms');
        expect(entry.kind, OnlineMeetingKind.teams);
        expect(entry.eventId, engine.preparedMeetings.single.eventId);
        expect(
          c.read(uiStateStoreProvider).readString(UiStateKeys.preparedMeetings),
          isNotNull,
        );
      });

      testWidgets('goes with the meeting at Send, is undone neither then nor '
          'as the screen goes, and leaves the ledger', (tester) async {
        engine = _EachKind();
        final c = await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Q3 review');
        await type(tester, 'meeting-attendees', 'dana@example.com');
        await type(tester, 'meeting-notes', 'Bring the numbers.');
        await tester.tap(online);
        await tester.pumpAndSettle();

        await send(tester);

        final m = engine.meetings.single;
        expect(m.prepared, same(engine.preparedMeetings.single));
        expect(m.preparedHere, same(m.prepared));
        expect(m.notes, 'Bring the numbers.',
            reason: 'the block goes as the calendar made it, not in the notes');
        // Sent, it is the meeting now: the screen going must not delete it,
        // nor the next start.
        expect(find.byType(NewMeetingScreen), findsNothing);
        expect(engine.discardedMeetings, isEmpty);
        expect(kept(c), isEmpty);
        expect(find.text('Invitation sent, with a Teams link'), findsOneWidget);
      });

      testWidgets('is undone when the switch goes off, and the block goes',
          (tester) async {
        engine = _EachKind();
        await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Q3 review');
        await tester.tap(online);
        await tester.pumpAndSettle();
        expect(invite, findsOneWidget);

        await tester.tap(online);
        await tester.pumpAndSettle();

        expect(invite, findsNothing);
        expect(engine.discardedMeetings.single,
            same(engine.preparedMeetings.single));

        await send(tester);
        expect(engine.meetings.single.online, isNull);
        expect(engine.meetings.single.prepared, isNull);
      });

      testWidgets('choosing Google Meet undoes the Teams meeting and shows the '
          'Meet link in its place', (tester) async {
        engine = _EachKind();
        await pumpScreen(tester, accountId: 'acct-ms');
        await tester.tap(online);
        await tester.pumpAndSettle();
        final teams = engine.preparedMeetings.single;

        await chooseKind(tester, 'Google Meet');

        expect(engine.discardedMeetings.single, same(teams));
        expect(engine.preparedMeetings, hasLength(2));
        final meet = engine.preparedMeetings.last;
        expect(meet.kind, OnlineMeetingKind.googleMeet);
        expect(meet.accountId, 'acct-ms');
        expect(saying('Join with Google Meet: $meetUrl'), findsOneWidget);
        expect(saying('Meeting ID'), findsNothing);

        // The kind already made, chosen again, makes no other.
        await chooseKind(tester, 'Google Meet');
        expect(engine.preparedMeetings, hasLength(2));
        expect(engine.discardedMeetings, hasLength(1));
      });

      testWidgets("a change of From undoes the old account's meeting and "
          'makes one for the new', (tester) async {
        engine = _EachKind();
        await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Planning');
        await tester.tap(online);
        await tester.pumpAndSettle();
        final teams = engine.preparedMeetings.single;

        await chooseFrom(tester, 'ron@gmail.com');

        expect(engine.discardedMeetings.single, same(teams));
        expect(engine.preparedMeetings, hasLength(2));
        final meet = engine.preparedMeetings.last;
        expect(meet.accountId, 'acct-g');
        expect(meet.kind, OnlineMeetingKind.googleMeet);
        expect(saying(meetUrl), findsOneWidget);
        expect(saying('Meeting ID'), findsNothing);

        await send(tester);
        expect(engine.meetings.single.accountId, 'acct-g');
        expect(engine.meetings.single.prepared, same(meet));
        expect(engine.discardedMeetings, hasLength(1));
      });

      testWidgets('a change of From to an account that holds none undoes it, '
          'and makes none in its place', (tester) async {
        engine = _EachKind();
        await pumpScreen(tester, accountId: 'acct-ms');
        await tester.tap(online);
        await tester.pumpAndSettle();

        await chooseFrom(tester, 'old@gmail.com');

        expect(engine.discardedMeetings.single,
            same(engine.preparedMeetings.single));
        expect(engine.preparedMeetings, hasLength(1));
        expect(invite, findsNothing);
      });

      testWidgets('is undone when the screen is left untouched',
          (tester) async {
        engine = _EachKind();
        await pumpScreen(tester, accountId: 'acct-ms');
        await tester.tap(online);
        await tester.pumpAndSettle();

        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(find.byType(NewMeetingScreen), findsNothing);
        expect(engine.discardedMeetings.single,
            same(engine.preparedMeetings.single));
        expect(engine.meetings, isEmpty);
      });

      testWidgets('is undone when a half-written meeting is discarded, and '
          'not when writing goes on', (tester) async {
        engine = _EachKind();
        await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Q3 review');
        await tester.tap(online);
        await tester.pumpAndSettle();

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Keep writing'));
        await tester.pumpAndSettle();
        expect(engine.discardedMeetings, isEmpty);
        expect(invite, findsOneWidget);

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Discard'));
        await tester.pumpAndSettle();
        expect(find.byType(NewMeetingScreen), findsNothing);
        expect(engine.discardedMeetings.single,
            same(engine.preparedMeetings.single));
      });

      testWidgets('still being made when Send is tapped, is waited for, and '
          'the meeting goes with it', (tester) async {
        final slow = _SlowLink();
        engine = slow;
        await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Q3 review');
        await type(tester, 'meeting-attendees', 'dana@example.com');
        // Not pumpAndSettle while it is being made: its spinner never
        // settles.
        await tester.tap(online);
        await tester.pump();
        expect(find.text('Making a Teams link…'), findsOneWidget);

        await tester.tap(find.byTooltip('Send'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(slow.meetings, isEmpty, reason: 'Send waits for the link');
        expect(tester.widget<Switch>(online).onChanged, isNull,
            reason: 'the screen is sending, and the switch stays put');

        slow.gate.complete();
        await tester.pumpAndSettle();

        expect(slow.meetings.single.prepared,
            same(slow.preparedMeetings.single));
        expect(slow.discardedMeetings, isEmpty);
        expect(find.byType(NewMeetingScreen), findsNothing);
        expect(find.text('Invitation sent, with a Teams link'), findsOneWidget);
      });

      testWidgets('that comes after the switch went off is undone as it comes',
          (tester) async {
        final slow = _SlowLink();
        engine = slow;
        await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Q3 review');
        await tester.tap(online);
        await tester.pump();
        await tester.tap(online);
        await tester.pump();
        expect(invite, findsNothing);

        slow.gate.complete();
        await tester.pumpAndSettle();

        expect(slow.discardedMeetings.single,
            same(slow.preparedMeetings.single));
        expect(invite, findsNothing);
        await send(tester);
        expect(slow.meetings.single.online, isNull);
        expect(slow.meetings.single.prepared, isNull);
      });

      testWidgets('that comes after the screen was left is undone as it comes',
          (tester) async {
        final slow = _SlowLink();
        engine = slow;
        await pumpScreen(tester, accountId: 'acct-ms');
        await tester.tap(online);
        await tester.pump();

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(NewMeetingScreen), findsNothing);
        slow.gate.complete();
        await tester.pumpAndSettle();

        expect(slow.discardedMeetings.single,
            same(slow.preparedMeetings.single));
        expect(slow.meetings, isEmpty);
      });

      testWidgets('that could not be made is left to Send, which still sends '
          'with a link', (tester) async {
        engine = _LinkFails();
        await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Q3 review');
        await type(tester, 'meeting-attendees', 'dana@example.com');
        await tester.tap(online);
        await tester.pumpAndSettle();

        expect(find.text('A Teams link is added when you send.'),
            findsOneWidget);
        // Not a failure to report: Send makes the link as it always did,
        // and says what went wrong only if it goes wrong again.
        expect(find.textContaining('could not be reached'), findsNothing);

        await send(tester);

        final m = engine.meetings.single;
        expect(m.online, OnlineMeetingKind.teams);
        expect(m.prepared, isNull);
        expect(find.text('Invitation sent, with a Teams link'), findsOneWidget);
      });

      testWidgets('a Send that fails puts it back on the ledger, and the next '
          'Send goes with it', (tester) async {
        final flaky = _SendFailsOnce();
        engine = flaky;
        final c = await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Q3 review');
        await type(tester, 'meeting-attendees', 'dana@example.com');
        await tester.tap(online);
        await tester.pumpAndSettle();
        final made = flaky.preparedMeetings.single;

        await send(tester);
        // Still made, and not sent: the next start's to delete should the
        // app be closed now.
        expect(find.byType(NewMeetingScreen), findsOneWidget);
        expect(kept(c), [made.eventId]);
        expect(flaky.discardedMeetings, isEmpty);

        await send(tester);
        expect(flaky.meetings.single.prepared, same(made));
        expect(kept(c), isEmpty);
        expect(flaky.discardedMeetings, isEmpty);
      });

      testWidgets('made and then not undone by the calendar, is kept on the '
          'ledger, left to Send, and Send still sends', (tester) async {
        final left = _LinkLeft();
        engine = left;
        final c = await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Q3 review');
        await type(tester, 'meeting-attendees', 'dana@example.com');
        await tester.tap(online);
        await tester.pumpAndSettle();

        // The event with nobody on it is the next start's to delete.
        final entry =
            c.read(preparedMeetingLedgerProvider).read().single.meeting;
        expect(entry.eventId, 'left-shell');
        expect(entry.accountId, 'acct-ms');
        expect(entry.kind, OnlineMeetingKind.teams);
        expect(
          c.read(uiStateStoreProvider).readString(UiStateKeys.preparedMeetings),
          contains('left-shell'),
        );
        expect(saying('A Teams link is added when you send.'), findsOneWidget);
        // What went wrong is the cause, a connection, which Send retries:
        // not a failure to report.
        expect(find.textContaining('could not be reached'), findsNothing);
        expect(find.byType(ProblemView), findsNothing);

        await send(tester);

        final m = left.meetings.single;
        expect(m.online, OnlineMeetingKind.teams);
        expect(m.prepared, isNull);
        expect(find.byType(NewMeetingScreen), findsNothing);
        expect(find.text('Invitation sent, with a Teams link'), findsOneWidget);
        // Not the meeting that went: still the next start's to delete.
        expect(kept(c), ['left-shell']);
        expect(left.discardedMeetings, isEmpty);
      });

      testWidgets('made and then not undone, for want of consent, offers the '
          'sign-in as the cause asks, and keeps the event on the ledger',
          (tester) async {
        engine = _LinkLeft(const SignInNeedsConsent(
          'The app has not been allowed the calendar.',
          needsAdministrator: false,
        ));
        final c = await pumpScreen(tester, accountId: 'acct-ms');
        await tester.tap(online);
        await tester.pumpAndSettle();

        expect(kept(c), ['left-shell']);
        expect(find.textContaining('Sign in again to allow it'), findsOneWidget);
        expect(find.text('Allow the calendar'), findsOneWidget);
        expect(find.byType(ProblemView), findsNothing);
      });

      testWidgets('that the calendar could not use at Send, and made anew, is '
          'undone, taken off the ledger, and the message says the link is new',
          (tester) async {
        final remade = _Remade();
        engine = remade;
        final c = await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Q3 review');
        await type(tester, 'meeting-attendees', 'dana@example.com');
        await tester.tap(online);
        await tester.pumpAndSettle();
        final made = remade.preparedMeetings.single;
        expect(kept(c), [made.eventId]);

        await send(tester);

        expect(remade.meetings.single.prepared, same(made));
        expect(find.byType(NewMeetingScreen), findsNothing);
        // The link shown may have been copied: it is not the one that went.
        expect(
          find.text('Invitation sent, with a new Teams link: the one shown '
              'could not be used'),
          findsOneWidget,
        );
        expect(find.text('Invitation sent, with a Teams link'), findsNothing);
        expect(remade.discardedMeetings.single, same(made));
        expect(kept(c), isEmpty);
      });

      testWidgets('that the calendar could not use, with nobody invited, is '
          'added with a new link and says so', (tester) async {
        final remade = _Remade();
        engine = remade;
        final c = await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Planning');
        await tester.tap(online);
        await tester.pumpAndSettle();

        await send(tester);

        expect(
          find.text('Added to your calendar, with a new Teams link: the one '
              'shown could not be used'),
          findsOneWidget,
        );
        expect(remade.discardedMeetings.single,
            same(remade.preparedMeetings.single));
        expect(kept(c), isEmpty);
      });

      testWidgets('a Meet link alone, with no event made ahead, is never '
          'called new whatever id the meeting comes back with',
          (tester) async {
        // Meet for a Microsoft account is a link with no event: the id the
        // calendar gives the meeting cannot differ from one there never was.
        final remade = _Remade();
        engine = remade;
        final c = await pumpScreen(tester, accountId: 'acct-ms');
        await type(tester, 'meeting-title', 'Q3 review');
        await type(tester, 'meeting-attendees', 'dana@example.com');
        await chooseKind(tester, 'Google Meet');
        final made = remade.preparedMeetings.single;
        expect(made.eventId, isNull);

        await send(tester);

        expect(remade.meetings.single.prepared, same(made));
        expect(find.text('Invitation sent, with a Google Meet link'),
            findsOneWidget);
        expect(remade.discardedMeetings, isEmpty);
        expect(kept(c), isEmpty);
      });

      group('under the notes, where there is room,', () {
        /// A phone standing up: 1080 by 2400 at 2.625, 411 by 914 or so.
        void phone(WidgetTester tester) {
          tester.view.physicalSize = const Size(1080, 2400);
          tester.view.devicePixelRatio = 2.625;
          addTearDown(tester.view.reset);
        }

        final notes = find.byKey(const ValueKey('meeting-notes'));

        testWidgets('shows on a phone with the keyboard down', (tester) async {
          phone(tester);
          engine = _EachKind();
          await pumpScreen(tester, accountId: 'acct-ms');
          await tester.tap(online);
          await tester.pumpAndSettle();

          expect(invite, findsOneWidget);
          expect(saying('Meeting ID: 244 810 212 347'), findsOneWidget);
          expect(tester.getSize(invite).height,
              lessThanOrEqualTo(tester.getSize(notes).height));
        });

        testWidgets('goes while the keyboard is up on a phone, and comes '
            'back as it goes down', (tester) async {
          phone(tester);
          engine = _EachKind();
          await pumpScreen(tester, accountId: 'acct-ms');
          await tester.tap(online);
          await tester.pumpAndSettle();
          expect(invite, findsOneWidget);

          await tester.tap(notes);
          await tester.pump();
          // Gboard's height on such a phone, in logical pixels.
          tester.view.viewInsets =
              const FakeViewPadding(bottom: 271 * 2.625);
          await tester.pumpAndSettle();

          expect(invite, findsNothing,
              reason: 'the notes are what is being written');
          expect(notes, findsOneWidget);
          expect(engine.discardedMeetings, isEmpty,
              reason: 'hidden, not undone');

          tester.view.resetViewInsets();
          await tester.pumpAndSettle();

          expect(invite, findsOneWidget);
          expect(saying('Meeting ID: 244 810 212 347'), findsOneWidget);
        });

        testWidgets('shows with large text where there is room, and no '
            'taller than the notes', (tester) async {
          // 800 by 1000: wide enough for the header rows in the test's
          // font, whose every letter is a full em, at 1.3 times.
          tester.view.physicalSize = const Size(1600, 2000);
          tester.view.devicePixelRatio = 2;
          addTearDown(tester.view.reset);
          tester.platformDispatcher.textScaleFactorTestValue = 1.3;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          engine = _EachKind();
          await pumpScreen(tester, accountId: 'acct-ms');
          await tester.tap(online);
          await tester.pumpAndSettle();

          expect(invite, findsOneWidget);
          expect(saying('Meeting ID: 244 810 212 347'), findsOneWidget);
          expect(tester.getSize(invite).height,
              lessThanOrEqualTo(tester.getSize(notes).height));
          expect(tester.takeException(), isNull, reason: 'no overflow');
        });
      });

      // testWidgets takes no reason to skip for; the group carries it.
      group('while Send is on its way,', () {
        testWidgets('is not undone when the screen is left', (tester) async {
          // The meeting goes out whatever the screen does now: Send cannot
          // be called back. Undone meanwhile, the calendar deletes the
          // event between its details and its attendees (Graph's second
          // PATCH then fails), or, for Gmail, after the invitations went,
          // telling nobody.
          final slow = _SlowSend();
          engine = slow;
          await pumpScreen(tester, accountId: 'acct-ms');
          await type(tester, 'meeting-title', 'Q3 review');
          await type(tester, 'meeting-attendees', 'dana@example.com');
          await tester.tap(online);
          await tester.pumpAndSettle();

          await tester.tap(find.byTooltip('Send'));
          await tester.pump();
          await tester.pageBack();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text('Discard'));
          // Gone before the calendar answers.
          await tester.pumpAndSettle();
          expect(find.byType(NewMeetingScreen), findsNothing);
          slow.gate.complete();
          await tester.pumpAndSettle();

          expect(slow.meetings.single.prepared,
              same(slow.preparedMeetings.single));
          expect(slow.discardedMeetings, isEmpty);
        });

        // Sent, it must not be the next start's to delete: taken off the
        // ledger before it goes, and not put back while the calendar takes
        // its time, the screen there or left.
        for (final leave in [false, true]) {
          testWidgets(
              'leaves the ledger, however long the calendar takes'
              '${leave ? ', the screen left meanwhile' : ''}', (tester) async {
            final slow = _SlowSend();
            engine = slow;
            final c = await pumpScreen(tester, accountId: 'acct-ms');
            await type(tester, 'meeting-title', 'Q3 review');
            await type(tester, 'meeting-attendees', 'dana@example.com');
            await tester.tap(online);
            await tester.pumpAndSettle();
            final made = slow.preparedMeetings.single;
            expect(kept(c), [made.eventId]);

            await tester.tap(find.byTooltip('Send'));
            await tester.pump();
            expect(kept(c), isEmpty, reason: 'off it before it goes');
            if (leave) {
              await tester.pageBack();
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 300));
              await tester.tap(find.text('Discard'));
              // Gone before the calendar answers.
              await tester.pumpAndSettle();
              expect(find.byType(NewMeetingScreen), findsNothing);
            }
            // Not pumpAndSettle while it is sending: its spinner never
            // settles.
            for (var i = 0; i < 10; i++) {
              await tester.pump(const Duration(seconds: 3));
              expect(kept(c), isEmpty);
            }
            expect(slow.meetings, isEmpty, reason: 'still on its way');

            slow.gate.complete();
            await tester.pumpAndSettle();

            expect(slow.meetings.single.prepared, same(made));
            expect(kept(c), isEmpty);
            expect(slow.discardedMeetings, isEmpty);
            expect(find.byType(NewMeetingScreen), findsNothing);
            if (!leave) {
              expect(find.text('Invitation sent, with a Teams link'),
                  findsOneWidget);
            }
          });
        }
      });

      group('refused for Meet,', () {
        testWidgets('takes its consent notice away once Teams is chosen '
            'instead', (tester) async {
          engine = _MeetNeedsConsent();
          await pumpScreen(tester, accountId: 'acct-ms');
          await chooseKind(tester, 'Google Meet');
          expect(find.textContaining('make Meet links with ron@gmail.com'),
              findsOneWidget);

          await chooseKind(tester, 'Teams meeting');

          expect(engine.preparedMeetings.single.kind, OnlineMeetingKind.teams);
          expect(find.textContaining('make Meet links'), findsNothing);
          expect(find.text('Sign in with Google'), findsNothing);
          expect(saying('Meeting ID: 244 810 212 347'), findsOneWidget);
        });
      });

      testWidgets('Copy link puts the join link on the clipboard and says so',
          (tester) async {
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            calls.add(call);
            return null;
          },
        );
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null));
        engine = _EachKind();
        await pumpScreen(tester, accountId: 'acct-ms');
        await tester.tap(online);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('meeting-copy-link')));
        await tester.pumpAndSettle();

        final set = calls.singleWhere((c) => c.method == 'Clipboard.setData');
        expect((set.arguments as Map)['text'], teamsUrl);
        expect(find.text('Link copied'), findsOneWidget);
      });
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

    /// The screen for a meeting from the Microsoft account, with its title
    /// and someone to invite, and Google Meet chosen: which is when its
    /// link is asked for, and refused. The browser's addresses go in
    /// [opened].
    Future<void> chooseMeet(WidgetTester tester, List<Uri> opened) async {
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
    }

    /// Sign in with Google from the notice, and come back from the browser.
    Future<void> signIn(WidgetTester tester, List<Uri> opened) async {
      await tester.tap(find.text('Sign in with Google'));
      // Not pumpAndSettle: the sign-in screen shows a spinner for as long
      // as it waits for the browser, and a spinner never settles.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(GoogleSignInScreen), findsOneWidget);
      await comeBack(tester, opened.single);
      await tester.pumpAndSettle();
    }

    testWidgets('names the Gmail account as Google Meet is chosen, offers its '
        'sign-in with Google asking for Meet, and makes the link after it '
        'rather than sending', (tester) async {
      final consent = _MeetNeedsConsent();
      engine = consent;
      final opened = <Uri>[];
      await chooseMeet(tester, opened);

      // Before Send: the link is made as Meet is chosen, and that is where
      // Google refuses it.
      expect(find.textContaining('make Meet links with ron@gmail.com'),
          findsOneWidget);
      expect(find.text('Allow the calendar'), findsNothing);
      expect(consent.preparedMeetings, isEmpty);
      expect(consent.meetings, isEmpty);

      await tester.tap(find.text('Sign in with Google'));
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
      // Signed in for the link, it makes the link: nobody is invited until
      // Send, and the screen stays for the rest to be written.
      expect(consent.meetings, isEmpty);
      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(find.textContaining('make Meet links'), findsNothing);
      expect(consent.preparedMeetings.single.kind, OnlineMeetingKind.googleMeet);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('meeting-invite-text')),
          matching: find
              .text('Join with Google Meet: https://meet.google.com/abc-defg-hij'),
        ),
        findsOneWidget,
      );

      await send(tester);

      expect(consent.meetings.single.prepared,
          same(consent.preparedMeetings.single));
      expect(find.byType(NewMeetingScreen), findsNothing);
      expect(find.text('Invitation sent, with a Google Meet link'),
          findsOneWidget);
    });

    testWidgets('Send before the sign-in is refused too, and the sign-in then '
        'sends', (tester) async {
      final consent = _MeetNeedsConsent();
      engine = consent;
      final opened = <Uri>[];
      await chooseMeet(tester, opened);

      await send(tester);

      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(find.textContaining('make Meet links with ron@gmail.com'),
          findsOneWidget);
      expect(consent.meetings, isEmpty);

      await signIn(tester, opened);

      expect(consent.signedInAccount, 'acct-g');
      // Asked for at Send, so the sign-in sends: the link is made there, as
      // it was before any was made ahead.
      expect(consent.meetings.single.online, OnlineMeetingKind.googleMeet);
      expect(consent.meetings.single.prepared, isNull);
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

    /// A Microsoft that redeems any code for a token.
    MicrosoftOAuth grants() => MicrosoftOAuth(
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

    testWidgets('otherwise offers the sign-in that asks, and sends after it',
        (tester) async {
      final web = FakeWebViewPlatform.install();
      final consent = _NeedsConsent(needsAdministrator: false);
      engine = consent;
      final oauth = grants();
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

    testWidgets('turning Teams on offers the sign-in before Send, and the '
        'sign-in makes the link rather than sending', (tester) async {
      final web = FakeWebViewPlatform.install();
      final consent = _NeedsConsent(needsAdministrator: false);
      engine = consent;
      await pumpScreen(tester, accountId: 'acct-ms', oauth: grants());
      await type(tester, 'meeting-title', 'Q3 review');
      await type(tester, 'meeting-attendees', 'dana@example.com');

      await tester.tap(find.byKey(const ValueKey('meeting-online')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Sign in again to allow it'), findsOneWidget);
      expect(consent.preparedMeetings, isEmpty);
      expect(consent.meetings, isEmpty);

      await tester.tap(find.text('Allow the calendar'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(MicrosoftSignInScreen), findsOneWidget);
      final asked = web.loadedUrls.last;
      await web.navigationHandler!(NavigationRequest(
        url: '${MicrosoftOAuth.redirectUri}?code=the-code'
            '&state=${asked.queryParameters['state']}',
        isMainFrame: true,
      ));
      await tester.pumpAndSettle();

      expect(consent.signedInAgain, isTrue);
      expect(consent.meetings, isEmpty, reason: 'nobody is invited before Send');
      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(find.textContaining('Sign in again to allow it'), findsNothing);
      expect(consent.preparedMeetings.single.kind, OnlineMeetingKind.teams);
      expect(find.textContaining('Meeting ID: 244 810 212 347'), findsOneWidget);

      await send(tester);

      expect(consent.meetings.single.prepared,
          same(consent.preparedMeetings.single));
      expect(find.text('Invitation sent, with a Teams link'), findsOneWidget);
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

    testWidgets("on a phone it is in the reading pane's menu, not the bar",
        (tester) async {
      final c = await pumpShell(tester, size: const Size(400, 900));
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final open = c.read(selectedMessageProvider)!;
      final pane = find.byType(ReadingPane);

      expect(
        find.descendant(
            of: pane,
            matching: find.byKey(const ValueKey('meeting-from-message'))),
        findsNothing,
      );
      await tester.tap(find.descendant(of: pane, matching: find.byTooltip('More')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Meeting from this message…'));
      await tester.pumpAndSettle();

      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(
        tester.widget<TextField>(field('meeting-attendees')).controller!.text,
        contains(open.from.email),
      );
    });

    testWidgets('on a tablet it is on the bar, and not in the menu too',
        (tester) async {
      await pumpShell(tester);
      final pane = find.byType(ReadingPane);
      expect(
        find.descendant(
            of: pane,
            matching: find.byKey(const ValueKey('meeting-from-message'))),
        findsOneWidget,
      );
      await tester.tap(find.descendant(of: pane, matching: find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(find.text('Meeting from this message…'), findsNothing);
    });

    testWidgets('on a tablet standing up, with the pane below, it goes in '
        'the menu so More stays on the bar', (tester) async {
      // 824 wide, the tree beside the list and the message under it: with
      // the meeting button the row was wider than the pane, and More, with
      // Print and Save source in it, went off the end.
      final c = await pumpShell(tester, size: const Size(824, 1200));
      c.read(displayProvider.notifier)
          .setReadingPane(ReadingPanePosition.bottom);
      await tester.pumpAndSettle();
      final pane = find.byType(ReadingPane);
      if (pane.evaluate().isEmpty) {
        await tester.tap(find.byType(MessageTile).first);
        await tester.pumpAndSettle();
      }

      final more = tester.getRect(
          find.descendant(of: pane, matching: find.byTooltip('More')).first);
      expect(more.right, lessThanOrEqualTo(tester.getRect(pane.first).right),
          reason: 'More is on screen');
      if (find
          .descendant(
              of: pane,
              matching: find.byKey(const ValueKey('meeting-from-message')))
          .evaluate()
          .isEmpty) {
        await tester.tap(
            find.descendant(of: pane, matching: find.byTooltip('More')).first);
        await tester.pumpAndSettle();
        expect(find.text('Meeting from this message…'), findsOneWidget);
      }
    });

    testWidgets('a meeting from a message opens filled in', (tester) async {
      final c = await pumpShell(tester);
      final open = c.read(selectedMessageProvider)!;
      final account = c
          .read(accountsProvider)
          .value!
          .firstWhere((a) => a.id == open.accountId);

      // On a tablet it is on the reading pane's bar, beside Forward.
      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('Meeting from this message'),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(tester.widget<TextField>(field('meeting-title')).controller!.text,
          open.subject);
      final notes =
          tester.widget<TextField>(find.byKey(const ValueKey('meeting-notes')));
      expect(notes.controller!.text, contains('From: ${open.from.display}'));
      expect(find.text(account.emailAddress), findsOneWidget,
          reason: 'from the account the message came to');
      expect(
        tester.widget<TextField>(field('meeting-attendees')).controller!.text,
        contains(open.from.email),
        reason: 'everyone on the message, as Reply with Meeting has them',
      );
      expect(calendar.inserted, isEmpty,
          reason: 'the calendar app is no longer the first stop');
    });
  });

  group('who a meeting from a message asks', () {
    MailMessage mail() => MailMessage(
          id: 'a:INBOX#1',
          accountId: 'a',
          folderId: 'a:INBOX',
          uid: 1,
          subject: 'Visit',
          preview: '',
          from: const MailAddress(email: 'don@hadco-metal.com', name: 'Don'),
          to: const [
            MailAddress(email: 'RDvir@hadco-metal.com', name: 'Ron'),
            MailAddress(email: 'gary@hadco-metal.com', name: 'Gary'),
          ],
          cc: const [
            MailAddress(email: 'Don@hadco-metal.com'),
            MailAddress(email: 'nz@example.com'),
          ],
          date: DateTime(2026, 9, 28),
        );

    test('whoever a reply goes to, and only addresses', () {
      final form = MailMessage(
        id: 'a:INBOX#2',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 2,
        subject: 'Can we meet Thursday?',
        preview: '',
        from: const MailAddress(email: 'noreply@hadco-metal.com'),
        replyTo: const [MailAddress(email: 'customer@client.com')],
        to: const [
          MailAddress(email: 'undisclosed-recipients'),
          MailAddress(email: 'Hadco Team'),
        ],
        cc: const [
          MailAddress(
              email: '/O=EXCHANGELABS/OU=EXCHANGE ADMINISTRATIVE GROUP '
                  '(FYDIBOHF23SPDLT)/CN=RECIPIENTS/CN=abc'),
        ],
        date: DateTime(2026, 9, 28),
      );

      expect(
        [for (final a in meetingAttendeesFor(form, own: const {})) a.email],
        ['customer@client.com'],
      );
    });

    test('the sender, then everyone it went to, once each, never you', () {
      expect(
        [
          for (final a in meetingAttendeesFor(mail(),
              own: const {'rdvir@hadco-metal.com'}))
            a.email,
        ],
        ['don@hadco-metal.com', 'gary@hadco-metal.com', 'nz@example.com'],
      );
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

/// An engine with an account of each kind whose links take until [gate]
/// opens: a link still being made when Send is tapped, the switch goes
/// off, or the screen is left.
class _SlowLink extends _EachKind {
  final gate = Completer<void>();

  @override
  Future<PreparedMeeting?> prepareOnlineMeeting(MeetingDraft meeting) async {
    await gate.future;
    return super.prepareOnlineMeeting(meeting);
  }
}

/// An engine with an account of each kind whose calendar cannot be reached
/// while the screen is open, so no link is made ahead; Send still sends.
class _LinkFails extends _EachKind {
  @override
  Future<PreparedMeeting?> prepareOnlineMeeting(MeetingDraft meeting) async =>
      throw const ConnectionFailed('The calendar could not be reached.');
}

/// An engine with an account of each kind whose calendar made the event
/// for the link and then failed, and could not delete it again: the event
/// is left over, named for the ledger, and [cause] is what went wrong.
class _LinkLeft extends _EachKind {
  _LinkLeft([
    this.cause = const ConnectionFailed('The calendar could not be reached.'),
  ]);

  final Object cause;

  @override
  Future<PreparedMeeting?> prepareOnlineMeeting(MeetingDraft meeting) async =>
      throw PreparedMeetingLeft(
        PreparedMeeting(
          accountId: meeting.accountId,
          kind: meeting.online!,
          eventId: 'left-shell',
          joinUrl: '',
          inviteText: '',
        ),
        cause,
      );
}

/// An engine with an account of each kind whose calendar, at Send, could
/// not use the meeting made ahead and made another in its place, as the
/// real ones do when it was deleted meanwhile or lost its Teams meeting.
class _Remade extends _EachKind {
  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) async {
    final made = await super.createMeeting(meeting);
    return CreatedMeeting(
      id: 'remade-${meetings.length}',
      joinUrl: made.joinUrl,
    );
  }
}

/// An engine with an account of each kind whose Send takes until [gate]
/// opens: a meeting on its way when the screen is left.
class _SlowSend extends _EachKind {
  final gate = Completer<void>();

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) async {
    await gate.future;
    return super.createMeeting(meeting);
  }
}

/// An engine with an account of each kind whose first Send fails on the
/// way, and whose second goes through.
class _SendFailsOnce extends _EachKind {
  bool _failed = false;

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) async {
    if (!_failed) {
      _failed = true;
      throw const ConnectionFailed('The calendar could not be reached.');
    }
    return super.createMeeting(meeting);
  }
}

/// An engine with an account of each kind whose Gmail account has not yet
/// allowed the app to make Meet links: a meeting on Google Meet from the
/// Microsoft account is refused until that account signs in again, both
/// its link made as it is chosen and the meeting at Send.
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
  Future<PreparedMeeting?> prepareOnlineMeeting(MeetingDraft meeting) {
    _refuseMeet(meeting);
    return super.prepareOnlineMeeting(meeting);
  }

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) {
    _refuseMeet(meeting);
    return super.createMeeting(meeting);
  }

  void _refuseMeet(MeetingDraft meeting) {
    if (meeting.online == OnlineMeetingKind.googleMeet &&
        signedInAccount == null) {
      throw const MeetLinkNeedsConsent(
        accountId: 'acct-g',
        emailAddress: 'ron@gmail.com',
        message: 'Not allowed Meet.',
      );
    }
  }
}

/// An engine with one Microsoft account whose calendar Microsoft has not
/// allowed the app: a meeting, and its Teams link made ahead, are refused
/// for want of consent until a sign-in again, after which they go through.
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
  Future<PreparedMeeting?> prepareOnlineMeeting(MeetingDraft meeting) {
    _refuse();
    return super.prepareOnlineMeeting(meeting);
  }

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) {
    _refuse();
    return super.createMeeting(meeting);
  }

  void _refuse() {
    if (!signedInAgain) {
      throw SignInNeedsConsent(
        'The app has not been allowed the calendar.',
        needsAdministrator: needsAdministrator,
      );
    }
  }
}
