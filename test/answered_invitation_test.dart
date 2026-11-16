import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/answered_invitations.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/notifications/notification_actions.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/calendar_meeting.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/messages/reading_pane.dart';

import 'fakes/fake_webview.dart';

/// An invitation answered goes to Deleted Items, as Outlook sends it, from
/// its card and from its notification, and from the calendar (#51);
/// Settings, Calendar keeps it instead.
void main() {
  final ics = [
    'BEGIN:VCALENDAR',
    'METHOD:REQUEST',
    'BEGIN:VEVENT',
    'UID:plan-1@example.com',
    'SUMMARY:Planning',
    'DTSTART:20261028T100000Z',
    'DTEND:20261028T110000Z',
    'ORGANIZER;CN=Dana Levi:mailto:dana@example.com',
    'ATTENDEE;CN=Personal:mailto:personal@example.com',
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n');

  test('kept as a setting, on to begin with', () {
    expect(const CalendarPrefs().deleteAnsweredInvites, isTrue);
    final off = const CalendarPrefs().copyWith(deleteAnsweredInvites: false);
    expect(CalendarPrefs.tryParse(jsonEncode(off.toJson())), off);
    expect(CalendarPrefs.tryParse('{}')!.deleteAnsweredInvites, isTrue);
  });

  Future<(SampleMailEngine, MailMessage)> invitation() async {
    final engine = _InviteEngine(ics);
    final inbox = (await engine.loadFolders('acct-personal'))
        .firstWhere((f) => f.role == FolderRole.inbox);
    return (engine, (await engine.loadMessages(inbox.id)).first);
  }

  // A notification posted before 3.9.0, whose buttons answer at once; a
  // newer one's open the invitation, whose card asks (meeting_card_test).
  group('from its notification', () {
    test('answered, then in Deleted Items', () async {
      final (engine, message) = await invitation();
      final outcome =
          await NotificationActions(engine: engine, deleteAnswered: true)
              .perform(NotificationActions.acceptId, message.id, null);
      expect(outcome, ActionOutcome.answered);
      expect(engine.inviteAnswers.single.response, InviteResponse.accepted);
      final inbox = await engine.loadMessages(message.folderId);
      expect(inbox.any((m) => m.id == message.id), isFalse);
    });

    test('kept, and read, where Settings says so', () async {
      final (engine, message) = await invitation();
      await engine.setRead(message.id, false);
      await NotificationActions(engine: engine)
          .perform(NotificationActions.declineId, message.id, null);
      final kept = await engine.cachedMessage(message.id);
      expect(kept, isNotNull);
      expect(kept!.isRead, isTrue);
    });
  });

  group('from its card', () {
    /// The invitation open in a reading pane. [prepare] is handed the engine
    /// and the message before the pane is built.
    Future<(ProviderContainer, SampleMailEngine, MailMessage)> pump(
      WidgetTester tester, {
      bool delete = true,
      void Function(SampleMailEngine, MailMessage)? prepare,
    }) async {
      FakeWebViewPlatform.install();
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (engine, message) = (await tester.runAsync(invitation))!;
      prepare?.call(engine, message);
      final ui = MemoryUiStateStore();
      await ui.writeString(
        UiStateKeys.calendarPrefs,
        jsonEncode(const CalendarPrefs()
            .copyWith(deleteAnsweredInvites: delete)
            .toJson()),
      );
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(engine),
        messageBodyProvider(message.id).overrideWith(
          (ref) async => MailBody(text: 'Shall we plan?', calendar: ics),
        ),
      ]);
      addTearDown(c.dispose);
      c.read(selectedFolderIdProvider.notifier).select(message.folderId);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: ReadingPane(message: message, onPopOut: () {}),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (c, engine, message);
    }

    /// Press [answer] on the card, then [how] in the menu it asks with.
    Future<void> answer(
      WidgetTester tester,
      String answer, {
      String how = 'answer-now',
    }) async {
      await tester.tap(find.text(answer));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(how)));
      await tester.pumpAndSettle();
    }

    testWidgets('Accept, and the invitation goes to Deleted Items, with Undo',
        (tester) async {
      final (_, engine, message) = await pump(tester);
      await answer(tester, 'Accept');
      expect(engine.inviteAnswers.single.response, InviteResponse.accepted);
      expect(
          find.text('Accepted. The organiser has been told. The invitation is '
              'in Deleted Items.'),
          findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      final inbox = (await tester
          .runAsync(() => engine.loadMessages(message.folderId)))!;
      expect(inbox.any((m) => m.id == message.id), isFalse);
    });

    testWidgets('kept where Settings, Calendar says so', (tester) async {
      final (_, engine, message) = await pump(tester, delete: false);
      await answer(tester, 'Accept');
      expect(find.text('Accepted. The organiser has been told.'),
          findsOneWidget);
      final inbox = (await tester
          .runAsync(() => engine.loadMessages(message.folderId)))!;
      expect(inbox.any((m) => m.id == message.id), isTrue);
    });

    testWidgets('answered without telling the organiser, it goes to Deleted '
        'Items all the same, as in Outlook', (tester) async {
      final (_, engine, message) = await pump(
        tester,
        // On the account's calendar, which can take an answer alone.
        prepare: (engine, message) => engine
          ..answersQuietly.add(message.accountId)
          ..calendar['plan-1@example.com'] = CalendarMeeting(
            accountId: message.accountId,
            eventId: 'e-1',
            start: DateTime.utc(2026, 10, 28, 10),
          ),
      );
      await answer(tester, 'Decline', how: 'answer-quiet');

      final given = engine.inviteAnswers.single;
      expect(given.response, InviteResponse.declined);
      expect(given.send, isFalse);
      expect(
          find.text('Declined. The organiser was not told. The invitation is '
              'in Deleted Items.'),
          findsOneWidget);
      final inbox = (await tester
          .runAsync(() => engine.loadMessages(message.folderId)))!;
      expect(inbox.any((m) => m.id == message.id), isFalse);
    });
  });

  // --- from the calendar (#51) ---------------------------------------------

  const dana = MailAddress(email: 'dana@hadco.example', name: 'Dana Levi');
  const ron = MailAddress(email: 'ron@hadco.example');

  DateTime tomorrowAt(int hour) {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day + 1, hour);
  }

  /// Dana's meeting tomorrow at [hour], inviting the account and not yet
  /// answered: one meeting of [seriesId]'s, where given; with [cancelled],
  /// one she has cancelled.
  CalendarEvent danas(
    Account account, {
    String id = 'm',
    String title = 'Budget',
    String? seriesId,
    int hour = 10,
    bool cancelled = false,
  }) =>
      CalendarEvent(
        id: id,
        accountId: account.id,
        seriesId: seriesId,
        cancelled: cancelled,
        title: title,
        start: tomorrowAt(hour),
        end: tomorrowAt(hour + 1),
        organizer: dana,
        response: EventResponse.notResponded,
        attendees: const [
          EventAttendee(dana, response: EventResponse.organizer),
          EventAttendee(ron, response: EventResponse.notResponded),
        ],
      );

  /// The account signed in with [provider], so with a calendar: Exchange's,
  /// which takes a declined meeting off, or Google's, which keeps it.
  Future<Account> signedIn(
    _CalendarInbox engine,
    MailProvider provider,
  ) async {
    final account = await engine.addOAuthAccount(
      displayName: 'Hadco',
      emailAddress: 'ron@hadco.example',
      provider: provider,
      token: OAuthToken(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.utc(2030),
      ),
    );
    if (provider == MailProvider.outlook) engine.exchange.add(account.id);
    return account;
  }

  group('which invitation is cleared, once a meeting is answered in the '
      'calendar', () {
    late _CalendarInbox engine;
    late Account hadco;

    setUp(() async {
      engine = _CalendarInbox();
      hadco = await signedIn(engine, MailProvider.outlook);
    });

    test("the one the calendar ties to the meeting, and not another of the "
        "same title from the same organiser", () async {
      final mine = engine.invitation(hadco, 5, uid: 'budget@hadco.example');
      engine.invitation(hadco, 4, uid: 'other@hadco.example');
      engine.invitation(hadco, 3, uid: 'unknown@hadco.example');
      engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      engine.place(hadco, 'other@hadco.example', eventId: 'another');

      final found = await answeredInvitations(engine, danas(hadco),
          wholeSeries: false);
      expect([for (final m in found) m.id], [mine.id],
          reason: "#3's UID is on no calendar, #4's is another meeting's");
    });

    test("only an invitation: the meeting's cancellation, or mail with its "
        'title that is no meeting mail, stays', () async {
      engine.invitation(hadco, 5,
          uid: 'budget@hadco.example', method: 'CANCEL');
      engine.invitation(hadco, 4,
          uid: 'budget@hadco.example', meeting: false);
      engine.place(hadco, 'budget@hadco.example', eventId: 'm');

      expect(
          await answeredInvitations(engine, danas(hadco), wholeSeries: false),
          isEmpty);
      expect(engine.bodiesRead, [engine.idOf(hadco, 5)],
          reason: 'mail that is no meeting mail is not even opened');
    });

    test("a series' invitation goes with every meeting of the series, never "
        'with one meeting of it', () async {
      final series = engine.invitation(hadco, 5, uid: 'weekly@hadco.example');
      engine.place(hadco, 'weekly@hadco.example', eventId: 'weekly');
      final tuesday = danas(hadco, seriesId: 'weekly');

      expect(await answeredInvitations(engine, tuesday, wholeSeries: false),
          isEmpty);
      expect(
          [
            for (final m in await answeredInvitations(engine, tuesday,
                wholeSeries: true))
              m.id,
          ],
          [series.id]);
    });

    test("one Outlook sent for one changed meeting of a series is that "
        "meeting's alone", () async {
      final tuesday = DateTime.utc(2026, 11, 3, 8);
      final changed = engine.invitation(hadco, 6,
          uid: 'weekly@hadco.example', meetingAt: tuesday);
      final series = engine.invitation(hadco, 5, uid: 'weekly@hadco.example');
      engine.place(hadco, 'weekly@hadco.example', eventId: 'weekly');
      engine.place(hadco, 'weekly@hadco.example',
          meetingAt: tuesday, eventId: 'm');

      final that = danas(hadco, seriesId: 'weekly');
      expect(
          [
            for (final m in await answeredInvitations(engine, that,
                wholeSeries: false))
              m.id,
          ],
          [changed.id]);
      expect(
          [
            for (final m in await answeredInvitations(engine, that,
                wholeSeries: true))
              m.id,
          ],
          [series.id]);
      final another = danas(hadco, id: 'm2', seriesId: 'weekly');
      expect(await answeredInvitations(engine, another, wholeSeries: false),
          isEmpty);
    });

    test('an invitation and its update, both tied to the meeting, go '
        'together, the newest first', () async {
      final first = engine.invitation(hadco, 4, uid: 'budget@hadco.example');
      final update = engine.invitation(hadco, 5,
          uid: 'budget@hadco.example', subject: 'Budget');
      engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      expect(
          [
            for (final m in await answeredInvitations(engine, danas(hadco),
                wholeSeries: false))
              m.id,
          ],
          [update.id, first.id]);
    });

    test("Google's subject, with the time after the title, is found as "
        'Outlook\'s is', () async {
      final gmail = _CalendarInbox();
      final personal = await signedIn(gmail, MailProvider.gmail);
      final mine = gmail.invitation(personal, 5,
          uid: 'abc123@google.com',
          subject: 'Invitation: Budget @ Tue 17 Nov 2026 10am - 11am (IST) '
              '(ron@hadco.example)');
      gmail.place(personal, 'abc123@google.com', eventId: 'm');
      expect(
          [
            for (final m in await answeredInvitations(gmail, danas(personal),
                wholeSeries: false))
              m.id,
          ],
          [mine.id]);
    });

    test('found where this device holds it, though the server search does '
        'not find it, and where the server finds it alone', () async {
      final held = engine.invitation(hadco, 5, uid: 'budget@hadco.example');
      engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      engine.searchFails = const ConnectionFailed('No connection');
      expect(
          [
            for (final m in await answeredInvitations(engine, danas(hadco),
                wholeSeries: false))
              m.id,
          ],
          [held.id]);

      engine.searchFails = null;
      engine.notHeld.add(held.id);
      expect(
          [
            for (final m in await answeredInvitations(engine, danas(hadco),
                wholeSeries: false))
              m.id,
          ],
          [held.id]);
    });

    test("one that cannot be read, or placed on the calendar, is left",
        () async {
      engine.invitation(hadco, 5, uid: 'budget@hadco.example');
      engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      engine.bodyFails = const ConnectionFailed('No connection');
      expect(
          await answeredInvitations(engine, danas(hadco), wholeSeries: false),
          isEmpty);
      engine
        ..bodyFails = null
        ..placingFails = const ConnectionFailed('No connection');
      expect(
          await answeredInvitations(engine, danas(hadco), wholeSeries: false),
          isEmpty);
    });

    test('a meeting with no title looks for nothing', () async {
      engine.invitation(hadco, 5, uid: 'budget@hadco.example', subject: '');
      engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      expect(
          await answeredInvitations(engine, danas(hadco, title: ' '),
              wholeSeries: false),
          isEmpty);
      expect(engine.searched, isEmpty);
    });
  });

  group('from the calendar', () {
    Future<(ProviderContainer, _CalendarInbox, Account)> pump(
      WidgetTester tester, {
      bool delete = true,
      MailProvider provider = MailProvider.outlook,
      required void Function(_CalendarInbox engine, Account hadco) prepare,
    }) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = _CalendarInbox();
      final hadco = (await tester.runAsync(() => signedIn(engine, provider)))!;
      prepare(engine, hadco);
      final ui = MemoryUiStateStore();
      if (!delete) {
        await ui.writeString(
          UiStateKeys.calendarPrefs,
          jsonEncode(const CalendarPrefs()
              .copyWith(deleteAnsweredInvites: false)
              .toJson()),
        );
      }
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(engine),
        deviceCalendarProvider.overrideWithValue(
            FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: const CalendarScreen(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (c, engine, hadco);
    }

    /// Open [id]'s sheet, press [button], then [how] in the menu it asks
    /// with.
    Future<void> answer(
      WidgetTester tester,
      String button, {
      String id = 'm',
      String how = 'answer-now',
    }) async {
      await tester.tap(find.byKey(ValueKey('agenda-event:$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(button)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(how)));
      await tester.pumpAndSettle();
    }

    for (final provider in [MailProvider.outlook, MailProvider.gmail]) {
      testWidgets('Accept on its sheet, and its invitation goes to Deleted '
          'Items, with Undo (${provider.name})', (tester) async {
        late MailMessage mine;
        final (_, engine, hadco) = await pump(tester, provider: provider,
            prepare: (engine, hadco) {
          engine.events[hadco.id] = [danas(hadco)];
          mine = engine.invitation(hadco, 5, uid: 'budget@hadco.example');
          engine.invitation(hadco, 4, uid: 'other@hadco.example');
          engine.place(hadco, 'budget@hadco.example', eventId: 'm');
          engine.place(hadco, 'other@hadco.example', eventId: 'another');
        });

        await answer(tester, 'event-accept');
        expect(engine.calendarActions, ['respond m accepted']);
        expect(
            find.text('Accepted. Dana is told. The invitation is in Deleted '
                'Items.'),
            findsOneWidget);
        expect(engine.deleted, [mine.id]);
        expect(engine.inboxOf(hadco).map((m) => m.uid), [4],
            reason: "another meeting's invitation stays");

        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(engine.inboxOf(hadco).map((m) => m.uid), [5, 4]);
        expect(engine.calendarActions, ['respond m accepted'],
            reason: 'Undo puts the invitation back, not the answer');
      });
    }

    testWidgets('declined from the list of those waiting (#50), on a '
        'Microsoft calendar, it goes the same way', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      });
      await tester.tap(find.byKey(const ValueKey('agenda-waiting')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byKey(ValueKey('waiting-event:${hadco.id}||m')),
        matching: find.byKey(const ValueKey('waiting-decline')),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-now')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['respond m declined']);
      expect(
          find.text('Declined. Dana is told. The invitation is in Deleted '
              'Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
      // The list reads its year again once answering stops.
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
    });

    testWidgets('Decline on a Microsoft calendar, which takes the meeting '
        'off, clears it all the same: looked for while the answer is chosen, '
        'and said in one bar with it', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      });
      await tester.tap(find.byKey(const ValueKey('agenda-event:m')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-decline')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-now')));
      // One bar, as the card's: never the answer's words alone first.
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(find.text('Declined. Dana is told.'), findsNothing);
      }
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['respond m declined']);
      expect(
          find.text('Declined. Dana is told. The invitation is in Deleted '
              'Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
    });

    testWidgets('every meeting of a series declined on a Microsoft calendar '
        "clears the series' invitation", (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco, seriesId: 'weekly')];
        engine.invitation(hadco, 5, uid: 'weekly@hadco.example');
        engine.place(hadco, 'weekly@hadco.example', eventId: 'weekly');
      });
      await answer(tester, 'event-decline');
      await tester.tap(find.byKey(const ValueKey('series-all')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['respond m declined series']);
      expect(
          find.text('Declined. Dana is told. The invitation is in Deleted '
              'Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
    });

    testWidgets('a new time proposed with Decline, on a Microsoft calendar, '
        'clears it', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      });
      await tester.tap(find.byKey(const ValueKey('agenda-event:m')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-propose')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('propose-send')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.single, startsWith('respond m declined'));
      expect(
          find.text('Declined, with a new time proposed. The organiser is '
              'told. The invitation is in Deleted Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
    });

    testWidgets('Decline on a Google calendar, which keeps the meeting, '
        'clears it too', (tester) async {
      final (_, engine, hadco) = await pump(tester,
          provider: MailProvider.gmail, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      });
      await answer(tester, 'event-decline');
      expect(engine.calendarActions, ['respond m declined']);
      expect(
          find.text('Declined. Dana is told. The invitation is in Deleted '
              'Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
    });

    testWidgets('looked for too slowly to say in one bar: the answer is said '
        "at once, and the invitation's line replaces it while it is up",
        (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
        engine.placing = const Duration(seconds: 2);
      });
      await answer(tester, 'event-accept');
      expect(find.text('Accepted. Dana is told.'), findsOneWidget,
          reason: 'not waiting for the looking');
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
          find.text('Accepted. Dana is told. The invitation is in Deleted '
              'Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
    });

    testWidgets("found once the answer's own bar has gone, the line names "
        'the meeting', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
        engine.placing = const Duration(seconds: 7);
      });
      await answer(tester, 'event-accept');
      expect(find.text('Accepted. Dana is told.'), findsOneWidget);
      // The answer's bar runs its five seconds, a frame at a time, while the
      // invitation is still being looked for.
      for (var i = 0; i < 11; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Accepted. Dana is told.'), findsNothing);

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
      expect(find.text('The invitation to Budget is in Deleted Items.'),
          findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
    });

    testWidgets("a late line never takes the place of another answer's "
        'failure: it waits behind it', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          danas(hadco),
          danas(hadco, id: 'n', title: 'Review', hour: 14),
        ];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
        engine.placing = const Duration(seconds: 4);
      });
      await answer(tester, 'event-accept');
      expect(find.text('Accepted. Dana is told.'), findsOneWidget);

      engine.answerFails = const ConnectionFailed('No connection');
      await answer(tester, 'event-accept', id: 'n');
      expect(find.text('Could not answer: No connection'), findsOneWidget);

      // The first one's invitation is found and goes meanwhile.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(engine.inboxOf(hadco), isEmpty);
      expect(find.text('Could not answer: No connection'), findsOneWidget);
      expect(find.textContaining('The invitation to Budget'), findsNothing);

      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
      expect(find.text('Could not answer: No connection'), findsNothing);
      expect(find.text('The invitation to Budget is in Deleted Items.'),
          findsOneWidget);
    });

    testWidgets('one the server will not delete leaves the answer said, and '
        'nothing alarming', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
        engine.deleteFails = const ConnectionFailed('Not there');
      });
      await answer(tester, 'event-accept');
      expect(find.text('Accepted. Dana is told.'), findsOneWidget);
      expect(find.textContaining('Could not delete'), findsNothing);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);
    });

    testWidgets('kept where Settings, Calendar says so, and nothing is looked '
        'for', (tester) async {
      final (_, engine, hadco) = await pump(tester, delete: false,
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      });

      await answer(tester, 'event-accept');
      expect(find.text('Accepted. Dana is told.'), findsOneWidget);
      expect(engine.deleted, isEmpty);
      expect(engine.searched, isEmpty);
      expect(engine.bodiesRead, isEmpty);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);
    });

    testWidgets('each way the answer goes clears it, as from the card: with '
        'a message, and with none sent', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          danas(hadco),
          danas(hadco, id: 'n', title: 'Review', hour: 14),
        ];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.invitation(hadco, 6,
            uid: 'review@hadco.example', subject: 'Review');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
        engine.place(hadco, 'review@hadco.example', eventId: 'n');
      });

      await answer(tester, 'event-decline', how: 'answer-edit');
      await tester.enterText(
          find.byKey(const ValueKey('answer-note')), 'Away that week');
      await tester.tap(find.byKey(const ValueKey('answer-send')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions,
          ['respond m declined note=Away that week']);
      expect(
          find.text('Declined. Dana is told. The invitation is in Deleted '
              'Items.'),
          findsOneWidget);

      await answer(tester, 'event-tentative', id: 'n', how: 'answer-quiet');
      expect(engine.calendarActions.last, 'respond n tentative quietly');
      expect(
          find.text('Maybe. The organiser was not told. The invitation '
              'is in Deleted Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
    });

    testWidgets('a new time proposed clears it too, as from the card',
        (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      });
      await tester.tap(find.byKey(const ValueKey('agenda-event:m')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-propose')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('propose-send')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.single, startsWith('respond m tentative'));
      expect(
          find.text('Maybe, with a new time proposed. The organiser is '
              'told. The invitation is in Deleted Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
    });

    testWidgets("one the calendar does not tie to the meeting is left, and "
        'nothing more is said', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        // The same title, from the same organiser, and an invitation: but
        // its UID is on no calendar.
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
      });

      await answer(tester, 'event-accept');
      expect(find.text('Accepted. Dana is told.'), findsOneWidget);
      expect(engine.deleted, isEmpty);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);
    });

    testWidgets("one meeting of a series answered leaves the series' "
        'invitation; every meeting of it answered clears it', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco, seriesId: 'weekly')];
        engine.invitation(hadco, 5, uid: 'weekly@hadco.example');
        engine.place(hadco, 'weekly@hadco.example', eventId: 'weekly');
      });

      await answer(tester, 'event-accept');
      await tester.tap(find.byKey(const ValueKey('series-one')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['respond m accepted']);
      expect(find.text('Accepted. Dana is told.'), findsOneWidget);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);

      await answer(tester, 'event-accept');
      await tester.tap(find.byKey(const ValueKey('series-all')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.last, 'respond m accepted series');
      expect(
          find.text('Accepted. Dana is told. The invitation is in Deleted '
              'Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
    });

    testWidgets('an answer the calendar refuses deletes nothing',
        (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
        engine.answerFails = const ConnectionFailed('No connection');
      });

      await answer(tester, 'event-accept');
      expect(find.text('Could not answer: No connection'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Could not answer: No connection'), findsOneWidget);
      expect(engine.deleted, isEmpty);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);
    });

    testWidgets('looking that fails leaves the answer said, and nothing '
        'alarming', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
        engine
          ..searchFails = const ConnectionFailed('No connection')
          ..bodyFails = const ConnectionFailed('No connection');
      });

      await answer(tester, 'event-accept');
      expect(find.text('Accepted. Dana is told.'), findsOneWidget);
      expect(find.textContaining('No connection'), findsNothing);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);
    });

    testWidgets('the calendar left before the invitation is found: it goes '
        'all the same, said over the screen beneath', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      });
      // The calendar opened over another screen, as from the folder pane.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      engine.slowSearch = true;
      await tester.tap(find.byKey(const ValueKey('agenda-event:m')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-accept')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-now')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(engine.calendarActions, ['respond m accepted']);
      // Left while the Inbox is still being searched.
      expect(engine.searched, ['Budget']);
      expect(engine.deleted, isEmpty);
      navigator.pushReplacement(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('The mail')),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('The mail'), findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
      expect(
          find.text('Accepted. Dana is told. The invitation is in Deleted '
              'Items.'),
          findsOneWidget);
    });

    // --- Decline and remove, a decline from the sheet ------------------------

    /// Open [id]'s sheet and choose ⋮ → Decline and remove; then [series],
    /// where given, and [confirm] the dialog, or Keep it.
    Future<void> declineAndRemove(
      WidgetTester tester, {
      String id = 'm',
      String? series,
      bool confirm = true,
    }) async {
      await tester.tap(find.byKey(ValueKey('agenda-event:$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      expect(find.text('Decline and remove'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-remove')));
      await tester.pumpAndSettle();
      if (series != null) {
        await tester.tap(find.byKey(ValueKey(series)));
        await tester.pumpAndSettle();
      }
      await tester.tap(confirm
          ? find.byKey(const ValueKey('cancel-go'))
          : find.text('Keep it'));
      await tester.pumpAndSettle();
    }

    testWidgets('Decline and remove clears it too: looked for while the '
        'calendar still has the meeting, which then comes off as before',
        (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.invitation(hadco, 4, uid: 'other@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
        engine.place(hadco, 'other@hadco.example', eventId: 'another');
      });

      await declineAndRemove(tester);
      expect(engine.calendarActions, ['remove m declined']);
      expect(find.byKey(const ValueKey('agenda-event:m')), findsNothing);
      expect(
          find.text('Declined and taken off your calendar. The invitation is '
              'in Deleted Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [4],
          reason: "another meeting's invitation stays");

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5, 4]);
      expect(engine.calendarActions, ['remove m declined'],
          reason: 'Undo puts the invitation back; the meeting stays off');
    });

    testWidgets("Decline and remove of one meeting of a series leaves the "
        "series' invitation; of every meeting, it goes", (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [
          danas(hadco, seriesId: 'weekly'),
          danas(hadco, id: 'm2', seriesId: 'weekly', hour: 14),
        ];
        engine.invitation(hadco, 5, uid: 'weekly@hadco.example');
        engine.place(hadco, 'weekly@hadco.example', eventId: 'weekly');
      });

      await declineAndRemove(tester, series: 'series-one');
      expect(engine.calendarActions, ['remove m declined']);
      expect(find.text('Declined and taken off your calendar.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);

      await declineAndRemove(tester, id: 'm2', series: 'series-all');
      expect(engine.calendarActions.last, 'remove m2 declined series');
      expect(
          find.text('Declined and taken off your calendar. The invitation is '
              'in Deleted Items.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco), isEmpty);
    });

    testWidgets('Decline and remove never waits for the looking: one too slow '
        'to place the invitation before the meeting comes off leaves it, '
        'saying nothing more', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
        engine.placing = const Duration(seconds: 1);
      });
      await tester.tap(find.byKey(const ValueKey('agenda-event:m')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-remove')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('cancel-go')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(engine.calendarActions, ['remove m declined'],
          reason: 'declined and taken off at once, the looking still going');

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Declined and taken off your calendar.'),
          findsOneWidget);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5],
          reason: 'placed only once the meeting was off: not sure, so left');
    });

    testWidgets('Decline and remove where Settings keep invitations looks for '
        'nothing, and takes the meeting off as before', (tester) async {
      final (_, engine, hadco) = await pump(tester, delete: false,
          prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      });

      await declineAndRemove(tester);
      expect(engine.calendarActions, ['remove m declined']);
      expect(find.text('Declined and taken off your calendar.'),
          findsOneWidget);
      expect(engine.searched, isEmpty);
      expect(engine.bodiesRead, isEmpty);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);
    });

    testWidgets('Decline and remove backed out of takes nothing off and '
        'deletes nothing; refused, it deletes nothing either', (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      });

      await declineAndRemove(tester, confirm: false);
      expect(engine.calendarActions, isEmpty);
      expect(find.byKey(const ValueKey('agenda-event:m')), findsOneWidget);
      expect(engine.deleted, isEmpty);

      engine.removeFails = const ConnectionFailed('No connection');
      await declineAndRemove(tester);
      expect(find.text('Could not remove it: No connection'), findsOneWidget);
      expect(find.byKey(const ValueKey('agenda-event:m')), findsOneWidget);
      expect(engine.deleted, isEmpty);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);
    });

    testWidgets('a meeting its organiser cancelled, removed from the '
        'calendar, is no answer: its mail stays, and nothing is looked for',
        (tester) async {
      final (_, engine, hadco) = await pump(tester, prepare: (engine, hadco) {
        engine.events[hadco.id] = [danas(hadco, cancelled: true)];
        engine.invitation(hadco, 5, uid: 'budget@hadco.example');
        engine.place(hadco, 'budget@hadco.example', eventId: 'm');
      });
      await tester.tap(find.byKey(const ValueKey('agenda-event:m')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      expect(find.text('Remove from calendar'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Removed from your calendar.'), findsOneWidget);
      // Once its Undo has gone, taken off, nobody told.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['remove m']);
      expect(engine.searched, isEmpty);
      expect(engine.inboxOf(hadco).map((m) => m.uid), [5]);
    });
  });
}

/// The sample engine, every message an invitation.
class _InviteEngine extends SampleMailEngine {
  _InviteEngine(this.ics);

  final String ics;

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    final body = await super.loadMessageBody(messageId);
    return MailBody(text: body.text, html: body.html, calendar: ics);
  }
}

/// The sample engine with an Inbox a test fills, its messages' calendar
/// parts, and a calendar that places an invitation by its UID, and by the
/// meeting of a series it names, as the real calendars do.
class _CalendarInbox extends SampleMailEngine {
  /// Each Inbox a test filled, by folder id, newest first.
  final Map<String, List<MailMessage>> inboxes = {};

  /// Each message's calendar part, by message id.
  final Map<String, String> parts = {};

  /// The meeting the calendar has for an invitation, by its account, its
  /// UID and, for one meeting of a series, when it was set for.
  final Map<(String, String, DateTime?), CalendarMeeting> placed = {};

  /// Messages deleted, searches made, and bodies read, for a test to look
  /// at.
  final List<String> deleted = [];
  final List<String> searched = [];
  final List<String> bodiesRead = [];

  /// Messages this device does not hold, which only the server finds.
  final Set<String> notHeld = {};

  /// The accounts whose calendar is Exchange's: a meeting declined there
  /// comes off the calendar, as Outlook takes it off, and nothing can be
  /// placed on it after. Google keeps a declined meeting.
  final Set<String> exchange = {};

  /// What each of these throws instead, for a test.
  Exception? searchFails;
  Exception? bodyFails;
  Exception? placingFails;
  Exception? answerFails;
  Exception? removeFails;
  Exception? deleteFails;

  /// A search that takes a second, and how long the calendar takes to
  /// place each invitation.
  bool slowSearch = false;
  Duration placing = const Duration(milliseconds: 30);

  final Map<String, (String, MailMessage)> _trashed = {};

  String inboxIdOf(Account account) => MailFolder.idFor(account.id, 'INBOX');

  String idOf(Account account, int uid) =>
      MailMessage.idFor(inboxIdOf(account), uid);

  List<MailMessage> inboxOf(Account account) =>
      List.of(inboxes[inboxIdOf(account)] ?? const <MailMessage>[]);

  /// Message [number] in [account]'s Inbox, from [from], called [subject]:
  /// meeting mail ([method], an invitation unless said) whose part carries
  /// [uid] and, for one meeting of a series, when it was set for
  /// ([meetingAt], its RECURRENCE-ID). With [meeting] false, a message the
  /// list does not mark as meeting mail.
  MailMessage invitation(
    Account account,
    int number, {
    required String uid,
    String subject = 'Budget',
    DateTime? meetingAt,
    String method = 'REQUEST',
    bool meeting = true,
    MailAddress from = const MailAddress(
      email: 'dana@hadco.example',
      name: 'Dana Levi',
    ),
  }) {
    final message = MailMessage(
      id: idOf(account, number),
      accountId: account.id,
      folderId: inboxIdOf(account),
      uid: number,
      subject: subject,
      from: from,
      to: [MailAddress(email: account.emailAddress)],
      date: DateTime(2026, 11, 1).add(Duration(hours: number)),
      preview: '',
      isMeeting: meeting,
    );
    final inbox = inboxes.putIfAbsent(inboxIdOf(account), () => [])
      ..add(message)
      ..sort((a, b) => b.date.compareTo(a.date));
    assert(inbox.isNotEmpty);
    String two(int n) => n.toString().padLeft(2, '0');
    String stamp(DateTime t) => '${t.year}${two(t.month)}${two(t.day)}T'
        '${two(t.hour)}${two(t.minute)}00Z';
    parts[message.id] = [
      'BEGIN:VCALENDAR',
      'METHOD:$method',
      'BEGIN:VEVENT',
      'UID:$uid',
      if (meetingAt != null) 'RECURRENCE-ID:${stamp(meetingAt.toUtc())}',
      'SUMMARY:${subject.isEmpty ? 'Budget' : subject}',
      'DTSTART:20261117T080000Z',
      'DTEND:20261117T090000Z',
      'ORGANIZER;CN=${from.display}:mailto:${from.email}',
      'ATTENDEE:mailto:${account.emailAddress}',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n');
    return message;
  }

  /// The calendar has [uid] (and the meeting of its series set for
  /// [meetingAt], where given) as [eventId] on [account]'s calendar.
  void place(
    Account account,
    String uid, {
    DateTime? meetingAt,
    required String eventId,
  }) =>
      placed[(account.id, uid, meetingAt?.toUtc())] = CalendarMeeting(
        accountId: account.id,
        eventId: eventId,
        start: DateTime.utc(2026, 11, 17, 8),
      );

  List<MailMessage>? _inbox(String folderId) => inboxes[folderId];

  MailMessage? _held(String messageId) {
    for (final list in inboxes.values) {
      for (final m in list) {
        if (m.id == messageId) return m;
      }
    }
    return null;
  }

  static List<MailMessage> _page(
    List<MailMessage> all,
    int offset,
    int limit,
  ) =>
      all.skip(offset).take(limit).toList();

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final inbox = _inbox(folderId);
    if (inbox == null) {
      return super.loadMessages(folderId, offset: offset, limit: limit);
    }
    return _page(inbox, offset, limit);
  }

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final inbox = _inbox(folderId);
    if (inbox == null) {
      return super.cachedMessages(folderId, offset: offset, limit: limit);
    }
    return _page([
      for (final m in inbox)
        if (!notHeld.contains(m.id)) m,
    ], offset, limit);
  }

  @override
  Future<MailMessage?> cachedMessage(String messageId) async =>
      _held(messageId) ?? await super.cachedMessage(messageId);

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
    SearchField field = SearchField.all,
  }) async {
    final inbox = scope.folderId == null ? null : _inbox(scope.folderId!);
    if (inbox == null) {
      return super.searchMessages(query, scope, limit: limit, field: field);
    }
    searched.add(query);
    await (slowSearch
        ? Future<void>.delayed(const Duration(seconds: 1))
        : _latency());
    final fails = searchFails;
    if (fails != null) throw fails;
    final words = query.toLowerCase().split(RegExp(r'\s+'));
    return [
      for (final m in inbox)
        if (words.every(m.subject.toLowerCase().contains)) m,
    ].take(limit).toList();
  }

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    if (_held(messageId) == null) return super.loadMessageBody(messageId);
    bodiesRead.add(messageId);
    await _latency();
    final fails = bodyFails;
    if (fails != null) throw fails;
    return MailBody(text: 'You are invited.', calendar: parts[messageId]);
  }

  @override
  Future<CalendarMeeting?> meetingOnCalendar(
    String messageId,
    CalendarInvite invite,
  ) async {
    await Future<void>.delayed(placing);
    final fails = placingFails;
    if (fails != null) throw fails;
    final accountId = messageId.substring(0, messageId.indexOf(':'));
    return placed[(accountId, invite.uid, invite.recurrenceStart)];
  }

  /// As long as the sample engine's own answers take.
  static Future<void> _latency() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  @override
  Future<void> respondToEvent(
    CalendarEvent event,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
    bool wholeSeries = false,
  }) async {
    final fails = answerFails;
    if (fails != null) throw fails;
    await super.respondToEvent(event, response,
        note: note, send: send, proposal: proposal, wholeSeries: wholeSeries);
    // Exchange takes a declined meeting off the calendar.
    if (response == InviteResponse.declined &&
        exchange.contains(event.accountId)) {
      _takenOff(event, wholeSeries: wholeSeries);
    }
  }

  void _takenOff(CalendarEvent event, {required bool wholeSeries}) =>
      placed.removeWhere((_, m) =>
          m.eventId == event.id ||
          (wholeSeries && m.eventId == event.seriesId));

  /// Taken off, a meeting is no longer on the calendar for an invitation
  /// to be placed on, as on Exchange and Google, which find nothing then.
  @override
  Future<void> removeEvent(
    CalendarEvent event, {
    bool wholeSeries = false,
  }) async {
    final fails = removeFails;
    if (fails != null) {
      await _latency();
      throw fails;
    }
    await super.removeEvent(event, wholeSeries: wholeSeries);
    _takenOff(event, wholeSeries: wholeSeries);
  }

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    await _latency();
    final refused = deleteFails;
    if (refused != null && messageIds.any((id) => _held(id) != null)) {
      throw refused;
    }
    final moves = <MessageMove>[];
    final rest = <String>[];
    for (final id in messageIds) {
      final message = _held(id);
      if (message == null) {
        rest.add(id);
        continue;
      }
      inboxes[message.folderId]!.removeWhere((m) => m.id == id);
      deleted.add(id);
      final trash = MailFolder.idFor(message.accountId, '[Gmail]/Trash');
      final there = MailMessage.idFor(trash, 1000 + _trashed.length);
      _trashed[there] = (message.folderId, message);
      moves.add(MessageMove(
        fromFolderId: message.folderId,
        toFolderId: trash,
        movedIds: [there],
      ));
    }
    return [
      ...moves,
      if (rest.isNotEmpty) ...await super.deleteMessages(rest),
    ];
  }

  @override
  Future<void> undoMoves(List<MessageMove> moves) async {
    final rest = <MessageMove>[];
    for (final move in moves) {
      final back = [for (final id in move.movedIds) ?_trashed.remove(id)];
      if (back.isEmpty) {
        rest.add(move);
        continue;
      }
      for (final (folderId, message) in back) {
        inboxes[folderId]!
          ..add(message)
          ..sort((a, b) => b.date.compareTo(a.date));
      }
    }
    if (rest.isNotEmpty) await super.undoMoves(rest);
  }
}
