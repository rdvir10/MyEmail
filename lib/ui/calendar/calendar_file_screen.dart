import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/files/file_bridge.dart' show IncomingFile;
import '../../domain/account.dart';
import '../../domain/account_calendars.dart';
import '../../domain/calendar_event.dart';
import '../../domain/calendar_files.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/meeting.dart';
import '../../domain/meeting_links.dart' show placeNamed;
import '../../domain/text_direction.dart';
import '../../state/calendar_providers.dart';
import '../../state/calendar_view_providers.dart';
import '../../state/providers.dart';
import '../../state/window_providers.dart';
import '../common/bottom_message.dart';
import '../messages/invite_card.dart' show describeTimes;

/// A calendar file opened with MyEmail from another app (calendar idea
/// #67): its events, earliest first, each with Add, and a choice of where
/// they go: one of the calendars MyEmail writes to, or the phone's calendar
/// app, which shows the event before it is kept.
///
/// The file is a stranger's. Nothing is added until Ron presses Add, and
/// each goes as his own meeting: whoever the file names on it is neither
/// invited nor told. Where it repeats it goes as a series, as far as the
/// calendar picked can be told how; where it cannot, the row says only its
/// first meeting goes, before Add is pressed.
class CalendarFileScreen extends ConsumerStatefulWidget {
  const CalendarFileScreen({super.key, required this.file});

  final IncomingFile file;

  static Future<void> open(BuildContext context, IncomingFile file) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => CalendarFileScreen(file: file),
      ));

  @override
  ConsumerState<CalendarFileScreen> createState() =>
      _CalendarFileScreenState();
}

/// What the file turned out to hold: its events, or why there are none.
typedef _Read = ({CalendarFile? calendar, String? problem});

/// Where an event goes: one of an account's calendars, or with neither,
/// the phone's calendar app.
@immutable
class _Target {
  const _Target.calendar(Account this.account, this.calendarId, this.label);
  const _Target.phone()
      : account = null,
        calendarId = null,
        label = "The phone's calendar app";

  final Account? account;
  final String? calendarId;
  final String label;

  bool get isPhone => account == null;

  String get key => isPhone ? 'phone' : '${account!.id}:$calendarId';
}

class _CalendarFileScreenState extends ConsumerState<CalendarFileScreen> {
  /// Read off the UI's own isolate: a file of thousands of events, or one
  /// written to be slow, would otherwise hold the screen still until
  /// Android offered to close MyEmail.
  late final Future<_Read> _reading = _readOff(widget.file.path);

  /// The target picked, by its key; the first offered until one is.
  String? _picked;

  /// What each event added says, by its place in the list.
  final _added = <int, String>{};
  final _busy = <int>{};

  /// One key for each event's Add to each calendar, however often it is
  /// tried there: see [FileEvent.draftFor]. Another calendar is another
  /// meeting, and never the first one answered again.
  final _transactions = <String, String>{};

  static Future<_Read> _readOff(String path) async {
    try {
      return await Isolate.run(() => _read(path));
    } catch (e) {
      debugPrint('[myemail] a calendar file could not be read apart: '
          '${e.runtimeType}');
      return (calendar: null, problem: 'This file could not be read.');
    }
  }

  /// The file at [path] read, all at once: a calendar is small, and one
  /// past [CalendarFile.largest] is not read at all. Android's copy of it
  /// is let go once it has been: a stranger's file is not kept.
  static _Read _read(String path) {
    final f = File(path);
    try {
      return _readFile(f);
    } finally {
      _letGo(f);
    }
  }

  /// The copy FilesBridge made (`incoming/<a folder of its own>/<name>`
  /// in the cache), deleted with its folder; nothing anywhere else.
  static void _letGo(File f) {
    try {
      final folder = f.parent;
      if (folder.parent.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .lastOrNull ==
          'incoming') {
        folder.deleteSync(recursive: true);
      }
    } catch (e) {
      debugPrint('[myemail] a calendar file copied in was not let go: '
          '${e.runtimeType}');
    }
  }

  static _Read _readFile(File f) {
    try {
      if (f.lengthSync() > CalendarFile.largest) {
        return (calendar: null, problem: 'This file is too large for a '
            'calendar, so MyEmail has not read it.');
      }
      final text = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
      final calendar = CalendarFile.read(text);
      debugPrint('[myemail] calendar file: '
          '${calendar?.events.length ?? 0} events read');
      return calendar == null
          ? (calendar: null, problem: 'This file has no events MyEmail can '
              'read.')
          : (calendar: calendar, problem: null);
    } catch (e) {
      debugPrint('[myemail] a calendar file could not be opened: '
          '${e.runtimeType}');
      return (calendar: null, problem: 'This file could not be read.');
    }
  }

  /// Every calendar an event can go on: each account's that MyEmail
  /// writes to, its main one first, then the phone's calendar app.
  List<_Target> _targets() {
    final targets = <_Target>[];
    for (final a in ref.watch(calendarAccountsProvider)) {
      targets.add(_Target.calendar(a, CalendarEvent.mainCalendar,
          a.displayName));
      for (final c in ref.watch(keptAccountCalendarsProvider(a.id)).value ??
          const <CalendarInfo>[]) {
        if (c.canEdit && !c.isMain) {
          targets.add(
              _Target.calendar(a, c.id, '${a.displayName} · ${c.name}'));
        }
      }
    }
    if (ref.watch(calendarAvailableProvider).value ?? false) {
      targets.add(const _Target.phone());
    }
    return targets;
  }

  Future<void> _add(int index, FileEvent event, _Target target) async {
    setState(() => _busy.add(index));
    // Read before the wait: the screen may be gone by the time it is over.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final phone = ref.read(deviceCalendarProvider);
    final engine = ref.read(mailEngineProvider);
    final inFlight = ref.read(workInFlightProvider);
    final refresh = ref.read(calendarRefreshProvider.notifier);
    try {
      final String said;
      if (target.isPhone) {
        final handed = await phone.insertEvent(
          title: event.title,
          description: event.event.description.trim().isEmpty
              ? null
              : event.event.description.trim(),
          location: event.event.location.trim().isEmpty
              ? null
              : event.event.location.trim(),
          start: event.start,
          // A whole day ends where the next begins, as the calendar app
          // takes it.
          end: event.allDay
              ? DateTime(event.end.year, event.end.month, event.end.day + 1)
              : event.end,
          allDay: event.allDay,
          rule: event.phoneRule,
        );
        if (!handed) throw const _NoCalendarApp();
        said = "Handed to the phone's calendar app";
      } else {
        String? zone;
        try {
          zone = await phone.timeZoneId();
        } catch (_) {
          // The times go in UTC, which every calendar reads the same.
        }
        final work = engine.createMeeting(event.draftFor(
          accountId: target.account!.id,
          calendarId: target.calendarId!,
          timeZone: zone,
          transactionId: _transactions.putIfAbsent(
              '$index ${target.key}', MeetingDraft.newTransactionId),
        ));
        // A window of its own waits for it before it ends.
        inFlight.add(work);
        await work;
        refresh.now();
        said = 'Added to ${target.label}';
      }
      if (mounted) setState(() => _added[index] = said);
    } catch (e) {
      final why = switch (e) {
        _NoCalendarApp() => 'There is no calendar app to add it to.',
        ReadableError(:final message) => 'Could not add it: $message',
        ArgumentError(:final message) => 'Could not add it: $message',
        _ => 'Could not add it: $e',
      };
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(why)));
    } finally {
      if (mounted) setState(() => _busy.remove(index));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar file'), centerTitle: false),
      body: FutureBuilder<_Read>(
        future: _reading,
        builder: (context, snapshot) {
          final read = snapshot.data;
          if (read == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final calendar = read.calendar;
          if (calendar == null) return _problem(context, read.problem!);
          return _events(context, calendar);
        },
      ),
    );
  }

  Widget _problem(BuildContext context, String problem) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.event_busy, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(problem, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 4),
            Text(
              widget.file.name,
              textDirection: firstStrongDirection(widget.file.name),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _events(BuildContext context, CalendarFile calendar) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final targets = _targets();
    final target = targets.where((t) => t.key == _picked).firstOrNull ??
        targets.firstOrNull;
    final name = calendar.name ?? widget.file.name;
    final count = calendar.events.length;
    final header = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            name,
            textDirection: firstStrongDirection(name),
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 2),
          Text(
            count == 1 ? 'One event' : '$count events',
            style: muted,
          ),
          const SizedBox(height: 10),
          Text(
            'Each goes on the calendar you pick as your own meeting: nobody '
            'on it is invited or told.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          if (target == null)
            Text(
              'There is no calendar here to add to. An account signed in '
              "with Microsoft or Google has one, and so has the phone's "
              'calendar app.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            )
          else
            Row(
              children: [
                Text('Add to', style: muted),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<String>(
                    key: const ValueKey('calendar-file-target'),
                    value: target.key,
                    isExpanded: true,
                    onChanged: (key) => setState(() => _picked = key),
                    items: [
                      for (final t in targets)
                        DropdownMenuItem(
                          key: ValueKey('calendar-file-target:${t.key}'),
                          value: t.key,
                          child: Text(t.label,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                  ),
                ),
              ],
            ),
        ],
    );
    // Opened at the first event from today on, those before it above: a
    // school's or a country's calendar can go back years. Where every one
    // has gone by, at the last.
    final events = calendar.events;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final upcoming = events.indexWhere(
        (e) => !DateTime(e.end.year, e.end.month, e.end.day).isBefore(today));
    final first = upcoming < 0 ? events.length - 1 : upcoming;
    // Built as they come into view: a published calendar can hold
    // thousands. No wider than a page reads on a tablet, the margins
    // scrolling with it. Where they go stays in sight above them.
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, box) {
          final side = math.max(16.0, (box.maxWidth - _widest) / 2);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(side, 12, side, 4),
                child: header,
              ),
              Expanded(
                child: CustomScrollView(
                  center: first > 0 ? _fromToday : null,
                  slivers: [
                    if (first > 0)
                      SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: side),
                        sliver: SliverList.builder(
                          itemCount: first,
                          // Nearest first, upwards.
                          itemBuilder: (context, i) => _event(context,
                              first - 1 - i, events[first - 1 - i], target),
                        ),
                      ),
                    SliverPadding(
                      key: _fromToday,
                      padding: EdgeInsets.fromLTRB(side, 0, side, 24),
                      sliver: SliverList.builder(
                        itemCount: events.length - first,
                        itemBuilder: (context, i) => _event(
                            context, first + i, events[first + i], target),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _event(
    BuildContext context,
    int index,
    FileEvent event,
    _Target? target,
  ) {
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final place = placeNamed(event.event.location);
    final notes = event.event.description.trim();
    final repeats = event.rule != null;
    final kept = target == null ||
        (target.isPhone ? event.phoneRuleKept : event.repeatKept);
    final added = _added[index];
    final changed = event.changed;
    return Card(
      key: const ValueKey('calendar-file-event'),
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              event.title,
              textDirection: firstStrongDirection(event.title),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            _line(theme, Icons.schedule, _when(event, use24h)),
            if (place.isNotEmpty) _line(theme, Icons.place_outlined, place),
            if (repeats)
              _line(theme, Icons.repeat, event.repeatWords ?? 'Repeats'),
            if (event.zoneUnknown)
              _line(
                theme,
                Icons.info_outline,
                'Its time zone is one MyEmail does not know: the time is as '
                "the file writes it, on this phone's clock.",
              ),
            if (repeats && !kept && added == null)
              _line(
                theme,
                Icons.info_outline,
                "It repeats in a way MyEmail can't copy to ${target.label}: "
                'only the first meeting is added.',
              ),
            if (repeats && kept && changed > 0)
              _line(
                theme,
                Icons.info_outline,
                changed == 1
                    ? 'One of its meetings is moved or left out in the file. '
                        'Added, the series has it as usual: change it there.'
                    : '$changed of its meetings are moved or left out in the '
                        'file. Added, the series has them as usual: change '
                        'them there.',
              ),
            if (notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 22),
                child: Text(
                  notes,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textDirection: firstStrongDirection(notes),
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: added != null
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check,
                            size: 18, color: theme.colorScheme.primary),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(added,
                              style: theme.textTheme.labelLarge),
                        ),
                      ],
                    )
                  : FilledButton.tonal(
                      key: const ValueKey('calendar-file-add'),
                      onPressed: target == null || _busy.contains(index)
                          ? null
                          : () => _add(index, event, target),
                      child: const Text('Add'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// The widest the list goes, its margins aside.
  static const _widest = 720.0;

  /// The list's part from today on, where it opens.
  static const _fromToday = ValueKey('calendar-file-from-today');

  /// "Wed 2 Dec 2026, 14:00–15:00", or for whole days the first and the
  /// last.
  static String _when(FileEvent event, bool use24h) {
    if (!event.allDay) {
      return describeTimes(event.start, event.end, use24h: use24h);
    }
    String day(DateTime d) =>
        describeTimes(d, null, allDay: true).replaceFirst(', all day', '');
    return event.end == event.start
        ? '${day(event.start)}, all day'
        : '${day(event.start)} to ${day(event.end)}, all day';
  }

  /// A line of the event: an icon, and [text] read the way its first
  /// letter reads.
  static Widget _line(ThemeData theme, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                textDirection: firstStrongDirection(text),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      );
}

/// The phone has no calendar app to hand an event to.
class _NoCalendarApp implements Exception {
  const _NoCalendarApp();
}
