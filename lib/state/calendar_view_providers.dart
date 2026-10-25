import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/calendar/account_calendar.dart';
import '../data/calendar/phone_calendar.dart';
import '../data/ui_state_store.dart';
import '../domain/account.dart';
import '../domain/calendar_event.dart';
import '../domain/calendar_prefs.dart';
import '../domain/calendar_reads.dart';
import 'message_keeping.dart' show notRetried;
import 'providers.dart';

/// How the calendar shows its events.
enum CalendarViewMode {
  agenda('Agenda'),
  day('Day'),
  week('Week'),
  month('Month');

  const CalendarViewMode(this.label);
  final String label;
}

/// How many days Week shows: Outlook's Work Week and Week, and Outlook for
/// Android's three days.
enum WeekSpan {
  threeDays('3 days', '3 days'),
  workWeek('Work week', 'Work week'),
  sevenDays('Week', '7 days');

  const WeekSpan(this.label, this.choice);

  /// On the view's button.
  final String label;

  /// Where it is chosen.
  final String choice;
}

/// The accounts whose calendars the app can read: those signed in with
/// Microsoft or Google themselves.
final calendarAccountsProvider = Provider<List<Account>>((ref) => [
      for (final a in ref.watch(accountsProvider).value ?? const <Account>[])
        if (AccountCalendar.canRead(a)) a,
    ]);

/// Agenda, Day, Week or Month, as last chosen.
class CalendarView extends Notifier<CalendarViewMode> {
  @override
  CalendarViewMode build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(UiStateKeys.calendarView, next.name));
    final kept = store.readString(UiStateKeys.calendarView);
    return CalendarViewMode.values.where((m) => m.name == kept).firstOrNull ??
        CalendarViewMode.agenda;
  }

  void set(CalendarViewMode mode) => state = mode;
}

final calendarViewProvider =
    NotifierProvider<CalendarView, CalendarViewMode>(CalendarView.new);

/// What Week shows on this device, or null where it was never chosen: then
/// the screen decides, a week on a tablet and three days on a phone.
class CalendarWeekSpan extends Notifier<WeekSpan?> {
  @override
  WeekSpan? build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) =>
        store.writeString(UiStateKeys.calendarWeekSpan, next?.name));
    final kept = store.readString(UiStateKeys.calendarWeekSpan);
    return WeekSpan.values.where((s) => s.name == kept).firstOrNull;
  }

  void set(WeekSpan span) => state = span;
}

final calendarWeekSpanProvider =
    NotifierProvider<CalendarWeekSpan, WeekSpan?>(CalendarWeekSpan.new);

/// How tall an hour is drawn in Day and Week, as last pinched to.
class CalendarHourHeight extends Notifier<double> {
  static const standard = 56.0;
  static const smallest = 24.0;
  static const largest = 160.0;

  @override
  double build() {
    final kept = double.tryParse(ref
            .watch(uiStateStoreProvider)
            .readString(UiStateKeys.calendarHourHeight) ??
        '');
    return kept == null ? standard : kept.clamp(smallest, largest);
  }

  /// Kept once a pinch ends, not at every step of one.
  void set(double height) {
    state = height.clamp(smallest, largest);
    ref
        .read(uiStateStoreProvider)
        .writeString(UiStateKeys.calendarHourHeight, state.toStringAsFixed(1));
  }
}

final calendarHourHeightProvider =
    NotifierProvider<CalendarHourHeight, double>(CalendarHourHeight.new);

/// Declined meetings and the working day: Settings, Calendar.
class CalendarPrefsNotifier extends Notifier<CalendarPrefs> {
  @override
  CalendarPrefs build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(
          UiStateKeys.calendarPrefs,
          jsonEncode(next.toJson()),
        ));
    final kept = store.readString(UiStateKeys.calendarPrefs);
    return kept == null
        ? const CalendarPrefs()
        : CalendarPrefs.tryParse(kept) ?? const CalendarPrefs();
  }

  void set(CalendarPrefs prefs) => state = prefs;
}

final calendarPrefsProvider =
    NotifierProvider<CalendarPrefsNotifier, CalendarPrefs>(
        CalendarPrefsNotifier.new);

/// [events] as the views show them: a meeting you declined only where
/// [prefs] say to show those.
List<CalendarEvent> shownEvents(
  Iterable<CalendarEvent> events,
  CalendarPrefs prefs,
) =>
    [
      for (final e in events)
        if (prefs.showDeclined || !e.declined) e,
    ];

/// The accounts the calendar leaves out, by id.
class HiddenCalendars extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeIds(UiStateKeys.hiddenCalendars, next));
    return Set.unmodifiable(store.readIds(UiStateKeys.hiddenCalendars));
  }

  void setShown(String accountId, bool shown) => state = Set.unmodifiable(
        shown ? ({...state}..remove(accountId)) : {...state, accountId},
      );
}

final hiddenCalendarsProvider =
    NotifierProvider<HiddenCalendars, Set<String>>(HiddenCalendars.new);

/// From one time to another: the stretch the calendar asks the accounts for.
typedef CalendarRange = ({DateTime start, DateTime end});

/// What the shown accounts' calendars hold over a range, earliest first,
/// and what went wrong, by account, where one could not be read.
///
/// [keptAt] is when the oldest of what is shown was read, where some of it
/// is what the device kept rather than a read just made: null when every
/// account was read just now. [reading] says the accounts are still being
/// asked, with what was kept on screen meanwhile.
typedef CalendarLoad = ({
  List<CalendarEvent> events,
  Map<String, Object> problems,
  DateTime? keptAt,
  bool reading,
});

/// How long a read counts as just made: a week swiped back to, or the
/// calendar opened again, within it is not read again.
const calendarFreshFor = Duration(minutes: 1);

/// Reads kept from before this time are read again whatever their age:
/// moved on by Refresh, and by anything the app changes on a calendar.
class CalendarRefresh extends Notifier<DateTime> {
  @override
  DateTime build() => DateTime.fromMillisecondsSinceEpoch(0);

  void now() => state = DateTime.now();

  /// Reads from before [time] are read again; one made since, of what an
  /// action changed, is shown as it is.
  void since(DateTime time) => state = time;
}

final calendarRefreshProvider =
    NotifierProvider<CalendarRefresh, DateTime>(CalendarRefresh.new);

/// A change the app made to [before]: [now] is where it went, or null for
/// one taken off (or waiting out its Undo), made at [at].
typedef PendingChange = ({CalendarEvent before, CalendarEvent? now, DateTime at});

/// Changes the app has made that the calendars may not show yet, so the
/// views show them at once. Each stands only while a view still has the
/// event as it was before it, and for a couple of minutes at most: once the
/// calendar has been read again, what it says is what shows.
class CalendarPending extends Notifier<Map<String, PendingChange>> {
  @override
  Map<String, PendingChange> build() => const {};

  static String keyOf(CalendarEvent e) =>
      '${e.accountId}\u0000${e.calendarId}\u0000${e.id}';

  void hide(CalendarEvent e) => state = {
        ...state,
        keyOf(e): (before: e, now: null, at: DateTime.now()),
      };

  void moved(CalendarEvent before, CalendarEvent now) => state = {
        ...state,
        keyOf(before): (before: before, now: now, at: DateTime.now()),
      };

  /// Undone, or refused: the event shows as the calendar has it.
  void settle(CalendarEvent e) => state = {...state}..remove(keyOf(e));
}

final calendarPendingProvider =
    NotifierProvider<CalendarPending, Map<String, PendingChange>>(
        CalendarPending.new);

/// How long a change made here is shown over what a view read before it.
const pendingFor = Duration(minutes: 2);

/// [events] with what is [pending] put in: one taken off left out, one
/// moved where it went, while the event read is still as it was before.
List<CalendarEvent> withPending(
  List<CalendarEvent> events,
  Map<String, PendingChange> pending, {
  DateTime? now,
}) {
  if (pending.isEmpty) return events;
  final since = (now ?? DateTime.now()).subtract(pendingFor);
  return [
    for (final e in events)
      if (pending[CalendarPending.keyOf(e)] case final p?
          when p.before == e && p.at.isAfter(since))
        ?p.now
      else
        e,
  ];
}

/// [CalendarLoad] over a range, every shown account at once: first what the
/// device kept, at once, then each account read again unless its kept read
/// was just made. Not retried: a refusal's answer is a sign-in, which reads
/// them again.
final calendarEventsProvider = StreamProvider.autoDispose
    .family<CalendarLoad, CalendarRange>((ref, range) async* {
  final engine = ref.watch(mailEngineProvider);
  final hidden = ref.watch(hiddenCalendarsProvider);
  final notBefore = ref.watch(calendarRefreshProvider);
  final accounts = [
    for (final a in ref.watch(calendarAccountsProvider))
      if (!hidden.contains(a.id)) a,
  ];
  final kept = <String, KeptCalendar>{};
  await Future.wait([
    for (final a in accounts)
      engine.keptCalendarEvents(a.id, range.start, range.end).then(
        (k) {
          kept[a.id] = k;
        },
        onError: (Object e) =>
            debugPrint('[myemail] kept calendar not read: $e'),
      ),
  ]);
  final now = DateTime.now();
  bool fresh(KeptCalendar? k) {
    final at = k?.readAt;
    return at != null &&
        !at.isBefore(notBefore) &&
        now.difference(at) < calendarFreshFor;
  }

  CalendarLoad load(
    Map<String, List<CalendarEvent>> read,
    Map<String, Object> problems, {
    required bool reading,
  }) {
    final events = <CalendarEvent>[];
    DateTime? keptAt;
    for (final a in accounts) {
      final readNow = read[a.id];
      if (readNow != null) {
        events.addAll(readNow);
        continue;
      }
      final k = kept[a.id];
      if (k == null) continue;
      events.addAll(k.events);
      final at = k.readAt;
      if (at != null && !fresh(k) && (keptAt == null || at.isBefore(keptAt))) {
        keptAt = at;
      }
    }
    events.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.end.compareTo(b.end);
    });
    return (
      events: events,
      problems: problems,
      keptAt: keptAt,
      reading: reading,
    );
  }

  final toRead = [
    for (final a in accounts)
      if (!fresh(kept[a.id])) a,
  ];
  if (toRead.isEmpty) {
    yield load(const {}, const {}, reading: false);
    return;
  }
  yield load(const {}, const {}, reading: true);
  final read = <String, List<CalendarEvent>>{};
  final problems = <String, Object>{};
  await Future.wait([
    for (final a in toRead)
      engine.calendarEvents(a.id, range.start, range.end).then(
        (events) {
          read[a.id] = events;
        },
        onError: (Object e) {
          problems[a.id] = e;
        },
      ),
  ]);
  yield load(read, problems, reading: false);
}, retry: notRetried);

/// The phone's own calendar, through the phone_calendar plugin; a fake in
/// tests.
final phoneCalendarProvider =
    Provider<PhoneCalendar>((ref) => const AndroidPhoneCalendar());

/// The accounts whose calendars are in the phone's calendar, by id: read
/// by the background worker as well (UiStateKeys.phoneCalendars).
class PhoneCalendars extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeIds(UiStateKeys.phoneCalendars, next));
    return Set.unmodifiable(store.readIds(UiStateKeys.phoneCalendars));
  }

  void setShown(String accountId, bool shown) => state = Set.unmodifiable(
        shown ? {...state, accountId} : ({...state}..remove(accountId)),
      );
}

final phoneCalendarsProvider =
    NotifierProvider<PhoneCalendars, Set<String>>(PhoneCalendars.new);
