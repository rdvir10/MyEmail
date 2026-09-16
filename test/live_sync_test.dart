import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/data/account_store.dart';
import 'package:mailtree/data/cache/cache_store.dart';
import 'package:mailtree/data/credential_store.dart';
import 'package:mailtree/data/imap/cached_imap_engine.dart';
import 'package:mailtree/data/sync/background_sync.dart';
import 'package:mailtree/data/sync/live_sync.dart';
import 'package:mailtree/domain/account.dart';
import 'package:mailtree/domain/folder_role.dart';
import 'package:mailtree/domain/sync_prefs.dart';

import 'fakes/fake_imap_transport.dart';

/// A clock the test moves by hand, so a fifty-minute budget takes no time.
class _Clock {
  DateTime now = DateTime(2026, 9, 16, 9);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('LiveSyncLoop', () {
    late _Clock clock;
    late List<Duration> slept;

    setUp(() {
      clock = _Clock();
      slept = [];
    });

    LiveSyncLoop loop({
      required Future<BackgroundSyncReport> Function() onePass,
      Duration tick = const Duration(minutes: 5),
      Duration budget = const Duration(minutes: 50),
      Future<void>? stopSignal,
    }) {
      return LiveSyncLoop(
        onePass: onePass,
        waitForNext: () async => clock.advance(tick),
        budget: budget,
        stopSignal: stopSignal,
        clock: clock.call,
        sleep: (d) async {
          slept.add(d);
          clock.advance(d);
        },
      );
    }

    test('checks straight away rather than waiting out the first interval',
        () async {
      // Turning the setting on and then seeing nothing for five minutes reads
      // as a broken switch.
      var passes = 0;
      final outcome = await loop(
        onePass: () async {
          passes++;
          return const BackgroundSyncReport();
        },
        budget: const Duration(minutes: 1),
        tick: const Duration(minutes: 5),
      ).run();

      expect(passes, 1);
      expect(outcome.passes, 1);
    });

    test('keeps checking until the budget is spent, then hands over', () async {
      final outcome = await loop(
        onePass: () async => const BackgroundSyncReport(),
        tick: const Duration(minutes: 5),
        budget: const Duration(minutes: 50),
      ).run();

      expect(outcome.passes, 10, reason: 'fifty minutes at five-minute ticks');
      expect(outcome.stoppedEarly, isFalse);
    });

    test('a failed pass does not end the loop', () async {
      // A phone loses its network constantly. Going quiet until the app is
      // reopened is the one outcome that makes the feature useless.
      var calls = 0;
      final outcome = await loop(
        onePass: () async {
          calls++;
          if (calls == 1) throw const SocketExceptionStub();
          return const BackgroundSyncReport();
        },
        budget: const Duration(minutes: 20),
      ).run();

      expect(calls, greaterThan(1));
      expect(outcome.failures, 1);
    });

    test('a failed pass backs off instead of spinning', () async {
      final outcome = await loop(
        onePass: () async => throw const SocketExceptionStub(),
        budget: const Duration(minutes: 5),
      ).run();

      expect(slept, isNotEmpty);
      expect(slept.first, const Duration(seconds: 30));
      expect(outcome.failures, greaterThan(0));
    });

    test('a pass that reports failures still counts as a pass', () async {
      // Reaching one of two mailboxes is not the same as reaching none.
      final outcome = await loop(
        onePass: () async =>
            const BackgroundSyncReport(posted: 1, failures: ['work: nope']),
        budget: const Duration(minutes: 10),
      ).run();

      expect(outcome.passes, 2);
      expect(outcome.failures, 2);
      expect(slept, isEmpty, reason: 'it reached the server, so no backoff');
    });

    test('a stop signal ends it after the pass in flight, not during',
        () async {
      final stop = Completer<void>();
      var passes = 0;
      final outcome = await loop(
        onePass: () async {
          passes++;
          if (passes == 1) stop.complete();
          return const BackgroundSyncReport();
        },
        stopSignal: stop.future,
        budget: const Duration(hours: 2),
      ).run();

      expect(outcome.passes, 1);
      expect(outcome.stoppedEarly, isTrue);
      expect(slept, isEmpty, reason: 'a worker being stopped must not sleep');
    });
  });

  group('SyncMode', () {
    test('only the cheap modes avoid a foreground service', () {
      expect(SyncMode.off.needsForegroundService, isFalse);
      expect(SyncMode.periodic.needsForegroundService, isFalse);
      expect(SyncMode.frequent.needsForegroundService, isTrue);
      expect(SyncMode.realtime.needsForegroundService, isTrue);
    });

    test('five minutes is below what Android will schedule, which is why it '
        'needs the service', () {
      expect(
        frequentSyncInterval.inMinutes,
        lessThan(SyncPrefs.minimumIntervalMinutes),
      );
    });

    test('an IDLE is renewed before a server would drop it', () {
      // RFC 2177 says re-issue at least every 29 minutes.
      expect(idleRenewInterval.inMinutes, lessThan(29));
    });

    test('the worker hands over well before its own budget looks risky', () {
      expect(liveSyncBudget.inMinutes, greaterThan(idleRenewInterval.inMinutes));
    });

    test('every mode states its battery cost', () {
      for (final mode in SyncMode.values) {
        expect(mode.cost, isNotEmpty, reason: mode.name);
        expect(mode.label, isNotEmpty, reason: mode.name);
      }
    });

    test('a permanent notification is predicted before the switch is flipped',
        () {
      expect(
        const SyncPrefs(mode: SyncMode.off).showsOngoingNotification,
        isFalse,
      );
      expect(
        const SyncPrefs(mode: SyncMode.realtime).showsOngoingNotification,
        isTrue,
      );
      expect(
        const SyncPrefs(mode: SyncMode.periodic).showsOngoingNotification,
        isFalse,
      );
    });

    test('an unknown mode falls back down, never up', () {
      // Guessing upward would start a foreground service nobody asked for.
      final prefs = SyncPrefs.fromJson({'mode': 'telepathy'});
      expect(prefs.mode, SyncMode.off);
    });

    test('the mode survives a round trip', () {
      const prefs = SyncPrefs(mode: SyncMode.realtime);
      expect(SyncPrefs.fromJson(prefs.toJson()), prefs);
    });
  });

  group('awaitNewMail', () {
    late FakeImapTransport server;
    late CachedImapEngine engine;

    setUp(() {
      server = FakeImapTransport()..folder('INBOX', role: FolderRole.inbox);
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
      );
    });

    Future<Account> addAccount() => engine.addAccount(
          displayName: 'Personal',
          emailAddress: 'me@example.com',
          provider: MailProvider.gmail,
          secret: 'abcdabcdabcdabcd',
        );

    test('returns as soon as the server says something arrived', () async {
      final account = await addAccount();
      final waiting = engine.awaitNewMail(
        ['${account.id}:INBOX'],
        timeout: const Duration(minutes: 24),
      );
      // Let the IDLE actually start before delivering into it.
      await Future<void>.delayed(Duration.zero);
      expect(server.isIdling, isTrue);

      server.deliverWhileIdle('INBOX', subject: 'Arrived');

      expect(await waiting, isTrue);
      expect(server.calls, contains('IDLE INBOX'));
    });

    test('returns false when nothing happens before the timeout', () async {
      final account = await addAccount();
      final woken = await engine.awaitNewMail(
        ['${account.id}:INBOX'],
        timeout: const Duration(milliseconds: 20),
      );
      expect(woken, isFalse);
    });

    test('with nothing to watch it waits rather than returning instantly',
        () async {
      // Returning at once would turn the loop into a spin.
      final started = DateTime.now();
      final woken =
          await engine.awaitNewMail([], timeout: const Duration(seconds: 5));
      expect(woken, isFalse);
      expect(DateTime.now().difference(started).inSeconds, lessThan(1),
          reason: 'an empty list is the one case that returns immediately');
    });

    test('an account that cannot be reached does not take the wait down',
        () async {
      final account = await addAccount();
      server.offline = true;

      final woken = await engine.awaitNewMail(
        ['${account.id}:INBOX'],
        timeout: const Duration(milliseconds: 20),
      );

      expect(woken, isFalse, reason: 'it degrades to a timeout, not a throw');
    });
  });
}

/// Stands in for a dropped network without dragging dart:io into the test.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'network went away';
}
