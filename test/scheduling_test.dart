import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/meeting_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/compose/mail_tips_line.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';

import 'fakes/fake_webview.dart';
import 'helpers/send_at_once.dart';

/// Batch 5 on screen: MailTips under the recipients, free times written
/// into a message, and who is free on New meeting.
void main() {
  late FakeWebViewPlatform page;
  setUp(() => page = FakeWebViewPlatform.install()..finishLoads = true);

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// The phone's clock set to 24 hours, for everything the app shows,
  /// sheets and dialogs too.
  Widget clock24(BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      );

  /// A header row's text field, by the label beside it.
  Finder field(String label) {
    final name = find.descendant(
      of: find.byWidgetPredicate((w) => w is SizedBox && w.width == 64),
      matching: find.text(label),
    );
    return find.descendant(
      of: find.ancestor(of: name, matching: find.byType(Row)),
      matching: find.byType(TextField),
    );
  }

  /// Long enough for a field's change to be asked about.
  Future<void> wait(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  group('compose', () {
    Future<ProviderContainer> compose(
      WidgetTester tester,
      _Accounts engine, {
      required String accountId,
      List<MailAddress> to = const [],
    }) async {
      tall(tester);
      final c = ProviderContainer(overrides: [
        mailEngineProvider.overrideWithValue(engine),
        uiStateStoreProvider.overrideWithValue(sendAtOnce()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          builder: clock24,
          home: ComposeScreen(
            draft: Draft(
              accountId: accountId,
              kind: ComposeKind.newMessage,
              to: to,
              subject: 'Plans',
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('MailTips under the recipients, from a Microsoft account, '
        'asked again as they change', (tester) async {
      final engine = _Accounts()
        ..tips['dana@contoso.com'] = const MailTip(
          email: 'dana@contoso.com',
          autoReply: 'Away until Sunday.',
        )
        ..tips['all@contoso.com'] =
            const MailTip(email: 'all@contoso.com', memberCount: 120);
      await compose(
        tester,
        engine,
        accountId: 'acct-ms',
        to: const [MailAddress(email: 'dana@contoso.com', name: 'Dana Levi')],
      );
      await wait(tester);

      expect(
        find.text('Dana Levi has an automatic reply on: "Away until Sunday."'),
        findsOneWidget,
      );

      await tester.enterText(field('To'), 'all@contoso.com');
      await wait(tester);
      expect(find.textContaining('automatic reply'), findsNothing);
      expect(find.text('all@contoso.com is a list of 120 people.'),
          findsOneWidget);

      await tester.enterText(field('To'), '');
      await wait(tester);
      expect(find.textContaining('a list of'), findsNothing);
    });

    testWidgets('no MailTips from a Gmail account', (tester) async {
      final engine = _Accounts()
        ..tips['dana@contoso.com'] =
            const MailTip(email: 'dana@contoso.com', autoReply: 'Away.');
      await compose(
        tester,
        engine,
        accountId: 'acct-g',
        to: const [MailAddress(email: 'dana@contoso.com')],
      );
      await wait(tester);

      expect(find.byType(MailTipsLine), findsNothing);
      expect(find.textContaining('automatic reply'), findsNothing);
    });

    testWidgets('free times go into the message, the days worked only, and '
        'the work week chosen is kept', (tester) async {
      // The first Wednesday after today: busy all day.
      final today = DateTime.now();
      var wednesday = DateTime(today.year, today.month, today.day + 1);
      while (wednesday.weekday != DateTime.wednesday) {
        wednesday =
            DateTime(wednesday.year, wednesday.month, wednesday.day + 1);
      }
      final engine = _Accounts()
        ..busy['ron@gmail.com'] = [
          (
            start: wednesday.add(const Duration(hours: 6)),
            end: wednesday.add(const Duration(hours: 20)),
          ),
        ];
      final c = await compose(tester, engine, accountId: 'acct-g');

      await tester.tap(find.byKey(const ValueKey('compose-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Insert free times…'));
      await tester.pumpAndSettle();
      // Wednesdays alone, two of them.
      for (final day in [
        DateTime.monday,
        DateTime.tuesday,
        DateTime.thursday,
        DateTime.friday,
      ]) {
        await tester.tap(find.byKey(ValueKey('work-day-$day')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('5'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('free-times-insert')));
      await tester.pumpAndSettle();

      const call = 'window.mailtreeInsert(';
      final inserted = page.ranJavaScript.singleWhere((j) => j.startsWith(call));
      final html = jsonDecode(
        inserted.substring(call.length, inserted.length - 2),
      ) as String;
      expect(html, startsWith('<div>Times I am free'));
      expect(RegExp('<li>Wednesday ').allMatches(html), hasLength(2));
      expect(html, isNot(contains('Thursday')));
      expect(html, contains('<li>${_dayName(wednesday)}: no free time</li>'));
      expect(c.read(workWeekProvider), {DateTime.wednesday});

      // Asked again: as chosen last time.
      await tester.tap(find.byKey(const ValueKey('compose-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Insert free times…'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('work-day-3')))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('work-day-1')))
            .selected,
        isFalse,
      );
    });

    testWidgets('a work week of no days cannot be asked for', (tester) async {
      await compose(tester, _Accounts(), accountId: 'acct-ms');
      await tester.tap(find.byKey(const ValueKey('compose-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Insert free times…'));
      await tester.pumpAndSettle();
      for (var day = DateTime.monday; day <= DateTime.friday; day++) {
        await tester.tap(find.byKey(ValueKey('work-day-$day')));
        await tester.pumpAndSettle();
      }

      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('free-times-insert')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('no free times from an account with a password',
        (tester) async {
      await compose(tester, _Accounts(), accountId: 'acct-p');
      await tester.tap(find.byKey(const ValueKey('compose-more')));
      await tester.pumpAndSettle();

      expect(find.text('Insert free times…'), findsNothing);
    });
  });

  group('who is free, on New meeting', () {
    /// The screen for [accountId], pushed over a plain page, starting at
    /// nine on Thursday 1 October 2026 for an hour.
    Future<ProviderContainer> meeting(
      WidgetTester tester,
      SampleMailEngine engine, {
      String accountId = 'acct-ms',
    }) async {
      tall(tester);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        deviceCalendarProvider.overrideWithValue(
          FakeDeviceCalendar(timeZone: 'America/New_York'),
        ),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          builder: clock24,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NewMeetingScreen(
                      accountId: accountId,
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

    Finder attendees() => find.descendant(
          of: find.byKey(const ValueKey('meeting-attendees')),
          matching: find.byType(TextField),
          matchRoot: true,
        );
    String? time(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('assistant-time')))
        .data;
    final button = find.byKey(const ValueKey('who-is-free'));

    Future<void> open(WidgetTester tester) async {
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    /// Send, with a title: a meeting needs one.
    Future<void> send(WidgetTester tester) async {
      await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('meeting-title')),
            matching: find.byType(TextField),
            matchRoot: true,
          ),
          'Q3 review');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
    }

    testWidgets('says who is busy at the time; the sheet shows each one\'s '
        'day, and Next free time moves the meeting', (tester) async {
      final engine = _Accounts()
        ..busy['ron@contoso.com'] = [
          (start: DateTime(2026, 10, 1, 9, 30), end: DateTime(2026, 10, 1, 10)),
        ]
        ..busy['dana@contoso.com'] = [
          (start: DateTime(2026, 10, 1, 9), end: DateTime(2026, 10, 1, 9, 30)),
          (start: DateTime(2026, 10, 1, 13), end: DateTime(2026, 10, 1, 15)),
        ];
      await meeting(tester, engine);

      expect(find.text('You are busy'), findsOneWidget);

      await tester.enterText(
          attendees(), 'Dana Levi <dana@contoso.com>, someone@example.org');
      await wait(tester);
      expect(find.text('2 busy'), findsOneWidget);

      await open(tester);
      expect(time(tester), '09:00 – 10:00');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('free:dana@contoso.com')),
          matching: find.text('Dana Levi'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('free:someone@example.org')),
          matching: find.text('Not shown'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('next-free-time')));
      await tester.pumpAndSettle();
      expect(time(tester), '10:00 – 11:00');

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('No one busy'), findsOneWidget,
          reason: 'someone@example.org is not shown, so not "everyone"');

      await send(tester);
      expect(engine.meetings.single.start, DateTime(2026, 10, 1, 10));
      expect(engine.meetings.single.end, DateTime(2026, 10, 1, 11));
    });

    testWidgets('a tap on the day moves the meeting to that half hour; the '
        'arrows move it a day', (tester) async {
      final engine = _Accounts();
      await meeting(tester, engine);
      await open(tester);

      // Eight to eight: the middle of the line is two o'clock.
      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('free:ron@contoso.com')),
        matching: find.byType(GestureDetector),
      ));
      await tester.pumpAndSettle();
      expect(time(tester), '14:00 – 15:00');

      await tester.tap(find.byKey(const ValueKey('assistant-day-after')));
      await tester.pumpAndSettle();
      expect(find.text('Friday, October 2, 2026'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      await send(tester);
      expect(engine.meetings.single.start, DateTime(2026, 10, 2, 14));
    });

    testWidgets('Next free time looks at the days worked', (tester) async {
      final engine = _Accounts()
        ..busy['ron@contoso.com'] = [
          (start: DateTime(2026, 10, 1, 9), end: DateTime(2026, 10, 1, 18)),
        ];
      final c = await meeting(tester, engine);
      c.read(workWeekProvider.notifier).set({DateTime.sunday});
      await open(tester);

      await tester.tap(find.byKey(const ValueKey('next-free-time')));
      await tester.pumpAndSettle();

      expect(find.text('Sunday, October 4, 2026'), findsOneWidget);
      expect(time(tester), '08:00 – 09:00');
    });

    testWidgets('says when there is no time free', (tester) async {
      final engine = _Accounts()
        ..busy['ron@contoso.com'] = [
          (start: DateTime(2026, 9, 30), end: DateTime(2026, 11, 30)),
        ];
      await meeting(tester, engine);
      await open(tester);

      await tester.tap(find.byKey(const ValueKey('next-free-time')));
      await tester.pumpAndSettle();

      expect(find.text('No time everyone is free in the next two weeks.'),
          findsOneWidget);
      expect(time(tester), '09:00 – 10:00', reason: 'the meeting stays');
    });

    testWidgets('a calendar that cannot be read says so on the sheet',
        (tester) async {
      await meeting(tester, _Unreadable());

      expect(find.text('Who is free'), findsOneWidget);
      await open(tester);
      expect(find.text('Could not read the calendars. No connection.'),
          findsOneWidget);
    });

    testWidgets('not for a whole day', (tester) async {
      await meeting(tester, _Accounts());
      expect(button, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('meeting-all-day')));
      await tester.pumpAndSettle();

      expect(button, findsNothing);
    });

    testWidgets('not from an account with a password, whose calendar the app '
        'cannot read', (tester) async {
      await meeting(tester, _Accounts(), accountId: 'acct-p');

      expect(button, findsNothing);
    });
  });
}

/// The way free times name a day: "Wednesday 28 October".
String _dayName(DateTime d) {
  const days = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday',
  ];
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December',
  ];
  return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
}

/// The sample engine with an account of each kind: Microsoft, Google, and
/// Gmail with a password, whose calendar the app cannot read.
class _Accounts extends SampleMailEngine {
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

/// A calendar that cannot be reached.
class _Unreadable extends _Accounts {
  @override
  Future<Map<String, List<TimeSpan>?>> schedules(
    String accountId,
    List<String> emails,
    DateTime start,
    DateTime end,
  ) async =>
      throw const ConnectionFailed('No connection.');
}
