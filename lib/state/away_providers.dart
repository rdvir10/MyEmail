import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/calendar/away_run.dart';
import '../domain/account.dart';
import '../domain/away.dart';
import '../domain/calendar_event.dart';
import 'calendar_view_providers.dart' show calendarRefreshProvider;
import 'providers.dart' show mailEngineProvider;

/// I am away's list for some days (calendar idea #53): what was read for
/// them, what is ticked, and where each has got to. The screen shows one;
/// a press of its button is held by [awayPressProvider], which outlives
/// the screen, so the press goes on to its end, and its list stays what
/// any Away screen opened meanwhile shows.
class AwayPress extends ChangeNotifier {
  AwayPress({required this.first, required this.last});

  /// The first and the last day away, at midnight.
  DateTime first;
  DateTime last;

  /// Read, and each one done or tried: the days stay as they are.
  bool reading = true;
  bool running = false;
  bool pressed = false;

  /// How far a press has got: [through] of [of].
  int through = 0;
  int of = 0;

  /// The calendar accounts, in Ron's order.
  List<Account> accounts = const [];
  List<AwayItem> blocks = const [];
  List<AwayItem> invited = const [];
  List<AwayItem> own = const [];
  final Set<AwayItem> ticked = {};

  /// Where a calendar already has the days out of office, by account.
  Map<String, CalendarEvent> blockedAlready = const {};

  /// An account whose calendar could not be read for the days, and why.
  Map<String, Object> unread = const {};

  /// The key each calendar's block goes with from this list, so a block
  /// sent again is the one event (see [awayBlock]).
  final Map<String, String> blockKeys = {};

  /// Which read is the latest, where the days changed while one went on.
  int reads = 0;

  bool tell = true;
  String note = '';

  void changed() => notifyListeners();

  List<AwayItem> get all => [...blocks, ...invited, ...own];

  /// What a press would do now: ticked, and not done or gone.
  List<AwayItem> get toDo => [
        for (final i in all)
          if (i.open && ticked.contains(i)) i,
      ];

  /// A press has left some that did not go: the screen keeps them shown.
  bool get leftUndone => all.any((i) => i.state == AwayState.failed);
}

/// The press going now, one at a time (#53). Away opened while it goes
/// shows it rather than a list of its own, and nothing can be pressed
/// again until it ends; at its end the calendar views and MyEmail's
/// reminders are read again, whether or not any screen is still there.
class AwayPresses extends Notifier<AwayPress?> {
  @override
  AwayPress? build() => null;

  /// [press]'s ticked ones, each once (see [AwayRun]), unless a press is
  /// going already: then nothing, and false.
  Future<bool> go(AwayPress press) async {
    if (state != null || press.running) return false;
    final todo = press.toDo;
    if (todo.isEmpty) return false;
    state = press;
    press
      ..running = true
      ..pressed = true
      ..through = 0
      ..of = todo.length
      ..changed();
    try {
      await AwayRun(ref.read(mailEngineProvider)).go(
        todo,
        first: press.first,
        last: press.last,
        note: press.note,
        tell: press.tell,
        changed: (through) {
          press
            ..through = through
            ..changed();
        },
      );
    } finally {
      press
        ..running = false
        ..changed();
      state = null;
      // The views and the reminders, from the calendars as they now are.
      ref.read(calendarRefreshProvider.notifier).now();
    }
    return true;
  }
}

final awayPressProvider =
    NotifierProvider<AwayPresses, AwayPress?>(AwayPresses.new);
