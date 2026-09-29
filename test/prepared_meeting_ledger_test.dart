import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/meeting.dart';
import 'package:myemail/state/meeting_providers.dart';

/// A calendar that cannot be reached for [failing]: its undo says it could
/// not be done, or with [throws], throws, though the real engines promise
/// never to. Every undo asked for is still written down first, so a test
/// sees the ones after it were asked too.
class _FailingEngine extends SampleMailEngine {
  _FailingEngine(this.failing, {this.throws = false});

  final Set<String> failing;
  final bool throws;

  @override
  Future<bool> discardPreparedMeeting(PreparedMeeting prepared) async {
    await super.discardPreparedMeeting(prepared);
    if (!failing.contains(prepared.eventId)) return true;
    if (throws) {
      throw const ConnectionFailed('The calendar could not be reached.');
    }
    return false;
  }
}

/// A calendar whose undo waits to be let go, so something can happen while
/// it is on the wire.
class _SlowEngine extends SampleMailEngine {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<bool> discardPreparedMeeting(PreparedMeeting prepared) async {
    await _gate.future;
    return super.discardPreparedMeeting(prepared);
  }
}

/// A store that says how often it was asked to read again.
class _CountingStore extends MemoryUiStateStore {
  var reloads = 0;

  @override
  Future<void> reload() async => reloads++;
}

/// Online meetings made ahead of Send: what is kept of one on the device,
/// and how the next start clears away those a closed screen left on the
/// calendar.
void main() {
  late MemoryUiStateStore store;
  late DateTime now;
  late PreparedMeetingLedger ledger;

  /// The same device's ledger as an earlier run of the app kept it: another
  /// process, since the app was closed.
  late PreparedMeetingLedger earlier;

  setUp(() {
    store = MemoryUiStateStore();
    now = DateTime(2026, 9, 29, 10);
    ledger = PreparedMeetingLedger(store, now: () => now, processId: 2);
    earlier = PreparedMeetingLedger(store, now: () => now, processId: 1);
  });

  PreparedMeeting teams(String eventId, {String accountId = 'acct-ms'}) =>
      PreparedMeeting(
        accountId: accountId,
        kind: OnlineMeetingKind.teams,
        eventId: eventId,
        joinUrl: 'https://teams.microsoft.com/l/meetup-join/$eventId',
        inviteText: 'Microsoft Teams meeting\n'
            'Join the meeting now\n'
            'Meeting ID: 244 810 212 347',
        bodyHtml: '<html><body>Microsoft Teams meeting</body></html>',
      );

  // Google Meet on a Microsoft account: a link, with no event anywhere.
  const linkAlone = PreparedMeeting(
    accountId: 'acct-ms',
    kind: OnlineMeetingKind.googleMeet,
    joinUrl: 'https://meet.google.com/abc-defg-hij',
    inviteText: 'Join with Google Meet: https://meet.google.com/abc-defg-hij',
  );

  List<String?> kept() => [for (final e in ledger.read()) e.meeting.eventId];

  /// What the ledger would find after a run that wrote [raw].
  Future<void> stored(Object raw) => store.writeString(
        UiStateKeys.preparedMeetings,
        raw is String ? raw : jsonEncode(raw),
      );

  /// The ledger says why it could not delete one; the tests read it or
  /// keep it off the output.
  List<String> quietLog() {
    final logged = <String>[];
    final was = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        logged.add(message ?? '');
    addTearDown(() => debugPrint = was);
    return logged;
  }

  group('PreparedMeeting as kept on the device', () {
    test('what is kept finds it again, and nothing of what it said', () {
      // The invite text and Exchange's body carry the meeting's passcode
      // and whatever was typed; deleting the event needs neither.
      final made = teams('evt-1');

      final encoded = jsonEncode(made.toJson());
      final back = PreparedMeeting.fromJson(jsonDecode(encoded))!;

      expect(back.accountId, 'acct-ms');
      expect(back.kind, OnlineMeetingKind.teams);
      expect(back.eventId, 'evt-1');
      expect(back.joinUrl, 'https://teams.microsoft.com/l/meetup-join/evt-1');
      expect(back.inviteText, '');
      expect(back.bodyHtml, isNull);
      expect(made.toJson().keys,
          unorderedEquals(['accountId', 'kind', 'eventId', 'joinUrl']));
      expect(encoded, isNot(contains('Meeting ID')));
      expect(encoded, isNot(contains('<html>')));
    });

    test('a link with no event is kept with no event id, not an empty one',
        () {
      expect(linkAlone.toJson().containsKey('eventId'), isFalse);

      final back = PreparedMeeting.fromJson(
          jsonDecode(jsonEncode(linkAlone.toJson())))!;

      expect(back.eventId, isNull);
      expect(back.kind, OnlineMeetingKind.googleMeet);
      expect(back.joinUrl, 'https://meet.google.com/abc-defg-hij');
    });

    test('anything toJson did not write reads as nothing', () {
      const whole = {
        'accountId': 'acct-ms',
        'kind': 'teams',
        'eventId': 'evt-1',
        'joinUrl': 'https://teams.microsoft.com/l/meetup-join/evt-1',
      };
      for (final json in <Object?>[
        null,
        'evt-1',
        42,
        ['acct-ms', 'teams'],
        <String, Object?>{},
        {...whole}..remove('accountId'),
        {...whole}..remove('kind'),
        {...whole}..remove('joinUrl'),
        {...whole, 'kind': 'zoom'},
        {...whole, 'accountId': 7},
        {...whole, 'joinUrl': null},
      ]) {
        expect(PreparedMeeting.fromJson(json), isNull, reason: '$json');
      }
      expect(PreparedMeeting.fromJson(whole)?.eventId, 'evt-1');
    });

    test('an event id that is not text is read as none', () {
      final back = PreparedMeeting.fromJson({
        'accountId': 'acct-ms',
        'kind': 'teams',
        'eventId': 42,
        'joinUrl': 'https://teams.microsoft.com/l/meetup-join/x',
      });

      expect(back, isNotNull);
      expect(back!.eventId, isNull);
    });
  });

  group('PreparedMeetingLedger', () {
    test('keeps a meeting made on the calendar, and when it was made',
        () async {
      await ledger.record(teams('evt-1'));

      final entry = ledger.read().single;
      expect(entry.meeting.accountId, 'acct-ms');
      expect(entry.meeting.kind, OnlineMeetingKind.teams);
      expect(entry.meeting.eventId, 'evt-1');
      expect(entry.at, now);
      expect(store.readString(UiStateKeys.preparedMeetings), isNotNull,
          reason: 'under its own key, where the next start looks');
    });

    test('a link with no event is not kept: there is nothing to delete',
        () async {
      await ledger.record(linkAlone);

      expect(ledger.read(), isEmpty);
      expect(store.readString(UiStateKeys.preparedMeetings), isNull);
    });

    test('the same event kept again is kept once, from the later time',
        () async {
      // Send forgets it before it goes and keeps it again when it did not
      // go; a second copy would have the next start deleting it twice.
      await ledger.record(teams('evt-1'));
      now = now.add(const Duration(minutes: 5));
      await ledger.record(teams('evt-1'));

      final entry = ledger.read().single;
      expect(entry.meeting.eventId, 'evt-1');
      expect(entry.at, DateTime(2026, 9, 29, 10, 5));
    });

    test('the same event id on another account is another meeting',
        () async {
      await ledger.record(teams('evt-1'));
      await ledger.record(teams('evt-1', accountId: 'acct-other'));

      expect(ledger.read().map((e) => e.meeting.accountId),
          ['acct-ms', 'acct-other']);
    });

    test('forgetting one leaves the rest', () async {
      await ledger.record(teams('evt-1'));
      await ledger.record(teams('evt-2'));

      // Found by account and event alone: what the screen forgets is the
      // meeting it made, invite text and all, and what the ledger read
      // back has none.
      await ledger.forget(PreparedMeeting.fromJson(teams('evt-1').toJson())!);

      expect(kept(), ['evt-2']);
    });

    test('forgetting the last leaves nothing stored', () async {
      await ledger.record(teams('evt-1'));

      await ledger.forget(teams('evt-1'));

      expect(ledger.read(), isEmpty);
      expect(store.readString(UiStateKeys.preparedMeetings), isNull);
    });

    test('forgetting one never kept changes nothing', () async {
      await ledger.record(teams('evt-1'));

      await ledger.forget(teams('evt-9'));
      await ledger.forget(teams('evt-1', accountId: 'acct-other'));

      expect(kept(), ['evt-1']);
    });

    group('reading what an earlier run stored', () {
      test('garbage reads as nothing kept rather than failing', () async {
        // Read at every start: a throw here would stop the clear-up, and
        // the screen's own keeping, for good.
        for (final raw in [
          '',
          'not json',
          '[{"accountId":',
          'null',
          '42',
          '"evt-1"',
          '{"accountId":"acct-ms","kind":"teams","eventId":"evt-1"}',
        ]) {
          await stored(raw);
          expect(ledger.read(), isEmpty, reason: raw);
        }
      });

      test('an entry missing what it needs is passed over, and the rest read',
          () async {
        await stored([
          1,
          'evt-0',
          null,
          <String, Object?>{},
          {'kind': 'teams', 'eventId': 'evt-2', 'joinUrl': 'https://x'},
          {'accountId': 'acct-ms', 'eventId': 'evt-3', 'joinUrl': 'https://x'},
          {
            'accountId': 'acct-ms',
            'kind': 'zoom',
            'eventId': 'evt-4',
            'joinUrl': 'https://x',
          },
          // No event: a link alone, which has nothing to delete.
          {
            'accountId': 'acct-ms',
            'kind': 'googleMeet',
            'joinUrl': 'https://x',
          },
          {
            'accountId': 'acct-ms',
            'kind': 'teams',
            'eventId': 'evt-1',
            'joinUrl': 'https://x',
            'at': DateTime(2026, 9, 29, 9).millisecondsSinceEpoch,
          },
        ]);

        final entry = ledger.read().single;
        expect(entry.meeting.eventId, 'evt-1');
        expect(entry.at, DateTime(2026, 9, 29, 9));
      });

      test('an entry with no time of its own counts as made long ago',
          () async {
        // Better deleted at the next start than kept on the calendar for
        // ever by a time nobody can read.
        await stored([
          {
            'accountId': 'acct-ms',
            'kind': 'teams',
            'eventId': 'evt-1',
            'joinUrl': 'https://x',
          },
          {
            'accountId': 'acct-ms',
            'kind': 'teams',
            'eventId': 'evt-2',
            'joinUrl': 'https://x',
            'at': 'yesterday',
          },
        ]);

        expect(ledger.read().map((e) => e.at),
            everyElement(DateTime.fromMillisecondsSinceEpoch(0)));
      });

      test('a time too far out to be a date is passed over rather than '
          'failing the read', () async {
        // Past the year 275760 DateTime refuses the number with a
        // RangeError, which the read does not catch the way it catches a
        // FormatException, so one such entry fails every record, forget
        // and start after it.
        await stored([
          {
            'accountId': 'acct-ms',
            'kind': 'teams',
            'eventId': 'evt-1',
            'joinUrl': 'https://x',
            'at': 9000000000000000,
          },
        ]);

        expect(ledger.read, returnsNormally);
        await expectLater(ledger.record(teams('evt-2')), completes);
      });
    });

    group('clearing up after an earlier run', () {
      test('deletes what an earlier run kept, however recently, and forgets '
          'it', () async {
        // Swiped away and opened again two minutes later: the event with
        // nobody on it would otherwise wait for a start ten minutes on, and
        // remind Ron of a meeting he never sent meanwhile.
        final engine = SampleMailEngine();
        await earlier.record(teams('evt-old'));
        await ledger.record(teams('evt-mine'));
        now = now.add(const Duration(minutes: 2));

        await ledger.dropLeftovers(engine);

        final discarded = engine.discardedMeetings.single;
        expect(discarded.accountId, 'acct-ms');
        expect(discarded.kind, OnlineMeetingKind.teams);
        expect(discarded.eventId, 'evt-old');
        expect(kept(), ['evt-mine']);
      });

      test('what this run kept is left alone, however old: its screen may '
          'still be open in another window', () async {
        final engine = SampleMailEngine();
        await ledger.record(teams('evt-1'));
        await ledger.record(teams('evt-2'));
        now = now.add(const Duration(hours: 2));

        await ledger.dropLeftovers(engine);

        expect(engine.discardedMeetings, isEmpty);
        expect(kept(), ['evt-1', 'evt-2']);
      });

      test('one kept before the process was, counts as an earlier run\'s',
          () async {
        final engine = SampleMailEngine();
        await stored([
          {
            'accountId': 'acct-ms',
            'kind': 'teams',
            'eventId': 'evt-1',
            'joinUrl': 'https://x',
            'at': now.millisecondsSinceEpoch,
          },
        ]);

        await ledger.dropLeftovers(engine);

        expect(engine.discardedMeetings.single.eventId, 'evt-1');
        expect(ledger.read(), isEmpty);
      });

      test('nothing kept asks nothing of the calendar', () async {
        final engine = SampleMailEngine();

        await ledger.dropLeftovers(engine);

        expect(engine.discardedMeetings, isEmpty);
      });

      test('an undo that could not be done now is kept for the next start, '
          'and the rest still undone', () async {
        // The app started offline: forgotten after one silent failure, the
        // event would have stayed on the calendar for good.
        final engine = _FailingEngine({'evt-1'});
        await earlier.record(teams('evt-1'));
        await earlier.record(teams('evt-2'));

        await ledger.dropLeftovers(engine);

        expect(engine.discardedMeetings.map((m) => m.eventId),
            ['evt-1', 'evt-2']);
        expect(kept(), ['evt-1']);
      });

      test('an undo that throws is kept too, and the rest still undone',
          () async {
        // The engines promise never to throw here; one that did anyway must
        // not stop the meetings after it being reached.
        final logged = quietLog();
        final engine = _FailingEngine({'evt-1'}, throws: true);
        await earlier.record(teams('evt-1'));
        await earlier.record(teams('evt-2'));

        await ledger.dropLeftovers(engine);

        expect(engine.discardedMeetings.map((m) => m.eventId),
            ['evt-1', 'evt-2']);
        expect(kept(), ['evt-1']);
        expect(logged.single, contains('could not be reached'));
      });

      test('one that has failed for a week is given up on', () async {
        // Kept for ever, a calendar that will never answer again (a
        // sign-in withdrawn) would be asked at every start.
        final engine = _FailingEngine({'evt-1'});
        await earlier.record(teams('evt-1'));
        now = now.add(const Duration(days: 8));

        await ledger.dropLeftovers(engine);

        expect(engine.discardedMeetings.single.eventId, 'evt-1');
        expect(ledger.read(), isEmpty);
      });

      test('a meeting kept while one is being deleted is not lost', () async {
        // The start's clear-up runs beside a screen that may keep a new
        // meeting while a delete is on the wire; forgetting the old one
        // must not write back the list as it was before that.
        final engine = _SlowEngine();
        await earlier.record(teams('evt-old'));

        final clearing = ledger.dropLeftovers(engine);
        await ledger.record(teams('evt-new'));
        engine.release();
        await clearing;

        expect(kept(), ['evt-new']);
      });

      test('a meeting another window kept since this one last looked is not '
          'written away', () async {
        // Each window holds its own copy of what is stored, read at its
        // start; the ledger reads again before it writes.
        final reloads = _CountingStore();
        final mine = PreparedMeetingLedger(reloads, now: () => now);

        await mine.record(teams('evt-1'));
        await mine.forget(teams('evt-1'));
        await mine.dropLeftovers(SampleMailEngine());

        expect(reloads.reloads, 3);
      });
    });
  });

  group('MeetingDraft ahead of Send', () {
    MeetingDraft draft({
      String accountId = 'acct-ms',
      String title = 'Q3 review',
      DateTime? start,
      DateTime? end,
      bool allDay = false,
      OnlineMeetingKind? online = OnlineMeetingKind.teams,
      PreparedMeeting? prepared,
    }) =>
        MeetingDraft(
          accountId: accountId,
          title: title,
          attendees: const [
            MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
          ],
          start: start ?? DateTime(2026, 10, 1, 9),
          end: end ?? DateTime(2026, 10, 1, 10),
          allDay: allDay,
          location: 'Room 4',
          notes: 'Bring the numbers.',
          timeZone: 'Asia/Jerusalem',
          online: online,
          prepared: prepared,
        );

    test('a meeting with no title yet is made as New meeting', () {
      expect(draft(title: '').shell.title, 'New meeting');
      expect(draft(title: '   ').shell.title, 'New meeting');
      expect(draft().shell.title, 'Q3 review');
    });

    test('ends an hour after it starts when the end is not after the start',
        () {
      // The calendars refuse an event that ends where it starts, and the
      // switch can be turned on before the times are right.
      final at = DateTime(2026, 10, 1, 9);
      expect(draft(start: at, end: at).shell.end, DateTime(2026, 10, 1, 10));
      expect(draft(start: at, end: DateTime(2026, 10, 1, 8)).shell.end,
          DateTime(2026, 10, 1, 10));
      expect(draft(start: at, end: DateTime(2026, 10, 1, 11, 30)).shell.end,
          DateTime(2026, 10, 1, 11, 30));
      expect(draft(start: at, end: at).shell.start, at);
    });

    test('a whole day keeps a valid last day, and is one day otherwise', () {
      final first = DateTime(2026, 10, 1);
      expect(
        draft(allDay: true, start: first, end: DateTime(2026, 10, 3)).shell.end,
        DateTime(2026, 10, 3),
      );
      expect(draft(allDay: true, start: first, end: first).shell.end, first,
          reason: 'one day starts and ends on the same date');
      expect(
        draft(allDay: true, start: first, end: DateTime(2026, 9, 30)).shell.end,
        first,
      );
      expect(
          draft(allDay: true, start: first, end: first).shell.allDay, isTrue);
    });

    test('has nobody on it, no notes and no location, and keeps the rest',
        () {
      // Nobody on it is what keeps it from sending an invitation; the
      // notes are the person's and go only with Send. A location typed now
      // and cleared before Send would have stayed on a Teams event.
      final shell = draft().shell;

      expect(shell.attendees, isEmpty);
      expect(shell.hasAttendees, isFalse);
      expect(shell.notes, '');
      expect(shell.accountId, 'acct-ms');
      expect(shell.location, '');
      expect(shell.timeZone, 'Asia/Jerusalem');
      expect(shell.online, OnlineMeetingKind.teams);
      expect(shell.start, DateTime(2026, 10, 1, 9));
    });

    test('is always one a calendar takes', () {
      final at = DateTime(2026, 10, 1, 9);
      for (final d in [
        draft(title: '', start: at, end: at),
        draft(title: ' ', start: at, end: at.subtract(const Duration(days: 1))),
        draft(
          allDay: true,
          start: at,
          end: at.subtract(const Duration(days: 2)),
        ),
      ]) {
        expect(d.isValid, isFalse);
        expect(d.shell.problem, isNull);
      }
    });

    test('the meeting made ahead is used only for its own account and kind',
        () {
      // From or the kind changed after it was made: Send makes its own
      // rather than sending one on another calendar, or a Teams block for a
      // Meet meeting.
      final made = teams('evt-1');

      expect(draft(prepared: made).preparedHere, same(made));
      expect(draft(accountId: 'acct-other', prepared: made).preparedHere,
          isNull);
      expect(
        draft(online: OnlineMeetingKind.googleMeet, prepared: made)
            .preparedHere,
        isNull,
      );
      expect(draft(online: null, prepared: made).preparedHere, isNull,
          reason: 'switched off: held in the room alone');
      expect(draft().preparedHere, isNull);
    });
  });
}
