import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../data/mail_engine.dart' show CalendarUnavailable;
import '../../domain/account.dart';
import '../../domain/calendar_event.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/search_refinement.dart' show weekStartFor;
import '../../state/calendar_view_providers.dart';
import '../../state/meeting_providers.dart' show workWeekProvider;
import '../../state/providers.dart';
import '../accounts/google_sign_in_screen.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import '../common/bottom_message.dart';
import '../meetings/new_meeting_screen.dart' show openNewMeeting;
import '../messages/date_format.dart';

/// Outlook's Calendar, beside the mail: every account's events as an
/// agenda, a day or a week. Read from each account's calendar as it is
/// shown; nothing here is kept. Reached from the folder pane's foot, the
/// ribbon, and Ctrl+2.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const CalendarScreen()));

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

DateTime _midnight(DateTime t) => DateTime(t.year, t.month, t.day);

DateTime _plus(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December',
];

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  DateTime _day = _midnight(DateTime.now());

  /// How far the agenda runs from [_day]; Show more adds a month.
  int _agendaDays = 30;

  /// A week on a tablet, three days on a phone, as Outlook for Android.
  int _weekDays(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 700 ? 7 : 3;

  CalendarRange _range(CalendarViewMode mode, int weekDays) {
    switch (mode) {
      case CalendarViewMode.agenda:
        return (start: _day, end: _plus(_day, _agendaDays));
      case CalendarViewMode.day:
        return (start: _day, end: _plus(_day, 1));
      case CalendarViewMode.week:
        final first = weekDays == 7
            ? weekStartFor(_day, workWeek: ref.read(workWeekProvider))
            : _day;
        return (start: first, end: _plus(first, weekDays));
    }
  }

  void _move(CalendarViewMode mode, int weekDays, int direction) =>
      setState(() => _day = _plus(
            _day,
            direction *
                switch (mode) {
                  CalendarViewMode.agenda => 7,
                  CalendarViewMode.day => 1,
                  CalendarViewMode.week => weekDays,
                },
          ));

  String _title(CalendarRange range) {
    final last = _plus(range.end, -1);
    final from = range.start;
    if (from.month == last.month && from.year == last.year) {
      return '${_months[from.month - 1]} ${from.year}';
    }
    String short(DateTime d) => _months[d.month - 1].substring(0, 3);
    return from.year == last.year
        ? '${short(from)} – ${short(last)} ${last.year}'
        : '${short(from)} ${from.year} – ${short(last)} ${last.year}';
  }

  /// A new meeting from the view: on the day shown, at the next hour today
  /// or nine on another day.
  DateTime? _newMeetingStart(CalendarViewMode mode) {
    if (mode == CalendarViewMode.agenda) return null;
    final now = DateTime.now();
    return _sameDay(_day, now)
        ? DateTime(now.year, now.month, now.day, now.hour + 1)
        : DateTime(_day.year, _day.month, _day.day, 9);
  }

  Future<void> _chooseCalendars(List<Account> accounts) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: Consumer(
            builder: (context, ref, _) {
              final hidden = ref.watch(hiddenCalendarsProvider);
              return ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(title: Text('Calendars shown')),
                  for (final a in accounts)
                    CheckboxListTile(
                      key: ValueKey('calendar-shown:${a.id}'),
                      secondary: CircleAvatar(
                        radius: 8,
                        backgroundColor: Color(a.colorValue),
                      ),
                      title: Text(a.displayName),
                      subtitle: Text(a.emailAddress),
                      value: !hidden.contains(a.id),
                      onChanged: (shown) => ref
                          .read(hiddenCalendarsProvider.notifier)
                          .setShown(a.id, shown ?? true),
                    ),
                ],
              );
            },
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(calendarViewProvider);
    final weekDays = _weekDays(context);
    final range = _range(mode, weekDays);
    final load = ref.watch(calendarEventsProvider(range));
    final accounts = ref.watch(calendarAccountsProvider);
    final colours = {for (final a in accounts) a.id: Color(a.colorValue)};
    void details(CalendarEvent e) => showEventDetails(
          context,
          e,
          accounts.where((a) => a.id == e.accountId).firstOrNull,
        );
    void newMeetingAt(DateTime start) =>
        openNewMeeting(context, ref, start: start);

    final Widget content;
    if (accounts.isEmpty) {
      content = const _NoCalendars();
    } else if (load.value case final value?) {
      content = switch (mode) {
        CalendarViewMode.agenda => _Agenda(
            start: _day,
            days: _agendaDays,
            events: value.events,
            colours: colours,
            onTap: details,
            onMore: () => setState(() => _agendaDays += 30),
          ),
        CalendarViewMode.day => _Timeline(
            key: ValueKey('day-$_day'),
            days: [_day],
            events: value.events,
            colours: colours,
            onTap: details,
            onSlot: newMeetingAt,
          ),
        CalendarViewMode.week => _Timeline(
            key: ValueKey('week-${range.start}-$weekDays'),
            days: [
              for (var i = 0; i < weekDays; i++) _plus(range.start, i),
            ],
            events: value.events,
            colours: colours,
            onTap: details,
            onSlot: newMeetingAt,
            onDay: (day) {
              setState(() => _day = day);
              ref.read(calendarViewProvider.notifier).set(CalendarViewMode.day);
            },
          ),
      };
    } else if (load.hasError) {
      content = Center(child: Text('${load.error}'));
    } else {
      content = const Center(child: CircularProgressIndicator());
    }
    final problems = load.value?.problems ?? const <String, Object>{};

    return Scaffold(
      appBar: AppBar(
        title: Text(_title(range)),
        centerTitle: false,
        actions: [
          IconButton(
            key: const ValueKey('calendar-previous'),
            tooltip: 'Back',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _move(mode, weekDays, -1),
          ),
          IconButton(
            key: const ValueKey('calendar-next'),
            tooltip: 'On',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => _move(mode, weekDays, 1),
          ),
          IconButton(
            key: const ValueKey('calendar-today'),
            tooltip: 'Today',
            icon: const Icon(Icons.today_outlined),
            onPressed: () => setState(() {
              _day = _midnight(DateTime.now());
              _agendaDays = 30;
            }),
          ),
          if (accounts.length > 1)
            IconButton(
              key: const ValueKey('calendar-accounts'),
              tooltip: 'Calendars shown',
              icon: const Icon(Icons.filter_list),
              onPressed: () => _chooseCalendars(accounts),
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(calendarEventsProvider),
          ),
        ],
      ),
      floatingActionButton: accounts.isEmpty
          ? null
          : FloatingActionButton(
              key: const ValueKey('calendar-new-meeting'),
              tooltip: 'New meeting',
              onPressed: () =>
                  openNewMeeting(context, ref, start: _newMeetingStart(mode)),
              child: const Icon(Icons.add),
            ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: SegmentedButton<CalendarViewMode>(
              showSelectedIcon: false,
              segments: [
                for (final m in CalendarViewMode.values)
                  ButtonSegment(
                    value: m,
                    label: Text(
                      m == CalendarViewMode.week && weekDays != 7
                          ? '$weekDays days'
                          : m.label,
                      key: ValueKey('calendar-view-${m.name}'),
                    ),
                  ),
              ],
              selected: {mode},
              onSelectionChanged: (chosen) =>
                  ref.read(calendarViewProvider.notifier).set(chosen.first),
            ),
          ),
          for (final MapEntry(:key, :value) in problems.entries)
            if (accounts.where((a) => a.id == key).firstOrNull
                case final account?)
              _ProblemBar(account: account, error: value),
          Expanded(child: content),
        ],
      ),
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

/// One account's calendar could not be read: why, and Allow where a
/// sign-in fixes it.
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
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
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
      ref.invalidate(calendarEventsProvider);
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

// --- the agenda -----------------------------------------------------------------

class _Agenda extends StatelessWidget {
  const _Agenda({
    required this.start,
    required this.days,
    required this.events,
    required this.colours,
    required this.onTap,
    required this.onMore,
  });

  final DateTime start;
  final int days;
  final List<CalendarEvent> events;
  final Map<String, Color> colours;
  final void Function(CalendarEvent) onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = _midnight(DateTime.now());
    final rows = <Widget>[];
    for (var i = 0; i < days; i++) {
      final day = _plus(start, i);
      final on = eventsOn(day, events);
      if (on.isEmpty) continue;
      final name = formatDay(day);
      final label = _sameDay(day, today)
          ? 'Today · $name'
          : _sameDay(day, _plus(today, 1))
              ? 'Tomorrow · $name'
              : name;
      rows.add(Container(
        key: ValueKey('agenda-day:${day.year}-${day.month}-${day.day}'),
        width: double.infinity,
        color: theme.colorScheme.surfaceContainerLow,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: _sameDay(day, today) ? theme.colorScheme.primary : null,
          ),
        ),
      ));
      for (final e in on) {
        rows.add(_AgendaRow(
          event: e,
          day: day,
          colour: colours[e.accountId] ?? theme.colorScheme.primary,
          onTap: () => onTap(e),
        ));
      }
    }
    if (rows.isEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Nothing on the calendar in these $days days.',
          textAlign: TextAlign.center,
        ),
      ));
    }
    rows.add(Center(
      child: TextButton(
        key: const ValueKey('agenda-more'),
        onPressed: onMore,
        child: const Text('Show the next 30 days'),
      ),
    ));
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: rows,
    );
  }
}

class _AgendaRow extends StatelessWidget {
  const _AgendaRow({
    required this.event,
    required this.day,
    required this.colour,
    required this.onTap,
  });

  final CalendarEvent event;
  final DateTime day;
  final Color colour;
  final VoidCallback onTap;

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
    final subtitle = [
      if (e.location.isNotEmpty) e.location,
      if (e.joinUrl != null && e.location.isEmpty) 'Online',
      if (e.response == EventResponse.tentative) 'Tentative',
      if (e.response == EventResponse.notResponded) 'Not answered',
      if (e.cancelled) 'Cancelled',
    ].join(' · ');
    return InkWell(
      key: ValueKey('agenda-event:${e.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(first, style: theme.textTheme.bodyMedium),
                  if (second != null) Text(second, style: muted),
                ],
              ),
            ),
            Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                color: e.showAs == EventShowAs.free ? colour.withAlpha(110) : colour,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.title.isEmpty ? '(No title)' : e.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      decoration: e.cancelled ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
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
      ),
    );
  }
}

// --- the day and the week ---------------------------------------------------------

/// Days side by side, hour by hour: the day view, and the week's.
class _Timeline extends StatefulWidget {
  const _Timeline({
    super.key,
    required this.days,
    required this.events,
    required this.colours,
    required this.onTap,
    required this.onSlot,
    this.onDay,
  });

  final List<DateTime> days;
  final List<CalendarEvent> events;
  final Map<String, Color> colours;
  final void Function(CalendarEvent) onTap;

  /// A new meeting at a time tapped on.
  final void Function(DateTime) onSlot;

  /// A day's name tapped on, in the week.
  final void Function(DateTime)? onDay;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  static const hourHeight = 56.0;
  static const gutter = 48.0;

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: () {
      final now = DateTime.now();
      final hour = widget.days.any((d) => _sameDay(d, now))
          ? math.max(0, now.hour - 1)
          : 8;
      return hour * hourHeight;
    }(),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final now = DateTime.now();
    final muted = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final allDay = {
      for (final d in widget.days)
        d: [
          for (final e in eventsOn(d, widget.events))
            if (e.allDay) e,
        ],
    };
    final anyAllDay = allDay.values.any((l) => l.isNotEmpty);
    return Column(
      children: [
        if (widget.days.length > 1)
          Row(
            children: [
              const SizedBox(width: gutter),
              for (final d in widget.days)
                Expanded(
                  child: InkWell(
                    key: ValueKey('week-day:${d.year}-${d.month}-${d.day}'),
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
                SizedBox(
                  width: gutter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4),
                    child: Text('All day', style: muted),
                  ),
                ),
                for (final d in widget.days)
                  Expanded(
                    child: Column(
                      children: [
                        for (final e in allDay[d]!)
                          _Block(
                            event: e,
                            colour: widget.colours[e.accountId] ??
                                theme.colorScheme.primary,
                            onTap: () => widget.onTap(e),
                            compact: true,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            child: SizedBox(
              height: 24 * hourHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: gutter,
                    child: Stack(
                      children: [
                        for (var h = 1; h < 24; h++)
                          Positioned(
                            top: h * hourHeight - 7,
                            right: 6,
                            child: Text(
                              formatClock(DateTime(2000, 1, 1, h), use24h: use24h),
                              style: muted,
                            ),
                          ),
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
                        onTap: widget.onTap,
                        onSlot: widget.onSlot,
                      ),
                    ),
                ],
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
    required this.onTap,
    required this.onSlot,
  });

  final DateTime day;
  final List<CalendarEvent> events;
  final Map<String, Color> colours;
  final void Function(CalendarEvent) onTap;
  final void Function(DateTime) onSlot;

  static const hourHeight = _TimelineState.hourHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayEnd = _plus(day, 1);
    final now = DateTime.now();
    double y(DateTime t) {
      final clipped = t.isBefore(day) ? day : (t.isAfter(dayEnd) ? dayEnd : t);
      return clipped.difference(day).inMinutes / 60 * hourHeight;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            // To the half hour it falls in.
            final minutes =
                (details.localPosition.dy / hourHeight * 60 ~/ 30) * 30;
            onSlot(day.add(Duration(minutes: minutes)));
          },
          child: Stack(
            children: [
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
              for (final slot in layOutDay(events))
                Positioned(
                  top: y(slot.event.start),
                  height: math.max(
                    hourHeight / 4,
                    y(slot.event.end) - y(slot.event.start),
                  ),
                  left: width * slot.column / slot.columns + 1,
                  width: width / slot.columns - 2,
                  child: _Block(
                    event: slot.event,
                    colour: colours[slot.event.accountId] ??
                        theme.colorScheme.primary,
                    onTap: () => onTap(slot.event),
                  ),
                ),
              if (_sameDay(day, now))
                Positioned(
                  top: y(now),
                  left: 0,
                  right: 0,
                  child: Container(height: 2, color: theme.colorScheme.error),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// An event as a block of its account's colour.
class _Block extends StatelessWidget {
  const _Block({
    required this.event,
    required this.colour,
    required this.onTap,
    this.compact = false,
  });

  final CalendarEvent event;
  final Color colour;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final faint = event.showAs == EventShowAs.free ||
        event.response == EventResponse.tentative ||
        event.response == EventResponse.notResponded;
    final style = TextStyle(
      color: faint ? colour : Colors.white,
      fontSize: 12,
      decoration: event.cancelled ? TextDecoration.lineThrough : null,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 2 : 0),
      child: Material(
        color: faint ? colour.withAlpha(40) : colour,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: faint ? BorderSide(color: colour) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('calendar-event:${event.id}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                compact || event.allDay
                    ? event.title
                    : '${event.title}\n${formatClock(event.start, use24h: use24h)}',
                maxLines: compact ? 1 : 3,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- an event, opened -------------------------------------------------------------

/// [event]'s details: when and where, who, and the way to join it.
Future<void> showEventDetails(
  BuildContext context,
  CalendarEvent event,
  Account? account,
) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => _EventDetails(event: event, account: account),
    );

class _EventDetails extends StatelessWidget {
  const _EventDetails({required this.event, required this.account});

  final CalendarEvent event;
  final Account? account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String clock(DateTime t) => formatClock(t, use24h: use24h);
    final e = event;
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

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(
              e.title.isEmpty ? '(No title)' : e.title,
              style: theme.textTheme.titleLarge?.copyWith(
                decoration: e.cancelled ? TextDecoration.lineThrough : null,
              ),
            ),
            if (e.cancelled)
              Text('Cancelled by the organiser', style: muted),
            const SizedBox(height: 8),
            Text(when, key: const ValueKey('event-when')),
            if (e.location.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(e.location, style: muted),
            ],
            if (account != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  CircleAvatar(radius: 6, backgroundColor: Color(account!.colorValue)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(account!.emailAddress, style: muted)),
                ],
              ),
            ],
            if (answer != null) ...[
              const SizedBox(height: 4),
              Text(answer, style: muted),
            ],
            if (e.joinUrl != null || e.webLink != null) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (e.joinUrl != null)
                    FilledButton.icon(
                      key: const ValueKey('event-join'),
                      onPressed: () => open(e.joinUrl!),
                      icon: const Icon(Icons.videocam_outlined),
                      label: const Text('Join'),
                    ),
                  if (e.webLink != null)
                    OutlinedButton.icon(
                      key: const ValueKey('event-web'),
                      onPressed: () => open(e.webLink!),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(account?.provider == MailProvider.gmail
                          ? 'Open in Google Calendar'
                          : 'Open in Outlook'),
                    ),
                ],
              ),
            ],
            if (e.organizer != null && !e.isOrganizer) ...[
              const SizedBox(height: 16),
              Text('Organiser', style: theme.textTheme.labelLarge),
              Text(e.organizer!.display),
            ],
            if (e.attendees.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '${e.attendees.length} '
                '${e.attendees.length == 1 ? 'person' : 'people'}',
                style: theme.textTheme.labelLarge,
              ),
              for (final a in e.attendees)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(switch (a.response) {
                    EventResponse.accepted ||
                    EventResponse.organizer =>
                      Icons.check_circle_outline,
                    EventResponse.tentative => Icons.help_outline,
                    EventResponse.declined => Icons.cancel_outlined,
                    _ => Icons.radio_button_unchecked,
                  }, size: 18),
                  title: Text(a.address.display),
                  subtitle: Text([
                    if (a.address.name != null) a.address.email,
                    if (a.response == EventResponse.organizer) 'Organiser',
                    if (a.optional) 'Optional',
                  ].join(' · ')),
                ),
            ],
            if (e.preview.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(e.preview, style: muted),
            ],
          ],
        ),
      ),
    );
  }
}
