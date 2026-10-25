import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/calendar/calendar_upkeep.dart';
import '../data/ui_state_store.dart';
import '../domain/calendar_event.dart';
import '../domain/meeting_alerts.dart';
import 'calendar_view_providers.dart' show CalendarRange;
import 'providers.dart';
import 'sync_providers.dart' show mailNotifierProvider;
import 'widget_providers.dart' show homeScreenSurfaceProvider;

/// Keeping the meeting reminders, the morning's agenda and the calendar
/// widget up to date from the app: as it starts and comes to the front,
/// while it is there, and at once after it changes a calendar or their
/// settings. The background passes keep them up otherwise.
abstract class CalendarKeeper {
  /// Brought up to date if a quarter of an hour has passed since they
  /// last were, or whatever the time with [now].
  Future<void> keepUp({bool now = false});
}

/// Does nothing: the default, for the tests and the browser preview, which
/// have no notifications to set. main() sets [AppCalendarKeeper] on
/// Android.
class NoCalendarKeeper implements CalendarKeeper {
  const NoCalendarKeeper();

  @override
  Future<void> keepUp({bool now = false}) async {}
}

/// The app's: [keepCalendarUpIfDue] with the app's own engine, notifier
/// and home screen, one run at a time.
class AppCalendarKeeper implements CalendarKeeper {
  AppCalendarKeeper(this._ref);

  final Ref _ref;
  Future<void>? _running;
  bool _again = false;

  @override
  Future<void> keepUp({bool now = false}) {
    final running = _running;
    if (running != null) {
      // Something changed while it ran: once more after, with that in.
      if (now) _again = true;
      return running;
    }
    return _running = _run(now).whenComplete(() {
      _running = null;
      if (_again) {
        _again = false;
        unawaited(keepUp(now: true));
      }
    });
  }

  Future<void> _run(bool now) async {
    final uiState = _ref.read(uiStateStoreProvider);
    // The clock as the phone has it, for what the background writes.
    await uiState.writeString(
      UiStateKeys.clock24h,
      '${PlatformDispatcher.instance.alwaysUse24HourFormat}',
    );
    await keepCalendarUpIfDue(
      _ref.read(mailEngineProvider),
      uiState,
      _ref.read(mailNotifierProvider),
      _ref.read(homeScreenSurfaceProvider),
      force: now,
    );
  }
}

final calendarKeeperProvider =
    Provider<CalendarKeeper>((ref) => const NoCalendarKeeper());

/// The time, as what is said about meetings sees it: a test's own.
final meetingClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

/// Today, midnight to midnight, as the calendar asks for a day.
CalendarRange dayRange(DateTime now) {
  final start = DateTime(now.year, now.month, now.day);
  return (start: start, end: DateTime(start.year, start.month, start.day + 1));
}

/// My Day in the folder pane's place, on a tablet: switched from the bar
/// over the list, and kept on this device.
class MyDayShown extends Notifier<bool> {
  @override
  bool build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(UiStateKeys.myDay, '$next'));
    return store.readString(UiStateKeys.myDay) == 'true';
  }

  void set(bool shown) => state = shown;

  void toggle() => state = !state;
}

final myDayShownProvider =
    NotifierProvider<MyDayShown, bool>(MyDayShown.new);

/// The meetings swiped off the bar over the mail, by [meetingKey], so it
/// stays away for that meeting and comes back for the next. Kept a day.
class MeetingBarDismissed extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) =>
        store.writeIds(UiStateKeys.meetingBarDismissed, next));
    final dayAgo = DateTime.now()
        .subtract(const Duration(days: 1))
        .millisecondsSinceEpoch;
    return Set.unmodifiable({
      for (final key in store.readIds(UiStateKeys.meetingBarDismissed))
        if ((int.tryParse(key.split('|').last) ?? 0) > dayAgo) key,
    });
  }

  void dismiss(CalendarEvent event) =>
      state = Set.unmodifiable({...state, meetingKey(event)});
}

final meetingBarDismissedProvider =
    NotifierProvider<MeetingBarDismissed, Set<String>>(
        MeetingBarDismissed.new);
