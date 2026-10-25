import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/calendar_event.dart';
import '../../domain/calendar_finding.dart';
import '../../state/calendar_view_providers.dart';
import '../messages/date_format.dart';
import 'calendar_screen.dart' show showEventDetails;
import 'event_colours.dart';

/// Search the calendar (#36): a meeting by its title, a person or a place,
/// a year back and a year ahead, in every account's calendars. What the
/// device kept is searched at once, and the calendars read again behind it.
class CalendarSearchScreen extends ConsumerStatefulWidget {
  const CalendarSearchScreen({super.key, this.query = ''});

  /// What it opens looking for: a person's address, from their card.
  final String query;

  static Future<void> open(BuildContext context, {String query = ''}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => CalendarSearchScreen(query: query),
      ));

  @override
  ConsumerState<CalendarSearchScreen> createState() =>
      _CalendarSearchScreenState();
}

class _CalendarSearchScreenState extends ConsumerState<CalendarSearchScreen> {
  late final _query = TextEditingController(text: widget.query);

  /// The stretch searched, fixed for the screen's life so the read it
  /// asks for is one read.
  final _span = searchSpan(DateTime.now());

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final load = ref.watch(calendarEventsProvider(_span));
    final accounts = ref.watch(calendarAccountsProvider);
    final colours = EventColours(
      accounts: {for (final a in accounts) a.id: Color(a.colorValue)},
      calendars: load.value?.calendars ?? const {},
    );
    final query = _query.text;
    final found = searchEvents(load.value?.events ?? const [], query, DateTime.now());
    final reading = load.isLoading || (load.value?.reading ?? false);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    void open(CalendarEvent e) => showEventDetails(
          context,
          ref,
          e,
          accounts.where((a) => a.id == e.accountId).firstOrNull,
        );
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          key: const ValueKey('calendar-search-box'),
          controller: _query,
          autofocus: widget.query.isEmpty,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search the calendar',
            border: InputBorder.none,
          ),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          if (query.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close),
              onPressed: () => setState(_query.clear),
            ),
        ],
        bottom: reading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: query.trim().isEmpty
          ? Center(
              child: Text('A title, a person or a place, a year either way.',
                  style: muted),
            )
          : found.coming.isEmpty && found.past.isEmpty
              ? Center(
                  child: Text(reading ? 'Looking…' : 'Nothing found.',
                      style: muted),
                )
              : ListView(
                  children: [
                    for (final e in found.coming)
                      _Result(event: e, colour: colours[e], onTap: () => open(e)),
                    if (found.past.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(
                          'Before today',
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: theme.colorScheme.primary),
                        ),
                      ),
                      for (final e in found.past)
                        _Result(
                            event: e, colour: colours[e], onTap: () => open(e)),
                    ],
                  ],
                ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.event, required this.colour, required this.onTap});

  final CalendarEvent event;
  final Color? colour;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final e = event;
    final when = e.allDay
        ? '${formatDay(e.start)}, all day'
        : '${formatDay(e.start)}, ${formatClock(e.start, use24h: use24h)}';
    return ListTile(
      key: ValueKey('calendar-search-result:${e.id}'),
      leading: Container(
        width: 4,
        height: 36,
        decoration: BoxDecoration(
          color: colour ?? theme.colorScheme.primary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      title: Text(
        e.title.trim().isEmpty ? '(No title)' : e.title.trim(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [when, if (e.location.trim().isNotEmpty) e.location.trim()].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
    );
  }
}
