import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/contacts/device_contacts.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_change.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/contact_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/theme/app_theme.dart' show buildTheme;
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';

import 'fakes/fake_webview.dart';
import 'helpers/real_fonts.dart';

/// New meeting's and Edit's labels down the left, each on one line: the
/// column is as wide as its longest label at the text size in use. It was
/// 64 wide, and "Attendees" broke to "Attendee / s" on the phone, and
/// "Location" at text 1.3. The message composer's column stays as it was.
/// In Roboto, as on the phone: the test font's square letters are far
/// wider.
void main() {
  setUpAll(() async {
    FakeWebViewPlatform.install();
    await loadRoboto();
  });

  const labels = [
    'From',
    'Title',
    'Attendees',
    'Start',
    'End',
    'All day',
    'Online',
    'Location',
  ];

  Future<void> pump(
    WidgetTester tester, {
    required double width,
    required double scale,
    EventEdit? editing,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(_EachKind()),
      deviceContactsProvider.overrideWithValue(FakeDeviceContacts()),
      deviceCalendarProvider
          .overrideWithValue(FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: NewMeetingScreen(
          accountId: 'acct-ms',
          start: DateTime(2026, 10, 1, 9),
          editing: editing,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// The height of one line of the labels' type, as 'End' is drawn.
  double line(WidgetTester tester) => tester.getSize(find.text('End')).height;

  for (final (width, scale) in [(412.0, 1.0), (427.0, 1.0), (360.0, 1.3)]) {
    testWidgets('each label on one line, $width wide at text $scale',
        (tester) async {
      await pump(tester, width: width, scale: scale);
      for (final label in labels) {
        expect(find.text(label), findsOneWidget, reason: label);
        expect(tester.getSize(find.text(label)).height, line(tester),
            reason: '$label at $width, $scale');
      }
      // The fields start where the column ends, the same for every row.
      final left = {
        for (final label in ['Title', 'Attendees', 'Location'])
          tester.getTopRight(find.text(label)).dx <=
              tester.getTopLeft(find.byKey(const ValueKey('start-date'))).dx,
      };
      expect(left, {true});
      expect(tester.takeException(), isNull);
    });

    testWidgets('and on Edit, $width wide at text $scale', (tester) async {
      await pump(
        tester,
        width: width,
        scale: scale,
        editing: EventEdit(
          event: CalendarEvent(
            id: 'm1',
            accountId: 'acct-ms',
            title: 'Q3 review',
            start: DateTime(2026, 10, 1, 9),
            end: DateTime(2026, 10, 1, 10),
            isOrganizer: true,
            response: EventResponse.organizer,
          ),
          notes: const EventNotes(text: ''),
        ),
      );
      for (final label in ['Title', 'Attendees', 'Start', 'Location']) {
        expect(tester.getSize(find.text(label)).height, line(tester),
            reason: '$label at $width, $scale');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets("the message composer's labels keep their 64", (tester) async {
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(SampleMailEngine()),
      deviceContactsProvider.overrideWithValue(FakeDeviceContacts()),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: ComposeScreen(
          draft: Draft(
            accountId: 'acct-personal',
            kind: ComposeKind.newMessage,
            to: const [],
            cc: const [],
            bcc: const [],
            subject: '',
            htmlBody: '<p></p>',
            attachments: const [],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    for (final label in ['To', 'Subject']) {
      final box = find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is SizedBox));
      expect(tester.widget<SizedBox>(box.first).width, 64, reason: label);
    }
  });
}

/// An engine with a Microsoft account, Teams, and a Gmail account beside
/// it, so From is a choice and Online has its row.
class _EachKind extends SampleMailEngine {
  @override
  Future<List<Account>> loadAccounts() async => const [
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
      ];
}
