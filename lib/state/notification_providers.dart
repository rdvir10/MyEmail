import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/notifications/mail_notifier.dart';
import '../data/sync/background_worker.dart';
import '../data/sync/sync_state_store.dart';
import '../domain/notification_prefs.dart';

/// Posts notifications. main() overrides this with the Android one; tests and
/// the browser preview get a fake that records instead.
final mailNotifierProvider =
    Provider<MailNotifier>((ref) => FakeMailNotifier(permitted: false));

/// The state the background isolate shares with the app. main() overrides this
/// with the shared_preferences one.
final syncStateStoreProvider =
    Provider<SyncStateStore>((ref) => MemorySyncStateStore());

/// Keeps Android's periodic work in step with the preferences. main()
/// overrides this with the WorkManager one; off Android it records and does
/// nothing, so the settings screen behaves the same in a test.
final backgroundSchedulerProvider =
    Provider<BackgroundScheduler>((ref) => FakeBackgroundScheduler());

/// Whether Android itself will let us show anything. The in-app switch is the
/// user's intent; this is whether the OS agrees, and the settings screen has
/// to show both rather than claim the feature is on when it is not.
final notificationPermissionProvider = FutureProvider<bool>(
  (ref) => ref.watch(mailNotifierProvider).isPermitted(),
);

/// The notification preferences, and the only place that changes them.
///
/// Every write does two things: persists the preferences where the background
/// isolate will read them, and brings Android's schedule into line. Those are
/// kept together deliberately — a setting saved without rescheduling is a
/// screen that disagrees with what the phone is actually doing.
class NotificationSettings extends AsyncNotifier<NotificationPrefs> {
  @override
  Future<NotificationPrefs> build() =>
      ref.watch(syncStateStoreProvider).readPrefs();

  Future<void> _save(NotificationPrefs next) async {
    await ref.read(syncStateStoreProvider).writePrefs(next);
    state = AsyncData(next);
    await ref.read(backgroundSchedulerProvider).apply(next);
  }

  /// Turning it on asks for permission first. Saying yes to a switch and then
  /// no to Android's dialog must not leave the switch on.
  Future<bool> setEnabled(bool enabled) async {
    final current = state.value ?? const NotificationPrefs();
    if (enabled) {
      final granted = await ref.read(mailNotifierProvider).requestPermission();
      ref.invalidate(notificationPermissionProvider);
      if (!granted) return false;
    }
    await _save(current.copyWith(enabled: enabled));
    if (!enabled) await ref.read(mailNotifierProvider).cancelAll();
    return true;
  }

  Future<void> setMode(SyncMode mode) async {
    final current = state.value ?? const NotificationPrefs();
    await _save(current.copyWith(mode: mode));
  }

  Future<void> setInterval(int minutes) async {
    final current = state.value ?? const NotificationPrefs();
    await _save(current.copyWith(intervalMinutes: minutes));
  }

  Future<void> setAccountMuted(String accountId, bool muted) async {
    final current = state.value ?? const NotificationPrefs();
    await _save(current.withAccountMuted(accountId, muted));
  }
}

final notificationSettingsProvider =
    AsyncNotifierProvider<NotificationSettings, NotificationPrefs>(
  NotificationSettings.new,
);
