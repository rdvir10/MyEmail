import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/notifications/notification_actions.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/calendar_invite.dart';
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
    Future<(ProviderContainer, SampleMailEngine, MailMessage)> pump(
      WidgetTester tester, {
      bool delete = true,
    }) async {
      FakeWebViewPlatform.install();
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (engine, message) = (await tester.runAsync(invitation))!;
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

    testWidgets('Accept, and the invitation goes to Deleted Items, with Undo',
        (tester) async {
      final (_, engine, message) = await pump(tester);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
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
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(find.text('Accepted. The organiser has been told.'),
          findsOneWidget);
      final inbox = (await tester
          .runAsync(() => engine.loadMessages(message.folderId)))!;
      expect(inbox.any((m) => m.id == message.id), isTrue);
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
