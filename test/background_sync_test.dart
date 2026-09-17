import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/imap/imap_transport.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sync/background_sync.dart';
import 'package:myemail/data/sync/new_mail_scan.dart';
import 'package:myemail/data/sync/sync_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/sync_prefs.dart';

import 'fakes/fake_imap_transport.dart';

final _now = DateTime(2026, 9, 14, 9, 0);

MailMessage _msg(
  int uid, {
  bool isRead = false,
  DateTime? date,
  String subject = 'Subject',
}) =>
    MailMessage(
      id: 'a:INBOX#$uid',
      accountId: 'a',
      folderId: 'a:INBOX',
      uid: uid,
      subject: subject,
      from: const MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
      to: const [MailAddress(email: 'me@example.com')],
      date: date ?? _now.subtract(const Duration(minutes: 5)),
      preview: 'Have a look',
      isRead: isRead,
    );

void main() {
  group('selectNotifiable', () {
    test('the first scan of a folder announces nothing', () {
      // Otherwise installing the app announces the whole inbox at once.
      final out = selectNotifiable(
        messages: [_msg(3), _msg(2), _msg(1)],
        watermark: null,
        now: _now,
      );
      expect(out, isEmpty);
    });

    test('only messages above the watermark', () {
      final out = selectNotifiable(
        messages: [_msg(5), _msg(4), _msg(3)],
        watermark: 3,
        now: _now,
      );
      expect(out.map((m) => m.uid), [5, 4]);
    });

    test('a message already read elsewhere is not announced', () {
      final out = selectNotifiable(
        messages: [_msg(5, isRead: true), _msg(4)],
        watermark: 3,
        now: _now,
      );
      expect(out.map((m) => m.uid), [4]);
    });

    test('a backlog after the phone was off is caught up, not announced', () {
      final out = selectNotifiable(
        messages: [
          _msg(5, date: _now.subtract(const Duration(days: 9))),
          _msg(4),
        ],
        watermark: 3,
        now: _now,
      );
      expect(out.map((m) => m.uid), [4]);
    });

    test('a renumbered folder announces nothing', () {
      // UIDVALIDITY changed: UIDs restarted low, so every cached message looks
      // new. Announcing them would mean the whole inbox arriving twice.
      final out = selectNotifiable(
        messages: [_msg(3), _msg(2), _msg(1)],
        watermark: 900,
        now: _now,
      );
      expect(out, isEmpty);
    });

    test('newest first', () {
      final out = selectNotifiable(
        messages: [_msg(7), _msg(9), _msg(8)],
        watermark: 6,
        now: _now,
      );
      expect(out.map((m) => m.uid), [9, 8, 7]);
    });

    test('an empty folder yields nothing rather than throwing', () {
      expect(
        selectNotifiable(messages: const [], watermark: 4, now: _now),
        isEmpty,
      );
    });
  });

  group('nextWatermark', () {
    test('an empty, never-scanned folder still gets a mark', () {
      // Without one its first delivered message counts as a first scan and is
      // swallowed.
      expect(nextWatermark(messages: const [], watermark: null), 0);
    });

    test('an empty folder keeps the mark it had', () {
      expect(nextWatermark(messages: const [], watermark: 12), 12);
    });

    test('follows the highest UID seen', () {
      expect(nextWatermark(messages: [_msg(9), _msg(8)], watermark: 4), 9);
    });

    test('follows UIDs downward after a renumber, so the mark gets back in step',
        () {
      expect(nextWatermark(messages: [_msg(3), _msg(2)], watermark: 900), 3);
    });

    test('moves past messages that were not announced', () {
      // Read, or too old: accounted for, and never reconsidered.
      expect(
        nextWatermark(messages: [_msg(9, isRead: true)], watermark: 4),
        9,
      );
    });
  });

  group('BackgroundSync', () {
    late FakeImapTransport server;
    late MemoryCacheStore cache;
    late MemorySyncStateStore state;
    late FakeMailNotifier notifier;
    late CachedImapEngine engine;

    setUp(() {
      server = FakeImapTransport();
      cache = MemoryCacheStore();
      state = MemorySyncStateStore(
        prefs: const SyncPrefs(mode: SyncMode.periodic),
      );
      notifier = FakeMailNotifier();
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: cache,
        transportFactory: (_, _) => server,
      );
      server.folder('INBOX', role: FolderRole.inbox);
      server.folder('Work');
    });

    BackgroundSync sync() => BackgroundSync(
          engine: engine,
          notifier: notifier,
          state: state,
          clock: () => _now,
        );

    Future<Account> addAccount() => engine.addAccount(
          displayName: 'Personal',
          emailAddress: 'me@example.com',
          provider: MailProvider.gmail,
          secret: 'abcdabcdabcdabcd',
        );

    void deliver({String? subject, bool isRead = false, String to = 'INBOX'}) {
      server.folder(to).deliver(
            subject: subject,
            date: _now.subtract(const Duration(minutes: 5)),
            isRead: isRead,
          );
    }

    test('does nothing at all while sync is off', () async {
      state = MemorySyncStateStore(); // off is the default
      await addAccount();
      deliver();
      final report = await sync().run();
      expect(report.posted, 0);
      expect(notifier.batches, isEmpty);
      expect(state.watermarks, isEmpty,
          reason: 'a pass that does not run must not touch the marks either');
    });

    test('with notifications off it still syncs, just quietly', () async {
      // The whole reason these are two settings. Turning notifications off
      // must not stop the app keeping itself current.
      final account = await addAccount();
      deliver(subject: 'Before');
      await sync().run();
      await state.writePrefs(
        const SyncPrefs(mode: SyncMode.periodic, notify: false),
      );

      deliver(subject: 'Quietly');
      final report = await sync().run();

      expect(report.posted, 0);
      expect(notifier.posted, isEmpty);
      expect(report.foldersScanned, 1, reason: 'it still looked');
      expect(await cache.countMessages(account.id, 'INBOX'), 2,
          reason: 'and the new mail is on the device');
    });

    test('turning notifications on does not announce the backlog', () async {
      // The watermark moves whether or not anything was announced, so what
      // arrived during the quiet spell is accounted for, not queued up.
      await addAccount();
      await state.writePrefs(
        const SyncPrefs(mode: SyncMode.periodic, notify: false),
      );
      await sync().run();
      for (var i = 0; i < 5; i++) {
        deliver(subject: 'While quiet $i');
      }
      await sync().run();

      await state.writePrefs(const SyncPrefs(mode: SyncMode.periodic));
      final report = await sync().run();

      expect(report.posted, 0, reason: 'a backlog of five is not a welcome');
    });

    test('the first pass records where it got to and announces nothing',
        () async {
      await addAccount();
      deliver();
      deliver();

      final report = await sync().run();

      expect(report.posted, 0);
      expect(notifier.posted, isEmpty);
      expect(state.watermarks.values.single, 2);
    });

    test('mail arriving after the first pass is announced', () async {
      final account = await addAccount();
      deliver(subject: 'Old news');
      await sync().run();

      deliver(subject: 'Contract draft');
      final report = await sync().run();

      expect(report.posted, 1);
      expect(notifier.batches.single.account.id, account.id);
      expect(notifier.posted.single.title, 'someone@example.com',
          reason: 'the address stands in when the sender has no display name');
      expect(notifier.posted.single.body, contains('Contract draft'));
    });

    test('the same message is never announced twice', () async {
      await addAccount();
      await sync().run();
      deliver(subject: 'Once');

      await sync().run();
      await sync().run();

      expect(notifier.posted, hasLength(1));
    });

    test('only the Inbox is watched', () async {
      // Mail a server-side rule filed elsewhere was, by the user's own
      // instruction, not urgent.
      await addAccount();
      await sync().run();
      deliver(subject: 'Filed away', to: 'Work');

      final report = await sync().run();

      expect(report.foldersScanned, 1);
      expect(notifier.posted, isEmpty);
    });

    test('a muted account is synced but not announced', () async {
      final account = await addAccount();
      await sync().run();
      await state.writePrefs(
        const SyncPrefs(mode: SyncMode.periodic)
            .withAccountMuted(account.id, true),
      );

      deliver(subject: 'Quiet please');
      final report = await sync().run();

      expect(report.posted, 0);
      expect(notifier.posted, isEmpty);
      expect(report.foldersScanned, 1,
          reason: 'muted means unannounced, not unsynced');
    });

    test('one folder posts a capped number of notifications', () async {
      await addAccount();
      await sync().run();
      for (var i = 0; i < 12; i++) {
        deliver(subject: 'Digest $i');
      }

      final report = await sync().run();

      expect(report.posted, 5);
      // The mark still covers every message, so the eleven that were not
      // announced are not announced later either.
      expect(state.watermarks.values.single, 12);
    });

    test('a message read before the pass ran is not announced', () async {
      await addAccount();
      await sync().run();
      deliver(subject: 'Already seen', isRead: true);

      final report = await sync().run();

      expect(report.posted, 0);
      expect(state.watermarks.values.single, 1);
    });

    test('a notifier that throws still leaves the mark moved', () async {
      // Otherwise the next pass finds the same mail and tries again forever.
      await addAccount();
      await sync().run();
      deliver(subject: 'Boom');

      final report = await BackgroundSync(
        engine: engine,
        notifier: _ThrowingNotifier(),
        state: state,
        clock: () => _now,
      ).run();

      expect(report.ok, isFalse);
      expect(state.watermarks.values.single, 1);
    });

    test('an unreachable account does not silence the other one', () async {
      final good = FakeImapTransport()..folder('INBOX', role: FolderRole.inbox);
      final bad = _BrokenTransport();
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: cache,
        transportFactory: (account, _) =>
            account.emailAddress.startsWith('me@') ? good : bad,
      );
      await addAccount();
      // The broken one is added with a transport that only fails later, so the
      // sign-in probe still passes.
      bad.failing = false;
      await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'work@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      bad.failing = true;

      await sync().run();
      good.folder('INBOX').deliver(
            subject: 'Still arrives',
            date: _now.subtract(const Duration(minutes: 5)),
          );
      final report = await sync().run();

      expect(report.posted, 1);
      expect(report.failures, hasLength(1));
      expect(report.failures.single, contains('work@example.com'));
    });
  });

  group('MailNotification', () {
    test('an id is stable for a message so a repeat updates rather than piles up',
        () {
      final a = MailNotification.forMessage(_msg(4));
      final b = MailNotification.forMessage(_msg(4));
      expect(a.id, b.id);
      expect(a.id, isNonNegative);
      expect(MailNotification.forMessage(_msg(5)).id, isNot(a.id));
    });

    test('a blank subject is labelled rather than shown empty', () {
      final n = MailNotification.forMessage(_msg(4, subject: '  '));
      expect(n.body, startsWith('(No subject)'));
    });

    test('the sender goes in the title and the message id in the payload', () {
      final n = MailNotification.forMessage(_msg(4));
      expect(n.title, 'Dana Levi');
      expect(n.payload, 'a:INBOX#4');
    });
  });

  group('SyncPrefs', () {
    test('round-trips through JSON', () {
      const prefs = SyncPrefs(
        mode: SyncMode.periodic,
        intervalMinutes: 60,
        mutedAccountIds: {'acct-1'},
      );
      expect(SyncPrefs.fromJson(prefs.toJson()), prefs);
    });

    test('a malformed record falls back to the default rather than throwing',
        () {
      // It is read in a background isolate, where a throw is a silent death.
      expect(
        SyncPrefs.fromJson({'mode': 42, 'notify': 'yes please'}),
        const SyncPrefs(),
      );
    });

    test('the interval never goes below what Android will schedule', () {
      expect(
        const SyncPrefs(intervalMinutes: 1).interval,
        const Duration(minutes: 15),
      );
    });

    test('muting and unmuting one account leaves the others alone', () {
      const prefs = SyncPrefs(mutedAccountIds: {'a', 'b'});
      expect(prefs.withAccountMuted('c', true).mutedAccountIds, {'a', 'b', 'c'});
      expect(prefs.withAccountMuted('a', false).mutedAccountIds, {'b'});
    });

    test('a muted account is not notified even while notifications are on', () {
      const prefs =
          SyncPrefs(mode: SyncMode.periodic, mutedAccountIds: {'a'});
      expect(prefs.notifiesFor('a'), isFalse);
      expect(prefs.notifiesFor('b'), isTrue);
    });

    test('nothing is notified while sync is off, whatever the switch says', () {
      // There is no pass to find anything, so an on switch would be a lie.
      const prefs = SyncPrefs(mode: SyncMode.off, notify: true);
      expect(prefs.notifiesFor('b'), isFalse);
      expect(prefs.notifyIsIdle, isTrue,
          reason: 'and the screen has to say so');
    });

    test('the old one-switch shape upgrades to the two settings', () {
      // Whoever had it on wanted both halves; whoever had it off wanted
      // neither, and must not find a foreground service running.
      final wasOn = SyncPrefs.fromJson(
        {'enabled': true, 'mode': 'realtime', 'muted': <String>[]},
      );
      expect(wasOn.mode, SyncMode.realtime);
      expect(wasOn.notify, isTrue);

      final wasOff = SyncPrefs.fromJson({'enabled': false, 'mode': 'realtime'});
      expect(wasOff.mode, SyncMode.off);
    });
  });
}

class _ThrowingNotifier extends FakeMailNotifier {
  @override
  Future<void> showNewMail({
    required Account account,
    required folder,
    required List<MailNotification> notifications,
  }) async =>
      throw StateError('no notification channel');
}

/// Fails every call once [failing] is set, so a pass can be run against an
/// account whose credentials have gone stale.
class _BrokenTransport extends FakeImapTransport {
  bool failing = true;

  @override
  Future<List<RemoteFolder>> listFolders() async {
    if (failing) throw const AuthenticationFailed('app password revoked');
    return super.listFolders();
  }
}
