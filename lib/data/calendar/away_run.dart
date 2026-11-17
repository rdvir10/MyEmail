import 'dart:async' show TimeoutException;

import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/away.dart';
import '../../domain/calendar_event.dart';
import '../../domain/calendar_invite.dart' show InviteResponse;
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/meeting.dart' show MeetingDraft;
import '../mail_engine.dart';
import 'calendar_not_taken.dart';

/// One thing on Away's list (calendar idea #53): the days blocked on one
/// account's calendar, or one meeting declined or cancelled. Where it has
/// got to is kept on it, so a press of the button after one that left
/// some not done does only those.
class AwayItem {
  AwayItem.block(MeetingDraft this.draft)
      : action = AwayAction.block,
        accountId = draft.accountId,
        event = null,
        quiet = false,
        copies = const [];

  /// [event] declined as Ron chooses, and the same meeting on his other
  /// accounts, [copies], each declined without a word once it has gone:
  /// its organiser gets one decline (see `awaySameMeetings`).
  AwayItem.decline(
    CalendarEvent this.event, {
    List<CalendarEvent> copies = const [],
  })  : action = AwayAction.decline,
        accountId = event.accountId,
        draft = null,
        quiet = false,
        copies = [for (final c in copies) AwayItem._copy(c)];

  AwayItem._copy(CalendarEvent this.event)
      : action = AwayAction.decline,
        accountId = event.accountId,
        draft = null,
        quiet = true,
        copies = const [];

  AwayItem.cancel(CalendarEvent this.event)
      : action = AwayAction.cancel,
        accountId = event.accountId,
        draft = null,
        quiet = false,
        copies = const [];

  final AwayAction action;
  final String accountId;

  /// The meeting, for a decline or a cancellation: one meeting, of a
  /// series or not, as the calendar listed it for the days.
  CalendarEvent? event;

  /// The event that blocks the days, for a block.
  final MeetingDraft? draft;

  /// The same meeting on Ron's other accounts, declined after this one
  /// without a word to its organiser.
  final List<AwayItem> copies;

  /// One of [copies]: declined telling nobody once another copy of the
  /// meeting has been declined as Ron chose; the one declined as he chose
  /// where every copy before it was gone first (see [lead]).
  final bool quiet;

  AwayState state = AwayState.waiting;

  /// Why it did not go, where it did not.
  String? problem;

  /// Its last try had no answer (the connection, or the server, gave
  /// none), as against a refusal: it may have gone.
  bool unanswered = false;

  /// Some try of it had no answer, and may have gone: found gone from its
  /// calendar after that, it was sent ([AwayState.sentGone]). Never set by
  /// a refusal, after which nothing was ([AwayState.gone]).
  bool mayHaveGone = false;

  String get key => switch (action) {
        AwayAction.block => 'block\u0000$accountId',
        _ => awayKey(event!),
      };

  /// Whether a press would do something for it: it, or one of its
  /// [copies], is neither done nor gone.
  bool get open => [this, ...copies].any((m) => m._open);

  bool get _open => state == AwayState.waiting || state == AwayState.failed;

  bool get _went => state == AwayState.done || state == AwayState.sentGone;

  /// Of this meeting and its [copies], the one declined as Ron chose: the
  /// first not gone from its calendar before anything was sent for it. The
  /// rest after it are declined without a word.
  AwayItem get lead => [this, ...copies]
      .firstWhere((m) => m.state != AwayState.gone, orElse: () => this);

  /// Where it has got to as its row counts it: as its [lead] has, so a
  /// meeting declined on one account and not yet on another went (its
  /// organiser has the decline), with what is left said on the row.
  AwayState get shown => lead.state;

  /// The copies, after the [lead] went, not yet declined: refused, or
  /// with no answer.
  List<AwayItem> get notYet => lead._went
      ? [
          for (final m in [this, ...copies])
            if (m.state == AwayState.failed) m,
        ]
      : const [];

  /// Its [lead] went already: all a press does for it now is a copy,
  /// telling nobody.
  bool get onlyCopiesLeft => lead._went && open;
}

/// Doing what Away's list has ticked, one thing at a time, through the
/// account's own calendar as the meeting's sheet does it: a decline as
/// Decline answers one meeting, a cancellation as Cancel meeting cancels
/// one, telling everyone on it. Only ever the meeting listed: never its
/// series, whatever it is one of.
class AwayRun {
  AwayRun(this._engine);

  final MailEngine _engine;

  /// Does [items] in order, each once: those [AwayItem.open], and none
  /// done or gone. A decline goes with [note] where [tell] says the
  /// organiser is told, and without a word to them otherwise; a
  /// cancellation always tells everyone on it, with [note] where the
  /// calendar sends one (Microsoft's). [changed] after each step, for the
  /// screen, with how many of [items] are through.
  ///
  /// One that failed before is first looked for again on its calendar,
  /// read afresh for [first] to [last]: one no longer there, or declined
  /// already, is not sent again (its answer may have gone with only the
  /// reply lost); where the calendar cannot be read just now, it is not
  /// tried, and says so. One that fails now leaves the rest to go on.
  Future<void> go(
    List<AwayItem> items, {
    required DateTime first,
    required DateTime last,
    String note = '',
    bool tell = true,
    void Function(int through)? changed,
  }) async {
    var through = 0;
    final todo = [
      for (final i in items)
        if (i.open) i,
    ];
    final held = await _lookAgain(
      [
        for (final i in todo)
          for (final one in [i, ...i.copies])
            if (one.state == AwayState.failed && one.action != AwayAction.block)
              one,
      ],
      first: first,
      last: last,
    );
    changed?.call(through);
    for (final item in todo) {
      // The copy declined as Ron chose; the rest go without a word once it
      // has. Where it was gone from its calendar before anything was sent,
      // the next copy is declined as he chose instead.
      var lead = item;
      for (final one in [item, ...item.copies]) {
        if (one != lead) {
          if (lead.state == AwayState.gone) {
            lead = one;
          } else if (!lead._went) {
            break;
          }
        }
        if (!one._open || held.contains(one)) continue;
        await _try(one, note: note, tell: tell && one == lead, changed: () {
          changed?.call(through);
        });
      }
      changed?.call(++through);
    }
    // In the log, for a look over adb at what a press did.
    int count(AwayState s) => todo.where((i) => i.state == s).length;
    debugPrint('[myemail] away: ${count(AwayState.done)} went, '
        '${count(AwayState.failed)} did not, ${count(AwayState.gone)} gone, '
        '${count(AwayState.sentGone)} sent with no answer and now gone');
  }

  /// [item] tried once, where it has got to kept on it.
  Future<void> _try(
    AwayItem item, {
    required String note,
    required bool tell,
    required void Function() changed,
  }) async {
    item
      ..state = AwayState.going
      ..problem = null;
    changed();
    try {
      await _do(item, note: note, tell: tell);
      item.state = AwayState.done;
    } on EventGone {
      // Before anything went: a decline Exchange answers 404, or a
      // cancellation whose meeting the look first found gone.
      item.state = AwayState.gone;
    } on _NothingSent catch (e) {
      debugPrint('[myemail] away: ${item.action.name} not sent: ${e.cause}');
      item
        ..state = AwayState.failed
        ..unanswered = false
        ..problem = _why(e.cause);
    } catch (e) {
      debugPrint('[myemail] away: ${item.action.name} did not go: $e');
      final none = _noAnswer(e);
      item
        ..state = AwayState.failed
        ..unanswered = none
        ..mayHaveGone = item.mayHaveGone || none
        ..problem = _why(e);
    }
    changed();
  }

  /// Whether [e] leaves it open that the request was carried out: no
  /// answer came (a connection lost, a timeout, a server in trouble), as
  /// against a refusal, after which nothing was done.
  static bool _noAnswer(Object e) => switch (e) {
        // An answer came, and it was no (or "not now"): nothing was done.
        CalendarNotTaken() => false,
        ConnectionFailed() || TimeoutException() => true,
        ReadableError() || ArgumentError() || StateError() => false,
        // Anything else came from below the engine's own words: the socket.
        _ => true,
      };

  Future<void> _do(
    AwayItem item, {
    required String note,
    required bool tell,
  }) async {
    switch (item.action) {
      case AwayAction.block:
        await _engine.createMeeting(item.draft!);
      case AwayAction.decline:
        final event = _oneMeeting(item.event!);
        // A copy after the one declined as Ron chose goes telling nobody:
        // its organiser has had one ([tell] is false for it).
        await _engine.respondToEvent(
          event,
          InviteResponse.declined,
          note: tell ? note.trim() : '',
          send: tell,
          wholeSeries: false,
        );
      case AwayAction.cancel:
        final event = _oneMeeting(item.event!);
        // Looked for first: a meeting gone already is answered "done" by
        // both calendars (Graph's 404, Google's 410), and the screen would
        // say Cancelled for a cancellation that never went.
        try {
          await _engine.eventNotes(event);
        } on EventGone {
          rethrow;
        } catch (e) {
          throw _NothingSent(e);
        }
        await _engine.cancelEvent(event, note: note.trim(), wholeSeries: false);
    }
  }

  /// [event] as it may be answered or cancelled here: one meeting, never
  /// a series itself.
  static CalendarEvent _oneMeeting(CalendarEvent event) {
    if (event.seriesId != null && event.id == event.seriesId) {
      throw ArgumentError('A whole series is never answered from here.');
    }
    return event;
  }

  /// [failed], each looked for again on its calendar, read afresh for the
  /// days. Gone, or already as the press wanted it: done with, and
  /// nothing more is sent. Still there as it was: left to be tried again,
  /// as the calendar has it now. Those whose calendar could not be read
  /// are handed back, not to be tried this time.
  Future<Set<AwayItem>> _lookAgain(
    List<AwayItem> failed, {
    required DateTime first,
    required DateTime last,
  }) async {
    final held = <AwayItem>{};
    if (failed.isEmpty) return held;
    final from = DateTime(first.year, first.month, first.day);
    final to = DateTime(last.year, last.month, last.day + 1);
    final accounts = {for (final i in failed) i.accountId};
    final read = <String, List<CalendarEvent>>{};
    final unread = <String, Object>{};
    await Future.wait([
      for (final a in accounts)
        _engine.calendarEvents(a, from, to).then(
          (events) {
            read[a] = events;
          },
          onError: (Object e) {
            unread[a] = e;
          },
        ),
    ]);
    for (final item in failed) {
      final events = read[item.accountId];
      if (events == null) {
        item.problem = 'Not tried again: its calendar could not be read to '
            'see whether it went (${_why(unread[item.accountId]!)}).';
        held.add(item);
        continue;
      }
      final was = item.event!;
      final now = events
          .where((e) => e.id == was.id && e.calendarId == was.calendarId)
          .firstOrNull;
      if (now == null || now.cancelled) {
        // Gone after a try with no answer: that try went. After a refusal,
        // nothing did.
        item.state =
            item.mayHaveGone ? AwayState.sentGone : AwayState.gone;
      } else if (item.action == AwayAction.decline && now.declined) {
        item.state = AwayState.done;
      } else {
        item.event = now;
      }
    }
    return held;
  }

  static String _why(Object e) => switch (e) {
        _NothingSent(:final cause) => _why(cause),
        ReadableError(:final message) => message,
        ArgumentError(:final message) => '$message',
        _ => '$e',
      };
}

/// A step before the request itself failed: nothing was sent.
class _NothingSent implements Exception {
  const _NothingSent(this.cause);

  final Object cause;
}
