import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/calendar/calendar_upkeep.dart';
import '../data/ui_state_store.dart';
import '../domain/calendar_event.dart';
import '../domain/meeting_alerts.dart';
import 'calendar_view_providers.dart'
    show
        CalendarRange,
        calendarReadAgainProvider,
        internetCalendarReaderProvider;
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

  /// Meeting mail has arrived in [accountId] while the app is open: its
  /// calendar read again at once, so a meeting moved or called off is
  /// moved or called off here too (calendar idea #74).
  void meetingMail(String accountId);
}

/// Does nothing: the default, for the tests and the browser preview, which
/// have no notifications to set. main() sets [AppCalendarKeeper] on
/// Android.
class NoCalendarKeeper implements CalendarKeeper {
  const NoCalendarKeeper();

  @override
  Future<void> keepUp({bool now = false}) async {}

  @override
  void meetingMail(String accountId) {}
}

/// The app's: [keepCalendarUpIfDue] with the app's own engine, notifier
/// and home screen, one run at a time.
class AppCalendarKeeper implements CalendarKeeper {
  AppCalendarKeeper(this._ref) {
    _ref.onDispose(_meetingMail.dispose);
  }

  final Ref _ref;
  Future<void>? _running;
  bool _again = false;

  /// Accounts whose meeting mail came while a run was going, which may
  /// have read their calendars before it: read once more after.
  final Set<String> _readAfter = {};

  late final MeetingMailReads _meetingMail = MeetingMailReads(
    (accountId) => unawaited(_keepUp(meetingMail: {accountId})),
  );

  @override
  Future<void> keepUp({bool now = false}) => _keepUp(now: now);

  @override
  void meetingMail(String accountId) => _meetingMail.arrived(accountId);

  Future<void> _keepUp({
    bool now = false,
    Set<String> meetingMail = const {},
  }) {
    final running = _running;
    if (running != null) {
      // Something changed while it ran: once more after, with that in.
      if (now) _again = true;
      _readAfter.addAll(meetingMail);
      return running;
    }
    return _running = _run(now, meetingMail).whenComplete(() {
      _running = null;
      final again = _again;
      final readAfter = {..._readAfter};
      _again = false;
      _readAfter.clear();
      if (again || readAfter.isNotEmpty) {
        unawaited(_keepUp(now: again, meetingMail: readAfter));
      }
    });
  }

  Future<void> _run(bool now, Set<String> meetingMail) async {
    final uiState = _ref.read(uiStateStoreProvider);
    // The clock as the phone has it, for what the background writes.
    await uiState.writeString(
      UiStateKeys.clock24h,
      '${PlatformDispatcher.instance.alwaysUse24HourFormat}',
    );
    // The pictures at the side of notifications, a calendar or the app's
    // mark on each account's colour, while there is a screen to draw them
    // on. Here, on every start, resume and minute in front, not left to
    // the upkeep below: that runs in the app only when the quarter hour
    // falls to it, and the background, which cannot draw, usually takes
    // the turn. Once drawn they are found at no cost.
    try {
      final accounts = await _ref.read(mailEngineProvider).loadAccounts();
      await _ref
          .read(mailNotifierProvider)
          .prepareBadges([for (final a in accounts) a.colorValue]);
    } catch (e) {
      debugPrint('[myemail] notification pictures not prepared: $e');
    }
    await keepCalendarUpIfDue(
      _ref.read(mailEngineProvider),
      uiState,
      _ref.read(mailNotifierProvider),
      _ref.read(homeScreenSurfaceProvider),
      links: _ref.read(internetCalendarReaderProvider),
      force: now,
      meetingMail: meetingMail,
    );
    // Read, and kept: the calendar screens open show it. Once a minute at
    // most, as these reads come.
    if (meetingMail.isNotEmpty) {
      _ref.read(calendarReadAgainProvider.notifier).readAgain(meetingMail);
    }
  }
}

/// Meeting mail arriving while the app is open (calendar idea #74): each
/// account's calendar read for it at once, then at most once every
/// [every] however much more comes. What comes inside that time is read
/// for once as it is up, so the last change is had too.
class MeetingMailReads {
  MeetingMailReads(
    this._read, {
    this.every = const Duration(minutes: 1),
    DateTime Function()? clock,
    Timer Function(Duration wait, void Function() then)? timer,
  })  : _clock = clock ?? DateTime.now,
        _timer = timer ?? Timer.new;

  final void Function(String accountId) _read;
  final Duration every;
  final DateTime Function() _clock;
  final Timer Function(Duration wait, void Function() then) _timer;

  /// When each account's calendar was last read for its meeting mail.
  final Map<String, DateTime> _readAt = {};

  /// A read waiting for an account's time to be up.
  final Map<String, Timer> _waiting = {};

  void arrived(String accountId) {
    if (_waiting.containsKey(accountId)) return;
    final now = _clock();
    final last = _readAt[accountId];
    final wait = last == null || now.isBefore(last)
        ? Duration.zero
        : every - now.difference(last);
    if (wait <= Duration.zero) {
      _readNow(accountId);
      return;
    }
    _waiting[accountId] = _timer(wait, () {
      _waiting.remove(accountId);
      _readNow(accountId);
    });
  }

  void _readNow(String accountId) {
    _readAt[accountId] = _clock();
    _read(accountId);
  }

  /// Nothing waiting is read: the app has gone.
  void dispose() {
    for (final waiting in _waiting.values) {
      waiting.cancel();
    }
    _waiting.clear();
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
