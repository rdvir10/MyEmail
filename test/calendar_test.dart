import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/invite_card.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Invitations: found in a message, shown, answered, kept.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  group('finding the invitation in a message', () {
    test('the text/calendar part comes out beside the body', () {
      const mime = 'From: dana@example.com\r\n'
          'To: me@example.com\r\n'
          'Subject: Q3 review\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: multipart/alternative; boundary="b1"\r\n'
          '\r\n'
          '--b1\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          '\r\n'
          'Please come.\r\n'
          '--b1\r\n'
          'Content-Type: text/calendar; method=REQUEST; charset=utf-8\r\n'
          '\r\n'
          'BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:1\r\n'
          'SUMMARY:Q3 review\r\nDTSTART:20260921T130000Z\r\nEND:VEVENT\r\n'
          'END:VCALENDAR\r\n'
          '--b1--\r\n';

      final body = bodyFromMime(em.MimeMessage.parseFromText(mime));

      expect(body.text, contains('Please come.'));
      expect(body.calendar, contains('BEGIN:VEVENT'));
      expect(CalendarInvite.parse(body.calendar!)!.summary, 'Q3 review');
    });

    test('a message with none has none', () {
      const mime = 'Subject: hi\r\nContent-Type: text/plain\r\n\r\nhello\r\n';
      expect(bodyFromMime(em.MimeMessage.parseFromText(mime)).calendar, isNull);
    });
  });

  group('the reply as mail', () {
    test('carries a text/calendar part marked as a REPLY', () {
      final account = Account(
        id: 'a',
        displayName: 'Ron Dvir',
        emailAddress: 'ron@example.com',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.appPassword,
        colorValue: 0xFF000000,
      );
      final invite = CalendarInvite.parse(
        'BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:abc\nSUMMARY:Lunch\n'
        'DTSTART:20260921T120000Z\nORGANIZER:mailto:dana@example.com\n'
        'END:VEVENT\nEND:VCALENDAR',
      )!;
      final draft = Draft(
        accountId: 'a',
        kind: ComposeKind.reply,
        to: const [MailAddress(email: 'dana@example.com')],
        subject: inviteReplySubject(invite, InviteResponse.accepted),
        htmlBody: '<p>Accepted</p>',
        calendarReply: iMipReply(
          invite,
          attendee: const MailAddress(email: 'ron@example.com', name: 'Ron Dvir'),
          response: InviteResponse.accepted,
        ),
      );

      final rendered = buildMimeMessage(draft: draft, account: account).renderMessage();

      expect(rendered, contains('Subject: Accepted: Lunch'));
      expect(rendered.toLowerCase(), contains('content-type: text/calendar'));
      expect(rendered.toLowerCase(), contains('method=reply'));
      expect(rendered, contains('PARTSTAT=ACCEPTED'));
    });
  });

  group('on screen', () {
    late FakeDeviceCalendar calendar;
    late SampleMailEngine engine;

    setUp(() {
      calendar = FakeDeviceCalendar();
      engine = SampleMailEngine();
    });

    Future<ProviderContainer> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        deviceCalendarProvider.overrideWithValue(calendar),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    /// Open the sample invitation: any inbox has one.
    Future<MailMessage> openInvite(WidgetTester tester, ProviderContainer c) async {
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final invite = c
          .read(messagesProvider(folder))
          .value!
          .firstWhere((m) => m.subject.startsWith('Invitation:'));
      c.read(selectedMessageIdProvider.notifier).select(invite.id);
      await tester.pumpAndSettle();
      expect(find.byType(InviteCard), findsOneWidget);
      return invite;
    }

    testWidgets('an invitation shows as a card with when and where',
        (tester) async {
      final c = await pump(tester);
      await openInvite(tester, c);

      expect(find.text('Invitation'), findsOneWidget);
      expect(find.text('Q3 review'), findsWidgets);
      expect(find.textContaining('10:00–11:00'), findsOneWidget);
      expect(find.textContaining('Room 4'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Add to calendar'), findsOneWidget);
    });

    testWidgets('Accept answers through the account and says so',
        (tester) async {
      final c = await pump(tester);
      final invite = await openInvite(tester, c);

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      expect(engine.inviteResponses.single.messageId, invite.id);
      expect(engine.inviteResponses.single.response, InviteResponse.accepted);
      expect(find.text('You accepted'), findsOneWidget);
      expect(find.text('Decline'), findsNothing, reason: 'answered once');
    });

    testWidgets('Add to calendar hands the event to the device',
        (tester) async {
      final c = await pump(tester);
      await openInvite(tester, c);

      await tester.tap(find.text('Add to calendar'));
      await tester.pumpAndSettle();

      final e = calendar.inserted.single;
      expect(e.title, 'Q3 review');
      expect(e.location, 'Room 4');
      expect(e.start!.hour, 10);
      expect(e.end!.hour, 11);
    });

    testWidgets('a time in a zone that cannot be worked out is not offered',
        (tester) async {
      // Added, it would go in at that hour of the phone's own clock.
      final c = ProviderContainer(overrides: [
        mailEngineProvider.overrideWithValue(engine),
        deviceCalendarProvider.overrideWithValue(calendar),
      ]);
      addTearDown(c.dispose);
      final message = MailMessage(
        id: 'acct-personal:INBOX#1',
        accountId: 'acct-personal',
        folderId: 'acct-personal:INBOX',
        uid: 1,
        subject: 'Invitation: Far away',
        from: const MailAddress(email: 'dana@example.com'),
        to: const [MailAddress(email: 'ron@example.com')],
        date: DateTime(2026, 9, 20),
        preview: '',
      );
      final invite = CalendarInvite.parse(
        'BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:z\n'
        'SUMMARY:Far away\nDTSTART;TZID=Somewhere:20260921T130000\n'
        'END:VEVENT\nEND:VCALENDAR',
      )!;

      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(body: InviteCard(message: message, invite: invite)),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Add to calendar'), findsNothing);
    });

    testWidgets('any message can become an event from the menu',
        (tester) async {
      final c = await pump(tester);
      final open = c.read(selectedMessageProvider)!;

      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create calendar event…'));
      await tester.pumpAndSettle();

      expect(calendar.inserted.single.title, open.subject);
      expect(calendar.inserted.single.description, contains('From: '));
      expect(find.byType(MessageTile), findsWidgets);
    });
  });
}
