import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/calendar/away_run.dart';
import '../../domain/account.dart';
import '../../domain/away.dart';
import '../../domain/calendar_change.dart' show everyoneOn;
import '../../domain/calendar_event.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/meeting.dart' show MeetingDraft;
import '../../domain/text_direction.dart' show firstStrongDirection;
import '../../state/away_providers.dart';
import '../../state/calendar_providers.dart' show deviceCalendarProvider;
import '../../state/calendar_view_providers.dart';
import '../../state/meeting_alert_providers.dart' show meetingClockProvider;
import '../../state/providers.dart';
import '../common/bottom_message.dart';
import '../messages/date_format.dart';
import '../settings/auto_replies_screen.dart';
import '../shell/put_away.dart' show GuardsPutAway;
import 'meeting_share.dart' show meetingWhen;

/// I am away (calendar idea #53), from the calendar's ⋮: the days asked
/// for, then [AwayScreen] for them. Backing out of the days opens nothing.
Future<void> openAway(BuildContext context, WidgetRef ref) async {
  final now = ref.read(meetingClockProvider)();
  final days = await _askDays(context, now: now);
  if (days == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AwayScreen(first: days.start, last: days.end),
  ));
}

/// The days, from today on, up to two years ahead.
Future<DateTimeRange?> _askDays(
  BuildContext context, {
  required DateTime now,
  DateTimeRange? initial,
}) {
  final today = DateTime(now.year, now.month, now.day);
  return showDateRangePicker(
    context: context,
    firstDate: today,
    lastDate: DateTime(today.year + 2, today.month, today.day),
    currentDate: today,
    initialDateRange: initial,
    helpText: 'The days you are away',
  );
}

DateTime _midnight(DateTime t) => DateTime(t.year, t.month, t.day);

/// The days blocked, and the meetings in them declined or cancelled, as
/// ticked here. Treated as the most dangerous screen in the app: it
/// answers and cancels real meetings and writes to the people on them.
/// So nothing is made, declined or cancelled until Ron has seen the list
/// and pressed the button, which says in numbers what it will do; only
/// what he left ticked goes, each once; a meeting of a series is only that
/// meeting; and a press that leaves some not done says which, and a press
/// again does only those (see [AwayRun]).
///
/// What it starts with: the days blocked on every account's calendar that
/// is not blocked already; every meeting Ron was invited to ticked, unless
/// he organised it from another of his addresses; his own meetings
/// unticked; the organisers told; no note.
class AwayScreen extends ConsumerStatefulWidget {
  const AwayScreen({super.key, required this.first, required this.last});

  /// The first and the last day away, both at midnight.
  final DateTime first;
  final DateTime last;

  @override
  ConsumerState<AwayScreen> createState() => _AwayScreenState();
}

class _AwayScreenState extends ConsumerState<AwayScreen>
    with GuardsPutAway<AwayScreen> {
  /// The press going now, where one is: shown rather than a list of this
  /// screen's own. Otherwise a list of its own, read for the days.
  late final AwayPress _press =
      ref.read(awayPressProvider) ?? AwayPress(first: _first0, last: _last0);
  late final TextEditingController _note =
      TextEditingController(text: _press.note);

  DateTime get _first0 => _midnight(widget.first);
  DateTime get _last0 => _midnight(widget.last);

  /// Asking whether to go: the button does nothing meanwhile.
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _press.addListener(_changed);
    _note.addListener(() => _press.note = _note.text);
    if (!_press.running && !_press.pressed && _press.reads == 0) _read();
  }

  @override
  void dispose() {
    _press.removeListener(_changed);
    _note.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Put away while it sends, or with some left that did not go: the
  /// screen stays, and its report with it (the press goes on regardless,
  /// in [awayPressProvider]).
  @override
  Future<bool> whenPutAway() async => !(_press.running || _press.leftUndone);

  Account? _account(String id) =>
      _press.accounts.where((a) => a.id == id).firstOrNull;

  /// The calendars, read afresh for the days, whatever the views kept: what
  /// is listed is what each calendar has now.
  Future<void> _read() async {
    final press = _press;
    final read = ++press.reads;
    if (!press.reading) {
      press
        ..reading = true
        ..changed();
    }
    final engine = ref.read(mailEngineProvider);
    try {
      // The accounts as they are, where they are still being read.
      await ref.read(accountsProvider.future);
    } catch (_) {
      // Then those known, as the calendar has them.
    }
    if (!mounted || read != press.reads) return;
    final accounts = ref.read(calendarAccountsProvider);
    final first = press.first, last = press.last;
    final events = <CalendarEvent>[];
    final unread = <String, Object>{};
    String? zone;
    await Future.wait([
      for (final a in accounts)
        engine.calendarEvents(a.id, first, _dayAfter(last)).then(
          events.addAll,
          onError: (Object e) {
            unread[a.id] = e;
          },
        ),
      ref.read(deviceCalendarProvider).timeZoneId().then(
        (z) {
          zone = z;
        },
        // Then the block's days go as UTC's, which every calendar reads.
        onError: (Object _) {},
      ),
    ]);
    if (!mounted || read != press.reads) return;
    final emails = {for (final a in accounts) a.id: a.emailAddress};
    final listed = awayMeetings(
      events,
      first: first,
      last: last,
      now: ref.read(meetingClockProvider)(),
      ownEmails: emails,
    );
    final blocked = {
      for (final a in accounts)
        a.id: ?awayBlockOn(events, a.id, first: first, last: last),
    };
    press
      ..accounts = accounts
      ..unread = unread
      ..blockedAlready = blocked
      ..blocks = [
        for (final a in accounts)
          AwayItem.block(awayBlock(
            accountId: a.id,
            first: first,
            last: last,
            timeZone: zone,
            transactionId: press.blockKeys
                .putIfAbsent(a.id, MeetingDraft.newTransactionId),
          )),
      ]
      ..invited = [for (final e in listed.invited) AwayItem.decline(e)]
      ..own = [for (final e in listed.own) AwayItem.cancel(e)];
    press.ticked
      ..clear()
      ..addAll([
        // Not where the days are blocked already, nor where the calendar
        // could not be read to see whether they are.
        for (final b in press.blocks)
          if (!blocked.containsKey(b.accountId) &&
              !unread.containsKey(b.accountId))
            b,
        for (final i in press.invited)
          if (awayStartsTicked(i.event!, emails.values)) i,
      ]);
    press
      ..reading = false
      ..changed();
  }

  Future<void> _changeDays() async {
    final days = await _askDays(
      context,
      now: ref.read(meetingClockProvider)(),
      initial: DateTimeRange(start: _press.first, end: _press.last),
    );
    if (days == null || !mounted || _press.pressed || _press.running) return;
    _press
      ..first = _midnight(days.start)
      ..last = _midnight(days.end)
      // Other days, another block.
      ..blockKeys.clear();
    await _read();
  }

  int _count(List<AwayItem> items, AwayAction action) => items
      .where((i) => i.action == action)
      .length;

  Future<void> _go() async {
    final press = _press;
    if (press.reading || _asking || press.running) return;
    // One press at a time, in the whole app.
    if (ref.read(awayPressProvider) != null) return;
    final todo = press.toDo;
    if (todo.isEmpty) return;
    final declines = _count(todo, AwayAction.decline);
    final cancels = _count(todo, AwayAction.cancel);
    // Whoever is told is told for good: asked once more, in words.
    if (declines + cancels > 0) {
      _asking = true;
      final sure = await showDialog<bool>(
        context: context,
        builder: (_) => _SureDialog(
          blocks: [
            for (final b in todo)
              if (b.action == AwayAction.block)
                _account(b.accountId)?.displayName ?? '',
          ],
          days: _daysText(),
          declines: declines,
          cancels: cancels,
          tell: press.tell,
          note: press.note.trim().isNotEmpty,
          words: _words(todo)!,
        ),
      );
      _asking = false;
      if (sure != true || !mounted) return;
    }
    // Held by the app, not the screen: it goes on to its end, and reads
    // the views and the reminders again then, whatever becomes of this.
    await ref.read(awayPressProvider.notifier).go(press);
  }

  /// The button's words for [todo]; again where an earlier press left
  /// some not done.
  String? _words(List<AwayItem> todo) => awayButtonWords(
        blocks: _count(todo, AwayAction.block),
        declines: _count(todo, AwayAction.decline),
        cancels: _count(todo, AwayAction.cancel),
        again: todo.any((i) => i.state == AwayState.failed),
      );

  String _daysText() => _press.first == _press.last
      ? formatDay(_press.first)
      : '${formatDay(_press.first)} – ${formatDay(_press.last)}';

  /// After a press: how it went, in a line over the button.
  String? _summary() {
    final press = _press;
    if (!press.pressed || press.running) return null;
    final all = press.all;
    int count(AwayState s) => all.where((i) => i.state == s).length;
    final went = count(AwayState.done);
    final failed = count(AwayState.failed);
    final gone = count(AwayState.gone);
    final sentGone = count(AwayState.sentGone);
    return [
      if (failed == 0)
        went == 0 ? 'Nothing more to send.' : 'Done: $went went.'
      else
        '$went went, $failed did not (marked in red).',
      if (sentGone > 0)
        '$sentGone sent once with no answer back, and no longer on the '
            'calendar: not sent again.',
      if (gone > 0)
        '$gone ${gone == 1 ? 'was' : 'were'} no longer on the calendar, so '
            'nothing was sent for ${gone == 1 ? 'it' : 'them'}.',
      if (failed > 0)
        'Those that went are not sent again. Pressing again does only the '
            '$failed, each once it is found still on its calendar as it was.',
    ].join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final press = _press;
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final todo = press.toDo;
    final words = _words(todo);
    final summary = _summary();
    final running = press.running;
    final reading = press.reading;
    final locked = running || _asking;
    final first = press.first, last = press.last;

    Widget row(
      AwayItem item, {
      required String title,
      List<String> lines = const [],
    }) =>
        _AwayRow(
          key: ValueKey(switch (item.action) {
            AwayAction.block => 'away-block:${item.accountId}',
            _ => 'away:${item.accountId}:${item.event!.id}',
          }),
          item: item,
          ticked: press.ticked.contains(item),
          enabled: !locked && !reading,
          colour: Color(_account(item.accountId)?.colorValue ??
              theme.colorScheme.primary.toARGB32()),
          title: title,
          lines: lines,
          onTick: (on) {
            on ? press.ticked.add(item) : press.ticked.remove(item);
            press.changed();
          },
        );

    Widget meeting(AwayItem item) {
      final e = item.event!;
      final title = e.title.trim().isEmpty ? '(No title)' : e.title.trim();
      final account = _account(e.accountId);
      final who = item.action == AwayAction.decline
          ? (e.organizer?.display.trim() ?? '')
          : switch (everyoneOn(e, account?.emailAddress ?? '').length) {
              1 => '1 other person',
              final n => '$n other people',
            };
      final mine = item.action == AwayAction.decline &&
          !awayStartsTicked(
              e, [for (final a in press.accounts) a.emailAddress]);
      return row(item, title: title, lines: [
        [meetingWhen(e, use24h: use24h), if (who.isNotEmpty) who].join(' · '),
        if (mine) 'You organised it, from ${e.organizer!.email}',
        if (e.seriesId != null)
          item.action == AwayAction.decline
              ? 'One of a series: only this one is declined'
              : 'One of a series: only this one is cancelled',
      ]);
    }

    List<Widget> problems(Iterable<String> accountIds) => [
          for (final id in accountIds)
            if (press.unread[id] case final why?)
              Padding(
                key: ValueKey('away-unread:$id'),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  "${_account(id)?.displayName ?? id}'s calendar could not "
                  'be read: ${_why(why)} Its meetings are not listed.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
        ];

    // Counted on dates, not hours: a day the clocks change is a day too.
    final dayCount = DateTime.utc(last.year, last.month, last.day)
            .difference(DateTime.utc(first.year, first.month, first.day))
            .inDays +
        1;
    final body = ListView(
      key: const ValueKey('away-list'),
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (reading) const LinearProgressIndicator(),
        ListTile(
          key: const ValueKey('away-days'),
          leading: const Icon(Icons.date_range_outlined),
          title: Text(_daysText()),
          subtitle: Text(dayCount == 1 ? '1 day' : '$dayCount days'),
          trailing: press.pressed || running
              ? null
              : TextButton(
                  key: const ValueKey('away-days-change'),
                  onPressed: locked ? null : _changeDays,
                  child: const Text('Change'),
                ),
        ),
        _Heading('Block the days'),
        _Note('An all-day event shown as out of office, on each calendar '
            'ticked. Nobody is sent anything.'),
        for (final b in press.blocks)
          row(b,
              title: _account(b.accountId)?.displayName ?? '',
              lines: [
                _account(b.accountId)?.emailAddress ?? '',
                if (press.blockedAlready[b.accountId] case final already?)
                  'Out of office already: '
                      '${already.title.trim().isEmpty ? awayTitle : ''}'
                      '${already.title.trim()}',
              ]),
        _Heading(reading
            ? 'Meetings you were invited to'
            : 'Meetings you were invited to (${press.invited.length})'),
        _Note('Ticked ones are declined, each as Decline does it: only the '
            'meeting in these days, never the rest of its series.'),
        ...problems(press.accounts.map((a) => a.id)),
        if (!reading && press.invited.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('None in these days.', style: muted),
          ),
        for (final i in press.invited) meeting(i),
        _Heading(reading
            ? 'Your own meetings'
            : 'Your own meetings (${press.own.length})'),
        _Note('Ticked ones are cancelled, as Cancel meeting does it: '
            'everyone on them is told.'),
        if (!reading && press.own.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('None with others on them in these days.',
                style: muted),
          ),
        for (final i in press.own) meeting(i),
        _Heading('Your answer'),
        SwitchListTile(
          key: const ValueKey('away-tell'),
          title: const Text('Tell the organisers'),
          subtitle: Text(press.tell
              ? 'Each gets your decline, with the note below'
              : 'Declined without a word to them'),
          value: press.tell,
          onChanged: locked
              ? null
              : (on) {
                  press
                    ..tell = on
                    ..changed();
                },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            key: const ValueKey('away-note'),
            controller: _note,
            enabled: !locked,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'A note to them',
              helperText: press.tell
                  ? 'Goes with each decline, and with each cancellation '
                      'from a Microsoft account.'
                  : 'Goes with each cancellation from a Microsoft account. '
                      'Declines go without a word.',
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        _Heading('While you are away'),
        ListTile(
          key: const ValueKey('away-auto-replies'),
          leading: const Icon(Icons.reply_all_outlined),
          title: const Text('Automatic replies'),
          subtitle: const Text('What people are told when they write to '
              'you, on its own screen'),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const AutoRepliesScreen(),
          )),
        ),
      ],
    );

    final done = press.pressed && words == null && !running;
    return PopScope(
      canPop: !running,
      onPopInvokedWithResult: (popped, _) {
        if (popped) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            duration: kBottomMessage,
            content: Text('Wait until it is done: each one is being sent.'),
          ));
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('I am away'), centerTitle: false),
        body: body,
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (summary != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      summary,
                      key: const ValueKey('away-summary'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: press.leftUndone
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                FilledButton(
                  key: const ValueKey('away-go'),
                  onPressed: done
                      ? () => Navigator.of(context).maybePop()
                      : (reading || locked || words == null ? null : _go),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      running
                          ? 'Sending: ${press.through} of ${press.of}'
                          : reading
                              ? 'Reading the calendars…'
                              : done
                                  ? 'Close'
                                  : words ?? 'Nothing ticked',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

DateTime _dayAfter(DateTime day) => DateTime(day.year, day.month, day.day + 1);

String _why(Object e) => switch (e) {
      ReadableError(:final message) => message,
      _ => '$e',
    };

/// Asked once more before anything that tells anyone goes: what will go,
/// in words, and that it cannot be taken back.
class _SureDialog extends StatelessWidget {
  const _SureDialog({
    required this.blocks,
    required this.days,
    required this.declines,
    required this.cancels,
    required this.tell,
    required this.note,
    required this.words,
  });

  final List<String> blocks;
  final String days;
  final int declines;
  final int cancels;
  final bool tell;
  final bool note;
  final String words;

  @override
  Widget build(BuildContext context) {
    String meetings(int n) => n == 1 ? '1 meeting' : '$n meetings';
    final names = blocks.length < 3
        ? blocks.join(' and ')
        : '${blocks.length} calendars';
    return AlertDialog(
      title: const Text('Go ahead?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in [
              if (blocks.isNotEmpty)
                '$days blocked as out of office on $names.',
              if (declines > 0)
                tell
                    ? '${meetings(declines)} declined. '
                        '${declines == 1 ? 'Its organiser is' : 'Their '
                            'organisers are'} told'
                        '${note ? ', with your note' : ''}.'
                    : '${meetings(declines)} declined, without a word to '
                        '${declines == 1 ? 'its' : 'their'} '
                        '${declines == 1 ? 'organiser' : 'organisers'}.',
              if (cancels > 0)
                '${meetings(cancels)} of your own cancelled. Everyone on '
                    '${cancels == 1 ? 'it' : 'them'} is told.',
              'An answer or a cancellation cannot be taken back.',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(line),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('away-go-back'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Go back'),
        ),
        FilledButton(
          key: const ValueKey('away-go-sure'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(words),
        ),
      ],
    );
  }
}

/// One thing on the list: its tick, or where it has got to, its
/// calendar's colour, and what it is.
class _AwayRow extends StatelessWidget {
  const _AwayRow({
    super.key,
    required this.item,
    required this.ticked,
    required this.enabled,
    required this.colour,
    required this.title,
    required this.lines,
    required this.onTick,
  });

  final AwayItem item;
  final bool ticked;
  final bool enabled;
  final Color colour;
  final String title;
  final List<String> lines;
  final void Function(bool on) onTick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    // Done or gone: never again, so no tick to give it.
    final tickable = enabled && item.open;
    final Widget lead = switch (item.state) {
      AwayState.going => const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      AwayState.done || AwayState.sentGone =>
        Icon(Icons.check_circle, color: scheme.primary),
      AwayState.gone =>
        Icon(Icons.remove_circle_outline, color: scheme.onSurfaceVariant),
      AwayState.waiting || AwayState.failed => Checkbox(
          value: ticked,
          onChanged: tickable ? (on) => onTick(on ?? false) : null,
        ),
    };
    final said = switch (item.state) {
      AwayState.done => switch (item.action) {
          AwayAction.block => 'Blocked',
          AwayAction.decline => 'Declined',
          AwayAction.cancel => 'Cancelled',
        },
      // Nothing went: gone before anything was sent. A cancellation finds
      // its meeting gone as it looks first (Graph would answer it "done").
      AwayState.gone => item.action == AwayAction.cancel
          ? 'Already gone from your calendar: nothing was sent'
          : 'No longer on your calendar: nothing was sent',
      // It went once; what came back was lost.
      AwayState.sentGone => 'Sent once; no answer came back, and it is no '
          'longer on your calendar, so it is not sent again',
      AwayState.failed => 'Did not go: ${item.problem ?? 'no answer came'}',
      AwayState.going || AwayState.waiting => null,
    };
    // One thing to a screen reader: its tick, what it is, and how it went.
    return MergeSemantics(
      child: InkWell(
        onTap: tickable ? () => onTick(!ticked) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                height: 40,
                child: Center(child: lead),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Container(
                  width: 4,
                  height: 32,
                  decoration: BoxDecoration(
                    color: colour,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // By its first letter: a Hebrew title reads from the
                      // right, as everywhere a meeting is named.
                      SizedBox(
                        width: double.infinity,
                        child: Text(
                          title,
                          textDirection: firstStrongDirection(title),
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
                      for (final line in lines)
                        if (line.isNotEmpty) Text(line, style: small),
                      if (said != null)
                        Text(
                          said,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: item.state == AwayState.failed
                                ? scheme.error
                                : item.state == AwayState.done ||
                                        item.state == AwayState.sentGone
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                            fontWeight: item.state == AwayState.gone
                                ? null
                                : FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 2),
      child: Text(
        text,
        style: theme.textTheme.titleSmall
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Text(
        text,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
