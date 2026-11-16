import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/state/calendar_view_providers.dart'
    show calendarReadAgainProvider;
import 'package:myemail/state/meeting_alert_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sync_providers.dart' show mailNotifierProvider;
import 'package:myemail/state/widget_providers.dart'
    show homeScreenSurfaceProvider;

import 'fakes/fake_imap_transport.dart';

/// The calendar keeps up with meeting mail (calendar idea #74), in the app:
/// meeting mail its own sync finds arriving has that account's calendar
/// read again, at most once a minute. The background pass's half is in
/// meeting_notifications_test.dart and calendar_upkeep_test.dart.
void main() {
  group('the engine says when meeting mail arrives', () {
    late FakeImapTransport server;
    late CachedImapEngine engine;
    late Account account;
    late List<String> heard;

    setUp(() async {
      server = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox)
        ..folder('Work');
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
      );
      account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      await engine.loadFolders(account.id);
      heard = [];
      final listening = engine.meetingMailArrived.listen(heard.add);
      addTearDown(listening.cancel);
    });

    String inbox() => '${account.id}:INBOX';

    test('meeting mail new since the last sync, by its account; other mail '
        'not at all', () async {
      await engine.loadMessages(inbox());
      server.folder('INBOX').deliver(subject: 'Lunch?');
      await engine.loadMessages(inbox());
      await pumpEventQueue();
      expect(heard, isEmpty, reason: 'nothing changes for other mail');

      server.folder('INBOX').deliver(subject: 'Planning').isMeeting = true;
      await engine.loadMessages(inbox());
      await pumpEventQueue();
      expect(heard, [account.id]);

      await engine.loadMessages(inbox());
      await pumpEventQueue();
      expect(heard, [account.id], reason: 'said once, as it arrives');
    });

    test('the first fill of a folder is the folder as it was, and says '
        'nothing', () async {
      server.folder('INBOX').deliver(subject: 'Old').isMeeting = true;

      await engine.loadMessages(inbox());
      await pumpEventQueue();

      expect(heard, isEmpty);
    });
  });

  group("the app's reads for meeting mail", () {
    late DateTime now;
    late List<String> read;
    late List<_Timer> timers;
    late MeetingMailReads reads;

    setUp(() {
      now = DateTime(2026, 10, 26, 9);
      read = [];
      timers = [];
      reads = MeetingMailReads(
        read.add,
        clock: () => now,
        timer: (wait, then) {
          final t = _Timer(wait, then);
          timers.add(t);
          return t;
        },
      );
    });

    test('at once, then once a minute at most, the last of it read too', () {
      reads.arrived('hadco');
      expect(read, ['hadco']);

      now = now.add(const Duration(seconds: 20));
      reads.arrived('hadco');
      reads.arrived('hadco');
      expect(read, ['hadco'], reason: 'not again inside the minute');
      expect(timers.single.wait, const Duration(seconds: 40));

      reads.arrived('gmail');
      expect(read, ['hadco', 'gmail'], reason: 'each account its own minute');

      now = now.add(const Duration(seconds: 40));
      timers.single.fire();
      expect(read, ['hadco', 'gmail', 'hadco'],
          reason: 'what came inside the minute is read as it is up');

      now = now.add(const Duration(minutes: 2));
      reads.arrived('hadco');
      expect(read, ['hadco', 'gmail', 'hadco', 'hadco']);
      expect(timers, hasLength(1));
    });

    test('nothing waiting is read once the app has gone', () {
      reads.arrived('hadco');
      reads.arrived('hadco');
      reads.dispose();
      expect(timers.single.cancelled, isTrue);
    });
  });

  group("the app's calendar keeper", () {
    late SampleMailEngine engine;
    late Account hadco;
    late Account gmail;
    late FakeMailNotifier notifier;
    late ProviderContainer c;
    late DateTime hour;

    setUp(() async {
      engine = SampleMailEngine();
      final token = OAuthToken(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.utc(2030),
      );
      hadco = await engine.addOAuthAccount(
        displayName: 'Hadco',
        emailAddress: 'ron@hadco.example',
        provider: MailProvider.outlook,
        token: token,
      );
      gmail = await engine.addOAuthAccount(
        displayName: 'Gmail',
        emailAddress: 'ron@gmail.example',
        provider: MailProvider.gmail,
        token: token,
      );
      final ui = MemoryUiStateStore();
      await ui.writeString(
        UiStateKeys.calendarPrefs,
        jsonEncode(const CalendarPrefs()
            .copyWith(meetingReminders: {gmail.id: true}).toJson()),
      );
      notifier = FakeMailNotifier();
      c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(engine),
        mailNotifierProvider.overrideWithValue(notifier),
        homeScreenSurfaceProvider.overrideWithValue(FakeHomeScreenSurface()),
        calendarKeeperProvider.overrideWith(AppCalendarKeeper.new),
      ]);
      addTearDown(c.dispose);
      // The keeper goes by the phone's clock: an hour off at least, so its
      // quarter of an hour's reminder is still to come.
      final soon = DateTime.now().add(const Duration(hours: 2));
      hour = DateTime(soon.year, soon.month, soon.day, soon.hour);
    });

    CalendarEvent meeting(Account account, String id, DateTime start) =>
        CalendarEvent(
          id: id,
          accountId: account.id,
          title: 'Weekly sync',
          start: start,
          end: start.add(const Duration(minutes: 30)),
          reminderMinutes: 15,
        );

    Map<String, DateTime> reminders() => {
          for (final r in notifier.meetingReminders.values)
            r.meeting.eventId: r.at,
        };

    test("meeting mail reads its account's calendar again, and the others "
        'as the device kept them', () async {
      engine.events[hadco.id] = [meeting(hadco, 'h', hour)];
      engine.events[gmail.id] = [meeting(gmail, 'g', hour)];
      final keeper = c.read(calendarKeeperProvider);
      await keeper.keepUp(now: true);
      final later = hour.add(const Duration(hours: 2));
      engine.events[hadco.id] = [meeting(hadco, 'h', later)];
      engine.events[gmail.id] = [meeting(gmail, 'g', later)];

      keeper.meetingMail(hadco.id);
      // The read it began, waited for.
      await keeper.keepUp();

      expect(reminders()['h'], later.subtract(const Duration(minutes: 15)));
      expect(reminders()['g'], hour.subtract(const Duration(minutes: 15)),
          reason: 'until its own read');
      expect(c.read(calendarReadAgainProvider)?.accounts, {hadco.id},
          reason: 'the calendar screens open are told, once it is read');
    });

    test('a read for anything but meeting mail tells the screens nothing',
        () async {
      engine.events[hadco.id] = [meeting(hadco, 'h', hour)];
      await c.read(calendarKeeperProvider).keepUp(now: true);
      expect(c.read(calendarReadAgainProvider), isNull);
    });

    // The pictures at the side of notifications can only be drawn where
    // there is a screen, the app. Left to the quarter hour's upkeep they
    // were drawn only when that turn fell to the app, and the background
    // usually takes it first.
    test("the pictures for every account's notifications are made ready "
        "each time it is asked, the quarter hour's upkeep due or not",
        () async {
      final keeper = c.read(calendarKeeperProvider);
      await keeper.keepUp(now: true);
      final after = notifier.badgesPrepared.length;
      expect(after, greaterThan(0));

      // A minute later, in front: the upkeep is not due, and sets nothing.
      notifier.meetingReminders.clear();
      engine.events[hadco.id] = [meeting(hadco, 'h', hour)];
      await keeper.keepUp();
      expect(notifier.meetingReminders, isEmpty,
          reason: 'the upkeep itself was not due');
      expect(notifier.badgesPrepared.length, after + 1);
      expect(notifier.badgesPrepared.last,
          containsAll([hadco.colorValue, gmail.colorValue]));
    });

    test('meeting mail while a read is going is read once it is done',
        () async {
      engine.events[hadco.id] = [meeting(hadco, 'h', hour)];
      final keeper = c.read(calendarKeeperProvider);
      final going = keeper.keepUp(now: true);
      final later = hour.add(const Duration(hours: 2));
      // Moved, and its mail come, while that read was on its way; the
      // read may already have had the calendar as it was.
      keeper.meetingMail(hadco.id);
      await going;
      engine.events[hadco.id] = [meeting(hadco, 'h', later)];
      await keeper.keepUp();

      expect(reminders()['h'], later.subtract(const Duration(minutes: 15)));
    });
  });
}

/// A timer a test fires by hand.
class _Timer implements Timer {
  _Timer(this.wait, this._then);

  final Duration wait;
  final void Function() _then;
  bool cancelled = false;

  void fire() {
    if (!cancelled) _then();
  }

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}
