import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../data/calendar/account_calendar.dart' show AccountCalendar;
import '../../data/calendar/calendar_upkeep.dart' show findKeptMeeting;
import '../../data/mail_engine.dart' show CalendarUnavailable;
import '../../domain/account.dart';
import '../../domain/calendar_change.dart';
import '../../domain/calendar_event.dart';
import '../../domain/calendar_invite.dart' show InviteResponse;
import '../../domain/calendar_prefs.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/internet_calendar.dart' show isInternetAccount;
import '../../domain/meeting_alerts.dart' show MeetingRef;
import '../../domain/meeting_links.dart' show placeLine;
import '../../domain/meeting_moment.dart';
import '../../domain/search_refinement.dart' show weekStartFor;
import '../../domain/text_direction.dart' show firstStrongDirection;
import '../../domain/time_zones.dart';
import '../../state/calendar_view_providers.dart';
import '../../state/meeting_providers.dart' show workWeekProvider;
import '../../state/providers.dart';
import '../accounts/google_sign_in_screen.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import '../common/bottom_message.dart';
import '../common/lined_up.dart';
import '../common/tap_target.dart';
import '../meetings/new_meeting_screen.dart' show openNewMeeting;
import '../messages/date_format.dart';
import '../messages/invite_answers.dart' show askHowToAnswer;
import '../../state/date_providers.dart' show deviceZoneProvider;
import 'agenda_row_parts.dart';
import 'block_look.dart';
import 'block_text.dart';
import 'button_corner.dart';
import 'calendar_keys.dart';
import 'calendar_search_screen.dart';
import 'calendar_title.dart';
import 'event_actions.dart';
import 'event_colours.dart';
import 'event_notes.dart';
import 'hour_scale.dart';
import 'invitation_clearing.dart' show InvitationClearing;
import 'meeting_mail.dart';
import 'meeting_people.dart';
import 'meeting_ticker.dart';
import 'now_line.dart';
import 'place_link.dart';
import 'waiting_answers.dart';

/// Outlook's Calendar, beside the mail: every account's events as an
/// agenda, a day, a week or a month. Shown from what the device kept of
/// each calendar at once, and read again behind it. Reached from the
/// folder pane's foot, the ribbon, and Ctrl+2.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key, this.day, this.event});

  /// The day it opens on: today where none is given.
  final DateTime? day;

  /// A meeting whose sheet opens over it: one a reminder, the agenda or
  /// the widget was tapped for.
  final CalendarEvent? event;

  static Future<void> open(
    BuildContext context, {
    DateTime? day,
    CalendarEvent? event,
  }) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => CalendarScreen(day: day, event: event),
      ));

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

DateTime _midnight(DateTime t) => DateTime(t.year, t.month, t.day);

DateTime _plus(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December',
];

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// What one page of Day, Week or Month shows: its days, the stretch the
/// calendars are asked for, and for Month, the month itself.
typedef CalendarPage = ({
  List<DateTime> days,
  CalendarRange range,
  DateTime? month,
});

/// The page [offset] pages from the one holding [origin], in [mode]. A
/// week starts where the [workWeek]'s run of days does; Work week shows
/// those days alone, and Month every week its days touch.
@visibleForTesting
CalendarPage calendarPage(
  CalendarViewMode mode,
  WeekSpan span,
  Set<int> workWeek,
  DateTime origin,
  int offset,
) {
  CalendarPage run(DateTime first, int count) {
    final days = [for (var i = 0; i < count; i++) _plus(first, i)];
    return (
      days: days,
      range: (start: first, end: _plus(first, count)),
      month: null,
    );
  }

  final day = _midnight(origin);
  switch (mode) {
    case CalendarViewMode.agenda:
    case CalendarViewMode.day:
      return run(_plus(day, offset), 1);
    case CalendarViewMode.week:
      switch (span) {
        case WeekSpan.threeDays:
          return run(_plus(day, 3 * offset), 3);
        case WeekSpan.sevenDays:
          return run(
              _plus(weekStartFor(day, workWeek: workWeek), 7 * offset), 7);
        case WeekSpan.workWeek:
          final first =
              _plus(weekStartFor(day, workWeek: workWeek), 7 * offset);
          final worked = [
            for (var i = 0; i < 7; i++)
              if (workWeek.isEmpty || workWeek.contains(_plus(first, i).weekday))
                _plus(first, i),
          ];
          return (
            days: worked,
            range: (start: worked.first, end: _plus(worked.last, 1)),
            month: null,
          );
      }
    case CalendarViewMode.month:
      final month = DateTime(day.year, day.month + offset, 1);
      final first = weekStartFor(month, workWeek: workWeek);
      final last = DateTime(month.year, month.month + 1, 0);
      final weeks = ((last.difference(first).inDays + 1) / 7).ceil();
      final page = run(first, weeks * 7);
      return (days: page.days, range: page.range, month: month);
  }
}

/// The page number of the page holding the day the pages were laid out
/// from: far enough in to swipe back for years.
const _home = 100000;

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  /// The day the view is on: the one Agenda opens at, Day shows, Week
  /// starts with, and Month has picked.
  late DateTime _day = _midnight(widget.day ?? DateTime.now());

  /// The day the pages were last laid out from, and how many pages on
  /// from it the one on screen is. Laid out again from [_day] by a jump
  /// (Today, a date picked, Back and On in Agenda) and by another view.
  late DateTime _origin = _day;
  int _offset = 0;
  int _layouts = 0;
  CalendarViewMode? _laidOutMode;
  WeekSpan? _laidOutSpan;

  /// The hour at the top of Day and Week, the same on every page, so a
  /// swipe lands where the last day was.
  final ValueNotifier<double> _topHour = ValueNotifier(8);

  /// Pinching the hours, when the pages must not turn.
  bool _pinching = false;

  final GlobalKey<_PagerState> _pager = GlobalKey();

  @override
  void initState() {
    super.initState();
    final event = widget.event;
    if (event == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final account = ref
          .read(calendarAccountsProvider)
          .where((a) => a.id == event.accountId)
          .firstOrNull;
      showEventDetails(context, ref, event, account);
    });
  }

  @override
  void dispose() {
    _topHour.dispose();
    super.dispose();
  }

  /// What Week shows: as chosen on this device, or a week on a tablet and
  /// three days on a phone.
  WeekSpan _span(BuildContext context, {bool watch = true}) =>
      (watch
          ? ref.watch(calendarWeekSpanProvider)
          : ref.read(calendarWeekSpanProvider)) ??
      (MediaQuery.sizeOf(context).width >= 700
          ? WeekSpan.sevenDays
          : WeekSpan.threeDays);

  CalendarPage _page(CalendarViewMode mode, WeekSpan span, [int? offset]) =>
      calendarPage(mode, span, ref.read(workWeekProvider), _origin,
          offset ?? _offset);

  /// The pages laid out again from [day], which the view is now on, opening
  /// at the hour that page opens at.
  void _jump(DateTime day) {
    setState(() {
      _day = _midnight(day);
      _origin = _day;
      _offset = 0;
      _layouts++;
    });
    final mode = ref.read(calendarViewProvider);
    _topHour.value =
        _openingHour(_page(mode, _span(context, watch: false)).days);
  }

  void _setMode(CalendarViewMode mode, {DateTime? day}) {
    if (day != null) _day = _midnight(day);
    ref.read(calendarViewProvider.notifier).set(mode);
    _jump(_day);
  }

  void _setSpan(WeekSpan span) {
    ref.read(calendarWeekSpanProvider.notifier).set(span);
    _jump(_day);
  }

  /// Where Day and Week open: an hour before now on a page with today,
  /// otherwise a little before the working day starts.
  double _openingHour(List<DateTime> days) {
    final now = DateTime.now();
    if (days.any((d) => _sameDay(d, now))) {
      return math.max(0, now.hour - 1).toDouble();
    }
    return math.max(0, ref.read(calendarPrefsProvider).dayStart - 0.5);
  }

  /// A page turned to: the day the view is now on goes with it.
  void _turned(CalendarViewMode mode, WeekSpan span, int offset) {
    final page = _page(mode, span, offset);
    final today = _midnight(DateTime.now());
    setState(() {
      _offset = offset;
      _day = switch (mode) {
        CalendarViewMode.month => page.month!.year == today.year &&
                page.month!.month == today.month
            ? today
            : page.month!,
        _ => page.days.first,
      };
    });
  }

  void _move(CalendarViewMode mode, int direction) {
    if (mode == CalendarViewMode.agenda) {
      _jump(_plus(_day, 7 * direction));
      return;
    }
    final pager = _pager.currentState;
    if (pager != null) pager.turn(direction);
  }

  /// The title's words, longest first, each shorter for less room (#88):
  /// "November 2026", "Nov 2026", "Nov". Over two months, as three days at
  /// a month's end are, the year while it fits, then both months, then the
  /// first alone: "Nov – Dec 2026", "Nov–Dec 2026", "Nov – Dec", "Nov–Dec",
  /// "Nov". Over two years, "Dec 2026 – Jan 2027" where it fits, and
  /// otherwise no year rather than one of the two: "Dec – Jan".
  List<String> _titles(CalendarViewMode mode, CalendarPage page) {
    String short(DateTime d) => _months[d.month - 1].substring(0, 3);
    final month = page.month;
    final from =
        month ?? (mode == CalendarViewMode.agenda ? _day : page.days.first);
    final last =
        month ?? (mode == CalendarViewMode.agenda ? _day : page.days.last);
    if (from.month == last.month && from.year == last.year) {
      return [
        '${_months[from.month - 1]} ${from.year}',
        '${short(from)} ${from.year}',
        short(from),
      ];
    }
    return [
      if (from.year != last.year)
        '${short(from)} ${from.year} – ${short(last)} ${last.year}'
      else ...[
        '${short(from)} – ${short(last)} ${last.year}',
        '${short(from)}–${short(last)} ${last.year}',
      ],
      '${short(from)} – ${short(last)}',
      '${short(from)}–${short(last)}',
      short(from),
    ];
  }

  /// What More says for ‹ and › on a phone, where they are not in the bar:
  /// as far as each goes in [mode] (#88).
  (String, String) _turnWords(CalendarViewMode mode, WeekSpan span) {
    final what = switch (mode) {
      CalendarViewMode.day => 'Day',
      CalendarViewMode.month => 'Month',
      CalendarViewMode.week when span == WeekSpan.threeDays => '3 days',
      // A week, and in Agenda ‹ › go a week.
      _ => 'Week',
    };
    return ('$what before', '$what after');
  }

  /// A new meeting from the view: at the next hour on a page with today,
  /// otherwise when the working day starts on the day the view is on.
  DateTime? _newMeetingStart(CalendarViewMode mode, CalendarPage page) {
    if (mode == CalendarViewMode.agenda) return null;
    final now = DateTime.now();
    if (mode != CalendarViewMode.month &&
        page.days.any((d) => _sameDay(d, now))) {
      return DateTime(now.year, now.month, now.day, now.hour + 1);
    }
    final day = mode == CalendarViewMode.month ? _day : page.days.first;
    return DateTime(day.year, day.month, day.day,
        ref.read(calendarPrefsProvider).dayStart);
  }

  Future<void> _chooseCalendars(List<Account> accounts) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheet) => SafeArea(
          child: Consumer(
            builder: (context, ref, _) {
              final hidden = ref.watch(hiddenCalendarsProvider);
              final links = ref.watch(internetCalendarsProvider);
              final shown = ref.read(hiddenCalendarsProvider.notifier);
              return ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(title: Text('Calendars shown')),
                  for (final a in accounts) ...[
                    CheckboxListTile(
                      key: ValueKey('calendar-shown:${a.id}'),
                      secondary: CircleAvatar(
                        radius: 8,
                        backgroundColor: Color(a.colorValue),
                      ),
                      title: Text(a.displayName),
                      subtitle: Text(a.emailAddress),
                      value: !hidden.contains(a.id),
                      onChanged: (on) => shown.setShown(a.id, on ?? true),
                    ),
                    // Each of its calendars, under it, once it has more
                    // than the one.
                    if (!hidden.contains(a.id))
                      _AccountCalendarsShown(account: a, hidden: hidden),
                  ],
                  for (final c in links)
                    CheckboxListTile(
                      key: ValueKey('calendar-shown:${c.accountId}'),
                      secondary: CircleAvatar(
                        radius: 8,
                        backgroundColor: Color(c.colour),
                      ),
                      title: Text(c.name),
                      subtitle: const Text('From a link'),
                      value: !hidden.contains(c.accountId),
                      onChanged: (on) =>
                          shown.setShown(c.accountId, on ?? true),
                    ),
                ],
              );
            },
          ),
        ),
      );

  Future<void> _pickDate() async {
    final picked = await pickCalendarDate(context, _day);
    if (picked != null && mounted) _jump(picked);
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(calendarViewProvider);
    final span = _span(context);
    ref.watch(workWeekProvider);
    if (mode != _laidOutMode || span != _laidOutSpan) {
      // Another view, or another week: laid out again from the day the
      // view is on, which is where the last one was.
      final first = _laidOutMode == null;
      _laidOutMode = mode;
      _laidOutSpan = span;
      _origin = _day;
      _offset = 0;
      _layouts++;
      if (first) _topHour.value = _openingHour(_page(mode, span).days);
    }
    final page = _page(mode, span);
    final range = mode == CalendarViewMode.agenda
        ? (start: _day, end: _plus(_day, _AgendaState.chunk))
        : page.range;
    final load = ref.watch(calendarEventsProvider(range));
    final accounts = ref.watch(calendarAccountsProvider);
    final prefs = ref.watch(calendarPrefsProvider);
    // Read now, for the sheet, which names the zone a meeting was set in.
    ref.watch(deviceZoneProvider);
    final colours = EventColours(
      accounts: {for (final a in accounts) a.id: Color(a.colorValue)},
      calendars: load.value?.calendars ?? const {},
    );
    final wide = MediaQuery.sizeOf(context).width >= 700;
    void details(CalendarEvent e) => showEventDetails(
          context,
          ref,
          e,
          accounts.where((a) => a.id == e.accountId).firstOrNull,
        );
    void newMeetingAt(DateTime start) =>
        openNewMeeting(context, ref, start: start);
    void moved(CalendarEvent e, DateTime start, DateTime end) =>
        moveEvent(context, ref, e, start, end);

    final Widget content;
    if (accounts.isEmpty) {
      content = const _NoCalendars();
    } else if (mode == CalendarViewMode.agenda) {
      content = _Agenda(
        key: ValueKey('agenda-$_day'),
        from: _day,
        colours: colours,
        onTap: details,
      );
    } else {
      content = _Pager(
        key: _pager,
        identity: '${mode.name}-${span.name}-$_layouts',
        onTurned: (offset) => _turned(mode, span, offset),
        locked: _pinching,
        clock: mode != CalendarViewMode.month,
        page: (offset) {
          final p = _page(mode, span, offset);
          return _CalendarPageView(
            page: p,
            mode: mode,
            wide: wide,
            selected: _day,
            colours: colours,
            topHour: _topHour,
            onTap: details,
            onSlot: newMeetingAt,
            onMove: moved,
            onSelect: (day) => setState(() => _day = day),
            onOpenDay: (day) => _setMode(CalendarViewMode.day, day: day),
            onPinching: (pinching) => setState(() => _pinching = pinching),
          );
        },
      );
    }
    final value = load.value;
    final problems = value?.problems ?? const <String, Object>{};
    final keptAt = value?.keptAt;
    final stale = keptAt != null &&
        value?.reading == false &&
        DateTime.now().difference(keptAt) > const Duration(minutes: 5);

    // Once there is a choice: more than one account, an account with more
    // than its main calendar, or a calendar from a link.
    final choosing = accounts.length > 1 ||
        (load.value?.calendars.length ?? 0) > accounts.length ||
        ref.watch(internetCalendarsProvider).isNotEmpty;
    // On a phone the title needs the room of three buttons (#88): ‹ › and
    // Calendars shown go under More, where they say what they do. A swipe
    // turns the page in Day, Week and Month, and the Agenda scrolls.
    final (before, after) = _turnWords(mode, span);

    final screen = Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: CalendarTitle(
          key: const ValueKey('calendar-title'),
          forms: _titles(mode, page),
          onTap: _pickDate,
        ),
        actions: [
          if (wide) ...[
            IconButton(
              key: const ValueKey('calendar-previous'),
              tooltip: 'Back',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _move(mode, -1),
            ),
            IconButton(
              key: const ValueKey('calendar-next'),
              tooltip: 'On',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _move(mode, 1),
            ),
          ],
          IconButton(
            key: const ValueKey('calendar-search'),
            tooltip: 'Search the calendar',
            icon: const Icon(Icons.search),
            onPressed: () => CalendarSearchScreen.open(context),
          ),
          IconButton(
            key: const ValueKey('calendar-today'),
            tooltip: 'Today',
            icon: const Icon(Icons.today_outlined),
            onPressed: () => _jump(DateTime.now()),
          ),
          if (wide && choosing)
            IconButton(
              key: const ValueKey('calendar-accounts'),
              tooltip: 'Calendars shown',
              icon: const Icon(Icons.filter_list),
              onPressed: () => _chooseCalendars(accounts),
            ),
          PopupMenuButton<String>(
            key: const ValueKey('calendar-menu'),
            tooltip: 'More',
            onSelected: (choice) {
              switch (choice) {
                case 'previous':
                  _move(mode, -1);
                case 'next':
                  _move(mode, 1);
                case 'accounts':
                  _chooseCalendars(accounts);
                case 'declined':
                  ref.read(calendarPrefsProvider.notifier).set(
                      prefs.copyWith(showDeclined: !prefs.showDeclined));
                case 'refresh':
                  ref.read(calendarRefreshProvider.notifier).now();
                default:
                  final chosen = WeekSpan.values
                      .where((s) => 'span:${s.name}' == choice)
                      .firstOrNull;
                  if (chosen != null) {
                    if (mode != CalendarViewMode.week) {
                      ref
                          .read(calendarViewProvider.notifier)
                          .set(CalendarViewMode.week);
                    }
                    _setSpan(chosen);
                  }
              }
            },
            itemBuilder: (context) => [
              if (!wide) ...[
                PopupMenuItem(
                  key: const ValueKey('calendar-previous'),
                  value: 'previous',
                  child: Text(before),
                ),
                PopupMenuItem(
                  key: const ValueKey('calendar-next'),
                  value: 'next',
                  child: Text(after),
                ),
                if (choosing)
                  const PopupMenuItem(
                    key: ValueKey('calendar-accounts'),
                    value: 'accounts',
                    child: Text('Calendars shown'),
                  ),
                const PopupMenuDivider(),
              ],
              for (final s in WeekSpan.values)
                CheckedPopupMenuItem(
                  key: ValueKey('calendar-span:${s.name}'),
                  value: 'span:${s.name}',
                  checked: s == span,
                  child: Text('Week shows ${s.choice.toLowerCase()}'),
                ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                key: const ValueKey('calendar-show-declined'),
                value: 'declined',
                checked: prefs.showDeclined,
                child: const Text('Show declined meetings'),
              ),
              const PopupMenuItem(
                key: ValueKey('calendar-refresh'),
                value: 'refresh',
                child: Text('Refresh'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: accounts.isEmpty
          ? null
          : FloatingActionButton(
              key: const ValueKey('calendar-new-meeting'),
              tooltip: 'New meeting',
              onPressed: () => openNewMeeting(context, ref,
                  start: _newMeetingStart(mode, page)),
              child: const Icon(Icons.add),
            ),
      body: Column(
        children: [
          Padding(
            // 4 above and below less, for the 4 more each way the views
            // answer a tap over (#90): drawn where they were.
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: TapTarget(
              oneButton: false,
              child: SegmentedButton<CalendarViewMode>(
              showSelectedIcon: false,
              segments: [
                for (final m in CalendarViewMode.values)
                  ButtonSegment(
                    value: m,
                    label: Text(
                      m == CalendarViewMode.week ? span.label : m.label,
                      key: ValueKey('calendar-view-${m.name}'),
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                    ),
                  ),
              ],
              selected: {mode},
              onSelectionChanged: (chosen) => _setMode(chosen.first),
              ),
            ),
          ),
          if (value?.reading == true && value?.events.isNotEmpty == true)
            const LinearProgressIndicator(minHeight: 2),
          for (final MapEntry(:key, :value) in problems.entries)
            if (accounts.where((a) => a.id == key).firstOrNull
                case final account?)
              _ProblemBar(account: account, error: value),
          if (stale)
            _KeptBar(
              keptAt: keptAt,
              onRefresh: () => ref.read(calendarRefreshProvider.notifier).now(),
            ),
          if (mode == CalendarViewMode.agenda && accounts.isNotEmpty)
            WaitingAnswersLine(agenda: range),
          Expanded(child: content),
        ],
      ),
    );
    // The calendar's keys (calendar idea #75), each doing what the button
    // for it does: Today, ‹ ›, the views, the title's date, search and +.
    return CalendarKeys(
      onToday: () => _jump(DateTime.now()),
      onTurn: (direction) => _move(mode, direction),
      onView: (view) {
        if (view != mode) _setMode(view);
      },
      onGoToDate: _pickDate,
      onSearch: () => CalendarSearchScreen.open(context),
      onNewMeeting: accounts.isEmpty
          ? null
          : () => openNewMeeting(context, ref,
              start: _newMeetingStart(mode, page)),
      child: screen,
    );
  }
}

/// No account here has a calendar the app can read.
class _NoCalendars extends StatelessWidget {
  const _NoCalendars();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No account here has a calendar MyEmail can read. A Microsoft '
            'account, or a Gmail account signed in with Google, brings its '
            'calendar with it.',
            textAlign: TextAlign.center,
          ),
        ),
      );
}

/// What is shown was read a while ago and could not be read again: when,
/// and Refresh.
class _KeptBar extends StatelessWidget {
  const _KeptBar({required this.keptAt, required this.onRefresh});

  final DateTime keptAt;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final clock = formatClock(keptAt, use24h: use24h);
    final when = _sameDay(keptAt, DateTime.now())
        ? clock
        : '${formatDay(keptAt)}, $clock';
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: ListTile(
        key: const ValueKey('calendar-kept'),
        dense: true,
        leading: const Icon(Icons.history),
        title: Text('As read at $when'),
        trailing: TextButton(
          onPressed: onRefresh,
          child: const Text('Refresh'),
        ),
      ),
    );
  }
}

/// One account's calendar could not be read: why, and Allow where a
/// sign-in fixes it.
/// [account] signed in again asking for its calendar, and every calendar
/// read again: the way past "Not allowed yet". What goes wrong is said.
Future<void> signInForCalendar(
  BuildContext context,
  WidgetRef ref,
  Account account,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    switch (account.provider) {
      case MailProvider.outlook:
        final token = await MicrosoftSignInScreen.show(
          context,
          loginHint: account.emailAddress,
          scopes: [...MicrosoftOAuth.scopes, ...MicrosoftOAuth.calendarScopes],
        );
        if (token == null) return;
        await ref
            .read(accountsProvider.notifier)
            .signInAgain(accountId: account.id, token: token);
      case MailProvider.gmail:
        final result = await GoogleSignInScreen.show(
          context,
          loginHint: account.emailAddress,
        );
        if (result == null) return;
        await ref.read(accountsProvider.notifier).signInAgain(
              accountId: account.id,
              token: result.token,
              signedInAs: result.identity?.email,
            );
    }
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: kBottomMessage,
        content: Text(e is ReadableError ? e.message : '$e'),
      ));
  } finally {
    ref.read(calendarRefreshProvider.notifier).now();
  }
}

/// [account]'s calendars in Calendars shown, each switched on or off in
/// its own colour, once it has more than its main one; and, where a
/// Google account was signed in before the app asked to list them,
/// Allow.
class _AccountCalendarsShown extends ConsumerWidget {
  const _AccountCalendarsShown({required this.account, required this.hidden});

  final Account account;
  final Set<String> hidden;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listed = ref.watch(accountCalendarsProvider(account.id));
    // Indented under the account at the start, and at the end as far in as
    // the account's own row (Material's 24), so the tick boxes line up
    // (#100).
    const inset = EdgeInsetsDirectional.only(start: 56, end: 24);
    return switch (listed) {
      AsyncData(value: final calendars) when calendars.length > 1 => Column(
          children: [
            for (final c in calendars)
              CheckboxListTile(
                key: ValueKey('calendar-shown:${c.key}'),
                contentPadding: inset,
                dense: true,
                secondary: CircleAvatar(
                  radius: 6,
                  backgroundColor: Color(c.colour ?? account.colorValue),
                ),
                title: Text(c.name),
                subtitle: c.canEdit ? null : const Text('Read only'),
                value: !hidden.contains(c.key),
                onChanged: (on) => ref
                    .read(hiddenCalendarsProvider.notifier)
                    .setCalendarShown(c.key, on ?? true),
              ),
          ],
        ),
      AsyncError(error: SignInNeedsConsent()) => ListTile(
          key: ValueKey('calendar-list-allow:${account.id}'),
          contentPadding: inset,
          dense: true,
          title: const Text('Its other calendars'),
          subtitle: const Text('Allow MyEmail to list them: sign in again.'),
          trailing: TextButton(
            onPressed: () => signInForCalendar(context, ref, account),
            child: const Text('Allow'),
          ),
        ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _ProblemBar extends ConsumerStatefulWidget {
  const _ProblemBar({required this.account, required this.error});

  final Account account;
  final Object error;

  @override
  ConsumerState<_ProblemBar> createState() => _ProblemBarState();
}

class _ProblemBarState extends ConsumerState<_ProblemBar> {
  bool _busy = false;

  Account get account => widget.account;

  Future<void> _allow() async {
    setState(() => _busy = true);
    try {
      await signInForCalendar(context, ref, account);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = widget.error;
    final (String line, bool offer) = switch (error) {
      SignInNeedsConsent(:final needsAdministrator) => (
          needsAdministrator
              ? 'Not allowed yet. Allow, then sign in; where your '
                  'organisation has to approve it, the sign-in sends them '
                  'the request.'
              : 'Not allowed yet. Allow, then sign in to allow it.',
          true,
        ),
      CalendarUnavailable(:final message) => (message, false),
      ReadableError(:final message) => (message, false),
      _ => ('$error', false),
    };
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: ListTile(
        key: ValueKey('calendar-problem:${account.id}'),
        dense: true,
        leading: Icon(offer ? Icons.lock_outline : Icons.cloud_off_outlined),
        title: Text(account.emailAddress),
        subtitle: Text(line),
        trailing: _busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : offer
                ? TextButton(
                    key: ValueKey('calendar-allow:${account.id}'),
                    onPressed: _allow,
                    child: const Text('Allow'),
                  )
                : null,
      ),
    );
  }
}

// --- paging ---------------------------------------------------------------------

/// Day, Week and Month as pages to swipe between, each read as it comes
/// near: the pages either side are laid out ahead, which reads them.
class _Pager extends StatefulWidget {
  const _Pager({
    super.key,
    required this.identity,
    required this.page,
    required this.onTurned,
    required this.locked,
    this.clock = false,
  });

  /// Which layout of the pages this is: another starts again at the page
  /// the view is on.
  final String identity;

  /// The page [offset] pages on from where the layout started.
  final Widget Function(int offset) page;
  final void Function(int offset) onTurned;

  /// Held still, while the hours are pinched.
  final bool locked;

  /// The hours' one clock over every page kept built, for the line at the
  /// present time (Day and Week; the month has none).
  final bool clock;

  @override
  State<_Pager> createState() => _PagerState();
}

class _PagerState extends State<_Pager> {
  PageController _controller = PageController(initialPage: _home);

  @override
  void didUpdateWidget(_Pager old) {
    super.didUpdateWidget(old);
    if (old.identity != widget.identity) {
      // A new controller for the new layout; the old one goes once the
      // frame that still shows it is done.
      final spent = _controller;
      _controller = PageController(initialPage: _home);
      WidgetsBinding.instance.addPostFrameCallback((_) => spent.dispose());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void turn(int direction) {
    if (!_controller.hasClients) return;
    // Nothing on the page turned from keeps the keyboard's focus, from the
    // key or button on rather than half way through the turn.
    releaseFocusWithin(context);
    final at = _controller.page?.round() ?? _home;
    _controller.animateToPage(
      at + direction,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = PageView.builder(
      key: ValueKey('pager-${widget.identity}'),
      controller: _controller,
      allowImplicitScrolling: true,
      physics: widget.locked ? const NeverScrollableScrollPhysics() : null,
      onPageChanged: (index) {
        // A swipe too: the page left stays built, off screen.
        releaseFocusWithin(context);
        widget.onTurned(index - _home);
      },
      itemBuilder: (context, index) => widget.page(index - _home),
    );
    return widget.clock ? NowClock(child: pages) : pages;
  }
}

/// One page: its events read, then drawn as Day and Week draw them or as
/// Month does.
class _CalendarPageView extends ConsumerWidget {
  const _CalendarPageView({
    required this.page,
    required this.mode,
    required this.wide,
    required this.selected,
    required this.colours,
    required this.topHour,
    required this.onTap,
    required this.onSlot,
    required this.onMove,
    required this.onSelect,
    required this.onOpenDay,
    required this.onPinching,
  });

  final CalendarPage page;
  final CalendarViewMode mode;
  final bool wide;
  final DateTime selected;
  final EventColours colours;
  final ValueNotifier<double> topHour;
  final void Function(CalendarEvent) onTap;
  final void Function(DateTime) onSlot;
  final void Function(CalendarEvent, DateTime, DateTime) onMove;
  final void Function(DateTime) onSelect;
  final void Function(DateTime) onOpenDay;
  final void Function(bool) onPinching;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = ref.watch(calendarEventsProvider(page.range));
    final prefs = ref.watch(calendarPrefsProvider);
    final pending = ref.watch(calendarPendingProvider);
    final value = load.value;
    if (value == null) {
      return load.hasError
          ? Center(child: Text('${load.error}'))
          : const Center(child: CircularProgressIndicator());
    }
    final events = shownEvents(withPending(value.events, pending), prefs);
    if (mode == CalendarViewMode.month) {
      final month = page.month!;
      if (wide) {
        // The month fills the page and does not scroll, so it ends above
        // the tablet's own bar at the foot of the screen: under Samsung's
        // taskbar its last week could not be read (seen on the tablet,
        // 2026-11-16). Inside, the bar is no longer there to allow for,
        // and the + button stands over the last box's corner as it does
        // where there is no bar.
        return SafeArea(
          top: false,
          left: false,
          right: false,
          child: _MonthGrid(
            days: page.days,
            month: month,
            events: events,
            colours: colours,
            selected: null,
            titles: true,
            onDay: onOpenDay,
            onEvent: onTap,
          ),
        );
      }
      // A day picked from the next month's first days, drawn faint at the
      // foot of this one, stays picked; one from further off is not here.
      final picked =
          page.days.any((d) => _sameDay(d, selected)) ? selected : month;
      return Column(
        children: [
          _MonthGrid(
            days: page.days,
            month: month,
            events: events,
            colours: colours,
            selected: picked,
            titles: false,
            rowHeight: 46,
            onDay: (d) => _sameDay(d, picked) ? onOpenDay(d) : onSelect(d),
          ),
          const Divider(height: 1),
          Expanded(
            child: _DayList(
              day: picked,
              events: eventsOn(picked, events),
              colours: colours,
              onTap: onTap,
              onOpen: () => onOpenDay(picked),
            ),
          ),
        ],
      );
    }
    return _Timeline(
      days: page.days,
      events: events,
      colours: colours,
      prefs: prefs,
      topHour: topHour,
      onTap: onTap,
      onSlot: onSlot,
      onMove: onMove,
      onDay: mode == CalendarViewMode.week ? onOpenDay : null,
      onPinching: onPinching,
    );
  }
}

// --- the agenda -----------------------------------------------------------------

/// Days with something on, from [from] on and back before it: the month
/// ahead first, more as the end comes near, and the month before above,
/// more as the top does.
class _Agenda extends ConsumerStatefulWidget {
  const _Agenda({
    super.key,
    required this.from,
    required this.colours,
    required this.onTap,
  });

  final DateTime from;
  final EventColours colours;
  final void Function(CalendarEvent) onTap;

  @override
  ConsumerState<_Agenda> createState() => _AgendaState();
}

class _AgendaState extends ConsumerState<_Agenda> {
  /// Days read at a time, and how many lots at most either way.
  static const chunk = 30;
  static const most = 24;

  int _ahead = 1;
  int _behind = 1;
  final _scroll = ScrollController();
  final _centre = UniqueKey();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_nearEdge);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// More days read as the end being scrolled towards comes near: only
  /// that end, so a short month behind is not read away at the first
  /// scroll down. And only once the last lot at that end has been read:
  /// until then it draws little or nothing, the end stays near, and each
  /// step of the scroll would ask every calendar for another month.
  void _nearEdge() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    switch (p.userScrollDirection) {
      case ScrollDirection.reverse
          when p.pixels > p.maxScrollExtent - 600 &&
              _ahead < most &&
              _read(_ahead - 1):
        setState(() => _ahead++);
      case ScrollDirection.forward
          when p.pixels < p.minScrollExtent + 600 &&
              _behind < most &&
              _read(-_behind):
        setState(() => _behind++);
      default:
    }
  }

  /// Whether lot [k] has been read: what was kept, and the calendars
  /// asked again where that was not just read.
  bool _read(int k) =>
      ref.read(calendarEventsProvider(_lot(k))).value?.reading == false;

  CalendarRange _lot(int k) => (
        start: _plus(widget.from, chunk * k),
        end: _plus(widget.from, chunk * (k + 1)),
      );

  @override
  Widget build(BuildContext context) => CustomScrollView(
        controller: _scroll,
        center: _centre,
        slivers: [
          if (_behind < most)
            SliverToBoxAdapter(
              child: Center(
                child: TextButton(
                  key: const ValueKey('agenda-earlier'),
                  onPressed: () => setState(() => _behind++),
                  child: const Text('Show the 30 days before'),
                ),
              ),
            ),
          for (var k = _behind; k >= 1; k--)
            _AgendaLot(
              range: _lot(-k),
              earlierFirst: false,
              colours: widget.colours,
              onTap: widget.onTap,
            ),
          _AgendaLot(
            key: _centre,
            range: _lot(0),
            earlierFirst: true,
            always: widget.from,
            colours: widget.colours,
            onTap: widget.onTap,
          ),
          for (var k = 1; k < _ahead; k++)
            _AgendaLot(
              range: _lot(k),
              earlierFirst: true,
              colours: widget.colours,
              onTap: widget.onTap,
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 88),
              child: Center(
                child: _ahead < most
                    ? TextButton(
                        key: const ValueKey('agenda-more'),
                        onPressed: () => setState(() => _ahead++),
                        child: const Text('Show the next 30 days'),
                      )
                    : null,
              ),
            ),
          ),
        ],
      );
}

/// One lot of the agenda's days, read as it comes into view. Above the
/// day it opens at, the days run upwards: the list grows from the middle.
class _AgendaLot extends ConsumerWidget {
  const _AgendaLot({
    super.key,
    required this.range,
    required this.earlierFirst,
    required this.colours,
    required this.onTap,
    this.always,
  });

  final CalendarRange range;

  /// In order of date down the screen; false above the middle, where the
  /// list is laid out from the bottom up.
  final bool earlierFirst;
  final EventColours colours;
  final void Function(CalendarEvent) onTap;

  /// A day shown even with nothing on: the one the agenda opens at.
  final DateTime? always;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = ref.watch(calendarEventsProvider(range));
    final prefs = ref.watch(calendarPrefsProvider);
    final pending = ref.watch(calendarPendingProvider);
    final value = load.value;
    if (value == null) {
      return SliverToBoxAdapter(
        child: always == null
            ? const SizedBox(height: 24)
            : const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
      );
    }
    final events = shownEvents(withPending(value.events, pending), prefs);
    final days = <Widget>[];
    for (var d = range.start; d.isBefore(range.end); d = _plus(d, 1)) {
      final on = eventsOn(d, events);
      final keep = always != null && _sameDay(d, always!);
      if (on.isEmpty && !keep) continue;
      days.add(_AgendaDay(day: d, events: on, colours: colours, onTap: onTap));
    }
    return SliverList(
      delegate: SliverChildListDelegate(
        earlierFirst ? days : days.reversed.toList(),
      ),
    );
  }
}

/// A day's heading, and its events under it.
class _AgendaDay extends StatelessWidget {
  const _AgendaDay({
    required this.day,
    required this.events,
    required this.colours,
    required this.onTap,
  });

  final DateTime day;
  final List<CalendarEvent> events;
  final EventColours colours;
  final void Function(CalendarEvent) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = _midnight(DateTime.now());
    final name = formatDay(day);
    final label = _sameDay(day, today)
        ? 'Today · $name'
        : _sameDay(day, _plus(today, 1))
            ? 'Tomorrow · $name'
            : name;
    Widget row(CalendarEvent e, [DateTime? now]) => _AgendaRow(
          event: e,
          day: day,
          colour: colours[e] ?? theme.colorScheme.primary,
          onTap: () => onTap(e),
          now: now,
        );
    return Column(
      key: ValueKey('agenda-day:${_dayKey(day)}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: _sameDay(day, today) ? theme.colorScheme.primary : null,
            ),
          ),
        ),
        if (events.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Text(
              _sameDay(day, today)
                  ? 'Nothing on the calendar today.'
                  : 'Nothing on the calendar this day.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        if (_sameDay(day, today) && events.isNotEmpty)
          // Where you are in the day (#91): today's rows go by the time,
          // looked at again as the next meeting's "in 13 min" over the
          // mail is.
          MeetingTicker(
            builder: (context, _, now) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final e in events) row(e, now)],
            ),
          )
        else
          for (final e in events) row(e),
      ],
    );
  }
}

class _AgendaRow extends StatelessWidget {
  const _AgendaRow({
    required this.event,
    required this.day,
    required this.colour,
    required this.onTap,
    this.now,
  });

  final CalendarEvent event;
  final DateTime day;
  final Color colour;
  final VoidCallback onTap;

  /// The time, for a row of today's in the Agenda (#91): what is over is
  /// dimmed, as My Day dims it, and what is on says "Now" under its times.
  /// A whole day is neither. Null in the lists that draw the row too, the
  /// waiting list and a day under the month, where nothing is.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String clock(DateTime t) => formatClock(t, use24h: use24h);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final e = event;
    final startsToday = !e.start.isBefore(day);
    final endsToday = e.end.isBefore(_plus(day, 1)) ||
        e.end == _plus(day, 1) && !e.allDay;
    final (String first, String? second) = e.allDay
        ? ('All day', null)
        : (
            startsToday ? clock(e.start) : 'Until',
            startsToday
                ? (endsToday ? clock(e.end) : '…')
                : clock(e.end),
          );
    // Where it is, which gives way on a short line, and how you answered,
    // which never does (#90). A link in its place is named, not written
    // out: a Zoom link here was a line of letters with its passcode in it.
    final place = placeLine(e) ?? '';
    // Maybe, as the sheet's button says it (#93).
    final answer = [
      if (e.response == EventResponse.tentative) 'Maybe',
      if (e.response == EventResponse.notResponded) 'Not answered',
      if (e.declined) 'Declined',
      if (e.cancelled) 'Cancelled',
    ].join(' · ');
    final faint = e.showAs == EventShowAs.free || e.declined;
    final title = e.title.isEmpty ? '(No title)' : e.title;
    // As wide as the times need at this text size and clock (#90).
    final times = agendaTimesWidth(context);
    final now = this.now;
    final over = now != null && !e.allDay && !e.end.isAfter(now);
    final on = now != null &&
        !e.allDay &&
        !e.start.isAfter(now) &&
        e.end.isAfter(now);
    final row = InkWell(
      key: ValueKey('agenda-event:${e.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: agendaRowInset, vertical: 8),
        child: ConstrainedBox(
          // The colour's bar is never shorter than its 40 of old.
          constraints: const BoxConstraints(minHeight: 40),
          child: Stack(
            children: [
              // As tall as the row, however many lines its words take.
              PositionedDirectional(
                start: times,
                top: 0,
                bottom: 0,
                width: 4,
                child: DecoratedBox(
                  key: ValueKey('agenda-bar:${e.id}'),
                  decoration: BoxDecoration(
                    color: faint ? agendaFaintBar(colour, theme) : colour,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: times,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(first,
                            maxLines: 1,
                            softWrap: false,
                            style: theme.textTheme.bodyMedium),
                        if (second != null)
                          Text(second,
                              maxLines: 1, softWrap: false, style: muted),
                        if (on)
                          Text(
                            'Now',
                            maxLines: 1,
                            softWrap: false,
                            style: muted?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: agendaBarAndRoom),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // As wide as the room, laid out by its first
                        // letter, as a place is (#100): a Hebrew title
                        // reads from the right.
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            title,
                            textDirection: firstStrongDirection(title),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              decoration: e.cancelled || e.declined
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: e.declined
                                  ? theme.colorScheme.onSurfaceVariant
                                  : null,
                            ),
                          ),
                        ),
                        if (place.isNotEmpty || answer.isNotEmpty)
                          AgendaWhere(
                              place: place,
                              answer: answer,
                              reads: firstStrongDirection(title),
                              style: muted),
                      ],
                    ),
                  ),
                  if (e.joinUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        Icons.videocam_outlined,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    // What is over stays, faded, as My Day shows it.
    return now == null ? row : Opacity(opacity: over ? 0.5 : 1, child: row);
  }
}

/// [event] drawn as the Agenda draws it under [day]'s heading, for a list
/// of meetings beside it: those waiting for an answer (#50).
Widget agendaRow(
  CalendarEvent event, {
  required DateTime day,
  required Color colour,
  required VoidCallback onTap,
}) =>
    _AgendaRow(event: event, day: day, colour: colour, onTap: onTap);

// --- the month ------------------------------------------------------------------

/// A month as a grid, a week to a row: each day's number, and its events as
/// dots ([titles] false: the phone, and choosing a date) or as titles.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.days,
    required this.month,
    required this.events,
    required this.colours,
    required this.selected,
    required this.titles,
    required this.onDay,
    this.onEvent,
    this.rowHeight,
  });

  /// Whole weeks, from the first day of the month's first week.
  final List<DateTime> days;

  /// The first of the month shown; days outside it are drawn faint.
  final DateTime month;
  final List<CalendarEvent> events;
  final EventColours colours;
  final DateTime? selected;
  final bool titles;
  final void Function(DateTime) onDay;
  final void Function(CalendarEvent)? onEvent;

  /// Each week's height, or null for an equal share of what there is.
  final double? rowHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final weeks = [
      for (var w = 0; w < days.length ~/ 7; w++) days.sublist(w * 7, w * 7 + 7),
    ];
    // With titles, the grid fills the page to its foot, and the + button
    // stands over the last box's corner.
    final corner = titles ? plusButtonCorner(context) : null;
    Widget week(List<DateTime> row) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final d in row)
              Expanded(
                child: _MonthDay(
                  day: d,
                  inMonth: d.month == month.month,
                  selected: selected != null && _sameDay(d, selected!),
                  events: eventsOn(d, events),
                  colours: colours,
                  titles: titles,
                  onTap: () => onDay(d),
                  onEvent: onEvent,
                  button: identical(d, days.last) ? corner : null,
                ),
              ),
          ],
        );
    return Column(
      mainAxisSize: rowHeight == null ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Row(
          children: [
            for (final d in weeks.first)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    _weekdays[d.weekday - 1],
                    style: muted,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
        for (final row in weeks)
          if (rowHeight case final height?)
            SizedBox(height: height, child: week(row))
          else
            Expanded(child: week(row)),
      ],
    );
  }
}

class _MonthDay extends StatelessWidget {
  const _MonthDay({
    required this.day,
    required this.inMonth,
    required this.selected,
    required this.events,
    required this.colours,
    required this.titles,
    required this.onTap,
    required this.onEvent,
    this.button,
  });

  final DateTime day;
  final bool inMonth;
  final bool selected;
  final List<CalendarEvent> events;
  final EventColours colours;
  final bool titles;
  final VoidCallback onTap;
  final void Function(CalendarEvent)? onEvent;

  /// The corner of this box the + button stands over, from its bottom
  /// right, for the last box of the month on a tablet.
  final ({double width, double height})? button;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = _sameDay(day, DateTime.now());
    final scheme = theme.colorScheme;
    Color colourOf(CalendarEvent e) => colours[e] ?? scheme.primary;
    final number = Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? scheme.primary
            : today
                ? scheme.primaryContainer
                : null,
      ),
      child: Text(
        '${day.day}',
        style: theme.textTheme.labelLarge?.copyWith(
          color: selected
              ? scheme.onPrimary
              : !inMonth
                  ? scheme.onSurfaceVariant.withAlpha(120)
                  : today
                      ? scheme.onPrimaryContainer
                      : null,
          fontWeight: today || selected ? FontWeight.bold : null,
        ),
      ),
    );
    final Widget body;
    if (!titles) {
      body = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          number,
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final e in events.take(3))
                Container(
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: e.declined ? colourOf(e).withAlpha(90) : colourOf(e),
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ],
      );
    } else {
      final moreStyle = theme.textTheme.labelSmall
          ?.copyWith(color: scheme.onSurfaceVariant);
      body = LayoutBuilder(
        builder: (context, constraints) {
          // Each line as it is drawn, at the text size in force: its words,
          // the 1 dp above and below them, and the 1 under it.
          final scaler = MediaQuery.textScalerOf(context);
          final base = DefaultTextStyle.of(context).style;
          double heightOf(TextStyle? style) {
            final painter = TextPainter(
              text: TextSpan(text: 'Ag', style: base.merge(style)),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
            )..layout();
            final height = painter.height;
            painter.dispose();
            return height;
          }

          final line = heightOf(_MonthEvent.textStyle) + 3;
          final moreLine = heightOf(moreStyle);
          // Under the + button, the lines stop short of it: beside it
          // where the box is wide enough to leave them readable, above it
          // where it is not.
          var height = constraints.maxHeight;
          var inset = 0.0;
          if (button case final corner?) {
            if (constraints.maxWidth - corner.width >= 64) {
              inset = corner.width;
            } else {
              height -= corner.height;
            }
          }
          final room = height - 28;
          final all = events.length * line <= room + 0.01;
          final shown = all
              ? events
              : events
                  .take(math.max(0, ((room - moreLine) / line + 0.01).floor()))
                  .toList();
          final more = events.length - shown.length;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(alignment: Alignment.topLeft, child: number),
              const SizedBox(height: 2),
              for (final e in shown)
                Padding(
                  padding: EdgeInsets.only(right: inset),
                  child: _MonthEvent(
                    event: e,
                    colour: colourOf(e),
                    onTap: onEvent == null ? null : () => onEvent!(e),
                  ),
                ),
              if (more > 0 && room - shown.length * line >= moreLine - 0.01)
                Padding(
                  padding: EdgeInsets.only(left: 4, right: inset),
                  child: Text(
                    '+$more more',
                    style: moreStyle,
                    maxLines: 1,
                  ),
                ),
            ],
          );
        },
      );
    }
    return InkWell(
      key: ValueKey('month-day:${_dayKey(day)}'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.dividerColor, width: 0.5),
            left: BorderSide(color: theme.dividerColor, width: 0.5),
          ),
          color: inMonth ? null : scheme.surfaceContainerLow,
        ),
        child: ClipRect(child: body),
      ),
    );
  }
}

/// An event's line in a month box on a tablet.
class _MonthEvent extends StatelessWidget {
  const _MonthEvent({required this.event, required this.colour, this.onTap});

  final CalendarEvent event;
  final Color colour;
  final VoidCallback? onTap;

  /// A line's letters.
  static const textStyle = TextStyle(fontSize: 11);

  @override
  Widget build(BuildContext context) {
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final e = event;
    // As a block on the hours is drawn: see MeetingLook.
    final look = MeetingLook.of(
      e,
      colour,
      Theme.of(context).colorScheme,
      declinedTint: 40,
    );
    // A Hebrew title reads from the right, by its first letter as the
    // place link decides it, and the line still starts with its time: the
    // time kept whole in its own order (an isolate), at the right.
    final direction = firstStrongDirection(e.title);
    final time = formatClock(e.start, use24h: use24h);
    final text = e.allDay
        ? e.title
        : direction == TextDirection.rtl
            ? '\u2066$time\u2069 ${e.title}'
            : '$time ${e.title}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: CustomPaint(
        foregroundPainter:
            look.dashed ? DashedOutline(colour: colour, radius: 3) : null,
        child: Material(
          color: look.fill,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3),
            side: look.edge == null
                ? BorderSide.none
                : BorderSide(color: look.edge!),
          ),
          child: InkWell(
            key: ValueKey('month-event:${e.id}'),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              child: Text(
                text.isEmpty ? '(No title)' : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: direction,
                style: textStyle.copyWith(
                  color: look.ink,
                  decoration: e.cancelled || e.declined
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The picked day's events, under the month on a phone.
class _DayList extends StatelessWidget {
  const _DayList({
    required this.day,
    required this.events,
    required this.colours,
    required this.onTap,
    required this.onOpen,
  });

  final DateTime day;
  final List<CalendarEvent> events;
  final EventColours colours;
  final void Function(CalendarEvent) onTap;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        Padding(
          // 4 less above, for the 4 more Open day answers a tap over (#90).
          padding: const EdgeInsets.fromLTRB(16, 2, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(formatDay(day), style: theme.textTheme.labelLarge),
              ),
              TapTarget(
                child: TextButton(
                  key: const ValueKey('month-open-day'),
                  onPressed: onOpen,
                  child: const Text('Open day'),
                ),
              ),
            ],
          ),
        ),
        if (events.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'Nothing on the calendar this day.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        for (final e in events)
          _AgendaRow(
            event: e,
            day: day,
            colour: colours[e] ?? theme.colorScheme.primary,
            onTap: () => onTap(e),
          ),
      ],
    );
  }
}

// --- choosing a date ------------------------------------------------------------

/// A month to choose a day from, with a dot on the days that have events:
/// the calendar's title opens it, as Outlook's does.
Future<DateTime?> pickCalendarDate(BuildContext context, DateTime initial) =>
    showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => _DatePicker(initial: initial),
    );

class _DatePicker extends ConsumerStatefulWidget {
  const _DatePicker({required this.initial});

  final DateTime initial;

  @override
  ConsumerState<_DatePicker> createState() => _DatePickerState();
}

class _DatePickerState extends ConsumerState<_DatePicker> {
  late DateTime _month = DateTime(widget.initial.year, widget.initial.month);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = calendarPage(
      CalendarViewMode.month,
      WeekSpan.sevenDays,
      ref.watch(workWeekProvider),
      _month,
      0,
    );
    final load = ref.watch(calendarEventsProvider(page.range));
    final prefs = ref.watch(calendarPrefsProvider);
    final accounts = ref.watch(calendarAccountsProvider);
    final colours = EventColours(
      accounts: {for (final a in accounts) a.id: Color(a.colorValue)},
      calendars: load.value?.calendars ?? const {},
    );
    void step(int months) =>
        setState(() => _month = DateTime(_month.year, _month.month + months));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  key: const ValueKey('pick-previous'),
                  tooltip: 'Month before',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => step(-1),
                ),
                Expanded(
                  child: Text(
                    '${_months[_month.month - 1]} ${_month.year}',
                    key: const ValueKey('pick-month'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: const ValueKey('pick-next'),
                  tooltip: 'Month after',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => step(1),
                ),
              ],
            ),
            _MonthGrid(
              days: page.days,
              month: _month,
              events: shownEvents(load.value?.events ?? const [], prefs),
              colours: colours,
              selected: widget.initial,
              titles: false,
              rowHeight: 44,
              onDay: (d) => Navigator.of(context).pop(d),
            ),
            TextButton(
              key: const ValueKey('pick-today'),
              onPressed: () => Navigator.of(context).pop(DateTime.now()),
              child: const Text('Today'),
            ),
          ],
        ),
      ),
    );
  }
}

// --- the day and the week ---------------------------------------------------------

/// Days side by side, hour by hour: the day view, and the week's. Pinch to
/// make the hours taller or shorter; hold a meeting of the account's own to
/// drag it to another time, or by its foot to make it longer or shorter.
class _Timeline extends ConsumerStatefulWidget {
  const _Timeline({
    required this.days,
    required this.events,
    required this.colours,
    required this.prefs,
    required this.topHour,
    required this.onTap,
    required this.onSlot,
    required this.onPinching,
    this.onMove,
    this.onDay,
  });

  final List<DateTime> days;
  final List<CalendarEvent> events;
  final EventColours colours;
  final CalendarPrefs prefs;

  /// The hour at the top, shared with the pages either side.
  final ValueNotifier<double> topHour;
  final void Function(CalendarEvent) onTap;

  /// A new meeting at a time tapped on.
  final void Function(DateTime) onSlot;

  /// A day's name tapped on, in the week.
  final void Function(DateTime)? onDay;

  /// A pinch or a drag begun, or ended: the pages hold still for it.
  final void Function(bool) onPinching;

  /// A meeting dragged to new times.
  final void Function(CalendarEvent, DateTime, DateTime)? onMove;

  @override
  ConsumerState<_Timeline> createState() => _TimelineState();
}

/// A meeting being dragged: from which day and minute it was taken, and the
/// times it would have if let go now.
class _Drag {
  _Drag({
    required this.event,
    required this.resize,
    required this.fromDay,
    required this.fromMinute,
  })  : start = event.start,
        end = event.end;

  final CalendarEvent event;

  /// Taken by its foot: the end moves, the start stays.
  final bool resize;
  final int fromDay;
  final int fromMinute;
  DateTime start;
  DateTime end;

  CalendarEvent get moved => event.copyWith(start: start, end: end);
}

class _TimelineState extends ConsumerState<_Timeline> {
  /// The hours down the side: the phone's own, and a second zone's beside
  /// them where Settings, Calendar names one. As wide as the labels need
  /// at the text size and clock in force, measured as the page is built.
  double get gutter => _scale?.width ?? 48.0;
  HourScale? _scale;
  Object? _scaleFor;

  HourScale _hourScale(TextStyle style, bool use24h) {
    final scaler = MediaQuery.textScalerOf(context);
    final zone = widget.prefs.secondZone;
    final day = widget.days.first;
    final key = (style, scaler, use24h, zone, day);
    final kept = _scale;
    if (kept != null && _scaleFor == key) return kept;
    _scaleFor = key;
    return _scale = HourScale.measure(
      style: style,
      scaler: scaler,
      use24h: use24h,
      day: day,
      zone: zone,
    );
  }

  /// How far the hours sit below the top of their scroll, so the label at
  /// the top shows whole: [HourScale.inset].
  double get _inset => _scale?.inset ?? 0;

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: widget.topHour.value * ref.read(calendarHourHeightProvider),
  );

  /// The hour's height while a pinch is under way, kept once it ends.
  double? _pinched;
  final Map<int, Offset> _pointers = {};
  double _pinchFrom = 0;
  double _heightFrom = 0;
  double _focusHour = 0;
  double _focusY = 0;

  /// A scroll this page made to follow another, not to be passed on.
  bool _following = false;

  /// The meeting being dragged, and the hours it is dragged over.
  _Drag? _drag;
  final GlobalKey _hours = GlobalKey();

  double get _height => _pinched ?? ref.read(calendarHourHeightProvider);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scrolled);
    widget.topHour.addListener(_follow);
  }

  @override
  void dispose() {
    widget.topHour.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }

  void _scrolled() {
    if (_following || _pinched != null || !_scroll.hasClients) return;
    widget.topHour.value = _scroll.offset / _height;
  }

  void _follow() {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return;
    final want = (widget.topHour.value * _height)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if ((_scroll.offset - want).abs() < 1) return;
    _following = true;
    _scroll.jumpTo(want);
    _following = false;
  }

  double _spread() {
    final points = _pointers.values.toList();
    return (points[0].dy - points[1].dy).abs();
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length != 2) return;
    final spread = _spread();
    if (spread < 24) return;
    _pinchFrom = spread;
    _heightFrom = _height;
    final points = _pointers.values.toList();
    _focusY = (points[0].dy + points[1].dy) / 2;
    _focusHour = (_scroll.offset + _focusY - _inset) / _heightFrom;
    setState(() => _pinched = _heightFrom);
    widget.onPinching(true);
  }

  void _moved(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pinched == null || _pointers.length != 2) return;
    final height = (_heightFrom * _spread() / _pinchFrom)
        .clamp(CalendarHourHeight.smallest, CalendarHourHeight.largest);
    setState(() => _pinched = height);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final at = (_focusHour * height + _inset - _focusY)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      _following = true;
      _scroll.jumpTo(at);
      _following = false;
    });
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    final height = _pinched;
    if (height == null || _pointers.length >= 2) return;
    ref.read(calendarHourHeightProvider.notifier).set(height);
    setState(() => _pinched = null);
    widget.onPinching(false);
    if (_scroll.hasClients) widget.topHour.value = _scroll.offset / height;
  }

  /// Which day's column and which minute of it [global] is over.
  (int, int)? _pointAt(Offset global) {
    final box = _hours.currentContext?.findRenderObject();
    if (box is! RenderBox) return null;
    final local = box.globalToLocal(global);
    final columns = widget.days.length;
    final width = (box.size.width - gutter) / columns;
    final day = ((local.dx - gutter) / width).floor().clamp(0, columns - 1);
    return (day, (local.dy / _height * 60).round());
  }

  void _take(CalendarEvent event, Offset global, {required bool resize}) {
    final at = _pointAt(global);
    if (at == null) return;
    HapticFeedback.selectionClick();
    setState(() => _drag = _Drag(
          event: event,
          resize: resize,
          fromDay: at.$1,
          fromMinute: at.$2,
        ));
    widget.onPinching(true);
  }

  /// To the quarter hour, as Outlook moves a meeting. By the clock, as the
  /// hours are drawn, so a drag across the hour the clocks change lands
  /// where it was dropped.
  void _dragTo(Offset global) {
    final d = _drag;
    final at = _pointAt(global);
    if (d == null || at == null) return;
    final minutes = _keptInDay(
      d,
      ((at.$2 - d.fromMinute) / 15).round() * 15,
    );
    final days = at.$1 - d.fromDay;
    setState(() {
      // Not moved at all: as it was, to the second, so a wobble under a
      // quarter hour is not a change to send.
      if (minutes == 0 && (d.resize || days == 0)) {
        d.start = d.event.start;
        d.end = d.event.end;
        return;
      }
      // The clock read on this phone's time, whatever zone the calendar
      // handed the time over in.
      if (d.resize) {
        final e = d.event.end.toLocal();
        final end =
            DateTime(e.year, e.month, e.day, e.hour, e.minute + minutes);
        final shortest = d.event.start.add(const Duration(minutes: 15));
        d.end = end.isAfter(shortest) ? end : shortest;
        return;
      }
      final s = d.event.start.toLocal();
      final start = DateTime(
          s.year, s.month, s.day + days, s.hour, s.minute + minutes);
      d.start = start;
      d.end = start.add(d.event.end.difference(d.event.start));
    });
  }

  /// [minutes] for [d], kept inside the day by the clock, in quarter hours
  /// from where it was: the room over midnight and under it, where the
  /// hours end, is not hours, and a meeting dragged into it stops at
  /// midnight, or the last quarter hour short of it. The day is that of
  /// the column the meeting was taken in. A meeting within that day stops
  /// with its start at the midnight before and its end at the midnight
  /// after; one across midnight moves as it did, its start kept by 23:45
  /// of that day (and, where it starts on it, after its midnight). Its foot
  /// stops at the midnight after the day it ends on. To another day a
  /// meeting goes across the columns.
  int _keptInDay(_Drag d, int minutes) {
    // Whole quarter hours, toward none.
    int quarters(int m) => m ~/ 15 * 15;
    int wall(DateTime t) => t.hour * 60 + t.minute;
    final s = d.event.start.toLocal();
    final e = d.event.end.toLocal();
    if (d.resize) {
      // Its end on the day it ends, one ending at midnight counted at the
      // end of the day before.
      final endWall = e.hour == 0 && e.minute == 0 ? 24 * 60 : wall(e);
      return math.min(minutes, quarters(24 * 60 - endWall));
    }
    final column = widget.days[d.fromDay];
    // By the clock, from the column's midnight.
    int fromColumn(DateTime t) =>
        DateTime.utc(t.year, t.month, t.day)
                .difference(DateTime.utc(column.year, column.month, column.day))
                .inDays *
            24 *
            60 +
        wall(t);
    final from = fromColumn(s);
    final to = fromColumn(e);
    if (from >= 0 && to <= 24 * 60) {
      return minutes.clamp(-quarters(from), quarters(24 * 60 - to));
    }
    final earliest = -quarters(from >= 0 ? from : wall(s));
    final latest = quarters(24 * 60 - 15 - from);
    return minutes.clamp(earliest, math.max(earliest, latest));
  }

  void _drop() {
    final d = _drag;
    if (d == null) return;
    setState(() => _drag = null);
    widget.onPinching(false);
    if (d.start != d.event.start || d.end != d.event.end) {
      widget.onMove?.call(d.event, d.start, d.end);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final double hourHeight =
        _pinched ?? ref.watch(calendarHourHeightProvider);
    final now = DateTime.now();
    final muted = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final scale = _hourScale(
      DefaultTextStyle.of(context).style.merge(muted),
      use24h,
    );
    final button = plusButtonCorner(context);
    final allDay = {
      for (final d in widget.days)
        d: [
          for (final e in eventsOn(d, widget.events))
            if (e.allDay) e,
        ],
    };
    final anyAllDay = allDay.values.any((l) => l.isNotEmpty);
    final folded = ref.watch(calendarAllDayFoldedProvider);
    final fold = ref.read(calendarAllDayFoldedProvider.notifier).toggle;
    Widget words() => Text(
          HourScale.allDay,
          style: muted,
          maxLines: 1,
          softWrap: false,
        );
    Widget block(CalendarEvent e) => _Block(
          event: e,
          colour: widget.colours[e] ?? theme.colorScheme.primary,
          edge: widget.colours.edgeOf(e),
          onTap: () => widget.onTap(e),
          compact: true,
        );
    return Column(
      children: [
        Row(
          children: [
            SizedBox(
              width: gutter,
              child: widget.prefs.secondZone == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        placeOf(widget.prefs.secondZone!),
                        key: const ValueKey('second-zone-name'),
                        style: muted,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
            ),
            for (final d in widget.days)
              Expanded(
                child: InkWell(
                  key: ValueKey(widget.onDay == null
                      ? 'day-head:${_dayKey(d)}'
                      : 'week-day:${_dayKey(d)}'),
                  onTap: widget.onDay == null ? null : () => widget.onDay!(d),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        Text(_weekdays[d.weekday - 1], style: muted),
                        Text(
                          '${d.day}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: _sameDay(d, now)
                                ? theme.colorScheme.primary
                                : null,
                            fontWeight:
                                _sameDay(d, now) ? FontWeight.bold : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (anyAllDay)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The group bars' arrow before the words: a tap folds every
                // day's all-day events to one line, and opens them again.
                // The words on one line, and the arrow under them where the
                // hours' column is too narrow for it beside them.
                SizedBox(
                  width: gutter,
                  child: Tooltip(
                    message: folded
                        ? 'Show all-day events'
                        : 'Fold all-day events',
                    child: InkWell(
                      key: const ValueKey('all-day-fold'),
                      onTap: fold,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(2, 4, 2, 2),
                        child: Flex(
                          direction: scale.arrowBeside
                              ? Axis.horizontal
                              : Axis.vertical,
                          crossAxisAlignment: scale.arrowBeside
                              ? CrossAxisAlignment.center
                              : CrossAxisAlignment.start,
                          children: [
                            if (!scale.arrowBeside) words(),
                            AnimatedRotation(
                              turns: folded ? -0.25 : 0,
                              duration: const Duration(milliseconds: 150),
                              child: Icon(
                                Icons.expand_more,
                                size: HourScale.arrow,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (scale.arrowBeside) ...[
                              const SizedBox(width: HourScale.arrowGap),
                              words(),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                for (final d in widget.days)
                  Expanded(
                    child: !folded
                        ? Column(
                            children: [for (final e in allDay[d]!) block(e)],
                          )
                        // Folded, a day's first, and how many more: a tap
                        // on the count opens them all.
                        : allDay[d]!.isEmpty
                            ? const SizedBox.shrink()
                            : Row(
                                children: [
                                  Expanded(child: block(allDay[d]!.first)),
                                  if (allDay[d]!.length > 1)
                                    InkWell(
                                      key: ValueKey(
                                        'all-day-more:${_dayKey(d)}',
                                      ),
                                      onTap: fold,
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          3,
                                          0,
                                          3,
                                          2,
                                        ),
                                        child: Text(
                                          '+${allDay[d]!.length - 1}',
                                          style: muted,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: Listener(
            onPointerDown: _down,
            onPointerMove: _moved,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: SingleChildScrollView(
              controller: _scroll,
              physics: _pinched != null
                  ? const NeverScrollableScrollPhysics()
                  : null,
              // Room over midnight for half a label, so the hour opened at
              // shows its label whole under the all-day row; and under
              // midnight to scroll the last hours clear of the + button.
              padding: EdgeInsets.only(
                top: scale.inset,
                bottom: button.height == 0
                    ? 0
                    : button.height + kFloatingActionButtonMargin,
              ),
              child: SizedBox(
                key: _hours,
                height: 24 * hourHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: gutter,
                            child: Stack(
                              children: [
                                // Each label centred on its hour's line.
                                for (var h = 1; h < 24; h++) ...[
                                  if (scale.second.isNotEmpty)
                                    Positioned(
                                      top: h * hourHeight -
                                          scale.lineHeight / 2,
                                      left: HourScale.start,
                                      child: Text(
                                        scale.second[h - 1],
                                        key: ValueKey('second-zone-hour:$h'),
                                        style: muted?.copyWith(
                                          color: muted.color?.withAlpha(150),
                                        ),
                                      ),
                                    ),
                                  Positioned(
                                    top: h * hourHeight - scale.lineHeight / 2,
                                    right: HourScale.end,
                                    child: Text(
                                      scale.own[h - 1],
                                      key: ValueKey('hour:$h'),
                                      style: muted,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          for (final d in widget.days)
                            Expanded(
                              child: _DayColumn(
                                day: d,
                                events: [
                                  for (final e in eventsOn(d, widget.events))
                                    if (!e.allDay) e,
                                ],
                                colours: widget.colours,
                                hourHeight: hourHeight,
                                prefs: widget.prefs,
                                onTap: widget.onTap,
                                onSlot: widget.onSlot,
                                dragged: _drag?.event,
                                ghost: _drag?.moved,
                                onTake: widget.onMove == null ? null : _take,
                                onDrag: _dragTo,
                                onDrop: _drop,
                              ),
                            ),
                        ],
                      ),
                    ),
                    // The present time's mark, over the meetings.
                    NowMark(
                      days: widget.days,
                      hourHeight: hourHeight,
                      left: gutter,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.events,
    required this.colours,
    required this.hourHeight,
    required this.prefs,
    required this.onTap,
    required this.onSlot,
    this.dragged,
    this.ghost,
    this.onTake,
    this.onDrag,
    this.onDrop,
  });

  final DateTime day;
  final List<CalendarEvent> events;
  final EventColours colours;
  final double hourHeight;
  final CalendarPrefs prefs;
  final void Function(CalendarEvent) onTap;
  final void Function(DateTime) onSlot;

  /// The meeting being dragged, drawn faint where it was, and where it
  /// would go, drawn over the day it would go to.
  final CalendarEvent? dragged;
  final CalendarEvent? ghost;

  /// Held for a drag, which only a meeting of the account's own takes.
  final void Function(CalendarEvent, Offset, {required bool resize})? onTake;
  final void Function(Offset)? onDrag;
  final VoidCallback? onDrop;

  bool _canDrag(CalendarEvent e) =>
      onTake != null &&
      isOwnEvent(e) &&
      !e.cancelled &&
      !e.allDay &&
      !e.readOnly &&
      !isInternetAccount(e.accountId);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayEnd = _plus(day, 1);
    // By the clock, as the hours down the side are: on the days the clocks
    // change, the time since midnight is an hour more or less than that.
    // This phone's clock: a calendar from a link hands over times in UTC.
    double y(DateTime t) {
      if (!t.isAfter(day)) return 0;
      if (!t.isBefore(dayEnd)) return 24 * hourHeight;
      final here = t.toLocal();
      return (here.hour * 60 + here.minute) / 60 * hourHeight;
    }

    final offHours = theme.colorScheme.surfaceContainerHighest.withAlpha(110);
    // However short a meeting, its block is drawn tall enough to read a
    // line and to tap, and laid out by that height: one starting as a
    // short one ends sits beside it, not under it. Never past half an
    // hour's height, though, so with the hours pinched small an ordinary
    // day of half hours stays one under the other, full width.
    final shortest = math.min(
      BlockText.minHeight(context, _Block.textStyle),
      hourHeight / 2,
    );
    final drawn = Duration(
      minutes: math.min(30, (shortest / hourHeight * 60).ceil()),
    );
    // Where a meeting's block goes: from its start, as tall as its time or
    // the least height, and inside the day: one drawn taller than its time
    // just before midnight is lifted to end there, not cut through.
    ({double top, double height}) blockAt(CalendarEvent e) {
      final height = math.max(shortest, y(e.end) - y(e.start));
      return (
        top: math.min(y(e.start), 24 * hourHeight - height),
        height: height,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            // To the half hour it falls in, by the clock.
            final minutes =
                (details.localPosition.dy / hourHeight * 60 ~/ 30) * 30;
            onSlot(DateTime(day.year, day.month, day.day, 0, minutes));
          },
          child: Stack(
            children: [
              // Outside the working day, shaded as Outlook shades it.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: prefs.dayStart * hourHeight,
                child: ColoredBox(color: offHours),
              ),
              Positioned(
                top: prefs.dayEnd * hourHeight,
                left: 0,
                right: 0,
                bottom: 0,
                child: ColoredBox(color: offHours),
              ),
              for (var h = 0; h < 24; h++)
                Positioned(
                  top: h * hourHeight,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: hourHeight,
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: theme.dividerColor, width: 0.5),
                        left: BorderSide(color: theme.dividerColor, width: 0.5),
                      ),
                    ),
                  ),
                ),
              // The present time, under the meetings: it moves on its own.
              NowLine(day: day, hourHeight: hourHeight),
              for (final slot
                  in layOutDay(events, shortest: drawn, dayEnd: dayEnd))
                Positioned(
                  top: blockAt(slot.event).top,
                  height: blockAt(slot.event).height,
                  left: width * slot.column / slot.columns + 1,
                  width: width / slot.columns - 2,
                  child: Opacity(
                    opacity: dragged != null && _same(dragged!, slot.event)
                        ? 0.35
                        : 1,
                    child: !_canDrag(slot.event)
                        ? _Block(
                            event: slot.event,
                            colour: colours[slot.event] ??
                                theme.colorScheme.primary,
                            edge: colours.edgeOf(slot.event),
                            onTap: () => onTap(slot.event),
                          )
                        : LayoutBuilder(
                            builder: (context, box) => GestureDetector(
                              onLongPressStart: (d) => onTake!(
                                slot.event,
                                d.globalPosition,
                                // Its foot: the bottom quarter, where there
                                // is room to tell the two apart.
                                resize: box.maxHeight >= 24 &&
                                    d.localPosition.dy > box.maxHeight * 0.75,
                              ),
                              onLongPressMoveUpdate: (d) =>
                                  onDrag?.call(d.globalPosition),
                              onLongPressEnd: (_) => onDrop?.call(),
                              onLongPressCancel: () => onDrop?.call(),
                              child: _Block(
                                event: slot.event,
                                colour: colours[slot.event] ??
                                    theme.colorScheme.primary,
                                edge: colours.edgeOf(slot.event),
                                onTap: () => onTap(slot.event),
                              ),
                            ),
                          ),
                  ),
                ),
              if (ghost case final g? when g.fallsOn(day))
                Positioned(
                  top: blockAt(g).top,
                  height: blockAt(g).height,
                  left: 1,
                  right: 1,
                  child: IgnorePointer(
                    child: Container(
                      key: const ValueKey('calendar-drag-ghost'),
                      decoration: BoxDecoration(
                        color: (colours[g] ?? theme.colorScheme.primary)
                            .withAlpha(140),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: colours[g] ?? theme.colorScheme.primary,
                          width: 2,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Text(
                        '${g.title}\n${formatClock(g.start, use24h: MediaQuery.alwaysUse24HourFormatOf(context))}'
                        '–${formatClock(g.end, use24h: MediaQuery.alwaysUse24HourFormatOf(context))}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

bool _same(CalendarEvent a, CalendarEvent b) =>
    a.id == b.id && a.accountId == b.accountId && a.calendarId == b.calendarId;

/// An event as a block of its account's colour.
class _Block extends StatelessWidget {
  const _Block({
    required this.event,
    required this.colour,
    required this.onTap,
    this.compact = false,
    this.edge,
  });

  final CalendarEvent event;
  final Color colour;
  final VoidCallback onTap;
  final bool compact;

  /// The account's colour, down the left, for an event drawn in a colour
  /// of its own: an Outlook category, a colour picked in Google Calendar,
  /// or its calendar's.
  final Color? edge;

  /// A block's letters.
  static const textStyle = TextStyle(fontSize: 12);

  @override
  Widget build(BuildContext context) {
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    // Black or white words on a solid block, the page's own on a faint one
    // (tentative, not answered, free, declined), which is opaque and edged
    // in the meeting's colour: dashed while the answer is open.
    final look = MeetingLook.of(event, colour, Theme.of(context).colorScheme);
    final style = textStyle.copyWith(
      color: look.ink,
      decoration: event.cancelled || event.declined
          ? TextDecoration.lineThrough
          : null,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 2 : 0),
      child: CustomPaint(
        foregroundPainter: look.dashed ? DashedOutline(colour: colour) : null,
        child: Material(
          color: look.fill,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: look.edge == null
                ? BorderSide.none
                : BorderSide(color: look.edge!),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('calendar-event:${event.id}'),
            onTap: onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: edge == null
                    ? null
                    : Border(left: BorderSide(color: edge!, width: 3)),
              ),
              child: Padding(
                padding: BlockText.padding,
                child: compact || event.allDay
                    ? SizedBox(
                        width: double.infinity,
                        child: Text(
                          event.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                          textDirection: firstStrongDirection(event.title),
                        ),
                      )
                    : BlockText(
                        title: event.title,
                        place: placeLine(event),
                        time: formatClock(event.start, use24h: use24h),
                        style: style,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- an event, opened -------------------------------------------------------------

/// The calendar on [meeting]'s day, with its sheet over it: a reminder,
/// the widget or a link tapped for it. The sheet only where the device
/// kept the meeting; the day alone otherwise.
Future<void> openMeeting(
  BuildContext context,
  WidgetRef ref,
  MeetingRef meeting,
) async {
  final event = await findKeptMeeting(ref.read(mailEngineProvider), meeting);
  if (!context.mounted) return;
  await CalendarScreen.open(
    context,
    day: event?.start ?? meeting.start,
    event: event,
  );
}

/// [event]'s details, and what can be done with it: answer it, join it,
/// change it, write to the people on it. Each action closes the sheet and
/// runs on the calendar screen's own [context] and [ref].
Future<void> showEventDetails(
  BuildContext context,
  WidgetRef ref,
  CalendarEvent event,
  Account? account,
) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => _EventDetails(
        event: event,
        account: account,
        host: context,
        hostRef: ref,
      ),
    );

/// How a meeting's people answered, counted for its organiser: Outlook's
/// Tracking. The organiser's own entry and the account's are not counted.
typedef AnswerCounts = ({
  int accepted,
  int tentative,
  int declined,
  int notAnswered,
});

AnswerCounts answerCounts(CalendarEvent event, String ownEmail) {
  final own = ownEmail.trim().toLowerCase();
  var accepted = 0, tentative = 0, declined = 0, waiting = 0;
  for (final a in event.attendees) {
    if (a.response == EventResponse.organizer ||
        a.address.email.trim().toLowerCase() == own) {
      continue;
    }
    switch (a.response) {
      case EventResponse.accepted:
        accepted++;
      case EventResponse.tentative:
        tentative++;
      case EventResponse.declined:
        declined++;
      default:
        waiting++;
    }
  }
  return (
    accepted: accepted,
    tentative: tentative,
    declined: declined,
    notAnswered: waiting,
  );
}

/// How the people in [people] answered, as their marks on the sheet show
/// it, for the counts of someone else's meeting folded (#93): the
/// organiser as accepted, Ron and the organiser counted too, and one not
/// given yet as not answered, Google's needsAction and Exchange's none
/// alike, so the counts add up to the heading. Only for a copy that
/// carries people's answers: where it carries none, "none" is no answer
/// anyone knows of, and the sheet counts nothing.
AnswerCounts countAsListed(List<EventAttendee> people) {
  var accepted = 0, tentative = 0, declined = 0, waiting = 0;
  for (final a in people) {
    switch (a.response) {
      case EventResponse.accepted || EventResponse.organizer:
        accepted++;
      case EventResponse.tentative:
        tentative++;
      case EventResponse.declined:
        declined++;
      case EventResponse.notResponded || EventResponse.none:
        waiting++;
    }
  }
  return (
    accepted: accepted,
    tentative: tentative,
    declined: declined,
    notAnswered: waiting,
  );
}

/// [counts] as the sheet says them: "5 accepted · 1 maybe · 2 not
/// answered", leaving out what is none. Maybe, as the button says it
/// (#93).
String describeAnswers(AnswerCounts counts) => [
      if (counts.accepted > 0) '${counts.accepted} accepted',
      if (counts.tentative > 0) '${counts.tentative} maybe',
      if (counts.declined > 0) '${counts.declined} declined',
      if (counts.notAnswered > 0) '${counts.notAnswered} not answered',
    ].join(' · ');

/// Where [event] was set in another zone than the phone's ([deviceZone]),
/// that zone's times for it: "Set in New York time: 10:00–11:00". Null for
/// one set in the phone's own, a whole day, or a zone not known.
String? setInZone(
  CalendarEvent event,
  String? deviceZone, {
  required bool use24h,
}) {
  final named = event.timeZone;
  if (event.allDay || named == null) return null;
  final zone = ianaZoneOf(named);
  if (zone == null) return null;
  if (deviceZone != null && ianaZoneOf(deviceZone) == zone) return null;
  final from = wallClockIn(event.start, zone);
  final to = wallClockIn(event.end, zone);
  // The same clock, under another name: nothing to say.
  if (from == event.start && to == event.end) return null;
  return 'Set in ${placeOf(zone)} time: ${formatClock(from, use24h: use24h)}'
      '–${formatClock(to, use24h: use24h)}';
}

class _EventDetails extends StatelessWidget {
  const _EventDetails({
    required this.event,
    required this.account,
    required this.host,
    required this.hostRef,
  });

  final CalendarEvent event;
  final Account? account;
  final BuildContext host;
  final WidgetRef hostRef;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String clock(DateTime t) => formatClock(t, use24h: use24h);
    final e = event;
    final account = this.account;
    final email = account?.emailAddress ?? '';
    final own = isOwnEvent(e);
    final others = hasOthers(e, email);
    // Only a calendar the app reaches takes a change; the rest is mail.
    // A calendar the account only reads (holidays, birthdays, one shared
    // to look at) takes nothing from here either.
    final reachable =
        account != null && AccountCalendar.canRead(account) && !e.readOnly;
    final microsoft = account?.provider == MailProvider.outlook;
    final invited = !own && e.organizer != null && !e.cancelled;
    final now = DateTime.now();
    final soon = !e.allDay &&
        others &&
        now.isAfter(e.start.subtract(const Duration(hours: 1))) &&
        now.isBefore(e.end);
    final lastDay = _plus(e.end, -1);
    final when = e.allDay
        ? (_sameDay(e.start, lastDay) || !lastDay.isAfter(e.start)
            ? 'All day, ${formatDay(e.start)}'
            : 'All day, ${formatDay(e.start)} to ${formatDay(lastDay)}')
        : _sameDay(e.start, e.end)
            ? '${formatDay(e.start)}, ${clock(e.start)}–${clock(e.end)}'
            : '${formatDay(e.start)}, ${clock(e.start)} to '
                '${formatDay(e.end)}, ${clock(e.end)}';
    final answer = switch (e.response) {
      EventResponse.organizer => 'You organised it',
      EventResponse.accepted => 'You accepted',
      EventResponse.tentative => 'You said maybe',
      EventResponse.declined => 'You declined',
      EventResponse.notResponded => 'Not answered yet',
      EventResponse.none => null,
    };
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Future<void> open(String url) async {
      final uri = Uri.tryParse(url);
      if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
    }

    /// Close the sheet, then [act] on the calendar screen.
    void then(
      Future<void> Function(BuildContext, WidgetRef, CalendarEvent) act,
    ) {
      Navigator.of(context).pop();
      act(host, hostRef, e);
    }

    final counts = answerCounts(e, email);
    // Those invited, as the answers count them: not you, who organised it
    // (#100). None where you organised it from another of your addresses
    // and nobody else is on it: then there is nothing to count.
    final invitedCount = counts.accepted +
        counts.tentative +
        counts.declined +
        counts.notAnswered;
    final tracked = own && others && invitedCount > 0;
    final waiting = notAnswered(e, email);
    // The people as listed. On someone else's meeting Ron's own row has
    // the answer the sheet has for him: Exchange keeps the people's answers
    // on the organiser's copy alone and gives "none" for everyone on Ron's,
    // Ron too (#93).
    final listed = own ? _byAnswer(e.attendees) : _withOwnAnswer(e, email);
    // Whether Ron's copy of someone else's meeting carries the people's
    // answers: it does where anyone but Ron and the organiser has one.
    // Exchange Online gives an attendee the others' answers, with "none"
    // for one not given yet (seen on Hadco's, 2026-11-16: eight of eleven
    // accepted, and 3.17.0 counted nothing). A calendar that keeps them on
    // the organiser's copy alone gives "none" for everyone, and there
    // nothing is counted: "1 accepted" of twelve, Ron alone known, would
    // read as the list's.
    final me = email.trim().toLowerCase();
    final carried = !own &&
        listed.any((a) =>
            a.address.email.trim().toLowerCase() != me &&
            switch (a.response) {
              EventResponse.accepted ||
              EventResponse.tentative ||
              EventResponse.declined ||
              EventResponse.notResponded =>
                true,
              EventResponse.organizer || EventResponse.none => false,
            });
    // [filled]: the one that matters now (#93), Accept on a meeting not
    // answered while Join is not near.
    Widget answerButton(InviteResponse r, String label, String key,
        {bool filled = false}) {
      final chosen = e.response == eventResponseFor(r);
      return TapTarget(child: Builder(builder: (button) {
        // Asked first, as Outlook asks, from a menu under the button while
        // the sheet is still up; answered once it has closed.
        Future<void> tap() async {
          // Its invitation looked for while this is asked, before the
          // answer goes: a decline takes a Microsoft meeting off (#51).
          final lookup = InvitationClearing.before(host, hostRef)?.lookUp(e);
          final answer = await askHowToAnswer(
            context,
            r,
            title: e.title,
            anchor: button,
          );
          if (answer == null || !context.mounted) return;
          then((c, ref, ev) => answerEvent(c, ref, ev, r,
              note: answer.note, send: answer.send, lookup: lookup));
        }

        if (filled) {
          return FilledButton(
            key: ValueKey(key),
            onPressed: tap,
            child: Text(label),
          );
        }
        return chosen
            ? FilledButton.tonal(
                key: ValueKey(key),
                onPressed: tap,
                child: Text(label),
              )
            : OutlinedButton(
                key: ValueKey(key),
                onPressed: tap,
                child: Text(label),
              );
      }));
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 20),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    e.title.isEmpty ? '(No title)' : e.title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      decoration: e.cancelled || e.declined
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                ),
                if (reachable || e.webLink != null)
                  PopupMenuButton<String>(
                    key: const ValueKey('event-more'),
                    tooltip: 'More',
                    onSelected: (choice) => switch (choice) {
                      'email' => then(emailEveryone),
                      'invite' => then(invitePeople),
                      'propose' => then(proposeForEvent),
                      'duplicate' => then(duplicateEvent),
                      'remove' => then(cancelOrDeleteEvent),
                      // The sheet stays, as it did for the button.
                      'web' => open(e.webLink!),
                      _ => null,
                    },
                    itemBuilder: (context) => [
                      if (reachable) ...[
                        if (others)
                          const PopupMenuItem(
                            key: ValueKey('event-email'),
                            value: 'email',
                            child: Text('Email everyone'),
                          ),
                        if (own || microsoft)
                          PopupMenuItem(
                            key: const ValueKey('event-invite'),
                            value: 'invite',
                            child: Text(own ? 'Invite people' : 'Forward'),
                          ),
                        if (invited && microsoft)
                          const PopupMenuItem(
                            key: ValueKey('event-propose'),
                            value: 'propose',
                            child: Text('Propose a new time'),
                          ),
                        const PopupMenuItem(
                          key: ValueKey('event-duplicate'),
                          value: 'duplicate',
                          child: Text('Duplicate'),
                        ),
                        PopupMenuItem(
                          key: const ValueKey('event-remove'),
                          value: 'remove',
                          child: Text(own
                              ? (others ? 'Cancel meeting' : 'Delete')
                              : e.cancelled
                                  ? 'Remove from calendar'
                                  : 'Decline and remove'),
                        ),
                      ],
                      // Last, for every meeting that has it, one on a
                      // calendar only read too: a row of buttons of its own
                      // on the sheet until #93.
                      if (e.webLink != null)
                        PopupMenuItem(
                          key: const ValueKey('event-web'),
                          value: 'web',
                          child: Text(account?.provider == MailProvider.gmail
                              ? 'Open in Google Calendar'
                              : 'Open in Outlook'),
                        ),
                    ],
                  ),
              ],
            ),
            if (e.cancelled)
              Text('Cancelled by the organiser', style: muted),
            const SizedBox(height: 8),
            Text(when, key: const ValueKey('event-when')),
            // How long until it starts, for a meeting today (#93), kept up
            // with the clock while the sheet is open; in the colour the
            // Agenda's "Now" has.
            MeetingTicker(builder: (_, _, now) {
              final left = timeToStart(e, now);
              if (left == null) return const SizedBox.shrink();
              return Text(
                left.shown,
                key: const ValueKey('event-starts'),
                semanticsLabel: left.spoken,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              );
            }),
            if (setInZone(e, hostRef.read(deviceZoneProvider).value,
                    use24h: use24h)
                case final setIn?)
              Text(setIn, key: const ValueKey('event-set-in'), style: muted),
            if (e.location.isNotEmpty) ...[
              const SizedBox(height: 4),
              // A tap from directions, where it is somewhere (#40).
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: PlaceLink(place: e.location, style: muted),
              ),
            ],
            if (account != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  CircleAvatar(radius: 6, backgroundColor: Color(account.colorValue)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(account.emailAddress, style: muted)),
                ],
              ),
            ],
            if (answer != null) ...[
              const SizedBox(height: 4),
              Text(answer, style: muted),
            ],
            // The one button that matters now filled (#93): Join from a
            // quarter of an hour before the meeting until it ends, as the
            // bar over the mail has it, else Accept on a meeting not
            // answered, else none. Looked at again as the time goes by
            // while the sheet is open.
            MeetingTicker(builder: (_, _, now) {
              final joinNow = e.joinUrl != null && meetingIsNear(e, now);
              final acceptNow =
                  !joinNow && e.response == EventResponse.notResponded;
              final actions = [
                if (e.joinUrl != null)
                  TapTarget(
                    child: joinNow
                        ? FilledButton.icon(
                            key: const ValueKey('event-join'),
                            onPressed: () => open(e.joinUrl!),
                            icon: const Icon(Icons.videocam_outlined),
                            label: const Text('Join'),
                          )
                        : OutlinedButton.icon(
                            key: const ValueKey('event-join'),
                            onPressed: () => open(e.joinUrl!),
                            icon: const Icon(Icons.videocam_outlined),
                            label: const Text('Join'),
                          ),
                  ),
                if (own && reachable && !e.cancelled)
                  TapTarget(
                    child: OutlinedButton.icon(
                      key: const ValueKey('event-edit'),
                      onPressed: () => then(editEvent),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    ),
                  ),
                if (soon && account != null)
                  TapTarget(
                    child: OutlinedButton.icon(
                      key: const ValueKey('event-late'),
                      onPressed: () => then(runningLate),
                      icon: const Icon(Icons.schedule),
                      label: const Text('Running late'),
                    ),
                  ),
              ];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (invited && reachable) ...[
                    // Each button 48 to tap (#90), 4 more above and below
                    // than the 40 it had: drawn where it was, and rows of
                    // them as far apart to the eye.
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        answerButton(
                            InviteResponse.accepted, 'Accept', 'event-accept',
                            filled: acceptNow),
                        answerButton(InviteResponse.tentative, 'Maybe',
                            'event-tentative'),
                        answerButton(InviteResponse.declined, 'Decline',
                            'event-decline'),
                      ],
                    ),
                  ],
                  if (actions.isNotEmpty) ...[
                    SizedBox(height: invited && reachable ? 8 : 12),
                    Wrap(spacing: 8, children: actions),
                  ],
                ],
              );
            }),
            // The whole of what it says, its links a tap away (#43): under
            // the buttons since #93, where a long list of people no longer
            // pushes it out of sight.
            EventNotesView(
              event: e,
              reachable: account != null && AccountCalendar.canRead(account),
              style: muted,
              onEmail: (address) => then((c, ref, _) =>
                  writeTo(c, ref, address, accountId: account?.id)),
            ),
            if (e.organizer != null && !own) ...[
              const SizedBox(height: 16),
              Text('Organiser', style: theme.textTheme.labelLarge),
              Text(e.organizer!.display),
            ],
            if (e.attendees.isNotEmpty) ...[
              const SizedBox(height: 16),
              MeetingPeople(
                key: const ValueKey('event-people-list'),
                heading: tracked
                    ? invitedCount == 1
                        ? '1 person invited'
                        : '$invitedCount people invited'
                    : '${e.attendees.length} '
                        '${e.attendees.length == 1 ? 'person' : 'people'}',
                count: tracked ? invitedCount : e.attendees.length,
                people: listed,
                answersCarried: own || carried,
                // Someone else's counted only where they fold, as the
                // marks of everyone listed show them, and only where the
                // copy carries people's answers (#93).
                answers: tracked
                    ? describeAnswers(counts)
                    : e.attendees.length > foldPeopleOver && carried
                        ? describeAnswers(countAsListed(listed))
                        : null,
                nudge: tracked && waiting.isNotEmpty && reachable
                    ? Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: LinedUp(
                          // 48 to tap, as the sheet's other buttons (#90).
                          child: TapTarget(
                            child: TextButton.icon(
                              key: const ValueKey('event-nudge'),
                              onPressed: () => then((c, ref, ev) =>
                                  emailEveryone(c, ref, ev,
                                      notAnsweredOnly: true)),
                              icon:
                                  const Icon(Icons.mail_outline, size: 18),
                              label: Text(waiting.length == 1
                                  ? 'Email the one who has not answered'
                                  : 'Email the ${waiting.length} who have '
                                      'not answered'),
                            ),
                          ),
                        ),
                      )
                    : null,
                muted: muted,
              ),
            ],
            // The invitation and the answers about it, from its account's
            // mail.
            if (account != null && e.title.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: LinedUp(
                  child: TapTarget(
                    child: TextButton.icon(
                      key: const ValueKey('event-mail-about'),
                      onPressed: () => showMeetingMail(context, e),
                      icon: const Icon(Icons.forum_outlined, size: 18),
                      label: const Text('Mail about this meeting'),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// [e]'s people, Ron's own row (by [email]) answered as the meeting says
  /// he answered it, where it says.
  static List<EventAttendee> _withOwnAnswer(CalendarEvent e, String email) {
    final me = email.trim().toLowerCase();
    final mine = switch (e.response) {
      EventResponse.accepted ||
      EventResponse.tentative ||
      EventResponse.declined ||
      EventResponse.notResponded =>
        e.response,
      _ => null,
    };
    if (me.isEmpty || mine == null) return e.attendees;
    return [
      for (final a in e.attendees)
        a.address.email.trim().toLowerCase() == me
            ? EventAttendee(a.address, response: mine, optional: a.optional)
            : a,
    ];
  }

  /// The people, as Outlook's Tracking groups them: the organiser, those
  /// who accepted, said maybe, declined, then those yet to answer.
  static List<EventAttendee> _byAnswer(List<EventAttendee> people) {
    int rank(EventResponse r) => switch (r) {
          EventResponse.organizer => 0,
          EventResponse.accepted => 1,
          EventResponse.tentative => 2,
          EventResponse.declined => 3,
          _ => 4,
        };
    return [...people]..sort((a, b) => rank(a.response).compareTo(rank(b.response)));
  }
}
