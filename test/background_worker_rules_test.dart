import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sync/background_sync.dart';
import 'package:myemail/data/sync/background_worker.dart';
import 'package:myemail/data/sync/sync_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/sync_prefs.dart';
import 'package:myemail/state/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fakes/fake_imap_transport.dart';

/// The rules the background worker runs by, apart from the worker.
void main() {
  Account account(String id, MailProvider provider, AuthMethod auth) =>
      Account(
        id: id,
        displayName: id,
        emailAddress: '$id@example.com',
        provider: provider,
        authMethod: auth,
        colorValue: 0,
      );

  group('how long push waits', () {
    final gmail = account('g', MailProvider.gmail, AuthMethod.appPassword);
    final work = account('w', MailProvider.outlook, AuthMethod.oauth);

    test('as long as an IDLE lasts, where every account can IDLE', () {
      expect(liveWaitFor([gmail]), idleRenewInterval);
    });

    test('no longer than the five-minute mode once Microsoft is watched', () {
      // Graph has no IDLE, so Microsoft mail waited for Gmail to speak or
      // the renewal to come round: up to 24 minutes.
      expect(liveWaitFor([gmail, work]), frequentSyncInterval);
    });
  });

  group('whether a periodic pass is tried again soon', () {
    late Map<String, FakeImapTransport> servers;
    late CachedImapEngine engine;
    late MemoryAccountStore accounts;

    setUp(() {
      servers = {};
      accounts = MemoryAccountStore();
      engine = CachedImapEngine(
        accountStore: accounts,
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (a, _) =>
            servers.putIfAbsent(a.emailAddress, FakeImapTransport.new),
      );
    });

    Future<void> add(String address) async {
      servers[address] = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox);
      await engine.addAccount(
        displayName: address,
        emailAddress: address,
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
    }

    Future<BackgroundSyncReport> pass() => BackgroundSync(
          engine: engine,
          notifier: FakeMailNotifier(),
          state: MemorySyncStateStore(
            prefs: const SyncPrefs(mode: SyncMode.periodic),
          ),
        ).run();

    test('not because one account needs signing in again', () async {
      // WorkManager answers a failed pass with an exponential backoff. One
      // lapsed sign-in failed every pass, and "Occasionally" soon ran every
      // five hours for the healthy accounts too.
      await add('ok@example.com');
      await add('stale@example.com');
      servers['stale@example.com']!.failWith =
          const AuthenticationFailed('Sign in again.');

      final report = await pass();

      expect(report.ok, isFalse);
      expect(report.worthRetrying, isFalse);
    });

    test('but when nothing could be reached at all, it is', () {
      const allUnreachable = BackgroundSyncReport(
        failures: ['a: offline', 'b: offline'],
        accounts: 2,
        unreachable: 1,
      );
      const oneOfTwo = BackgroundSyncReport(
        failures: ['a: offline'],
        accounts: 2,
        unreachable: 1,
      );
      expect(allUnreachable.worthRetrying, isTrue);
      expect(oneOfTwo.worthRetrying, isFalse);
    });
  });

  group('when Android has stopped push', () {
    const push = SyncPrefs(mode: SyncMode.realtime);
    final now = DateTime(2026, 9, 23, 8);

    test('a pass more than 40 minutes ago means it has', () {
      expect(
        liveSyncStalled(push, now.subtract(const Duration(hours: 7)), now),
        isTrue,
      );
      expect(
        liveSyncStalled(push, now.subtract(const Duration(minutes: 10)), now),
        isFalse,
      );
    });

    test('a worker yet to pass, or a mode without one, has not', () {
      expect(liveSyncStalled(push, null, now), isFalse);
      expect(
        liveSyncStalled(
          const SyncPrefs(mode: SyncMode.periodic),
          now.subtract(const Duration(days: 1)),
          now,
        ),
        isFalse,
      );
    });

    test('opening the app starts it again', () async {
      // Android 15 allows a data-sync service six hours a day, reset only
      // by opening the app. Push left on overnight stopped until then, and
      // nothing said so.
      final store = MemorySyncStateStore(prefs: push)
        ..lastLivePass = now.subtract(const Duration(hours: 7));
      final scheduler = FakeBackgroundScheduler();

      expect(await restartStalledLiveSync(store, scheduler, now: now), isTrue);
      expect(scheduler.last?.mode, SyncMode.realtime);

      store.lastLivePass = now.subtract(const Duration(minutes: 5));
      expect(await restartStalledLiveSync(store, scheduler, now: now), isFalse);
    });
  });

  group('the push worker and the account list', () {
    test('an account added in the app is seen once the cache is reloaded',
        () async {
      // The worker read the list once and ran for most of an hour.
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      const options = SharedPreferencesWithCacheOptions();
      final app = await SharedPreferencesWithCache.create(cacheOptions: options);
      final worker =
          await SharedPreferencesWithCache.create(cacheOptions: options);

      await PrefsAccountStore(app).write([
        account('a', MailProvider.gmail, AuthMethod.appPassword),
      ]);
      expect(PrefsAccountStore(worker).read(), isEmpty);

      await worker.reloadCache();
      expect(PrefsAccountStore(worker).read().single.id, 'a');
    });

    test('an account removed in the app is let go of', () async {
      final server = FakeImapTransport()..folder('INBOX', role: FolderRole.inbox);
      final accounts = MemoryAccountStore();
      final engine = CachedImapEngine(
        accountStore: accounts,
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
      );
      final added = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      await engine.loadFolders(added.id);
      server.calls.clear();

      // What the app's own engine does, from here.
      await accounts.write(const []);
      await engine.releaseRemovedAccounts();

      expect(server.calls, contains('LOGOUT'));
    });
  });
}
