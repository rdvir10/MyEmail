import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
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
      plugin = _Plugin();
      queued = [];
      notifier = AndroidMailNotifier(
        plugin: plugin,
        queueAction: (action) async => queued.add(action),
        drawBadge: (_) async => null,
        postingMarks: () async => null,
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

  @override
  Future<void> sendDraft(Draft draft) async {
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

  @override
  Future<MailBody> loadMessageBody(String messageId) async =>
      MailBody(text: 'Hello.', calendar: calendars[messageId]);
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
  }) async =>
      scheduled.add((
        id: id,
        at: scheduledDate,
        title: title,
        details: notificationDetails,
      ));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
