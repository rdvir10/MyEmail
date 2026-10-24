import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/error_report.dart' show ReadableError;
import '../../domain/free_busy.dart';
import '../../domain/mail_message.dart';
import '../../state/compose_providers.dart' show addressesLookValid, parseAddresses;
import '../../state/meeting_providers.dart' show workWeekProvider;
import '../../state/providers.dart';

/// Outlook's Scheduling Assistant, on New meeting. A button beside All day
/// says whether everyone is free at the meeting's time; it opens each
/// person's busy times on the day with the meeting drawn over them, and
/// Next free time, the first time after it that everyone known is free.
///
/// Everyone in a Microsoft organisation can be seen; from a Gmail account,
/// only its own calendar, the rest marked as not shown.
class WhoIsFree extends ConsumerStatefulWidget {
  const WhoIsFree({
    super.key,
    required this.accountId,
    required this.ownEmail,
    required this.attendees,
    required this.start,
    required this.end,
    required this.onPick,
  });

  final String accountId;
  final String ownEmail;

  /// The Attendees field, as typed.
  final TextEditingController attendees;
  final DateTime start;
  final DateTime end;

  /// A start chosen on the sheet: the meeting keeps its length.
  final ValueChanged<DateTime> onPick;

  /// How long the attendees have to stay as they are before the calendars
  /// are asked again.
  static const pause = Duration(milliseconds: 800);

  @override
  ConsumerState<WhoIsFree> createState() => _WhoIsFreeState();
}

class _WhoIsFreeState extends ConsumerState<WhoIsFree> {
  Timer? _wait;
  String _asked = '';
  bool _loading = false;
  List<MailAddress> _people = const [];
  Map<String, List<TimeSpan>?> _busy = const {};

  @override
  void initState() {
    super.initState();
    widget.attendees.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
  }

  @override
  void didUpdateWidget(WhoIsFree old) {
    super.didUpdateWidget(old);
    if (!_sameDay(old.start, widget.start) ||
        old.accountId != widget.accountId) {
      _ask();
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    widget.attendees.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    _wait?.cancel();
    _wait = Timer(WhoIsFree.pause, _ask);
  }

  String _keyFor(List<MailAddress> people) =>
      '${widget.accountId}|${_dayOf(widget.start).toIso8601String()}|'
      '${people.map((p) => p.email.toLowerCase()).join(',')}';

  Future<void> _ask() async {
    if (!mounted) return;
    final people = _everyone(widget.ownEmail, widget.attendees.text);
    final key = _keyFor(people);
    if (key == _asked) return;
    _asked = key;
    setState(() {
      _loading = true;
      _people = people;
      _busy = const {};
    });
    try {
      final busy = await _scheduleOf(ref, widget.accountId, people, widget.start);
      if (!mounted || key != _asked) return;
      setState(() {
        _busy = busy;
        _loading = false;
      });
    } catch (_) {
      // The sheet says what went wrong, when it is opened.
      if (!mounted || key != _asked) return;
      setState(() => _loading = false);
    }
  }

  /// What the button says: who is busy at the meeting's time, of those
  /// whose calendars can be seen.
  ({IconData icon, String label, bool busy}) _status() {
    List<TimeSpan>? spans(MailAddress p) => _busy[p.email.toLowerCase()];
    final known = [
      for (final p in _people)
        if (spans(p) != null) p,
    ];
    if (_loading || known.isEmpty) {
      return (icon: Icons.groups_outlined, label: 'Who is free', busy: false);
    }
    final busy = [
      for (final p in known)
        if (_busyAt(spans(p), widget.start, widget.end)) p,
    ];
    final you = widget.ownEmail.toLowerCase();
    if (busy.isEmpty) {
      return (
        icon: Icons.event_available_outlined,
        label: _people.length == 1
            ? 'You are free'
            : known.length == _people.length
                ? 'Everyone free'
                : 'No one busy',
        busy: false,
      );
    }
    return (
      icon: Icons.event_busy_outlined,
      label: busy.length > 1
          ? '${busy.length} busy'
          : busy.single.email.toLowerCase() == you
              ? 'You are busy'
              : '${_nameOf(busy.single)} busy',
      busy: true,
    );
  }

  Future<void> _open() async {
    _wait?.cancel();
    final people = _everyone(widget.ownEmail, widget.attendees.text);
    final same = !_loading && _keyFor(people) == _asked && _busy.isNotEmpty;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SchedulingSheet(
        accountId: widget.accountId,
        people: people,
        start: widget.start,
        end: widget.end,
        known: same ? _busy : null,
        onPick: widget.onPick,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status();
    final scheme = Theme.of(context).colorScheme;
    return TextButton.icon(
      key: const ValueKey('who-is-free'),
      style: status.busy
          ? TextButton.styleFrom(foregroundColor: scheme.error)
          : null,
      onPressed: _open,
      icon: Icon(status.icon, size: 18),
      label: Text(status.label, overflow: TextOverflow.ellipsis),
    );
  }
}

/// Each person's busy times on the meeting's day, the meeting over them.
/// A tap on a time moves the meeting there; the arrows move it a day.
class _SchedulingSheet extends ConsumerStatefulWidget {
  const _SchedulingSheet({
    required this.accountId,
    required this.people,
    required this.start,
    required this.end,
    required this.known,
    required this.onPick,
  });

  final String accountId;

  /// You first, then the attendees.
  final List<MailAddress> people;
  final DateTime start;
  final DateTime end;

  /// The day's answer the button already had, where it is for this day
  /// and these people; asked again otherwise.
  final Map<String, List<TimeSpan>?>? known;
  final ValueChanged<DateTime> onPick;

  @override
  ConsumerState<_SchedulingSheet> createState() => _SchedulingSheetState();
}

class _SchedulingSheetState extends ConsumerState<_SchedulingSheet> {
  late DateTime _start = widget.start;
  late DateTime _end = widget.end;
  late Map<String, List<TimeSpan>?>? _busy = widget.known;
  String? _problem;
  bool _finding = false;
  int _asking = 0;

  /// The meeting's length, an hour where it has none to keep.
  Duration get _length {
    final length = _end.difference(_start);
    return length > Duration.zero ? length : const Duration(hours: 1);
  }

  @override
  void initState() {
    super.initState();
    if (_busy == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final asking = ++_asking;
    setState(() {
      _busy = null;
      _problem = null;
    });
    try {
      final busy =
          await _scheduleOf(ref, widget.accountId, widget.people, _start);
      if (!mounted || asking != _asking) return;
      setState(() => _busy = busy);
    } catch (e) {
      if (!mounted || asking != _asking) return;
      setState(() => _problem = 'Could not read the calendars.'
          '${e is ReadableError ? ' ${e.message}' : ''}');
    }
  }

  /// The meeting to [start], its length kept, on the screen as well.
  void _move(DateTime start) {
    final newDay = !_sameDay(start, _start);
    final length = _length;
    setState(() {
      _start = start;
      _end = start.add(length);
      _problem = null;
    });
    widget.onPick(start);
    if (newDay) _load();
  }

  Future<void> _nextFree() async {
    setState(() {
      _finding = true;
      _problem = null;
    });
    final from = _start;
    try {
      final busy = await ref.read(mailEngineProvider).schedules(
            widget.accountId,
            [for (final p in widget.people) p.email],
            from,
            DateTime(from.year, from.month, from.day + 15),
          );
      if (!mounted) return;
      // Not the meeting's own time: the next one after it.
      final next = nextFree(
        [for (final b in busy.values) ?b],
        after: from.add(const Duration(minutes: 1)),
        length: _length,
        workWeek: ref.read(workWeekProvider),
      );
      setState(() => _finding = false);
      if (next == null) {
        setState(() =>
            _problem = 'No time everyone is free in the next two weeks.');
        return;
      }
      _move(next.start);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _finding = false;
        _problem = 'Could not read the calendars.'
            '${e is ReadableError ? ' ${e.message}' : ''}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String clock(DateTime t) => localizations.formatTimeOfDay(
          TimeOfDay.fromDateTime(t.toLocal()),
          alwaysUse24HourFormat: use24h,
        );
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final hours = _hours(_start, _end);
    final busy = _busy;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  key: const ValueKey('assistant-day-before'),
                  tooltip: 'A day earlier',
                  onPressed: _finding
                      ? null
                      : () => _move(DateTime(_start.year, _start.month,
                          _start.day - 1, _start.hour, _start.minute)),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        localizations.formatFullDate(_start),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        '${clock(_start)} – ${clock(_end)}',
                        key: const ValueKey('assistant-time'),
                        style: muted,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('assistant-day-after'),
                  tooltip: 'A day later',
                  onPressed: _finding
                      ? null
                      : () => _move(DateTime(_start.year, _start.month,
                          _start.day + 1, _start.hour, _start.minute)),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (busy == null && _problem == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              ),
            if (busy != null)
              for (final person in widget.people)
                _PersonRow(
                  key: ValueKey('free:${person.email.toLowerCase()}'),
                  name: _nameOf(person),
                  busy: busy[person.email.toLowerCase()],
                  first: hours.first,
                  last: hours.last,
                  start: _start,
                  end: _end,
                  onTapAt: _finding ? null : _move,
                ),
            if (busy != null)
              Padding(
                padding: const EdgeInsets.only(left: _PersonRow.nameWidth),
                child: SizedBox(
                  height: 16,
                  child: Stack(
                    children: [
                      for (var h = hours.first; h <= hours.last; h += 2)
                        Align(
                          alignment: Alignment(
                            -1 + 2 * (h - hours.first) / (hours.last - hours.first),
                            0,
                          ),
                          child: Text(
                            '${(h % 24).toString().padLeft(2, '0')}:00',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_problem!, style: muted),
              ),
            const SizedBox(height: 8),
            Text(
              'Blocks are busy times; the outline is the meeting. Tap a time '
              'to move the meeting there.',
              style: muted,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_finding)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                FilledButton.tonalIcon(
                  key: const ValueKey('next-free-time'),
                  onPressed: _finding ? null : _nextFree,
                  icon: const Icon(Icons.skip_next_outlined, size: 18),
                  label: const Text('Next free time'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The hours drawn: eight to eight, or wider for a meeting outside them.
  static ({int first, int last}) _hours(DateTime start, DateTime end) {
    final s = start.toLocal(), e = end.toLocal();
    final first = s.hour < 8 ? s.hour : 8;
    final endHour = _sameDay(s, e) ? e.hour + (e.minute > 0 ? 1 : 0) : 24;
    return (first: first, last: endHour > 20 ? endHour : 20);
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.name,
    required this.busy,
    required this.first,
    required this.last,
    required this.start,
    required this.end,
    required this.onTapAt,
  });

  static const nameWidth = 88.0;

  final String name;

  /// Null for someone whose calendar is not shown.
  final List<TimeSpan>? busy;
  final int first;
  final int last;
  final DateTime start;
  final DateTime end;

  /// A tap on the line, as the half hour it fell in.
  final ValueChanged<DateTime>? onTapAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final day = start.toLocal();
    final from = DateTime(day.year, day.month, day.day, first);
    final to = DateTime(day.year, day.month, day.day, last);
    final span = to.difference(from).inMinutes.toDouble();
    double at(DateTime t) =>
        (t.toLocal().difference(from).inMinutes / span).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: nameWidth,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 24,
              child: LayoutBuilder(
                builder: (context, box) {
                  final w = box.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: onTapAt == null
                        ? null
                        : (d) {
                            final minutes =
                                (span * (d.localPosition.dx / w)).floor();
                            onTapAt!(DateTime(day.year, day.month, day.day,
                                first, minutes ~/ 30 * 30));
                          },
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                        if (busy == null)
                          Center(
                            child: Text(
                              'Not shown',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        for (final b in busy ?? const <TimeSpan>[])
                          if (b.end.isAfter(from) && b.start.isBefore(to))
                            Positioned(
                              left: at(b.start) * w,
                              width:
                                  ((at(b.end) - at(b.start)) * w).clamp(2.0, w),
                              top: 3,
                              bottom: 3,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color:
                                      scheme.primary.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                        // The meeting, over them.
                        Positioned(
                          left: at(start) * w,
                          width: ((at(end) - at(start)) * w).clamp(2.0, w),
                          top: 0,
                          bottom: 0,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border:
                                    Border.all(color: scheme.error, width: 1.5),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// You, then everyone in [attendees] that reads as an address, once each.
List<MailAddress> _everyone(String ownEmail, String attendees) {
  final seen = <String>{ownEmail.toLowerCase()};
  return [
    MailAddress(email: ownEmail, name: 'You'),
    for (final a in parseAddresses(attendees))
      if (addressesLookValid([a]) && seen.add(a.email.toLowerCase())) a,
  ];
}

/// Who of [people] is busy on [at]'s day, as far as [accountId]'s calendar
/// can see, by address in lower case.
Future<Map<String, List<TimeSpan>?>> _scheduleOf(
  WidgetRef ref,
  String accountId,
  List<MailAddress> people,
  DateTime at,
) {
  final day = _dayOf(at);
  return ref.read(mailEngineProvider).schedules(
        accountId,
        [for (final p in people) p.email],
        day,
        DateTime(day.year, day.month, day.day + 1),
      );
}

DateTime _dayOf(DateTime at) {
  final local = at.toLocal();
  return DateTime(local.year, local.month, local.day);
}

bool _sameDay(DateTime a, DateTime b) => _dayOf(a) == _dayOf(b);

bool _busyAt(List<TimeSpan>? spans, DateTime start, DateTime end) =>
    spans != null &&
    spans.any((s) => s.start.isBefore(end) && s.end.isAfter(start));

String _nameOf(MailAddress a) =>
    (a.name?.trim().isNotEmpty ?? false) ? a.name!.trim() : a.email;
