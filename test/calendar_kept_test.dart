import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/calendar_reads.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart'
    show CalendarPage, calendarPage;

/// The calendar kept on the device (calendar ideas #2), and the arithmetic
/// of the views' pages (#5, #6).
void main() {
  CalendarEvent event(
    String id,
    DateTime start,
    DateTime end, {
    String title = 'Meeting',
    String accountId = 'a',
    bool allDay = false,
  }) =>
      CalendarEvent(
        id: id,
        accountId: accountId,
        title: title,
        start: start,
        end: end,
        allDay: allDay,
      );

  group('an event as kept', () {
    test('a timed event, a whole day and everyone on it come back as they '
        'went', () {
      final timed = CalendarEvent(
        id: 'm1',
        accountId: 'hadco',
        calendarId: 'team',
        title: 'Project review',
        start: DateTime(2026, 10, 27, 14),
        end: DateTime(2026, 10, 27, 15, 30),
        location: 'Room 2',
        organizer: const MailAddress(email: 'dana@hadco.example', name: 'Dana'),
        attendees: const [
          EventAttendee(MailAddress(email: 'dana@hadco.example', name: 'Dana'),
              response: EventResponse.organizer),
          EventAttendee(MailAddress(email: 'yossi@hadco.example'),
              response: EventResponse.declined, optional: true),
        ],
        joinUrl: 'https://teams.microsoft.com/l/x',
        webLink: 'https://outlook.office.com/x',
        showAs: EventShowAs.tentative,
        response: EventResponse.tentative,
        cancelled: true,
        reminderMinutes: 15,
        preview: 'Agenda attached',
      );
      expect(CalendarEvent.fromJson(timed.toJson()), timed);

      final day = event('d', DateTime(2026, 11, 2), DateTime(2026, 11, 4),
          allDay: true);
      expect(day.toJson()['start'], '2026-11-02',
          reason: 'a date, the same day wherever the phone is');
      expect(CalendarEvent.fromJson(day.toJson()), day);
      expect(CalendarEvent.fromJson(day.toJson())!.calendarId,
          CalendarEvent.mainCalendar);
    });

    test('what is not one is passed over, and what it does not know is '
        'the plain case', () {
      expect(CalendarEvent.fromJson('nonsense'), isNull);
      expect(CalendarEvent.fromJson({'id': 'x', 'accountId': 'a'}), isNull,
          reason: 'no times');
      final odd = CalendarEvent.fromJson({
        'id': 'x',
        'accountId': 'a',
        'start': '2026-10-27T10:00:00.000Z',
        'end': '2026-10-27T09:00:00.000Z',
        'showAs': 'somewhereElse',
        'response': 'shrugged',
      })!;
      expect(odd.showAs, EventShowAs.busy);
      expect(odd.response, EventResponse.none);
      expect(odd.end, odd.start, reason: 'never ends before it starts');
    });
  });

  group('which stretches were read', () {
    final at9 = DateTime(2026, 10, 25, 9), at10 = DateTime(2026, 10, 25, 10);
    CalendarRead read(int from, int to, DateTime at, [String id = '']) =>
        CalendarRead(
          calendarId: id,
          start: DateTime(2026, 10, from),
          end: DateTime(2026, 10, to),
          readAt: at,
        );

    test('a new read is what counts where it reaches; an older one keeps '
        'the rest', () {
      final reads = withRead([read(1, 31, at9)], read(10, 20, at10));
      expect(reads, [read(1, 10, at9), read(10, 20, at10), read(20, 31, at9)]);
      expect(readAtOver(reads, DateTime(2026, 10, 12), DateTime(2026, 10, 18)),
          at10);
      expect(readAtOver(reads, DateTime(2026, 10, 5), DateTime(2026, 10, 25)),
          at9, reason: 'the oldest part');
      expect(readAtOver(reads, DateTime(2026, 10, 25), DateTime(2026, 11, 3)),
          isNull, reason: 'November was never read');
      expect(
          readAtOver([read(1, 10, at9), read(12, 20, at9)],
              DateTime(2026, 10, 5), DateTime(2026, 10, 15)),
          isNull,
          reason: 'a gap');
      expect(
          readAtOver([read(1, 31, at9, 'other')], DateTime(2026, 10, 5),
              DateTime(2026, 10, 6)),
          isNull,
          reason: "another calendar's read is not this one's");
    });

    test('an answer that took longer than one asked for after it is stale',
        () {
      expect(readIsStale([read(1, 31, at10)], read(10, 20, at9)), isTrue);
      expect(readIsStale([read(1, 31, at9)], read(10, 20, at10)), isFalse);
      expect(readIsStale([read(1, 5, at10)], read(10, 20, at9)), isFalse,
          reason: 'not the same stretch');
    });

    test('what a stretch answers for: anything of it in the stretch', () {
      final from = DateTime(2026, 10, 27), to = DateTime(2026, 10, 28);
      expect(eventIsIn(event('a', DateTime(2026, 10, 26, 23), from), from, to),
          isFalse, reason: 'ends as it starts');
      expect(eventIsIn(event('b', from, from), from, to), isTrue,
          reason: 'no length, at its start');
      expect(
          eventIsIn(event('c', DateTime(2026, 10, 26), DateTime(2026, 10, 29)),
              from, to),
          isTrue);
    });
  });

  /// The one behaviour, on either store.
  Future<void> keeps(CacheStore store) async {
    final mon = DateTime(2026, 10, 26), nextMon = DateTime(2026, 11, 2);
    final at9 = DateTime(2026, 10, 25, 9), at10 = DateTime(2026, 10, 25, 10);
    await store.keepCalendar('a', mon, nextMon, [
      event('tue', DateTime(2026, 10, 27, 9), DateTime(2026, 10, 27, 10)),
      event('thu', DateTime(2026, 10, 29, 9), DateTime(2026, 10, 29, 10)),
      event('long', DateTime(2026, 10, 25, 20), DateTime(2026, 10, 26, 2)),
    ], readAt: at9);
    var kept = await store.keptCalendar('a', mon, nextMon);
    expect([for (final e in kept.events) e.id], ['long', 'tue', 'thu']);
    expect(kept.readAt, at9);

    // Thursday read again, its meeting gone and another in its place.
    final thu = DateTime(2026, 10, 29), fri = DateTime(2026, 10, 30);
    await store.keepCalendar('a', thu, fri, [
      event('thu2', DateTime(2026, 10, 29, 15), DateTime(2026, 10, 29, 16)),
    ], readAt: at10);
    kept = await store.keptCalendar('a', mon, nextMon);
    expect([for (final e in kept.events) e.id], ['long', 'tue', 'thu2']);
    expect(kept.readAt, at9, reason: "the rest of the week is 9 o'clock's");
    expect((await store.keptCalendar('a', thu, fri)).readAt, at10);

    // A slower answer to an earlier question does not undo that.
    await store.keepCalendar('a', thu, fri, [
      event('thu', DateTime(2026, 10, 29, 9), DateTime(2026, 10, 29, 10)),
    ], readAt: DateTime(2026, 10, 25, 9, 30));
    expect([for (final e in (await store.keptCalendar('a', thu, fri)).events) e.id],
        ['thu2']);

    // Beyond what was read: what there is, and no time.
    final beyond =
        await store.keptCalendar('a', DateTime(2026, 10, 29), DateTime(2026, 11, 9));
    expect(beyond.readAt, isNull);
    expect([for (final e in beyond.events) e.id], ['thu2']);
    expect((await store.keptCalendar('b', mon, nextMon)).events, isEmpty,
        reason: "another account's");

    // Another account's, kept, then gone with the account.
    await store.keepCalendar('b', mon, nextMon, [
      event('b1', DateTime(2026, 10, 27, 9), DateTime(2026, 10, 27, 10),
          accountId: 'b'),
    ], readAt: at9);
    expect((await store.keptCalendar('b', mon, nextMon)).events, hasLength(1));
    await store.deleteAccount('b');
    final gone = await store.keptCalendar('b', mon, nextMon);
    expect(gone.events, isEmpty);
    expect(gone.readAt, isNull);
    expect((await store.keptCalendar('a', mon, nextMon)).events, hasLength(3),
        reason: "the other account's stay");

    // Long gone: let go when a much later read is kept.
    await store.keepCalendar('a', DateTime(2028, 1, 1), DateTime(2028, 1, 2),
        const [], readAt: DateTime(2028, 1, 1));
    final pruned = await store.keptCalendar('a', mon, nextMon);
    expect(pruned.events, isEmpty);
    expect(pruned.readAt, isNull);
  }

  test('kept in memory', () => keeps(MemoryCacheStore()));

  test('kept in the database', () async {
    final db = MailDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await keeps(DriftCacheStore(db));
  });

  group("the calendar view's load", () {
    late _CountingEngine engine;
    late ProviderContainer c;
    late Account hadco;
    final today = DateTime.now();
    final range = (
      start: DateTime(today.year, today.month, today.day),
      end: DateTime(today.year, today.month, today.day + 7),
    );

    setUp(() async {
      engine = _CountingEngine();
      hadco = await engine.addOAuthAccount(
        displayName: 'Hadco',
        emailAddress: 'ron@hadco.example',
        provider: MailProvider.outlook,
        token: OAuthToken(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.utc(2030),
        ),
      );
      engine.events[hadco.id] = [
        event('m1', range.start.add(const Duration(days: 1, hours: 9)),
            range.start.add(const Duration(days: 1, hours: 10)),
            accountId: hadco.id, title: 'Read'),
      ];
      c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      await c.read(accountsProvider.future);
    });

    /// Every load the range gives until it stops reading.
    Future<List<CalendarLoad>> loads() async {
      final seen = <CalendarLoad>[];
      final done = Completer<void>();
      final sub = c.listen(calendarEventsProvider(range), (_, next) {
        // A rebuild still carries the last value: not this one's.
        if (next.isLoading) return;
        final v = next.value;
        if (v == null) return;
        seen.add(v);
        if (!v.reading && !done.isCompleted) done.complete();
      }, fireImmediately: true);
      try {
        await done.future.timeout(const Duration(seconds: 5));
      } finally {
        sub.close();
      }
      return seen;
    }

    test('read, then kept: opened again within a minute it is not read '
        'again, and Refresh reads it', () async {
      final first = await loads();
      expect(first.first.reading, isTrue, reason: 'what was kept, first');
      expect(first.last.events.single.title, 'Read');
      expect(first.last.keptAt, isNull, reason: 'read just now');
      expect(engine.reads, 1);

      c.invalidate(calendarEventsProvider(range));
      final again = await loads();
      expect(again.single.events.single.title, 'Read');
      expect(again.single.reading, isFalse);
      expect(engine.reads, 1, reason: 'just read');

      c.read(calendarRefreshProvider.notifier).now();
      final refreshed = await loads();
      expect(refreshed.last.events.single.title, 'Read');
      expect(engine.reads, 2);
    });

    test('a calendar that cannot be read shows what was kept, and when it '
        'was read', () async {
      await loads();
      engine.calendarRefusals[hadco.id] =
          const ConnectionFailed('No connection.');
      c.read(calendarRefreshProvider.notifier).now();
      final last = (await loads()).last;
      expect(last.events.single.title, 'Read');
      expect(last.problems[hadco.id], isA<ConnectionFailed>());
      expect(last.keptAt, isNotNull);
    });

    test('a declined meeting is shown only where the prefs say so', () {
      final declined = CalendarEvent(
        id: 'no',
        accountId: 'a',
        title: 'No',
        start: DateTime(2026, 10, 27, 9),
        end: DateTime(2026, 10, 27, 10),
        response: EventResponse.declined,
      );
      final going = event('yes', DateTime(2026, 10, 27, 9),
          DateTime(2026, 10, 27, 10));
      expect(shownEvents([declined, going], const CalendarPrefs()), [going]);
      expect(
          shownEvents(
              [declined, going], const CalendarPrefs(showDeclined: true)),
          [declined, going]);
    });
  });

  group('the prefs', () {
    test('kept as text and read back; a day never ends before it starts',
        () {
      const prefs = CalendarPrefs(showDeclined: true, dayStart: 8, dayEnd: 18);
      expect(CalendarPrefs.fromJson(prefs.toJson()), prefs);
      expect(CalendarPrefs.tryParse('nonsense'), isNull);
      expect(CalendarPrefs.fromJson({'dayStart': 20, 'dayEnd': 9}),
          const CalendarPrefs(), reason: 'out of order: the defaults');
      expect(prefs.copyWith(dayStart: 19).dayEnd, 20,
          reason: 'the end gives way');
    });
  });

  group('the pages', () {
    const monFri = {1, 2, 3, 4, 5};
    const sunThu = {7, 1, 2, 3, 4};
    final wed = DateTime(2026, 10, 28);
    List<int> days(CalendarPage p) => [for (final d in p.days) d.day];

    test('Week: the work week alone, the whole week, or three days at a '
        'time', () {
      final work = calendarPage(
          CalendarViewMode.week, WeekSpan.workWeek, monFri, wed, 0);
      expect(days(work), [26, 27, 28, 29, 30]);
      expect(work.range.end, DateTime(2026, 10, 31));
      expect(
          days(calendarPage(
              CalendarViewMode.week, WeekSpan.workWeek, sunThu, wed, 0)),
          [25, 26, 27, 28, 29]);
      expect(
          days(calendarPage(
              CalendarViewMode.week, WeekSpan.sevenDays, monFri, wed, 0)),
          [26, 27, 28, 29, 30, 31, 1]);
      expect(
          days(calendarPage(
              CalendarViewMode.week, WeekSpan.workWeek, monFri, wed, 1)),
          [2, 3, 4, 5, 6]);
      expect(
          days(calendarPage(
              CalendarViewMode.week, WeekSpan.threeDays, monFri, wed, 1)),
          [31, 1, 2]);
    });

    test('Month: every week its days touch, from the week start', () {
      final october = calendarPage(
          CalendarViewMode.month, WeekSpan.sevenDays, monFri, wed, 0);
      expect(october.month, DateTime(2026, 10));
      expect(october.days.first, DateTime(2026, 9, 28));
      expect(october.days.length, 35);
      expect(october.range.end, DateTime(2026, 11, 2));
      final november = calendarPage(
          CalendarViewMode.month, WeekSpan.sevenDays, monFri, wed, 1);
      expect(november.month, DateTime(2026, 11));
      expect(november.days.first, DateTime(2026, 10, 26));
    });
  });
}

/// The sample engine, counting its reads of a calendar.
class _CountingEngine extends SampleMailEngine {
  int reads = 0;

  @override
  Future<List<CalendarEvent>> calendarEvents(
    String accountId,
    DateTime start,
    DateTime end,
  ) {
    reads++;
    return super.calendarEvents(accountId, start, end);
  }
}
