import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../domain/folder_role.dart';
import '../../domain/mail_folder.dart';
import '../../domain/sync_prefs.dart';
import '../account_store.dart';
import '../cache/mail_database.dart';
import '../graph/graph_id_map.dart';
import '../folder_list_store.dart';
import '../imap/cached_imap_engine.dart';
import '../notifications/android_mail_notifier.dart';
import '../secure_credential_store.dart';
import '../widget/home_screen_surface.dart';
import '../widget/mailbox_widgets.dart';
import '../widget/widget_state_store.dart';
import '../notifications/notification_action_isolate.dart';
import 'background_sync.dart';
import 'live_sync.dart';
import 'sync_state_store.dart';

/// Scheduling the periodic pass, and the entry point Android calls into.
///
/// The part to understand before changing anything here: [_dispatcher] does
/// not run in the app's isolate. Android starts a *second* Dart isolate for
/// it, which shares nothing with the running app — no providers, no widget
/// tree, no open database, not even the plugin registrations. Everything it
/// needs is rebuilt from the platform, and everything it produces has to go
/// back through the platform for the app to see it. That is why the engine is
/// constructed from scratch below rather than passed in, and why the state
/// store reads through to shared preferences rather than caching.

// These keep the old name after the rename to MyEmail on purpose. A unique
// name is how WorkManager recognises work it already has; changing one leaves
// the old job enqueued alongside the new, which is two things checking mail
// and every message arriving twice.
const _taskName = 'mailtree.new-mail';
const _uniqueName = 'mailtree.new-mail.periodic';

/// The foreground modes. A separate task and name from the periodic one so
/// that switching modes cancels the old shape rather than leaving both
/// running, which is the failure that shows up as double notifications.
const _liveTaskName = 'mailtree.live';
const _liveUniqueName = 'mailtree.live.foreground';

/// Carrying out a notification button that was pressed.
///
/// Its own task because it has nothing to do with checking for mail and must
/// run whatever the sync settings say: somebody pressed Delete, and that is
/// not something to hold until the next scheduled pass.
const _actionsTaskName = 'mailtree.notification-actions';
const _actionsUniqueName = 'mailtree.notification-actions.pending';

/// The ongoing notification the foreground service is legally required to
/// show. Its own channel, set to the lowest importance Android allows for a
/// foreground service, so it sits silently at the bottom of the shade instead
/// of announcing itself next to actual mail.
const _serviceChannelId = 'mailtree.sync-service';
const _serviceChannelName = 'Background sync';

/// Keeping Android's schedule in step with the preferences.
///
/// A port, not a free function, for one reason: every caller is a settings
/// change, and a settings change has to be testable without a phone. The real
/// one talks to WorkManager; tests and the browser preview record instead.
abstract class BackgroundScheduler {
  Future<void> apply(SyncPrefs prefs);
}

class WorkManagerScheduler implements BackgroundScheduler {
  const WorkManagerScheduler();

  @override
  Future<void> apply(SyncPrefs prefs) => applyBackgroundSchedule(prefs);
}

/// Records what it was asked to do. The default outside Android.
class FakeBackgroundScheduler implements BackgroundScheduler {
  final List<SyncPrefs> applied = [];

  @override
  Future<void> apply(SyncPrefs prefs) async => applied.add(prefs);

  SyncPrefs? get last => applied.isEmpty ? null : applied.last;
}

/// Set up WorkManager and bring the schedule in line with [prefs].
///
/// Called at startup and again whenever the settings change, so a schedule
/// left over from a previous run is always either updated or cancelled.
Future<void> applyBackgroundSchedule(SyncPrefs prefs) async {
  if (!_supported) return;
  await Workmanager().initialize(backgroundCallbackDispatcher);

  // Always clear the shape we are not in. Leaving the other one enqueued is
  // how a mode change turns into two things checking mail at once.
  if (!prefs.syncs || prefs.mode.needsForegroundService) {
    await Workmanager().cancelByUniqueName(_uniqueName);
  }
  if (!prefs.syncs || !prefs.mode.needsForegroundService) {
    await Workmanager().cancelByUniqueName(_liveUniqueName);
  }
  if (!prefs.syncs) return;

  if (prefs.mode.needsForegroundService) {
    await _startLiveWorker(prefs);
    return;
  }

  await Workmanager().registerPeriodicTask(
    _uniqueName,
    _taskName,
    frequency: prefs.interval,
    // `update` rather than `keep`: with `keep`, changing the interval in
    // settings would leave the old one running and the screen would be lying.
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    constraints: Constraints(
      networkType: NetworkType.connected,
      // Not `requiresCharging`, which would mean no mail all day. Battery-not-low
      // is the right stopping point: a phone about to die should not be opening
      // IMAP connections.
      requiresBatteryNotLow: true,
    ),
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(minutes: 5),
  );
}

Future<void> cancelBackgroundSchedule() async {
  if (!_supported) return;
  await Workmanager().cancelByUniqueName(_uniqueName);
  await Workmanager().cancelByUniqueName(_liveUniqueName);
}

/// Start (or replace) the long-running foreground worker.
///
/// A one-off rather than a periodic task, because what is wanted is one
/// process that stays alive and loops, not a job that runs and exits. It
/// re-enqueues itself when its budget is spent; see [_runLive]. [after]
/// holds the start back, for a worker handing over after it failed.
Future<void> _startLiveWorker(SyncPrefs prefs, {Duration? after}) async {
  await Workmanager().registerOneOffTask(
    _liveUniqueName,
    _liveTaskName,
    inputData: {'mode': prefs.mode.name},
    initialDelay: after,
    // `replace`, so changing from five-minute to push does not leave the
    // previous worker running alongside the new one.
    existingWorkPolicy: ExistingWorkPolicy.replace,
    constraints: Constraints(
      networkType: NetworkType.connected,
      requiresBatteryNotLow: true,
    ),
    backoffPolicy: BackoffPolicy.linear,
    backoffPolicyDelay: const Duration(minutes: 1),
    foregroundServiceConfig: ForegroundServiceConfig(
      notificationTitle: 'MyEmail',
      notificationText: prefs.mode == SyncMode.realtime
          ? 'Watching for new mail'
          : 'Checking for mail every 5 minutes',
      notificationChannelId: _serviceChannelId,
      notificationChannelName: _serviceChannelName,
      notificationId: 424242,
      foregroundServiceType: ForegroundServiceType.dataSync,
    ),
  );
}

/// Android only. The browser preview has no WorkManager, and calling into it
/// there throws on a missing plugin rather than failing quietly.
bool get _supported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Ask for everything waiting in the queue to be carried out.
///
/// `append`, not `replace`: two presses in quick succession must both be
/// done, and replacing the job would drop the first one's work on the floor
/// even though its entry is still in the queue.
Future<void> runPendingNotificationActions() async {
  if (!_supported) return;
  await Workmanager().initialize(backgroundCallbackDispatcher);
  await Workmanager().registerOneOffTask(
    _actionsUniqueName,
    _actionsTaskName,
    existingWorkPolicy: ExistingWorkPolicy.append,
    constraints: Constraints(networkType: NetworkType.connected),
    backoffPolicy: BackoffPolicy.linear,
    backoffPolicyDelay: const Duration(seconds: 30),
  );
}

@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    return switch (task) {
      _taskName => _runOnePass(),
      _liveTaskName => _runLive(inputData),
      _actionsTaskName => _runPendingActions(),
      _ => Future.value(true),
    };
  });
}

/// Carry out the notification buttons that are waiting.
///
/// True whatever happens. A false would have WorkManager try again with
/// backoff, and the queue is already emptied by the time anything can fail
/// — so a retry would do nothing except wake the phone up again.
Future<bool> _runPendingActions() async {
  DartPluginRegistrant.ensureInitialized();
  try {
    final done = await drainPendingNotificationActions();
    if (done > 0) debugPrint('[myemail] carried out $done from the shade');
  } catch (e, stack) {
    debugPrint('[myemail] pending notification actions failed: $e');
    debugPrint('$stack');
  }
  return true;
}

/// The foreground modes: one worker that stays alive and loops.
///
/// Returns true either way. A false here would make WorkManager retry with
/// backoff, but this worker re-enqueues itself deliberately and immediately,
/// and two competing restart mechanisms is how you end up with two services.
Future<bool> _runLive(Map<String, dynamic>? inputData) async {
  DartPluginRegistrant.ensureInitialized();

  final mode = SyncMode.values.firstWhere(
    (m) => m.name == inputData?['mode'],
    orElse: () => SyncMode.frequent,
  );

  MailDatabase? database;
  CachedImapEngine? engine;
  try {
    final prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    database = MailDatabase.open();
    final liveEngine = CachedImapEngine(
      accountStore: PrefsAccountStore(prefs),
      credentialStore: SecureCredentialStore(),
      cache: DriftCacheStore(database),
      folderLists: PrefsFolderListStore(prefs),
      graphIdMap: DriftGraphIdMap(database),
    );
    engine = liveEngine;

    final state = PrefsSyncStateStore();
    final sync = BackgroundSync(
      engine: liveEngine,
      notifier: AndroidMailNotifier(),
      state: state,
    );

    final widgets = MailboxWidgets(
      surface: homeScreenSurface(),
      store: PrefsWidgetStateStore(),
    );

    final outcome = await LiveSyncLoop(
      // The widgets are brought up to date after every pass rather than when
      // the worker finishes, because this worker runs for hours.
      onePass: () async {
        final report = await sync.run();
        await widgets.refresh(liveEngine);
        return report;
      },
      waitForNext: () => _waitForNext(mode, liveEngine),
    ).run();
    debugPrint('[myemail] live worker finished: $outcome');

    // Hand over to a fresh worker unless the settings changed underneath us,
    // which is the one case where stopping is correct.
    final current = await state.readPrefs();
    if (current.mode.needsForegroundService) {
      await _startLiveWorker(current);
    }
    return true;
  } catch (e, stack) {
    debugPrint('[myemail] live worker threw: $e');
    debugPrint('$stack');
    // Still hand over, a minute on, while the settings ask for it. Ending
    // here used to leave push off with nothing to say so until the app was
    // next opened; the delay keeps a fault that repeats from spinning.
    try {
      final current = await PrefsSyncStateStore().readPrefs();
      if (current.mode.needsForegroundService) {
        await _startLiveWorker(current, after: const Duration(minutes: 1));
      }
    } catch (e) {
      debugPrint('[myemail] could not hand the live worker over: $e');
    }
    return true;
  } finally {
    await engine?.close();
    await database?.close();
  }
}

/// What the loop waits on between passes, per mode.
Future<void> _waitForNext(SyncMode mode, CachedImapEngine engine) async {
  if (mode != SyncMode.realtime) {
    await Future<void>.delayed(frequentSyncInterval);
    return;
  }
  // Push: hold an IDLE on every watched inbox and return the moment one of
  // them speaks. The renew interval caps it, because a server drops an IDLE
  // that is never re-issued and silence would look identical to no mail.
  //
  // The inboxes come from the folder lists the pass just saved, not from the
  // server. Asking the server again was redundant, and it threw for any
  // account that could not be reached in anything but a plain connection
  // failure — a revoked app password, a Microsoft sign-in to redo — which
  // ended the worker and every account's notifications with it.
  final inboxes = <String>[];
  for (final account in await engine.loadAccounts()) {
    for (final folder in await _foldersToWatch(engine, account.id)) {
      if (folder.role == FolderRole.inbox) inboxes.add(folder.id);
    }
  }
  await engine.awaitNewMail(inboxes, timeout: idleRenewInterval);
}

/// The account's folders as last saved, asking the server only when nothing
/// has been saved yet, and never letting one account's trouble out.
Future<List<MailFolder>> _foldersToWatch(
  CachedImapEngine engine,
  String accountId,
) async {
  try {
    final saved = await engine.cachedFolders(accountId);
    return saved.isNotEmpty ? saved : await engine.loadFolders(accountId);
  } catch (e) {
    debugPrint('[myemail] not watching $accountId: $e');
    return const [];
  }
}

Future<bool> _runOnePass() async {
  // Nothing is registered in a fresh isolate, so secure storage, sqlite and
  // the notification channel are all unavailable until this runs.
  DartPluginRegistrant.ensureInitialized();

  MailDatabase? database;
  CachedImapEngine? engine;
  try {
    final prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    database = MailDatabase.open();
    engine = CachedImapEngine(
      accountStore: PrefsAccountStore(prefs),
      credentialStore: SecureCredentialStore(),
      cache: DriftCacheStore(database),
      folderLists: PrefsFolderListStore(prefs),
      graphIdMap: DriftGraphIdMap(database),
    );

    final report = await BackgroundSync(
      engine: engine,
      notifier: AndroidMailNotifier(),
      state: PrefsSyncStateStore(),
    ).run();

    // After the sync, so the numbers it writes are the ones just fetched.
    // It never throws; see MailboxWidgets.refresh.
    await MailboxWidgets(
      surface: homeScreenSurface(),
      store: PrefsWidgetStateStore(),
    ).refresh(engine);

    debugPrint('[myemail] background pass: $report');
    for (final failure in report.failures) {
      debugPrint('[myemail] background pass failure: $failure');
    }

    // Returning false asks WorkManager to retry with backoff. Worth it for a
    // mailbox that could not be reached; not worth it when the pass ran fine.
    return report.ok;
  } catch (e, stack) {
    debugPrint('[myemail] background pass threw: $e\n$stack');
    return false;
  } finally {
    // The isolate is about to be torn down either way, but an IMAP socket and
    // a SQLite handle left open are the two things that survive long enough to
    // matter to the next pass.
    await engine?.close();
    await database?.close();
  }
}
