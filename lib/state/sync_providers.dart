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
  /// Asks for notification permission on the way into a foreground mode, and
  /// only then: those show a permanent notification whether or not new mail is
  /// ever announced, and Android will not start the service without it. The
  /// occasional mode needs no permission at all, which is the point of
  /// keeping these two settings apart.
  Future<bool> setMode(SyncMode mode) async {
    final current = state.value ?? const SyncPrefs();
    if (mode.needsForegroundService && !await _ensurePermission()) return false;
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
