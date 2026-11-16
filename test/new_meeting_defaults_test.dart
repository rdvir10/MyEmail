import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/backup/backup_service.dart';
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/calendar/phone_calendar.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_change.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/meeting.dart';
import 'package:myemail/domain/new_meeting_defaults.dart';
import 'package:myemail/domain/settings_backup.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/calendar_view_providers.dart'
    show phoneCalendarProvider;
import 'package:myemail/state/meeting_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';
import 'package:myemail/ui/settings/calendar_settings_screen.dart';

import 'fakes/fake_webview.dart';

/// Your own defaults for a new meeting (calendar idea #61): how long it
/// lasts, whether it ends a few minutes early, and whether it starts
/// online, chosen in Settings, Calendar; New meeting starts from them and
/// an edit never does.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  group('the defaults', () {
    test('start as New meeting always was: an hour, on time, not online', () {
      const d = NewMeetingDefaults();
      expect(d.minutes, 60);
      expect(d.endEarly, 0);
      expect(d.length, const Duration(hours: 1));
      expect(d.onlineFor('acct-ms'), isFalse);
      expect(NewMeetingDefaults.fromJson(null), d);
      expect(NewMeetingDefaults.tryParse('not json'), isNull);
    });

    test('ending early takes the minutes off: a half hour ends at 25 past', () {
      expect(const NewMeetingDefaults(minutes: 30, endEarly: 5).length,
          const Duration(minutes: 25));
      expect(const NewMeetingDefaults(minutes: 15, endEarly: 10).length,
          const Duration(minutes: 5));
    });

    test('kept as text and read back; anything out of range is the default',
        () {
      const d = NewMeetingDefaults(
        minutes: 45,
        endEarly: 10,
        online: {'acct-ms', 'acct-g'},
      );
      expect(NewMeetingDefaults.tryParse(jsonEncode(d.toJson())), d);
      expect(
        NewMeetingDefaults.fromJson({
          'minutes': 50,
          'endEarly': 7,
          'online': ['acct-ms', 3, null],
        }),
        const NewMeetingDefaults(online: {'acct-ms'}),
      );
    });
  });

  group('Settings, Calendar, New meetings', () {
    late MemoryUiStateStore ui;

    setUp(() => ui = MemoryUiStateStore());

    Future<ProviderContainer> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(_EachKind()),
        deviceCalendarProvider.overrideWithValue(FakeDeviceCalendar()),
        phoneCalendarProvider.overrideWithValue(FakePhoneCalendar()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: CalendarSettingsScreen()),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    Future<void> reach(WidgetTester tester, Finder row) async {
      await tester.scrollUntilVisible(row, 200);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
    }

    Future<void> choose(WidgetTester tester, String key, String item) async {
      final menu = find.byKey(ValueKey(key));
      await reach(tester, menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text(item).last);
      await tester.pumpAndSettle();
    }

    testWidgets('the length, ending early and online by default are chosen '
        'there and kept', (tester) async {
      final c = await pump(tester);
      await reach(tester, find.text('New meetings'));
      expect(find.text('1 hour'), findsOneWidget, reason: 'as it always was');

      await choose(tester, 'new-meeting-length', '30 minutes');
      await choose(tester, 'new-meeting-end-early', '5 minutes');
      expect(find.textContaining('ends at 9:25 AM'), findsOneWidget,
          reason: 'what it does, said with a time');

      final work = find.byKey(const ValueKey('new-meeting-online:acct-ms'));
      await reach(tester, work);
      expect(tester.widget<SwitchListTile>(work).value, isFalse);
      await tester.tap(work);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(work).value, isTrue);
      // Only accounts whose calendar the app reaches: an app password's
      // has no Teams or Meet to switch on.
      expect(find.byKey(const ValueKey('new-meeting-online:acct-p')),
          findsNothing);

      const want = NewMeetingDefaults(
        minutes: 30,
        endEarly: 5,
        online: {'acct-ms'},
      );
      expect(c.read(newMeetingDefaultsProvider), want);
      expect(
        NewMeetingDefaults.tryParse(
            ui.readString(UiStateKeys.newMeetingDefaults)!),
        want,
      );
    });
  });

  group('New meeting', () {
    late SampleMailEngine engine;

    setUp(() => engine = _EachKind());

    /// New meeting for [accountId], at nine on 1 October 2026, with
    /// [defaults] kept in Settings; or [editing] a meeting.
    Future<ProviderContainer> pumpScreen(
      WidgetTester tester, {
      String accountId = 'acct-ms',
      NewMeetingDefaults? defaults,
      Duration? length,
      EventEdit? editing,
    }) async {
      final ui = MemoryUiStateStore();
      if (defaults != null) {
        unawaited(ui.writeString(
            UiStateKeys.newMeetingDefaults, jsonEncode(defaults.toJson())));
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
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NewMeetingScreen(
                      accountId: accountId,
                      start: DateTime(2026, 10, 1, 9),
                      length: length,
                      editing: editing,
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

    final online = find.byKey(const ValueKey('meeting-online'));

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

    testWidgets('with nothing chosen it is an hour, and not online',
        (tester) async {
      await pumpScreen(tester);
      expect(find.text('10:00 AM'), findsOneWidget);
      expect(tester.widget<Switch>(online).value, isFalse);
      expect(engine.preparedMeetings, isEmpty);
    });

    testWidgets('it lasts as long as chosen, less the minutes it ends early',
        (tester) async {
      await pumpScreen(tester,
          defaults: const NewMeetingDefaults(minutes: 30, endEarly: 5));
      expect(find.text('9:00 AM'), findsOneWidget);
      expect(find.text('9:25 AM'), findsOneWidget);

      await send(tester);
      expect(engine.meetings.single.end, DateTime(2026, 10, 1, 9, 25));
    });

    testWidgets('a length it was given, a meeting duplicated say, stays',
        (tester) async {
      await pumpScreen(
        tester,
        defaults: const NewMeetingDefaults(minutes: 30, endEarly: 5),
        length: const Duration(minutes: 90),
      );
      expect(find.text('10:30 AM'), findsOneWidget);
    });

    testWidgets('online by default: the switch starts on for that account, '
        'with its link made, and off for another', (tester) async {
      await pumpScreen(tester,
          defaults: const NewMeetingDefaults(online: {'acct-ms'}));
      expect(tester.widget<Switch>(online).value, isTrue);
      expect(engine.preparedMeetings.single.kind, OnlineMeetingKind.teams);

      // From another account, not chosen: off, and the link undone.
      await tester.tap(find.byKey(const ValueKey('meeting-from-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ron@gmail.com').last);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(online).value, isFalse);
      expect(engine.discardedMeetings, hasLength(1));

      // Back again: on again.
      await tester.tap(find.byKey(const ValueKey('meeting-from-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ron@contoso.com').last);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(online).value, isTrue);

      await send(tester);
      expect(engine.meetings.single.online, OnlineMeetingKind.teams);
    });

    testWidgets('the switch, once set by hand, stays as set through a change '
        'of From', (tester) async {
      await pumpScreen(tester,
          defaults: const NewMeetingDefaults(online: {'acct-ms'}));
      await tester.tap(online);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(online).value, isFalse);

      await tester.tap(find.byKey(const ValueKey('meeting-from-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ron@gmail.com').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('meeting-from-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ron@contoso.com').last);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(online).value, isFalse);
    });

    testWidgets('the screen opened with the defaults is still untouched: '
        'leaving asks nothing', (tester) async {
      await pumpScreen(tester,
          defaults: const NewMeetingDefaults(
              minutes: 30, endEarly: 5, online: {'acct-ms'}));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(NewMeetingScreen), findsNothing);
      expect(find.text('Discard this meeting?'), findsNothing);
    });

    testWidgets('an edit keeps the meeting as it is, whatever the defaults',
        (tester) async {
      final meeting = CalendarEvent(
        id: 'm1',
        accountId: 'acct-ms',
        title: 'Q3 review',
        start: DateTime(2026, 10, 1, 9),
        end: DateTime(2026, 10, 1, 10),
        isOrganizer: true,
        response: EventResponse.organizer,
        attendees: const [
          EventAttendee(MailAddress(email: 'dana@example.com')),
        ],
      );
      await pumpScreen(
        tester,
        defaults: const NewMeetingDefaults(
            minutes: 15, endEarly: 5, online: {'acct-ms'}),
        editing:
            EventEdit(event: meeting, notes: const EventNotes(text: '')),
      );
      expect(find.text('10:00 AM'), findsOneWidget);
      expect(online, findsNothing);
      expect(engine.preparedMeetings, isEmpty);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing was changed.'), findsOneWidget);
    });
  });

  group('the backup', () {
    test('carries them, the accounts as the device restored to knows them',
        () async {
      final from = MemoryUiStateStore();
      await from.writeString(
        UiStateKeys.newMeetingDefaults,
        jsonEncode(const NewMeetingDefaults(
          minutes: 30,
          endEarly: 5,
          online: {'acct-ms'},
        ).toJson()),
      );
      expect(BackupService.exported.containsKey(UiStateKeys.newMeetingDefaults),
          isTrue);
      final file = (await BackupService(
        accountStore: MemoryAccountStore(const [_EachKind.microsoft]),
        uiState: from,
      ).export())
          .toJsonString();
      expect(
        SettingsBackup.parse(file).entries[UiStateKeys.newMeetingDefaults],
        isA<String>(),
      );

      // The tablet knows the same mailbox by an id of its own.
      final to = MemoryUiStateStore();
      await BackupService(
        accountStore: MemoryAccountStore(const [
          Account(
            id: 'acct-other',
            displayName: 'Work',
            emailAddress: 'ron@contoso.com',
            provider: MailProvider.outlook,
            authMethod: AuthMethod.oauth,
            colorValue: 0xFF0F6CBD,
          ),
        ]),
        uiState: to,
      ).import(SettingsBackup.parse(file));
      expect(
        NewMeetingDefaults.tryParse(
            to.readString(UiStateKeys.newMeetingDefaults)!),
        const NewMeetingDefaults(
          minutes: 30,
          endEarly: 5,
          online: {'acct-other'},
        ),
      );

      // One written by nothing of ours is left out, not written blind.
      final odd = MemoryUiStateStore();
      final report = await BackupService(
        accountStore: MemoryAccountStore(),
        uiState: odd,
      ).import(SettingsBackup(
        accounts: const [],
        entries: const {UiStateKeys.newMeetingDefaults: '[1, 2]'},
      ));
      expect(report.settingsRestored, 0);
      expect(odd.readString(UiStateKeys.newMeetingDefaults), isNull);
    });
  });
}

/// An engine with an account of each kind: a Microsoft one, whose calendar
/// holds meetings on Teams; a Google one, with Meet; and one with an app
/// password, whose calendar holds none.
class _EachKind extends SampleMailEngine {
  static const microsoft = Account(
    id: 'acct-ms',
    displayName: 'Work',
    emailAddress: 'ron@contoso.com',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF0F6CBD,
  );

  static const accounts = [
    microsoft,
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
