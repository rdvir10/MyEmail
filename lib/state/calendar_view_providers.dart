import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/calendar/account_calendar.dart';
import '../data/calendar/phone_calendar.dart';
import '../data/ui_state_store.dart';
import '../domain/account.dart';
import '../domain/calendar_event.dart';
import 'message_keeping.dart' show notRetried;
import 'providers.dart';

/// How the calendar shows its events.
enum CalendarViewMode {
  agenda('Agenda'),
  day('Day'),
  week('Week');

  const CalendarViewMode(this.label);
  final String label;
}

/// The accounts whose calendars the app can read: those signed in with
/// Microsoft or Google themselves.
final calendarAccountsProvider = Provider<List<Account>>((ref) => [
      for (final a in ref.watch(accountsProvider).value ?? const <Account>[])
        if (AccountCalendar.canRead(a)) a,
    ]);

/// Agenda, Day or Week, as last chosen.
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
typedef CalendarLoad = ({
  List<CalendarEvent> events,
  Map<String, Object> problems,
});

/// [CalendarLoad] over a range, every shown account asked at once. Not
/// retried: a refusal's answer is a sign-in, which reads them again.
final calendarEventsProvider = FutureProvider.autoDispose
    .family<CalendarLoad, CalendarRange>((ref, range) async {
  final engine = ref.watch(mailEngineProvider);
  final hidden = ref.watch(hiddenCalendarsProvider);
  final accounts = [
    for (final a in ref.watch(calendarAccountsProvider))
      if (!hidden.contains(a.id)) a,
  ];
  final events = <CalendarEvent>[];
  final problems = <String, Object>{};
  await Future.wait([
    for (final a in accounts)
      engine.calendarEvents(a.id, range.start, range.end).then(
            events.addAll,
            onError: (Object e) => problems[a.id] = e,
          ),
  ]);
  events.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.end.compareTo(b.end);
  });
  return (events: events, problems: problems);
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
