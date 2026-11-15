import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../domain/account_calendars.dart' show calendarShown;
import '../../domain/calendar_change.dart' show isOwnEvent;
import '../../domain/calendar_event.dart';
import '../../domain/calendar_finding.dart' show searchSpan;
import '../../domain/calendar_invite.dart' show InviteResponse;
import '../../state/calendar_view_providers.dart';
import '../../state/message_keeping.dart' show notRetried;
import '../../state/providers.dart';
import '../messages/date_format.dart';
import '../messages/invite_answers.dart' show askHowToAnswer;
import 'calendar_screen.dart' show agendaRow, showEventDetails;
import 'event_actions.dart' show answerEvent;
import 'event_colours.dart';
import 'invitation_clearing.dart' show InvitationClearing;

/// The invitations waiting for your answer (#50): a line at the Agenda's
/// top saying how many, and the list it opens, each one answered there as
/// on its sheet. A series counts once, as its next meeting waiting.
///
/// The line counts the year ahead where the device can vouch for it: all of
/// it read, on every calendar of each account shown, since the last change
/// made here and within half an hour (the list or search read it).
/// Otherwise it counts the next 30 days as the Agenda shows them, from what
/// the device keeps of them however old, so that nothing the Agenda shows
/// as not answered is left out; and it says which. It reads nothing of its
/// own. The list opens on what the line counted, and reads the year ahead
/// once, as search reads its year, then once more a few seconds after
/// answering stops, or as it closes: never with every answer. A meeting
/// answered from it leaves it at once.

/// The days the Agenda reads first, from the day it opens on: what the line
/// counts where the year ahead cannot be vouched for.
const _agendaDays = 30;

/// From today to where search's year ends: what the list reads, and the
/// line counts where it was read lately.
({DateTime start, DateTime end}) waitingSpan(DateTime now) => (
      start: DateTime(now.year, now.month, now.day),
      end: searchSpan(now).end,
    );

/// One meeting waiting for your answer, or the next of a series' meetings
/// that are, with how many [more] of the series wait after it.
typedef Waiting = ({CalendarEvent event, int more});

/// What waits for your answer in [events] at [now], soonest first. Each
/// meeting someone else organised that you have not answered, not
/// cancelled and not over yet, on your own calendar, where the answer is
/// yours: the account's main one (on a calendar shared to it, even one it
/// may change, the answer is its owner's, and a meeting on both would come
/// twice). A series counts once, as its next meeting waiting.
List<Waiting> waitingForAnswer(
  Iterable<CalendarEvent> events,
  DateTime now,
) {
  final seen = <String>{};
  final groups = <String, List<CalendarEvent>>{};
  for (final e in events) {
    if (e.response != EventResponse.notResponded ||
        e.organizer == null ||
        isOwnEvent(e) ||
        e.cancelled ||
        e.readOnly ||
        e.calendarId != CalendarEvent.mainCalendar ||
        !e.end.isAfter(now) ||
        !seen.add(_keyOf(e))) {
      continue;
    }
    (groups[_seriesOf(e) ?? _keyOf(e)] ??= []).add(e);
  }
  int byTime(CalendarEvent a, CalendarEvent b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.end.compareTo(b.end);
  }

  return [
    for (final meetings in groups.values)
      (event: (meetings..sort(byTime)).first, more: meetings.length - 1),
  ]..sort((a, b) => byTime(a.event, b.event));
}

String _keyOf(CalendarEvent e) => '${e.accountId}|${e.calendarId}|${e.id}';

/// [e]'s series, by account, or null for a meeting on its own.
String? _seriesOf(CalendarEvent e) =>
    e.seriesId == null ? null : '${e.accountId}|~${e.seriesId}';

/// What the line counts from: what the device keeps of the calendars
/// shown, a year ahead where it can vouch for all of it ([wholeYear]), or
/// else the Agenda's next 30 days, as the Agenda shows them.
typedef WaitingCount = ({List<CalendarEvent> events, bool wholeYear});

/// Whether a read made at [at] vouches for what it found at [now]: made
/// since the last change made here ([notBefore]), and within half an hour,
/// as search reckons its year fresh.
bool _vouched(DateTime? at, DateTime notBefore, DateTime now) =>
    at != null &&
    !at.isBefore(notBefore) &&
    now.difference(at) < calendarLongFreshFor;

/// The calendar accounts shown.
List<String> _shownAccounts(T Function<T>(ProviderListenable<T>) read) {
  final hidden = read(hiddenCalendarsProvider);
  return [
    for (final a in read(calendarAccountsProvider))
      if (!hidden.contains(a.id)) a.id,
  ];
}

/// What the Agenda's line counts, from what this device keeps of every
/// calendar shown, reading nothing itself: the year ahead where every
/// account's was read lately enough to vouch for it; or else the next 30
/// days of each, however old what is kept of them, as the Agenda shows
/// them (it reads them again as it opens, after each change and on
/// Refresh, and shows what is kept where it cannot). Counted again after
/// every change made here and on Refresh, and by the line and the list as
/// the reads they listen to come in.
final waitingAnswersProvider =
    FutureProvider.autoDispose<WaitingCount>((ref) async {
  final engine = ref.watch(mailEngineProvider);
  final hidden = ref.watch(hiddenCalendarsProvider);
  final notBefore = ref.watch(calendarRefreshProvider);
  final accounts = _shownAccounts(ref.watch);
  final now = DateTime.now();
  final span = waitingSpan(now);
  final month = DateTime(
      span.start.year, span.start.month, span.start.day + _agendaDays);
  final kept = <CalendarEvent>[];
  var wholeYear = true;
  await Future.wait([
    for (final accountId in accounts)
      () async {
        try {
          final year =
              await engine.keptCalendarEvents(accountId, span.start, span.end);
          kept.addAll(year.events);
          if (!_vouched(year.readAt, notBefore, now)) wholeYear = false;
        } catch (e) {
          wholeYear = false;
          debugPrint('[myemail] kept calendar not counted: $e');
        }
      }(),
  ]);
  return (
    events: [
      for (final e in kept)
        if (calendarShown(e, hidden) &&
            (wholeYear || e.start.isBefore(month)))
          e,
    ],
    wholeYear: wholeYear,
  );
}, retry: notRetried);

/// [span] read again on each calendar shown whose kept copy it cannot vouch
/// for, as search reads its year, and the line counted again after it.
Future<void> _readAhead(
  ProviderContainer container,
  ({DateTime start, DateTime end}) span,
) async {
  final engine = container.read(mailEngineProvider);
  final notBefore = container.read(calendarRefreshProvider);
  final now = DateTime.now();
  await Future.wait([
    for (final accountId in _shownAccounts(container.read))
      () async {
        try {
          final kept =
              await engine.keptCalendarEvents(accountId, span.start, span.end);
          if (_vouched(kept.readAt, notBefore, now)) return;
          await engine.calendarEvents(accountId, span.start, span.end);
        } catch (e) {
          debugPrint('[myemail] the waiting list did not read a calendar: $e');
        }
      }(),
  ]);
  container.invalidate(waitingAnswersProvider);
}

/// "3 waiting for your answer", at the top of the Agenda, a tap from the
/// list of them; "in the next 30 days" where the year ahead cannot be
/// vouched for; nothing where none is.
class WaitingAnswersLine extends ConsumerWidget {
  const WaitingAnswersLine({super.key, required this.agenda});

  /// The days the Agenda reads first: what it keeps of them is counted
  /// once it comes in. Listened to, not read again.
  final CalendarRange agenda;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(calendarEventsProvider(agenda),
        (_, _) => ref.invalidate(waitingAnswersProvider));
    final count = ref.watch(waitingAnswersProvider).value;
    final waiting = count == null
        ? const <Waiting>[]
        : waitingForAnswer(
            withPending(count.events, ref.watch(calendarPendingProvider)),
            DateTime.now(),
          );
    if (count == null || waiting.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final n = waiting.length;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: ListTile(
        key: const ValueKey('agenda-waiting'),
        dense: true,
        leading: const Icon(Icons.event_note_outlined),
        title: Text(count.wholeYear
            ? '$n waiting for your answer'
            : '$n waiting for your answer in the next $_agendaDays days'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => WaitingAnswersScreen.open(context),
      ),
    );
  }
}

/// The meetings waiting for your answer, soonest first, under their days'
/// headings as the Agenda draws them, a series once, each with Accept,
/// Maybe and Decline, which ask as the sheet's do. A tap on one opens its
/// sheet. One answered leaves the list.
class WaitingAnswersScreen extends ConsumerStatefulWidget {
  const WaitingAnswersScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const WaitingAnswersScreen(),
      ));

  @override
  ConsumerState<WaitingAnswersScreen> createState() =>
      _WaitingAnswersScreenState();
}

class _WaitingAnswersScreenState extends ConsumerState<WaitingAnswersScreen> {
  /// How long answering has to have stopped before the year is read again.
  static const _settleAfter = Duration(seconds: 5);

  /// From today to a year ahead, fixed for the screen's life.
  final _span = waitingSpan(DateTime.now());

  late final ProviderContainer _container;

  /// The calendars over [_span] as the device keeps them, once the list has
  /// read them (or found them read lately); till then, what the line
  /// counted.
  List<CalendarEvent>? _kept;

  /// Reading [_span]: as the list opens, and once answering stops.
  bool _reading = false;

  /// Answered from here, for the screen's life: meetings by [_keyOf], and
  /// series answered whole by [_seriesOf]. They leave the list at once and
  /// stay out, though the calendar is not read again with each answer.
  final _answered = <String>{};
  final _answeredSeries = <String>{};

  /// The meetings an answer is on its way for, whose buttons wait.
  final _answering = <String>{};

  /// Set while answering goes on: when it has stopped for [_settleAfter],
  /// or the list closes, the year is read again, once.
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    // Anything changed on a calendar, an answer from a meeting's sheet
    // among it: what was kept of it since shows at once, and the year is
    // read again once things are quiet.
    ref.listenManual(calendarRefreshProvider, (_, _) => _changed());
    unawaited(_read());
  }

  @override
  void dispose() {
    final settling = _settle != null;
    _settle?.cancel();
    // Closed as answering stopped: the year read again once, behind it,
    // so the Agenda's line can count it whole.
    if (settling) unawaited(_readAhead(_container, _span));
    super.dispose();
  }

  Future<void> _read() async {
    if (mounted) setState(() => _reading = true);
    await _readAhead(_container, _span);
    await _recount();
    if (mounted) setState(() => _reading = false);
  }

  /// What the device keeps over [_span] now, shown.
  Future<void> _recount() async {
    final engine = _container.read(mailEngineProvider);
    final hidden = _container.read(hiddenCalendarsProvider);
    final events = <CalendarEvent>[];
    await Future.wait([
      for (final accountId in _shownAccounts(_container.read))
        engine.keptCalendarEvents(accountId, _span.start, _span.end).then(
          (k) {
            events.addAll(k.events);
          },
          onError: (Object e) =>
              debugPrint('[myemail] kept calendar not listed: $e'),
        ),
    ]);
    if (!mounted) return;
    setState(() => _kept = [
          for (final e in events)
            if (calendarShown(e, hidden)) e,
        ]);
  }

  void _changed() {
    if (_kept != null) unawaited(_recount());
    _settle?.cancel();
    _settle = Timer(_settleAfter, () {
      _settle = null;
      unawaited(_read());
    });
  }

  /// [event] answered as [response], asked first as its sheet asks: how the
  /// answer goes, from a menu under [anchor], the button pressed, and then,
  /// for one meeting of a series, whether it is for the whole series.
  Future<void> _answer(
    CalendarEvent event,
    InviteResponse response,
    BuildContext anchor,
  ) async {
    // Its invitation looked for while this is asked, before the answer
    // goes, as from the sheet (#51).
    final lookup = InvitationClearing.before(context, ref)?.lookUp(event);
    final answer = await askHowToAnswer(
      context,
      response,
      title: event.title,
      anchor: anchor,
    );
    if (answer == null || !mounted) return;
    final key = _keyOf(event);
    setState(() => _answering.add(key));
    bool? whole;
    try {
      whole = await answerEvent(context, ref, event, response,
          note: answer.note, send: answer.send, lookup: lookup);
    } finally {
      if (mounted) {
        setState(() {
          _answering.remove(key);
          final series = _seriesOf(event);
          if (whole == true && series != null) {
            _answeredSeries.add(series);
          } else if (whole != null) {
            _answered.add(key);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counted = ref.watch(waitingAnswersProvider);
    final waiting = waitingForAnswer([
      for (final e in withPending(
        _kept ?? counted.value?.events ?? const [],
        ref.watch(calendarPendingProvider),
      ))
        if (!_answered.contains(_keyOf(e)) &&
            !_answeredSeries.contains(_seriesOf(e)))
          e,
    ], DateTime.now());
    final reading = _reading || (_kept == null && counted.isLoading);
    final accounts = ref.watch(calendarAccountsProvider);
    final colours = EventColours(
      accounts: {for (final a in accounts) a.id: Color(a.colorValue)},
    );
    final days = <DateTime, List<Waiting>>{};
    for (final w in waiting) {
      final s = w.event.start;
      (days[DateTime(s.year, s.month, s.day)] ??= []).add(w);
    }
    final screen = Scaffold(
      appBar: AppBar(
        title: const Text('Waiting for your answer'),
        bottom: reading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: waiting.isEmpty
          ? Center(
              child: Text(
                reading ? 'Looking…' : 'Nothing is waiting for your answer.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                for (final MapEntry(key: day, value: meetings)
                    in days.entries) ...[
                  _DayHeading(day: day),
                  for (final (:event, :more) in meetings)
                    _Waiting(
                      key: ValueKey('waiting-event:${_keyOf(event)}'),
                      event: event,
                      more: more,
                      day: day,
                      colour: colours[event] ?? theme.colorScheme.primary,
                      busy: _answering.contains(_keyOf(event)),
                      onOpen: () => showEventDetails(
                        context,
                        ref,
                        event,
                        accounts
                            .where((a) => a.id == event.accountId)
                            .firstOrNull,
                      ),
                      onAnswer: (response, anchor) =>
                          _answer(event, response, anchor),
                    ),
                ],
              ],
            ),
    );
    // Esc back to the calendar, as Esc goes back from the calendar itself
    // (calendar idea #75). The calendar's other keys are its own screen's,
    // and a route over it, as this is, does not hear them.
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        final onTop = ModalRoute.isCurrentOf(context) ?? false;
        if (event is KeyDownEvent && onTop) {
          unawaited(Navigator.of(context).maybePop());
        }
        return KeyEventResult.handled;
      },
      child: screen,
    );
  }
}

/// A day's heading, as the Agenda heads its days.
class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final name = formatDay(day);
    final label = day == today
        ? 'Today · $name'
        : day == tomorrow
            ? 'Tomorrow · $name'
            : name;
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: day == today ? theme.colorScheme.primary : null,
        ),
      ),
    );
  }
}

/// One meeting waiting for an answer: its row, as the Agenda draws it, for
/// one of a series that it repeats and how many [more] of it wait, and the
/// three answers under it.
class _Waiting extends StatelessWidget {
  const _Waiting({
    super.key,
    required this.event,
    required this.more,
    required this.day,
    required this.colour,
    required this.busy,
    required this.onOpen,
    required this.onAnswer,
  });

  final CalendarEvent event;
  final int more;
  final DateTime day;
  final Color colour;

  /// Its answer is on its way: the buttons wait.
  final bool busy;
  final VoidCallback onOpen;
  final void Function(InviteResponse response, BuildContext anchor) onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Under the title, past the time and the colour's bar.
    const indent = EdgeInsetsDirectional.fromSTEB(96, 0, 16, 8);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        agendaRow(event, day: day, colour: colour, onTap: onOpen),
        if (event.seriesId != null)
          Padding(
            padding: indent,
            child: Text(
              more == 0 ? 'Repeats' : 'Repeats · $more more not answered',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        Padding(
          padding: indent,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (response, label, key) in const [
                (InviteResponse.accepted, 'Accept', 'waiting-accept'),
                (InviteResponse.tentative, 'Maybe', 'waiting-tentative'),
                (InviteResponse.declined, 'Decline', 'waiting-decline'),
              ])
                Builder(
                  builder: (button) => OutlinedButton(
                    key: ValueKey(key),
                    onPressed: busy ? null : () => onAnswer(response, button),
                    child: Text(label),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
