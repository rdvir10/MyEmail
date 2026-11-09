import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/notifications/notification_actions.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/calendar_meeting.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/reading_pane.dart';

import 'fakes/fake_webview.dart';

/// An invitation answered goes to Deleted Items, as Outlook sends it, from
/// its card and from its notification; Settings, Calendar keeps it instead.
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
