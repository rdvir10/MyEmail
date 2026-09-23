import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/notifications/mail_notifier.dart';
import '../data/sync/background_worker.dart';
import '../data/sync/sync_state_store.dart';
import '../domain/sync_prefs.dart';

/// Posts notifications. main() overrides this with the Android one; tests and
/// the browser preview get a fake that records instead.
final mailNotifierProvider =
    Provider<MailNotifier>((ref) => FakeMailNotifier(permitted: false));

/// The state the background isolate shares with the app. main() overrides this
/// with the shared_preferences one.
final syncStateStoreProvider =
    Provider<SyncStateStore>((ref) => MemorySyncStateStore());

/// Keeps Android's background work in step with the preferences. main()
/// overrides this with the WorkManager one; off Android it records and does
/// nothing, so the settings screens behave the same in a test.
final backgroundSchedulerProvider =
    Provider<BackgroundScheduler>((ref) => FakeBackgroundScheduler());

/// Whether Android itself will let us show anything. The in-app switch is the
/// user's intent; this is whether the OS agrees, and the screen has to show
/// both rather than claim the feature is on when it is not.
final notificationPermissionProvider = FutureProvider<bool>(
  (ref) => ref.watch(mailNotifierProvider).isPermitted(),
);

/// Background sync and notification preferences, and the only place that
/// changes them.
///
/// Every write does two things: persists where the background isolate will
/// read it, and brings Android's schedule into line. Those are kept together
/// deliberately, because a setting saved without rescheduling is a screen that
/// disagrees with what the phone is actually doing.
class SyncSettings extends AsyncNotifier<SyncPrefs> {
  @override
  Future<SyncPrefs> build() => ref.watch(syncStateStoreProvider).readPrefs();

  Future<void> _save(SyncPrefs next) async {
    await ref.read(syncStateStoreProvider).writePrefs(next);
    state = AsyncData(next);
    await ref.read(backgroundSchedulerProvider).apply(next);
  }

  /// How often to look.
  ///
  /// Asks for notification permission on the way into a foreground mode:
  /// those show a permanent notification whether or not new mail is ever
  /// announced, and Android will not start the service without it.
  ///
  /// The occasional mode asks too when new mail is to be announced, which
  /// it is from the start. It used not to, and on a new phone every
  /// notification it raised was dropped by Android without a word. A no
  /// there does not stop it syncing: the mode stands, and the screen shows
  /// that Android is blocking the notifications.
  Future<bool> setMode(SyncMode mode) async {
    final current = state.value ?? const SyncPrefs();
    if (mode.needsForegroundService && !await _ensurePermission()) return false;
    if (mode.isOn && !mode.needsForegroundService && current.notify) {
      await _ensurePermission();
    }
    if (mode.needsForegroundService && mode != current.mode) {
      // A worker about to start fresh has not stopped; see liveSyncStalled.
      await ref.read(syncStateStoreProvider).writeLastLivePass(DateTime.now());
    }
    await _save(current.copyWith(mode: mode));
    if (!mode.isOn) await ref.read(mailNotifierProvider).cancelAll();
    return true;
  }

  Future<void> setInterval(int minutes) async {
    final current = state.value ?? const SyncPrefs();
    await _save(current.copyWith(intervalMinutes: minutes));
  }

  /// Whether to be told. Separate from [setMode] on purpose: syncing quietly
  /// so the app is current when opened is an ordinary thing to want.
  Future<bool> setNotify(bool notify) async {
    final current = state.value ?? const SyncPrefs();
    if (notify && !await _ensurePermission()) return false;
    await _save(current.copyWith(notify: notify));
    if (!notify) await ref.read(mailNotifierProvider).cancelAll();
    return true;
  }

  Future<void> setAccountMuted(String accountId, bool muted) async {
    final current = state.value ?? const SyncPrefs();
    await _save(current.withAccountMuted(accountId, muted));
  }

  /// Saying yes to a switch and then no to Android's dialog must not leave
  /// the switch on.
  Future<bool> _ensurePermission() async {
    final granted = await ref.read(mailNotifierProvider).requestPermission();
    ref.invalidate(notificationPermissionProvider);
    return granted;
  }
}

final syncSettingsProvider =
    AsyncNotifierProvider<SyncSettings, SyncPrefs>(SyncSettings.new);

/// When the push or five-minute worker last ran, if it has stopped when it
/// should be running; null otherwise. See [liveSyncStalled].
final stalledLiveSyncProvider = FutureProvider<DateTime?>((ref) async {
  final prefs = await ref.watch(syncSettingsProvider.future);
  final last = await ref.watch(syncStateStoreProvider).readLastLivePass();
  return liveSyncStalled(prefs, last, DateTime.now()) ? last : null;
});

/// Start the push or five-minute worker again if Android has stopped it.
///
/// Opening the app is what resets Android's six-hour allowance, so this is
/// the moment. Returns whether it had to.
Future<bool> restartStalledLiveSync(
  SyncStateStore store,
  BackgroundScheduler scheduler, {
  DateTime? now,
}) async {
  final prefs = await store.readPrefs();
  final last = await store.readLastLivePass();
  if (!liveSyncStalled(prefs, last, now ?? DateTime.now())) return false;
  await scheduler.apply(prefs);
  return true;
}
