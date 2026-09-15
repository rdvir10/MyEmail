import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../domain/notification_prefs.dart';
import '../account_store.dart';
import '../cache/mail_database.dart';
import '../folder_list_store.dart';
import '../imap/cached_imap_engine.dart';
import '../notifications/android_mail_notifier.dart';
import '../secure_credential_store.dart';
import 'background_sync.dart';
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

const _taskName = 'mailtree.new-mail';
const _uniqueName = 'mailtree.new-mail.periodic';

/// Keeping Android's schedule in step with the preferences.
///
/// A port, not a free function, for one reason: every caller is a settings
/// change, and a settings change has to be testable without a phone. The real
/// one talks to WorkManager; tests and the browser preview record instead.
abstract class BackgroundScheduler {
  Future<void> apply(NotificationPrefs prefs);
}

class WorkManagerScheduler implements BackgroundScheduler {
  const WorkManagerScheduler();

  @override
  Future<void> apply(NotificationPrefs prefs) => applyBackgroundSchedule(prefs);
}

/// Records what it was asked to do. The default outside Android.
class FakeBackgroundScheduler implements BackgroundScheduler {
  final List<NotificationPrefs> applied = [];

  @override
  Future<void> apply(NotificationPrefs prefs) async => applied.add(prefs);

  NotificationPrefs? get last => applied.isEmpty ? null : applied.last;
}

/// Set up WorkManager and bring the schedule in line with [prefs].
///
/// Called at startup and again whenever the settings change, so a schedule
/// left over from a previous run is always either updated or cancelled.
Future<void> applyBackgroundSchedule(NotificationPrefs prefs) async {
  if (!_supported) return;
  await Workmanager().initialize(backgroundCallbackDispatcher);
  if (!prefs.enabled) {
    await Workmanager().cancelByUniqueName(_uniqueName);
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
}

/// Android only. The browser preview has no WorkManager, and calling into it
/// there throws on a missing plugin rather than failing quietly.
bool get _supported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != _taskName) return true;
    return _runOnePass();
  });
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
    );

    final report = await BackgroundSync(
      engine: engine,
      notifier: AndroidMailNotifier(),
      state: PrefsSyncStateStore(),
    ).run();

    debugPrint('[mailtree] background pass: $report');
    for (final failure in report.failures) {
      debugPrint('[mailtree] background pass failure: $failure');
    }

    // Returning false asks WorkManager to retry with backoff. Worth it for a
    // mailbox that could not be reached; not worth it when the pass ran fine.
    return report.ok;
  } catch (e, stack) {
    debugPrint('[mailtree] background pass threw: $e\n$stack');
    return false;
  } finally {
    // The isolate is about to be torn down either way, but an IMAP socket and
    // a SQLite handle left open are the two things that survive long enough to
    // matter to the next pass.
    await engine?.close();
    await database?.close();
  }
}
