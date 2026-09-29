import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:myemail_power/myemail_power.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../domain/account.dart';
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
import '../notifications/pending_actions.dart';
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

/// Another look at presses the first could not finish: offline, failing,
/// or held by a drain that may yet die. Its own name, so its growing
/// backoff never stands in front of a new press; see
/// [runPendingNotificationActions].
const _actionsRetryName = 'mailtree.notification-actions.retry';

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
///
/// [restart] replaces a live worker that is already running, which a change
/// of mode needs. Startup passes false: the settings have not changed, and
/// replacing the worker there cut it off mid-pass every time the app was
/// opened, after it had moved the notification mark and before it posted,
/// so that mail was never announced.
Future<void> applyBackgroundSchedule(
  SyncPrefs prefs, {
  bool restart = true,
}) async {
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
    await _startLiveWorker(prefs, policy: liveWorkPolicy(restart: restart));
    return;
  }

  await _registerPeriodicPass(prefs.interval);
}

/// The occasional check, every [frequency].
///
/// Also where push falls back to when Android refuses its foreground
/// service, until the app is opened and can start it again.
Future<void> _registerPeriodicPass(Duration frequency) async {
  await Workmanager().registerPeriodicTask(
    _uniqueName,
    _taskName,
    frequency: frequency,
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

/// How to enqueue the live worker when one may already be there.
///
/// `replace` for a change, so changing from five-minute to push does not
/// leave the previous worker running alongside the new one. `keep`
/// otherwise, so one that is running is left to run.
@visibleForTesting
ExistingWorkPolicy liveWorkPolicy({required bool restart}) =>
    restart ? ExistingWorkPolicy.replace : ExistingWorkPolicy.keep;

/// Start (or replace) the long-running foreground worker.
///
/// A one-off rather than a periodic task, because what is wanted is one
/// process that stays alive and loops, not a job that runs and exits; see
/// [_runLive]. [after] holds the start back, for a worker handing over
/// after it failed.
///
/// Best started from the app while it is on screen. Android refuses a
/// foreground service started from the background unless MyEmail is exempt
/// from battery optimisation, and a worker without one falls back to
/// occasional checks until the app is next opened.
Future<void> _startLiveWorker(
  SyncPrefs prefs, {
  Duration? after,
  ExistingWorkPolicy policy = ExistingWorkPolicy.replace,
}) async {
  await Workmanager().registerOneOffTask(
    _liveUniqueName,
    _liveTaskName,
    inputData: {'mode': prefs.mode.name},
    initialDelay: after,
    existingWorkPolicy: policy,
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
/// even though its entry is still in the queue. (The plugin makes it
/// APPEND_OR_REPLACE, which drops a job that had already failed when the
/// next is added; one that fails while the next waits behind it takes that
/// one down with it, which is why a press also schedules a retry.)
///
/// This job always succeeds, whatever it could not finish: what is left
/// goes to the retry job instead. Retrying here put the chain into
/// WorkManager's backoff, and every press made after it waited behind a
/// gap that grew by half a minute a try, to five hours.
Future<void> runPendingNotificationActions() async {
  if (!_supported) return;
  await Workmanager().initialize(backgroundCallbackDispatcher);
  await Workmanager().registerOneOffTask(
    _actionsUniqueName,
    _actionsTaskName,
    existingWorkPolicy: ExistingWorkPolicy.append,
    constraints: Constraints(networkType: NetworkType.connected),
  );
}

/// Look again in a minute, and then as WorkManager's backoff says: a minute
/// more each time, not doubling, because a press left behind a retry that is
/// already waiting waits as long as it does. `keep`: one retry waiting is
/// enough, and replacing one that is running would cut it off mid-press; a
/// running one looks at the whole queue again before it calls itself done.
Future<void> scheduleNotificationActionsRetry() async {
  if (!_supported) return;
  await Workmanager().registerOneOffTask(
    _actionsRetryName,
    _actionsTaskName,
    inputData: {'retry': true},
    initialDelay: const Duration(minutes: 1),
    existingWorkPolicy: ExistingWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.connected),
    backoffPolicy: BackoffPolicy.linear,
    backoffPolicyDelay: const Duration(minutes: 1),
  );
}

@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask(
    (task, inputData) async {
      return switch (task) {
        _taskName => _runOnePass(),
        _liveTaskName => _runLive(inputData),
        _actionsTaskName =>
          _runPendingActions(retry: inputData?['retry'] == true),
        _ => Future.value(true),
      };
    },
    onTaskStopped: (task, _) async {
      if (task == _liveTaskName) await _liveStop?.stop();
      if (task == _actionsTaskName) await _actionsStop?.stop();
    },
  );
}

/// The running actions drain's stop, while there is one.
_ActionsStop? _actionsStop;

/// Android stopping the actions job: a lost connection, or its time up.
///
/// The drain finishes the press in hand, if it can within [grace], and
/// claims no more; the rest stay in the queue, unclaimed, for the retry.
/// Without this the engine was torn down mid-press and the presses it had
/// claimed sat untouched.
class _ActionsStop {
  static const grace = Duration(seconds: 8);

  var requested = false;
  Future<void> _finished = Future<void>.value();

  Future<T> guard<T>(Future<T> drain) {
    _finished = drain.then<void>((_) {}, onError: (Object _) {});
    return drain;
  }

  Future<void> stop() async {
    requested = true;
    await _finished.timeout(grace, onTimeout: () {});
  }
}

/// The running live worker's stop, while there is one.
LiveWorkerStop? _liveStop;

/// Android stopping the live worker: replaced by a change of mode, or out
/// of its time.
///
/// The loop is told, finishes the pass it is on rather than being cut off
/// mid-write, and ends. WorkManager tears the worker down as soon as its
/// stop handler returns, so [stop] waits for the loop, but only for
/// [grace]: a worker that will not stop is stopped anyway.
class LiveWorkerStop {
  LiveWorkerStop({this.grace = const Duration(seconds: 10)});

  final Duration grace;
  final _signal = Completer<void>();
  Future<void> _finished = Future<void>.value();

  /// For [LiveSyncLoop.stopSignal].
  Future<void> get signal => _signal.future;

  /// Run the loop under this stop, so [stop] can wait for it.
  Future<T> guard<T>(Future<T> loop) {
    _finished = loop.then<void>((_) {}, onError: (Object _) {});
    return loop;
  }

  Future<void> stop() async {
    if (!_signal.isCompleted) _signal.complete();
    await _finished.timeout(grace, onTimeout: () {});
  }
}

/// Whether a live worker whose loop has ended falls back to occasional
/// checks.
///
/// Only when it lost its foreground service while the settings still ask
/// for one. Starting another worker from here would be refused in the same
/// way, and a worker Android stopped needs nothing: it stopped it for a new
/// one already enqueued in its place, or because it ran out of time, which
/// opening the app starts again.
@visibleForTesting
bool fallsBack(LiveSyncOutcome outcome, SyncPrefs current) =>
    outcome.lostForeground && current.mode.needsForegroundService;

/// What the loop asks after each pass: does the worker still have its
/// foreground service?
///
/// The first time, it waits up to [grace] for one. WorkManager asks Android
/// for the service as the worker starts, and it comes up a moment after;
/// a worker checking too early would take itself for refused.
///
/// Why this is asked at all. When Android refuses the service, which it
/// does to a worker started from the background unless MyEmail is exempt
/// from battery optimisation, WorkManager still counts the worker as
/// foreground work and ignores Android's stop. The worker then lives on
/// with no service and no job: frozen between Android's rationed job slots
/// on a Pixel, so mail from a Microsoft account arrived twenty minutes late
/// or more; waking every ten seconds with its network cut on a Samsung,
/// until Android killed it for the battery it was using.
@visibleForTesting
Future<bool> Function() foregroundCheck(
  Future<bool> Function() running, {
  Duration grace = const Duration(seconds: 15),
  Duration poll = const Duration(seconds: 1),
  Future<void> Function(Duration)? sleep,
}) {
  final wait = sleep ?? (d) => Future<void>.delayed(d);
  var first = true;
  return () async {
    if (!first) return running();
    first = false;
    for (var waited = Duration.zero;; waited += poll) {
      if (await running()) return true;
      if (waited >= grace) return false;
      await wait(poll);
    }
  };
}

/// Carry out the notification buttons that are waiting.
///
/// A press job ([retry] false) always succeeds and leaves what it could not
/// finish to the retry job. The retry job returns false while anything is
/// left, so WorkManager comes back with its backoff; see
/// [runPendingNotificationActions] for why the two are kept apart.
Future<bool> _runPendingActions({required bool retry}) async {
  DartPluginRegistrant.ensureInitialized();
  final stop = _actionsStop = _ActionsStop();
  try {
    final result = await stop.guard(drainPendingNotificationActions(
      shouldStop: () => stop.requested,
    ));
    if (result.done > 0) {
      debugPrint('[myemail] carried out ${result.done} from the shade');
      announceActionsDone();
    }
    // A summary left over by a pressed row, should the press isolate not
    // have caught it.
    await AndroidMailNotifier().dropEmptySummaries();
    if (retry) {
      // The whole queue, not only what this run listed when it began: a
      // press left over by a press job while this ran found this retry
      // already there, and would otherwise be left with nobody to look.
      final left = result.leftOver || (await PendingActions().waiting()).isNotEmpty;
      if (left) debugPrint('[myemail] notification presses still waiting');
      return !left;
    }
    if (!result.leftOver) return true;
    debugPrint('[myemail] notification presses left: ${result.waiting} '
        'waiting, ${result.held} held elsewhere');
    await scheduleNotificationActionsRetry();
    return true;
  } catch (e, stack) {
    debugPrint('[myemail] pending notification actions failed: $e');
    debugPrint('$stack');
    // Something is still in the queue, most likely. The retry job comes
    // back for it; a press job leaves one behind it.
    if (retry) return false;
    try {
      await scheduleNotificationActionsRetry();
    } catch (_) {}
    return true;
  } finally {
    if (identical(_actionsStop, stop)) _actionsStop = null;
  }
}

/// The foreground modes: one worker that stays alive and loops, for as long
/// as Android keeps its foreground service going.
///
/// Returns true either way. A false here would make WorkManager retry with
/// backoff, and a worker Android refused its service would be refused again.
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

    final stop = _liveStop = LiveWorkerStop();
    final outcome = await stop.guard(LiveSyncLoop(
      // The widgets are brought up to date after every pass rather than when
      // the worker finishes, because this worker runs for hours.
      onePass: () async {
        // The account list as it is now. This worker runs for most of an
        // hour, and read it once at the start: an account removed in the
        // app went on being synced and announced here, and one added was
        // not watched until the next worker.
        await prefs.reloadCache();
        await liveEngine.releaseRemovedAccounts();
        final report = await sync.run();
        await widgets.refresh(liveEngine);
        await state.writeLastLivePass(DateTime.now());
        return report;
      },
      waitForNext: () => _waitForNext(mode, liveEngine),
      stopSignal: stop.signal,
      stillForeground:
          foregroundCheck(const MyEmailPower().foregroundServiceRunning),
    ).run());
    debugPrint('[myemail] live worker finished: $outcome');

    // Refused its service: occasional checks until the app is opened, which
    // starts push again where Android allows it. See restartStalledLiveSync.
    final current = await state.readPrefs();
    if (fallsBack(outcome, current)) {
      await state.writeLiveRefused(DateTime.now());
      await _registerPeriodicPass(
        const Duration(minutes: SyncPrefs.minimumIntervalMinutes),
      );
      debugPrint('[myemail] live: Android refused the foreground service; '
          'checking every ${SyncPrefs.minimumIntervalMinutes} minutes '
          'until MyEmail is opened');
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
  final watched = <Account>[];
  for (final account in await engine.loadAccounts()) {
    for (final folder in await _foldersToWatch(engine, account.id)) {
      if (folder.role != FolderRole.inbox) continue;
      inboxes.add(folder.id);
      watched.add(account);
    }
  }
  await engine.awaitNewMail(inboxes, timeout: liveWaitFor(watched));
}

/// How long the push worker waits for news before looking anyway.
///
/// The IDLE renewal, unless a watched account cannot IDLE. Microsoft's
/// mail comes over Graph, where waiting is a plain sleep, so its new mail
/// was found only when Gmail spoke or the renewal came round: up to 24
/// minutes, slower than the five-minute mode. With one watched, the wait
/// is the five-minute mode's.
Duration liveWaitFor(Iterable<Account> watched) =>
    watched.every(CachedImapEngine.hearsNewMail)
        ? idleRenewInterval
        : frequentSyncInterval;

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

    // Returning false asks WorkManager to retry with backoff: see
    // BackgroundSyncReport.worthRetrying for why that is so rarely right.
    return !report.worthRetrying;
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
