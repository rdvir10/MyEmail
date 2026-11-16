import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/compose/graph_sender.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/notifications/android_mail_notifier.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/notifications/notification_action_isolate.dart';
import 'package:myemail/data/notifications/notification_actions.dart';
import 'package:myemail/data/notifications/pending_actions.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/sync/background_sync.dart';
import 'package:myemail/data/sync/sync_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/folder_capabilities.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/meeting_alerts.dart';
import 'package:myemail/domain/sync_prefs.dart';
import 'package:timezone/timezone.dart' as tz;

/// The buttons on an invitation's notification (#32) and on a meeting's
/// reminder (#31): carried out with no app, as Reply and Delete are.
void main() {
  String ics(String method) => [
        'BEGIN:VCALENDAR',
        'METHOD:$method',
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

  group('Accept and Decline on an invitation', () {
    late _InviteEngine engine;
    late String messageId;

    setUp(() async {
      engine = _InviteEngine();
      final inbox = (await engine.loadFolders('acct-personal'))
          .firstWhere((f) => f.role == FolderRole.inbox);
      final message = (await engine.loadMessages(inbox.id)).first;
      messageId = message.id;
      await engine.setRead(messageId, false);
    });

    test('are known presses, carried out with the rest', () {
      expect(NotificationActions.isKnown(NotificationActions.acceptId), isTrue);
      expect(NotificationActions.isKnown(NotificationActions.declineId), isTrue);
      expect(NotificationActions.isKnown(NotificationActions.lateId), isTrue);
      // Join opens the app; Snooze is done where it is pressed.
      expect(NotificationActions.isKnown(NotificationActions.joinId), isFalse);
      expect(NotificationActions.isKnown(NotificationActions.snoozeId), isFalse);
    });

    test('answer it as its card would, and leave it read', () async {
      engine.calendarText = ics('REQUEST');
      final actions = NotificationActions(engine: engine);
      expect(await actions.perform(NotificationActions.acceptId, messageId, null),
          ActionOutcome.answered);
      expect(engine.inviteAnswers.single.response, InviteResponse.accepted);
      expect(engine.inviteAnswers.single.send, isTrue);
      expect((await engine.cachedMessage(messageId))!.isRead, isTrue);

      expect(
          await actions.perform(NotificationActions.declineId, messageId, null),
          ActionOutcome.answered);
      expect(engine.inviteAnswers.last.response, InviteResponse.declined);
      expect(ActionOutcome.answered.message, isNull, reason: 'the row going '
          'away says it');
    });

    test('a cancellation is not answered, and says to open it', () async {
      engine.calendarText = ics('CANCEL');
      final outcome = await NotificationActions(engine: engine)
          .perform(NotificationActions.acceptId, messageId, null);
      expect(outcome, ActionOutcome.notAnswerable);
      expect(engine.inviteAnswers, isEmpty);
      expect(outcome.message, contains('Open it in MyEmail'));
    });

    test('offline, the press waits for a connection', () async {
      engine.bodyFailure = const ConnectionFailed('No connection.');
      final outcome = await NotificationActions(engine: engine)
          .perform(NotificationActions.acceptId, messageId, null);
      expect(outcome, ActionOutcome.offline);
      expect(outcome.worthRetrying, isTrue);
    });

    test('a refused answer is said, not tried again', () async {
      engine.calendarText = ics('REQUEST');
      engine.answerFailure = StateError('refused');
      final outcome = await NotificationActions(engine: engine)
          .perform(NotificationActions.declineId, messageId, null);
      expect(outcome, ActionOutcome.notAnswered);
      expect(outcome.worthRetrying, isFalse);
    });
  });

  group('Running late on a reminder', () {
    late _InviteEngine engine;
    late Account hadco;
    late CalendarEvent meeting;
    final start = DateTime(2026, 10, 26, 10);

    setUp(() async {
      engine = _InviteEngine();
      hadco = await engine.addOAuthAccount(
        displayName: 'Hadco',
        emailAddress: 'ron@hadco.example',
        provider: MailProvider.outlook,
        token: OAuthToken(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.utc(2030),
        ),
      );
      meeting = CalendarEvent(
        id: 'm1',
        accountId: hadco.id,
        title: 'Weekly sync',
        start: start,
        end: start.add(const Duration(minutes: 30)),
        organizer: const MailAddress(email: 'dana@example.com'),
        reminderMinutes: 15,
      );
      engine.events[hadco.id] = [meeting];
      // Read once, so the device keeps it, as the reminder's pass did.
      await engine.calendarEvents(
          hadco.id, DateTime(2026, 10, 26), DateTime(2026, 10, 27));
    });

    NotificationActions actions(DateTime at) => NotificationActions(
          engine: engine,
          accounts: [hadco],
          clock: () => at,
        );

    test('tells the organiser, by the minutes picked', () async {
      final payload = MeetingRef.of(meeting).payload;
      expect(
          await actions(start.subtract(const Duration(minutes: 5)))
              .perform(NotificationActions.lateId, payload, '10 min late'),
          ActionOutcome.toldLate);
      final sent = engine.sent.single;
      expect([for (final a in sent.to) a.email], ['dana@example.com']);
      expect(sent.subject, 'Running late: Weekly sync');
      expect(sent.htmlBody, contains('about 10 minutes'));
    });

    test('says nothing went once the meeting is over', () async {
      final outcome = await actions(start.add(const Duration(hours: 1)))
          .perform(NotificationActions.lateId, MeetingRef.of(meeting).payload,
              '5 min late');
      expect(outcome, ActionOutcome.meetingOver);
      expect(engine.sent, isEmpty);
    });

    group('sent through Microsoft, answered with an error of its own', () {
      /// The message goes to a Microsoft that answers the send with a 500
      /// and, looked at after, has it in Sent Items where [filed], or
      /// cannot be read at all where [unreadable].
      void graph({required bool filed, bool unreadable = false}) {
        var messageId = '';
        final sender = GraphSender(
          accessToken: ({bool force = false}) async => 'graph-token',
          lookAfter: const [Duration.zero, Duration.zero],
          httpClient: http_testing.MockClient((request) async {
            if (request.method == 'POST') {
              final mime = utf8.decode(base64Decode(request.body));
              messageId =
                  RegExp(r'Message-Id: (<[^>]+>)', caseSensitive: false)
                      .firstMatch(mime)![1]!;
              return http.Response(
                jsonEncode({
                  'error': {'code': 'ErrorInternalServerError'},
                }),
                500,
              );
            }
            if (unreadable) return http.Response('', 503);
            return http.Response(
              jsonEncode({
                'value': [
                  if (filed) {'internetMessageId': messageId},
                ],
              }),
              200,
            );
          }),
        );
        engine.sendWith =
            (draft) => sender.sendDraft(draft: draft, account: hadco);
      }

      test('not in Sent Items: it could not be sent, as it always said',
          () async {
        // Taken for "may have gone", it reported the people told, in
        // silence, when nobody had been.
        graph(filed: false);

        final outcome =
            await actions(start.subtract(const Duration(minutes: 5))).perform(
                NotificationActions.lateId,
                MeetingRef.of(meeting).payload,
                '10 min late');

        expect(outcome, ActionOutcome.lateNotSent);
        expect(outcome.message,
            'Your running-late message could not be sent.');
      });

      test('Sent Items not to be read at all: it could not be sent, as it '
          'always said', () async {
        // Graph failing its reads as well as the send is when an honest
        // 500 is likeliest. Taken for "may have gone", it said nothing.
        graph(filed: false, unreadable: true);

        final outcome =
            await actions(start.subtract(const Duration(minutes: 5))).perform(
                NotificationActions.lateId,
                MeetingRef.of(meeting).payload,
                '10 min late');

        expect(outcome, ActionOutcome.lateNotSent);
        expect(outcome.message,
            'Your running-late message could not be sent.');
      });

      test('in Sent Items: they were told', () async {
        graph(filed: true);

        expect(
          await actions(start.subtract(const Duration(minutes: 5))).perform(
              NotificationActions.lateId,
              MeetingRef.of(meeting).payload,
              '10 min late'),
          ActionOutcome.toldLate,
        );
      });
    });

    test('with nobody else on it, nobody is told', () async {
      final alone = CalendarEvent(
        id: 'm2',
        accountId: hadco.id,
        title: 'Focus',
        start: start,
        end: start.add(const Duration(hours: 1)),
        isOrganizer: true,
      );
      engine.events[hadco.id] = [alone];
      await engine.calendarEvents(
          hadco.id, DateTime(2026, 10, 26), DateTime(2026, 10, 27));
      expect(
          await actions(start).perform(
              NotificationActions.lateId, MeetingRef.of(alone).payload, null),
          ActionOutcome.nobodyToTell);
    });
  });

  group('Snooze on a reminder', () {
    final start = DateTime(2026, 10, 26, 10);
    final meeting = MeetingRef(
      accountId: 'hadco',
      eventId: 'm1',
      start: start,
      end: start.add(const Duration(minutes: 30)),
      title: 'Weekly sync',
      body: '10:00–10:30',
      canTellLate: true,
    );

    test('the same reminder, five minutes on', () async {
      final notifier = FakeMailNotifier();
      await snoozeMeetingReminder(
        7,
        meeting.payload,
        notifier: notifier,
        clock: () => DateTime(2026, 10, 26, 9, 45),
      );
      final again = notifier.meetingReminders[7]!;
      expect(again.at, DateTime(2026, 10, 26, 9, 50));
      expect(again.meeting, meeting);
      expect(again.canTellLate, isTrue);
    });

    test("it keeps its account's colour", () async {
      final notifier = FakeMailNotifier();
      final coloured = MeetingRef(
        accountId: meeting.accountId,
        eventId: meeting.eventId,
        start: meeting.start,
        end: meeting.end,
        title: meeting.title,
        colour: 0xFF0F6CBD,
      );
      await snoozeMeetingReminder(
        7,
        coloured.payload,
        notifier: notifier,
        clock: () => DateTime(2026, 10, 26, 9, 45),
      );
      expect(notifier.meetingReminders[7]!.meeting.colour, 0xFF0F6CBD);
    });

    test('nothing once the meeting is over, nor for a message', () async {
      final notifier = FakeMailNotifier();
      await snoozeMeetingReminder(7, meeting.payload,
          notifier: notifier, clock: () => DateTime(2026, 10, 26, 10, 28));
      await snoozeMeetingReminder(8, 'acct:INBOX#3', notifier: notifier);
      expect(notifier.meetingReminders, isEmpty);
    });
  });

  group('through the real notifier', () {
    late _Plugin plugin;
    late List<PendingAction> queued;
    late AndroidMailNotifier notifier;
    final start = DateTime(2026, 10, 26, 10);
    // The phone's clock, the notifier's and the plugin's alike.
    final now = DateTime(2026, 10, 26, 9);
    final meeting = MeetingRef(
      accountId: 'hadco',
      eventId: 'm1',
      start: start,
      end: start.add(const Duration(minutes: 30)),
      title: 'Weekly sync',
      body: '10:00–10:30',
      joinUrl: 'https://teams.microsoft.com/l/meetup-join/x',
    );

    setUp(() {
      plugin = _Plugin()..now = () => now;
      queued = [];
      notifier = AndroidMailNotifier(
        plugin: plugin,
        queueAction: (action) async => queued.add(action),
        drawBadge: (_) async => null,
        postingMarks: () async => null,
        clock: () => now,
      );
    });

    test('Join opens the meeting\'s link, through the app', () async {
      await notifier.ensureReady();
      plugin.tapped!(NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationActions.joinId,
        payload: meeting.payload,
      ));
      final payload = await notifier.takeLaunchPayload();
      expect(MeetingRef.isJoin(payload), isTrue);
      expect(MeetingRef.fromPayload(payload)!.joinUrl, meeting.joinUrl);
      expect(queued, isEmpty);
    });

    test('Join that started the app does the same', () async {
      plugin.launch = NotificationAppLaunchDetails(
        true,
        notificationResponse: NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: NotificationActions.joinId,
          payload: meeting.payload,
        ),
      );
      expect(MeetingRef.isJoin(await notifier.takeLaunchPayload()), isTrue);
    });

    test('a reminder tapped opens its meeting', () async {
      await notifier.ensureReady();
      plugin.tapped!(NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: meeting.payload,
      ));
      expect(await notifier.takeLaunchPayload(), meeting.payload);
    });

    test('a reminder is set for its time, with Join, Running late and Snooze',
        () async {
      await notifier.scheduleMeetingReminder(MeetingReminder(
        id: 7,
        at: DateTime(2026, 10, 26, 9, 45),
        meeting: MeetingRef(
          accountId: meeting.accountId,
          eventId: meeting.eventId,
          start: meeting.start,
          end: meeting.end,
          title: meeting.title,
          body: meeting.body,
          joinUrl: meeting.joinUrl,
          canTellLate: true,
        ),
      ));
      final set = plugin.scheduled.single;
      expect(set.id, 7);
      expect(set.at.millisecondsSinceEpoch,
          DateTime(2026, 10, 26, 9, 45).millisecondsSinceEpoch);
      expect(set.title, 'Weekly sync');
      final android = set.details.android!;
      expect([for (final a in android.actions!) a.id], [
        NotificationActions.joinId,
        NotificationActions.lateId,
        NotificationActions.snoozeId,
      ]);
      expect(android.actions!.first.showsUserInterface, isTrue);
      expect(android.actions![1].inputs.single.choices, hasLength(3));
      expect(android.timeoutAfter, const Duration(minutes: 45).inMilliseconds,
          reason: 'gone once the meeting is over');
      expect(android.chronometerCountDown, isTrue);
      expect(android.icon, '@drawable/ic_stat_event',
          reason: "the calendar's own icon, not new mail's envelope");
    });

    // A reminder for all-day events (#68).
    test("an all-day reminder: the meeting reminders' channel and icon, no "
        "buttons, its day opened, gone at its own day's end", () async {
      await notifier.scheduleDayReminder(DayReminder(
        id: 9,
        at: DateTime(2026, 10, 26, 18),
        day: DateTime(2026, 10, 27),
        title: 'Tomorrow: Thanksgiving',
        body: 'All day',
        until: DateTime(2026, 10, 27),
      ));
      final set = plugin.scheduled.single;
      expect(set.id, 9);
      expect(set.at.millisecondsSinceEpoch,
          DateTime(2026, 10, 26, 18).millisecondsSinceEpoch);
      expect(set.title, 'Tomorrow: Thanksgiving');
      expect(set.payload, calendarDayPayload(DateTime(2026, 10, 27)));
      final android = set.details.android!;
      expect(android.channelId, AndroidMailNotifier.meetingChannelId);
      expect(android.icon, '@drawable/ic_stat_event');
      expect(android.actions ?? const [], isEmpty);
      expect(android.timeoutAfter, const Duration(hours: 6).inMilliseconds);
    });

    test('a reminder whose time has just passed goes off now, not refused',
        () async {
      // A meeting made inside its own reminder time is set for a moment
      // on, and that moment has passed when reading the calendars first
      // took longer. The plugin throws at a time gone by.
      await notifier.scheduleMeetingReminder(MeetingReminder(
        id: 7,
        at: now.subtract(const Duration(seconds: 3)),
        meeting: meeting,
      ));
      final at = plugin.scheduled.single.at;
      expect(at.isAfter(now), isTrue);
      expect(at.difference(now), lessThanOrEqualTo(const Duration(seconds: 2)));
    });

    test('Snooze pressed in the app sets it again', () async {
      await notifier.ensureReady();
      plugin.tapped!(NotificationResponse(
        id: 7,
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationActions.snoozeId,
        payload: MeetingRef(
          accountId: 'hadco',
          eventId: 'm1',
          start: DateTime.now().add(const Duration(hours: 1)),
          end: DateTime.now().add(const Duration(hours: 2)),
        ).payload,
      ));
      await pumpEventQueue();
      expect(plugin.scheduled.single.id, 7);
      expect(queued, isEmpty);
      expect(await notifier.takeLaunchPayload(), isNull);
    });

    test("an invitation's notification has Accept and Decline", () async {
      const account = Account(
        id: 'a',
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.oauth,
        colorValue: 0xFF0F6CBD,
      );
      final inbox = MailFolder.at(
        accountId: 'a',
        path: 'INBOX',
        role: FolderRole.inbox,
        capabilities: FolderCapabilities.forGmail(FolderRole.inbox),
      );
      await notifier.showNewMail(
        account: account,
        folder: inbox,
        notifications: [
          MailNotification(
            id: 1,
            title: 'Dana Levi',
            body: 'Planning',
            payload: 'a:INBOX#1',
            when: DateTime(2026, 10, 25),
            invitation: true,
          ),
          MailNotification(
            id: 2,
            title: 'Dana Levi',
            body: 'Lunch?',
            payload: 'a:INBOX#2',
            when: DateTime(2026, 10, 25),
          ),
        ],
      );
      List<String> actionsOf(int id) => [
            for (final a in plugin.shown
                .firstWhere((s) => s.id == id)
                .details
                .android!
                .actions!)
              a.id,
          ];
      expect(actionsOf(1), [
        NotificationActions.acceptId,
        NotificationActions.declineId,
        NotificationActions.replyId,
      ]);
      expect(actionsOf(2), [
        NotificationActions.replyId,
        NotificationActions.replyAllId,
        NotificationActions.deleteId,
      ]);
      String? iconOf(int id) =>
          plugin.shown.firstWhere((s) => s.id == id).details.android!.icon;
      expect(iconOf(1), '@drawable/ic_stat_event',
          reason: 'meeting mail wears the calendar, as the reminders do');
      expect(iconOf(2), isNull, reason: 'other mail keeps the envelope');
      final invitation =
          plugin.shown.firstWhere((s) => s.id == 1).details.android!.actions!;
      expect(
        [for (final a in invitation) a.showsUserInterface],
        [true, true, false],
        reason: 'Accept and Decline open the invitation, which asks how the '
            'answer goes; Reply is typed in the shade',
      );
    });

    test('Accept pressed opens the invitation with the answer begun, and '
        'takes its row down by its tag', () async {
      await notifier.ensureReady();
      plugin.tapped!(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationActions.acceptId,
        id: 1,
        payload: 'a:INBOX#1',
      ));
      await pumpEventQueue();

      final payload = await notifier.takeLaunchPayload();
      final begun = NotificationActions.answerBegun(payload);
      expect(begun?.messageId, 'a:INBOX#1');
      expect(begun?.response, InviteResponse.accepted);
      expect(queued, isEmpty, reason: 'not answered behind your back');
      expect(plugin.cancelled, [(id: 1, tag: 'a:INBOX#1')]);
    });

    test('Decline that started the app does the same', () async {
      plugin.launch = const NotificationAppLaunchDetails(
        true,
        notificationResponse: NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: NotificationActions.declineId,
          id: 1,
          payload: 'a:INBOX#1',
        ),
      );
      final begun =
          NotificationActions.answerBegun(await notifier.takeLaunchPayload());
      await pumpEventQueue();

      expect(begun?.messageId, 'a:INBOX#1');
      expect(begun?.response, InviteResponse.declined);
      expect(plugin.cancelled, [(id: 1, tag: 'a:INBOX#1')]);
    });

    test('a tap on the invitation itself opens it, with nothing begun',
        () async {
      await notifier.ensureReady();
      plugin.tapped!(const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        id: 1,
        payload: 'a:INBOX#1',
      ));
      expect(await notifier.takeLaunchPayload(), 'a:INBOX#1');
    });

    // Quiet while you are in a meeting (#70): in the shade, on the channel
    // new mail always has, with no sound, vibration or pop-up.
    test('mail posted silently goes up silently, the rest as ever',
        () async {
      const account = Account(
        id: 'a',
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.oauth,
        colorValue: 0xFF0F6CBD,
      );
      final inbox = MailFolder.at(
        accountId: 'a',
        path: 'INBOX',
        role: FolderRole.inbox,
        capabilities: FolderCapabilities.forGmail(FolderRole.inbox),
      );
      await notifier.showNewMail(
        account: account,
        folder: inbox,
        notifications: [
          MailNotification(
            id: 5,
            title: 'Dana Levi',
            body: 'Lunch?',
            payload: 'a:INBOX#5',
            when: DateTime(2026, 10, 25),
            silent: true,
          ),
        ],
      );
      await notifier.showNewMail(
        account: account,
        folder: inbox,
        notifications: [
          MailNotification(
            id: 6,
            title: 'Dana Levi',
            body: 'After the meeting',
            payload: 'a:INBOX#6',
            when: DateTime(2026, 10, 25),
          ),
        ],
      );
      AndroidNotificationDetails row(int id) =>
          plugin.shown.firstWhere((s) => s.id == id).details.android!;
      expect(row(5).silent, isTrue);
      expect(row(5).channelId, AndroidMailNotifier.channelId,
          reason: 'no new channel');
      expect(row(5).actions!.first.id, NotificationActions.replyId,
          reason: 'its buttons as ever');
      expect(row(6).silent, isFalse);
      final summary = plugin.shown
          .where((s) => s.details.android!.setAsGroupSummary)
          .map((s) => s.details.android!);
      expect(summary.every((s) => !s.silent), isTrue);
      expect(
          summary.every(
              (s) => s.groupAlertBehavior == GroupAlertBehavior.children),
          isTrue,
          reason: 'the summary never sounds by itself');

      await notifier.scheduleMeetingReminder(MeetingReminder(
        id: 7,
        at: DateTime(2026, 10, 26, 9, 45),
        meeting: meeting,
      ));
      expect(plugin.scheduled.single.details.android!.silent, isFalse,
          reason: 'meeting reminders still sound');
    });

    test('a cancellation wears the calendar too, without Accept', () async {
      const account = Account(
        id: 'a',
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.oauth,
        colorValue: 0xFF0F6CBD,
      );
      final inbox = MailFolder.at(
        accountId: 'a',
        path: 'INBOX',
        role: FolderRole.inbox,
        capabilities: FolderCapabilities.forGmail(FolderRole.inbox),
      );
      await notifier.showNewMail(
        account: account,
        folder: inbox,
        notifications: [
          MailNotification(
            id: 3,
            title: 'Dana Levi',
            body: 'Cancelled: Planning',
            payload: 'a:INBOX#3',
            when: DateTime(2026, 10, 25),
            meeting: true,
          ),
        ],
      );
      final android =
          plugin.shown.firstWhere((s) => s.id == 3).details.android!;
      expect(android.icon, '@drawable/ic_stat_event');
      expect(android.actions!.first.id, NotificationActions.replyId);
    });
  });

  // On Ron's tablet (2026-11-16) a Samsung draws the app's own icon on
  // every notification's row, so a reminder showed neither a calendar nor
  // its account's colour, and the mail notifications had lost the picture
  // at their side: the background has no screen to draw one on.
  group('the picture at the side of a calendar notification', () {
    const blue = 0xFF0F6CBD;
    final start = DateTime(2026, 10, 26, 10);
    final now = DateTime(2026, 10, 26, 9);
    late _Plugin plugin;
    late Directory kept;

    setUp(() {
      plugin = _Plugin()..now = () => now;
      kept = Directory.systemTemp.createTempSync('myemail-badges');
      addTearDown(() => kept.deleteSync(recursive: true));
    });

    /// A notifier that draws: the dart as [1, …], a calendar as [2, …],
    /// each with its colour's last byte. [draws] false is the background,
    /// which cannot.
    AndroidMailNotifier notifierThat({
      bool draws = true,
      bool keeps = false,
      List<String>? drawn,
    }) =>
        AndroidMailNotifier(
          plugin: plugin,
          queueAction: (_) async {},
          drawBadge: (c) async {
            drawn?.add('dart');
            return draws ? Uint8List.fromList([1, c & 0xff]) : null;
          },
          drawCalendar: (c) async {
            drawn?.add('calendar');
            return draws ? Uint8List.fromList([2, c & 0xff]) : null;
          },
          postingMarks: () async => null,
          badgeFiles: () async => keeps ? kept : null,
          clock: () => now,
        );

    MeetingReminder reminder({int? colour}) => MeetingReminder(
          id: 7,
          at: DateTime(2026, 10, 26, 9, 45),
          meeting: MeetingRef(
            accountId: 'hadco',
            eventId: 'm1',
            start: start,
            end: start.add(const Duration(minutes: 30)),
            title: 'Weekly sync',
            colour: colour,
          ),
        );

    test("a reminder has its account's colour, and a calendar on that "
        'colour at its side; its own icon is still the calendar', () async {
      await notifierThat().scheduleMeetingReminder(reminder(colour: blue));
      final android = plugin.scheduled.single.details.android!;
      expect(android.color, const Color(blue));
      expect(android.icon, '@drawable/ic_stat_event');
      expect((android.largeIcon! as ByteArrayAndroidBitmap).data,
          [2, blue & 0xff]);
    });

    test('one with no colour given is as it was', () async {
      await notifierThat().scheduleMeetingReminder(reminder());
      final android = plugin.scheduled.single.details.android!;
      expect(android.color, isNull);
      expect(android.largeIcon, isNull);
    });

    test("an all-day reminder and the morning's agenda, which are no one "
        "account's, have a calendar on the app's own colour", () async {
      final notifier = notifierThat();
      await notifier.scheduleDayReminder(DayReminder(
        id: 9,
        at: DateTime(2026, 10, 26, 18),
        day: DateTime(2026, 10, 27),
        title: 'Tomorrow: Thanksgiving',
        body: 'All day',
        until: DateTime(2026, 10, 27),
      ));
      await notifier.scheduleAgenda(
        id: 10,
        at: DateTime(2026, 10, 27, 7, 30),
        title: '3 meetings today',
        body: 'The first at 09:30: Stand-up',
        lines: const ['09:30 Stand-up'],
        payload: calendarDayPayload(DateTime(2026, 10, 27)),
      );
      expect(plugin.scheduled, hasLength(2));
      for (final set in plugin.scheduled) {
        final android = set.details.android!;
        expect(android.color, const Color(AndroidMailNotifier.appColour));
        expect((android.largeIcon! as ByteArrayAndroidBitmap).data,
            [2, AndroidMailNotifier.appColour & 0xff]);
      }
    });

    test('mail about a meeting has the calendar at its side, other mail '
        "and the account's row the app's mark", () async {
      const account = Account(
        id: 'a',
        displayName: 'Hadco',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.oauth,
        colorValue: blue,
      );
      final inbox = MailFolder.at(
        accountId: 'a',
        path: 'INBOX',
        role: FolderRole.inbox,
        capabilities: FolderCapabilities.forGmail(FolderRole.inbox),
      );
      MailNotification mail(int id, {required bool meeting}) =>
          MailNotification(
            id: id,
            title: 'Dana Levi',
            body: meeting ? 'Invitation: Planning' : 'The numbers',
            payload: 'a:INBOX#$id',
            when: DateTime(2026, 10, 25),
            meeting: meeting,
          );
      await notifierThat().showNewMail(
        account: account,
        folder: inbox,
        notifications: [mail(3, meeting: true), mail(4, meeting: false)],
      );
      Object? sideOf(int id) => (plugin.shown
              .firstWhere((s) => s.id == id)
              .details
              .android!
              .largeIcon! as ByteArrayAndroidBitmap)
          .data;
      expect(sideOf(3), [2, blue & 0xff]);
      expect(sideOf(4), [1, blue & 0xff]);
      final row = plugin.shown.firstWhere((s) => s.id != 3 && s.id != 4);
      expect((row.details.android!.largeIcon! as ByteArrayAndroidBitmap).data,
          [1, blue & 0xff]);
    });

    test('drawn once, the picture is kept as a file, and a notification set '
        'for later carries the file, not the picture', () async {
      final drawn = <String>[];
      final notifier = notifierThat(keeps: true, drawn: drawn);
      await notifier.scheduleMeetingReminder(reminder(colour: blue));
      await notifier.scheduleMeetingReminder(reminder(colour: blue));
      expect(drawn, ['calendar']);
      final side = plugin.scheduled.last.details.android!.largeIcon!;
      expect(side, isA<FilePathAndroidBitmap>());
      final file = File((side as FilePathAndroidBitmap).data);
      expect(file.parent.path, kept.path);
      expect(file.readAsBytesSync(), [2, blue & 0xff]);
      expect(kept.listSync().whereType<File>(), hasLength(1),
          reason: 'nothing half written is left beside it');
    });

    test('the background, which cannot draw, finds what the app drew; and '
        'has no picture, and nothing worse, where the app drew none',
        () async {
      await notifierThat(keeps: true).prepareBadges([blue, blue]);
      expect([for (final f in kept.listSync()) f.uri.pathSegments.last]..sort(),
          ['v1-calendar-ff0f6cbd.png', 'v1-dart-ff0f6cbd.png']);

      final drawn = <String>[];
      final background = notifierThat(draws: false, keeps: true, drawn: drawn);
      await background.scheduleMeetingReminder(reminder(colour: blue));
      expect(plugin.scheduled.single.details.android!.largeIcon,
          isA<FilePathAndroidBitmap>());
      expect(drawn, isEmpty, reason: 'found, so not tried');

      // Another account's, which nobody has drawn: set all the same.
      await background.scheduleMeetingReminder(reminder(colour: 0xFF107C41));
      final plain = plugin.scheduled.last.details.android!;
      expect(plain.largeIcon, isNull);
      expect(plain.color, const Color(0xFF107C41));
      // And one failure spares the next the wait.
      await background.scheduleMeetingReminder(reminder(colour: 0xFFB4009E));
      expect(drawn, ['calendar']);
    });

    test('making them ready never throws, and tries again another time',
        () async {
      final drawn = <String>[];
      final background = notifierThat(draws: false, keeps: true, drawn: drawn);
      await background.prepareBadges([blue, 0xFF107C41]);
      expect(drawn, hasLength(1), reason: 'one failure spares the rest');
      await background.prepareBadges([blue]);
      expect(drawn, hasLength(2), reason: 'tried again on the next pass');
      expect(kept.listSync(), isEmpty);
    });
  });

  group('an answer begun on a notification', () {
    test('carries the message and the answer to the app, and back', () {
      const id = 'acct-hadco:Inbox/Projects#42';
      final payload =
          NotificationActions.answering(NotificationActions.declineId, id);
      final begun = NotificationActions.answerBegun(payload);
      expect(begun?.messageId, id, reason: 'colons and all');
      expect(begun?.response, InviteResponse.declined);
    });

    test('anything else is handed on as it was', () {
      expect(
          NotificationActions.answering(NotificationActions.replyId, 'a:I#1'),
          'a:I#1');
      expect(NotificationActions.answering(null, 'a:I#1'), 'a:I#1');
      expect(
          NotificationActions.answering(NotificationActions.acceptId, null),
          isNull);
      expect(NotificationActions.answerBegun('a:INBOX#1'), isNull);
      expect(NotificationActions.answerBegun('myemail-answer:maybe:a:I#1'),
          isNull);
      expect(NotificationActions.answerBegun(null), isNull);
    });
  });

  group('the background pass', () {
    final now = DateTime(2026, 10, 25, 9);

    test('marks an invitation, and only an invitation, as one', () async {
      final engine = _PassEngine(now);
      final notifier = FakeMailNotifier();
      final state = MemorySyncStateStore(
        prefs: const SyncPrefs(mode: SyncMode.periodic),
      );
      BackgroundSync pass() => BackgroundSync(
            engine: engine,
            notifier: notifier,
            state: state,
            clock: () => now,
          );
      await pass().run();
      engine.arrive(2, ics('REQUEST'));
      engine.arrive(3, ics('CANCEL'));
      engine.arrive(4, null);
      await pass().run();
      expect(
        {for (final n in notifier.posted) n.payload: n.invitation},
        {'a:INBOX#2': true, 'a:INBOX#3': false, 'a:INBOX#4': false},
      );
      expect(
        {for (final n in notifier.posted) n.payload: n.meeting},
        {'a:INBOX#2': true, 'a:INBOX#3': true, 'a:INBOX#4': false},
        reason: 'a cancellation is meeting mail, so it wears the calendar',
      );
    });

    // The calendar keeps up with meeting mail (#74): the reminders, the
    // widget and the morning agenda have a meeting moved or called off as
    // its mail arrives, not at the next quarter hour's read.
    group("says whose calendar to read again (#74)", () {
      late _PassEngine engine;
      late FakeMailNotifier notifier;
      late MemorySyncStateStore state;

      setUp(() {
        engine = _PassEngine(now);
        notifier = FakeMailNotifier();
        state = MemorySyncStateStore(
          prefs: const SyncPrefs(mode: SyncMode.periodic),
        );
      });

      Future<BackgroundSyncReport> pass() => BackgroundSync(
            engine: engine,
            notifier: notifier,
            state: state,
            clock: () => now,
          ).run();

      test('an invitation, a change or a cancellation, once for the '
          'account; an answer or other mail, not at all', () async {
        await pass();
        engine.arrive(2, ics('REPLY'));
        engine.arrive(3, null);
        expect((await pass()).meetingMail, isEmpty,
            reason: 'an answer changes only who has said yes, and other '
                'mail nothing');

        engine.arrive(4, ics('REQUEST'));
        expect((await pass()).meetingMail, {'a'});

        engine.arrive(5, ics('CANCEL'));
        engine.arrive(6, ics('REQUEST'));
        expect((await pass()).meetingMail, {'a'});
        expect((await pass()).meetingMail, isEmpty,
            reason: 'mail is new to one pass only');
      });

      test('meeting mail that is not announced is not opened to see what '
          'it is, and its calendar is read all the same', () async {
        await pass();
        await state.writePrefs((await state.readPrefs()).withQuiet(
            'a', QuietRule(until: now.add(const Duration(hours: 1)))));
        engine.arrive(2, ics('REPLY'));

        final report = await pass();

        expect(report.meetingMail, {'a'});
        expect(engine.opened, isEmpty,
            reason: 'nothing more is asked of the mail server');
        expect(notifier.posted, isEmpty);
      });
    });
  });
}

/// The sample engine with an invitation's calendar part in every message,
/// and what was sent kept.
class _InviteEngine extends SampleMailEngine {
  String? calendarText;
  Exception? bodyFailure;
  Object? answerFailure;
  final List<Draft> sent = [];

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    final failure = bodyFailure;
    if (failure != null) throw failure;
    final body = await super.loadMessageBody(messageId);
    return MailBody(text: body.text, html: body.html, calendar: calendarText);
  }

  @override
  Future<void> respondToInvite(
    String messageId,
    CalendarInvite invite,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
  }) async {
    final failure = answerFailure;
    if (failure != null) throw failure;
    return super.respondToInvite(messageId, invite, response,
        note: note, send: send, proposal: proposal);
  }

  /// How a draft goes, where a test says; otherwise it is only kept.
  Future<void> Function(Draft draft)? sendWith;

  @override
  Future<void> sendDraft(Draft draft) async {
    if (sendWith case final send?) return send(draft);
    sent.add(draft);
  }
}

/// One account and its Inbox, for a background pass to read: what has
/// arrived, and each message's calendar part.
class _PassEngine extends Fake implements MailEngine {
  _PassEngine(this.now) {
    arrive(1, null);
  }

  final DateTime now;
  final List<MailMessage> inbox = [];
  final Map<String, String?> calendars = {};

  static const account = Account(
    id: 'a',
    displayName: 'Personal',
    emailAddress: 'me@example.com',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF0F6CBD,
  );

  void arrive(int uid, String? calendar) {
    final id = 'a:INBOX#$uid';
    inbox.insert(
      0,
      MailMessage(
        id: id,
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: uid,
        subject: 'Message $uid',
        preview: '',
        from: const MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
        to: const [MailAddress(email: 'me@example.com')],
        date: now.subtract(const Duration(minutes: 5)),
        isRead: false,
        isMeeting: calendar != null,
      ),
    );
    calendars[id] = calendar;
  }

  @override
  Future<int> wakeSnoozed({DateTime? now}) async => 0;

  @override
  Future<List<Account>> loadAccounts() async => const [account];

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async => [
        MailFolder.at(
          accountId: 'a',
          path: 'INBOX',
          role: FolderRole.inbox,
          capabilities: FolderCapabilities.forGmail(FolderRole.inbox),
        ),
      ];

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      List.of(inbox);

  @override
  Future<MailMessage?> cachedMessage(String messageId) async =>
      inbox.where((m) => m.id == messageId).firstOrNull;

  /// Each message whose body was asked for, in order.
  final List<String> opened = [];

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    opened.add(messageId);
    return MailBody(text: 'Hello.', calendar: calendars[messageId]);
  }
}

/// Android's side: what is shown and what is set for later.
class _Plugin implements FlutterLocalNotificationsPlugin {
  DidReceiveNotificationResponseCallback? tapped;
  NotificationAppLaunchDetails? launch;
  final List<({int id, NotificationDetails details})> shown = [];
  final List<
      ({
        int id,
        tz.TZDateTime at,
        String? title,
        String? payload,
        NotificationDetails details,
      })> scheduled = [];

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async {
    tapped = onDidReceiveNotificationResponse;
    return true;
  }

  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async =>
      launch;

  final List<({int id, String? tag})> cancelled = [];

  @override
  Future<void> cancel({required int id, String? tag}) async =>
      cancelled.add((id: id, tag: tag));

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async => const [];

  @override
  T? resolvePlatformSpecificImplementation<
      T extends FlutterLocalNotificationsPlatform>() => null;

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async =>
      shown.add((id: id, details: notificationDetails!));

  /// The phone's clock, as the plugin reads it.
  DateTime Function() now = DateTime.now;

  @override
  Future<void> zonedSchedule({
    required int id,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    // As the plugin's validateDateIsInTheFuture.
    if (scheduledDate.isBefore(now())) {
      throw ArgumentError.value(
          scheduledDate, 'scheduledDate', 'Must be a date in the future');
    }
    scheduled.add((
      id: id,
      at: scheduledDate,
      title: title,
      payload: payload,
      details: notificationDetails,
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
