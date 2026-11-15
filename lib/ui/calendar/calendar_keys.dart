import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/calendar_view_providers.dart' show CalendarViewMode;
import '../shell/app_shortcuts.dart' show ShortcutHelp, showShortcutsHelp;
import '../shell/pane_focus.dart' show focusIsInTextField;

/// What a key does in the calendar: one of its own buttons, from the
/// keyboard (calendar idea #75).
enum CalendarCommand {
  today,
  previous,
  next,
  day,
  week,
  month,
  agenda,
  goToDate,
  newMeeting,
  search,
  help,
  back,
}

/// One line of the calendar's keys: what the help says, and each key the
/// line names with what that key does.
///
/// One table drives both the keys and the F1 help, as AppShortcuts' does
/// for the mail, so the help cannot name a key the calendar does not
/// answer to.
class CalendarKey extends ShortcutHelp {
  const CalendarKey(super.keys, super.does, [this.bindings = const []]);

  /// Each key the line names, and what it does. Empty for a line about
  /// Flutter's own keys, which the calendar leaves to it.
  final List<(ShortcutActivator, CalendarCommand)> bindings;
}

/// The calendar's keys. Single letters, which the mail has none of: there
/// one would be a keystroke from a delete, but none of these changes
/// anything, each moves or opens. Letters and arrows by the key's own
/// name, which a Hebrew layout leaves as it is; / by the key or by the
/// character, which some layouts put elsewhere. Each without Ctrl, Alt or
/// Shift, which a [SingleActivator] holds to.
const calendarKeys = <CalendarKey>[
  CalendarKey('T', 'Today', [
    (SingleActivator(LogicalKeyboardKey.keyT), CalendarCommand.today),
  ]),
  CalendarKey(
    '←  →',
    'The day, week or month before or after, as shown; in Agenda, a week',
    [
      (SingleActivator(LogicalKeyboardKey.arrowLeft), CalendarCommand.previous),
      (SingleActivator(LogicalKeyboardKey.arrowRight), CalendarCommand.next),
    ],
  ),
  CalendarKey('D  W  M  A', 'Day, Week, Month or Agenda', [
    (SingleActivator(LogicalKeyboardKey.keyD), CalendarCommand.day),
    (SingleActivator(LogicalKeyboardKey.keyW), CalendarCommand.week),
    (SingleActivator(LogicalKeyboardKey.keyM), CalendarCommand.month),
    (SingleActivator(LogicalKeyboardKey.keyA), CalendarCommand.agenda),
  ]),
  CalendarKey('G', 'Go to a date', [
    (SingleActivator(LogicalKeyboardKey.keyG), CalendarCommand.goToDate),
  ]),
  CalendarKey('N', 'New meeting', [
    (SingleActivator(LogicalKeyboardKey.keyN), CalendarCommand.newMeeting),
  ]),
  CalendarKey('/', 'Search the calendar', [
    (SingleActivator(LogicalKeyboardKey.slash), CalendarCommand.search),
    (CharacterActivator('/'), CalendarCommand.search),
  ]),
  // Flutter's own: Tab moves the focus through the buttons and the
  // meetings, each a button of its own, and Enter presses the one it is
  // on. The calendar's keys leave both alone.
  CalendarKey(
    'Tab  Enter',
    'Through the buttons and the meetings, and open the one with the focus',
  ),
  CalendarKey('F1', "The calendar's keys", [
    (SingleActivator(LogicalKeyboardKey.f1), CalendarCommand.help),
  ]),
  CalendarKey('Esc', 'Back to the mail; an open sheet or dialog closes first', [
    (SingleActivator(LogicalKeyboardKey.escape), CalendarCommand.back),
  ]),
];

/// The calendar's keys around [child], the calendar screen, while the
/// focus is in it and nothing is being typed (calendar idea #75): each
/// does what the button for it does, given here by the screen.
///
/// A focus scope of its own, which takes the focus as the calendar opens,
/// so the keys work before anything is tapped, and takes it back when a
/// meeting that had it goes, or is on a page turned from (see
/// [releaseFocusWithin]). A sheet or a dialog over the calendar is a route
/// of its own: keys go to it, and Esc closes it, as Flutter has it. Tab
/// and Enter are never taken.
class CalendarKeys extends StatelessWidget {
  const CalendarKeys({
    super.key,
    required this.onToday,
    required this.onTurn,
    required this.onView,
    required this.onGoToDate,
    required this.onSearch,
    required this.onNewMeeting,
    required this.child,
  });

  final VoidCallback onToday;

  /// The page before (-1) or after (1).
  final void Function(int direction) onTurn;
  final void Function(CalendarViewMode view) onView;
  final VoidCallback onGoToDate;
  final VoidCallback onSearch;

  /// Null where there is no New meeting: no calendar to make one on.
  final VoidCallback? onNewMeeting;
  final Widget child;

  /// What [event] is in the calendar, or null where it is none of its
  /// keys.
  static CalendarCommand? commandFor(KeyEvent event) {
    for (final line in calendarKeys) {
      for (final (key, command) in line.bindings) {
        if (key.accepts(event, HardwareKeyboard.instance)) return command;
      }
    }
    return null;
  }

  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    // Never while typing.
    if (focusIsInTextField()) return KeyEventResult.ignored;
    final command = commandFor(event);
    if (command == null) return KeyEventResult.ignored;
    // Pressed, not held: one press is one day, one page, one screen, as
    // the mail's keys take only the press. The repeats of a key held down
    // are the calendar's all the same, and do nothing: let through, the
    // arrows' walked Flutter's focus over the page just turned from.
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    switch (command) {
      case CalendarCommand.today:
        onToday();
      case CalendarCommand.previous:
        onTurn(-1);
      case CalendarCommand.next:
        onTurn(1);
      case CalendarCommand.day:
        onView(CalendarViewMode.day);
      case CalendarCommand.week:
        onView(CalendarViewMode.week);
      case CalendarCommand.month:
        onView(CalendarViewMode.month);
      case CalendarCommand.agenda:
        onView(CalendarViewMode.agenda);
      case CalendarCommand.goToDate:
        onGoToDate();
      case CalendarCommand.newMeeting:
        onNewMeeting?.call();
      case CalendarCommand.search:
        onSearch();
      case CalendarCommand.help:
        unawaited(showCalendarKeys(context));
      case CalendarCommand.back:
        // The calendar itself, and only while it is on top.
        if (ModalRoute.isCurrentOf(context) ?? false) {
          unawaited(Navigator.of(context).maybePop());
        }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => FocusScope(
        autofocus: true,
        onKeyEvent: (_, event) => _onKey(context, event),
        child: child,
      );
}

/// The calendar's keys, as F1 lists them there: the table's lines.
Future<void> showCalendarKeys(BuildContext context) => showShortcutsHelp(
      context,
      title: 'Keys in the calendar',
      sections: const {'In the calendar': calendarKeys},
    );

/// The keyboard's focus taken out of [area], where it is anywhere in it,
/// and given to the calendar itself: the nearest focus scope, which is
/// [CalendarKeys]'. For the pages of Day, Week and Month, those either
/// side of the one shown staying built, off screen, for a swipe: a meeting
/// on a page turned from must not keep the focus, or Enter would open what
/// Ron cannot see. Tab starts again from the top.
void releaseFocusWithin(BuildContext area) {
  final focus = FocusManager.instance.primaryFocus;
  final at = focus?.context;
  if (focus == null || at == null || focus is FocusScopeNode) return;
  var within = false;
  at.visitAncestorElements((e) => !(within = identical(e, area)));
  if (within) focus.unfocus(disposition: UnfocusDisposition.scope);
}
