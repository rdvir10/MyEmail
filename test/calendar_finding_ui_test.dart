import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/calendar/calendar_search_screen.dart';
import 'package:myemail/ui/messages/invite_card.dart';
import 'package:myemail/ui/messages/person_card.dart';

import 'fakes/fake_webview.dart';

/// Finding in the calendar on screen: its search (#36), the meetings on a
/// person's card (#37), an invitation's clashes (#34), and the mail about
/// a meeting (#38).
void main() {
  const dana = MailAddress(email: 'dana@example.com', name: 'Dana Levi');

  setUp(FakeWebViewPlatform.install);

  DateTime day(int fromToday, int hour) {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day + fromToday, hour);
  }

  CalendarEvent meeting(
    Account hadco,
    String id,
    String title,
    DateTime start, {
    MailAddress? organizer = dana,
  }) =>
      CalendarEvent(
        id: id,
        accountId: hadco.id,
        title: title,
        start: start,
        end: start.add(const Duration(hours: 1)),
        organizer: organizer,
        attendees: [if (organizer != null) EventAttendee(organizer)],
        response: EventResponse.accepted,
      );

  Future<(ProviderContainer, _Engine, Account)> pump(
    WidgetTester tester,
    Widget Function(Account hadco) home, {
    List<CalendarEvent> Function(Account hadco)? events,
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _Engine();
    final hadco = (await tester.runAsync(() => engine.addOAuthAccount(
          displayName: 'Hadco',
          emailAddress: 'ron@hadco.example',
          provider: MailProvider.outlook,
          token: OAuthToken(
            accessToken: 'a',
            refreshToken: 'r',
            expiresAt: DateTime.utc(2030),
          ),
        )))!;
    engine.events[hadco.id] = events?.call(hadco) ?? const [];
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider
          .overrideWithValue(FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: home(hadco),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (c, engine, hadco);
  }

  testWidgets('the calendar searched by title, a year either way (#36)',
      (tester) async {
    await pump(tester, (_) => const CalendarScreen(),
        events: (hadco) => [
              meeting(hadco, 'coming', 'Budget review', day(2, 10)),
              meeting(hadco, 'gone', 'Budget kickoff', day(-40, 10)),
              meeting(hadco, 'other', 'Lunch', day(1, 12)),
            ]);
    await tester.tap(find.byKey(const ValueKey('calendar-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('calendar-search-box')), 'budget');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-search-result:coming')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-search-result:gone')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-search-result:other')),
        findsNothing);
    expect(find.text('Before today'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('calendar-search-result:coming')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('event-more')), findsOneWidget,
        reason: "the meeting's sheet");
  });

  testWidgets("a person's card: the next and the last meeting, and all of "
      'them (#37)', (tester) async {
    await pump(
      tester,
      (hadco) => Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () =>
                showPersonCard(context, ref, dana, accountId: hadco.id),
            child: const Text('Dana'),
          ),
        ),
      ),
      events: (hadco) => [
        meeting(hadco, 'next', 'Planning', day(3, 10)),
        meeting(hadco, 'last', 'Retro', day(-5, 15)),
        meeting(hadco, 'older', 'Kickoff', day(-30, 9)),
        meeting(hadco, 'none', 'Alone', day(1, 9), organizer: null),
      ],
    );
    await tester.tap(find.text('Dana'));
    await tester.pumpAndSettle();
    expect(find.text('Next: Planning'), findsOneWidget);
    expect(find.text('Last: Retro'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('person-all-meetings')));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarSearchScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-search-result:next')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-search-result:older')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-search-result:none')),
        findsNothing);
  });

  testWidgets("an invitation says what it clashes with (#34)", (tester) async {
    final at = day(2, 14);
    final until = at.add(const Duration(hours: 1));
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}T'
          '${two(u.hour)}${two(u.minute)}00Z';
    }

    final invite = CalendarInvite.parse([
      'BEGIN:VCALENDAR',
      'METHOD:REQUEST',
      'BEGIN:VEVENT',
      'UID:plan-1@example.com',
      'SUMMARY:Planning',
      'DTSTART:${stamp(at)}',
      'DTEND:${stamp(until)}',
      'ORGANIZER;CN=Dana Levi:mailto:dana@example.com',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n'))!;
    await pump(
      tester,
      (hadco) => Scaffold(
        body: SingleChildScrollView(
          child: InviteCard(
            message: MailMessage(
              id: '${hadco.id}:INBOX#7',
              accountId: hadco.id,
              folderId: '${hadco.id}:INBOX',
              uid: 7,
              subject: 'Planning',
              from: dana,
              to: const [MailAddress(email: 'ron@hadco.example')],
              date: DateTime.now(),
              preview: '',
              isMeeting: true,
            ),
            invite: invite,
          ),
        ),
      ),
      events: (hadco) => [
        meeting(hadco, 'sync', 'Weekly sync', at.add(const Duration(minutes: 30))),
        // The invitation itself, on the calendar before it is answered.
        meeting(hadco, 'itself', 'Planning', at),
      ],
    );
    final line = find.byKey(const ValueKey('invite-clashes'));
    expect(line, findsOneWidget);
    final sync = at.add(const Duration(minutes: 30));
    String two(int n) => n.toString().padLeft(2, '0');
    expect(
        tester.widget<Text>(line).data,
        'Clashes with Weekly sync, ${two(sync.hour)}:${two(sync.minute)}–'
        '${two(sync.hour + 1)}:${two(sync.minute)}');
    expect(find.byKey(const ValueKey('invite-clash-strip')), findsOneWidget);
  });

  testWidgets("the mail about a meeting, from its sheet (#38)", (tester) async {
    final (_, engine, hadco) = await pump(tester, (_) => const SizedBox());
    MailMessage mail(int uid, String subject, MailAddress from) => MailMessage(
          id: '${hadco.id}:INBOX#$uid',
          accountId: hadco.id,
          folderId: '${hadco.id}:INBOX',
          uid: uid,
          subject: subject,
          from: from,
          to: const [MailAddress(email: 'ron@hadco.example')],
          date: DateTime(2026, 10, uid),
          preview: '',
        );
    engine.found = [
      mail(3, 'Accepted: Budget review', dana),
      mail(5, 'Budget review', dana),
      mail(4, 'Budget review notes', const MailAddress(email: 'x@else.com')),
    ];
    final event = meeting(hadco, 'b', 'Budget review', day(2, 10));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: ProviderScope.containerOf(tester.element(find.byType(SizedBox))),
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showEventDetails(context, ref, event, hadco),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final about = find.byKey(const ValueKey('event-mail-about'));
    await tester.scrollUntilVisible(about, 100,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(about);
    await tester.pumpAndSettle();
    expect(engine.searched, ['Budget review']);
    final rows = find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('meeting-mail:'));
    expect(
        [for (final e in rows.evaluate()) (e.widget.key as ValueKey<String>).value],
        ['meeting-mail:${hadco.id}:INBOX#5', 'meeting-mail:${hadco.id}:INBOX#3'],
        reason: "newest first, and only those to or from the people on it");
  });
}

/// The sample engine, answering a search with what a test gave it.
class _Engine extends SampleMailEngine {
  List<MailMessage> found = const [];
  final List<String> searched = [];

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
    SearchField field = SearchField.all,
  }) async {
    searched.add(query);
    return found;
  }
}
