import 'package:flutter/material.dart';

import '../../domain/calendar_event.dart';

/// More people than this on a meeting are listed folded on its sheet, to
/// their heading and counts (calendar idea #93).
const foldPeopleOver = 6;

/// The people on a meeting, on its sheet: a heading ("4 people", "5 people
/// invited"), the answers counted where there are any to show, Email the …
/// who have not answered beside them on a meeting of Ron's ([nudge]), and
/// each person with how they answered.
///
/// More than [foldPeopleOver] (as the heading counts them) start folded to
/// the heading and the counts, with an arrow: a tap opens the list, and it
/// stays as Ron left it while the sheet is open, as the notes' Show more
/// does (#93). The notes come before this, so a long list no longer pushes
/// them out of sight.
class MeetingPeople extends StatefulWidget {
  const MeetingPeople({
    super.key,
    required this.heading,
    required this.count,
    required this.people,
    this.organised = false,
    this.answers,
    this.nudge,
    this.muted,
  });

  /// "4 people", "5 people invited".
  final String heading;

  /// How many [heading] says: more than [foldPeopleOver] fold.
  final int count;

  /// Everyone, in the order listed.
  final List<EventAttendee> people;

  /// Whether Ron organised the meeting. There an answer of none is one
  /// not given; on someone else's it is one not known (Exchange gives none
  /// for everyone on a copy other than the organiser's), and a screen
  /// reader hears the name alone.
  final bool organised;

  /// The answers counted, under [heading]; null for none.
  final String? answers;

  /// Email the … who have not answered, under the counts, folded or not.
  final Widget? nudge;

  final TextStyle? muted;

  @override
  State<MeetingPeople> createState() => _MeetingPeopleState();
}

class _MeetingPeopleState extends State<MeetingPeople>
    with AutomaticKeepAliveClientMixin {
  bool _open = false;

  /// The sheet builds its rows as they scroll into sight and lets go of
  /// them as they leave it: kept, so the list stays open or folded as Ron
  /// left it.
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final heading = Text(widget.heading, style: theme.textTheme.labelLarge);
    final answers = widget.answers == null
        ? null
        : Text(
            widget.answers!,
            key: const ValueKey('event-answers'),
            style: widget.muted,
          );
    final folds = widget.count > foldPeopleOver;
    final nudge = widget.nudge;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (folds)
          // The heading and the counts are the button: a screen reader
          // hears them, that it opens, and whether it is open.
          Semantics(
            key: const ValueKey('event-people'),
            container: true,
            button: true,
            expanded: _open,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                    minHeight: kMinInteractiveDimension),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [heading, ?answers],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          )
        else ...[
          heading,
          ?answers,
        ],
        ?nudge,
        if (!folds || _open)
          for (final a in widget.people)
            _Person(attendee: a, organised: widget.organised),
      ],
    );
  }
}

/// The colour of an answer's mark on a meeting's sheet (#93): green
/// accepted (the organiser's own too), amber maybe, red declined, and the
/// usual grey not answered; each at least 3 to 1 against the sheet in
/// either theme. Colour is never the only sign: the marks differ too.
Color answerColour(EventResponse response, ThemeData theme) {
  final dark = theme.brightness == Brightness.dark;
  return switch (response) {
    EventResponse.accepted ||
    EventResponse.organizer =>
      dark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
    EventResponse.tentative =>
      dark ? const Color(0xFFFFB74D) : const Color(0xFFB26A00),
    EventResponse.declined => theme.colorScheme.error,
    _ => theme.colorScheme.onSurfaceVariant,
  };
}

/// An answer as a screen reader says it after the name: "Dana Levi,
/// accepted". Null for an answer of none on someone else's meeting
/// ([organised] false), which is not known, not one not given: the name is
/// said alone.
String? answerSaid(EventResponse response, {required bool organised}) =>
    switch (response) {
      EventResponse.accepted || EventResponse.organizer => 'accepted',
      EventResponse.tentative => 'maybe',
      EventResponse.declined => 'declined',
      EventResponse.notResponded => 'not answered',
      EventResponse.none => organised ? 'not answered' : null,
    };

/// One person on the list: how they answered, by a mark in the answer's
/// colour, their name, and their address with Organiser or Optional beside
/// it. A screen reader hears the answer with the name, which the mark alone
/// never told it, where the answer is known. An answer not known keeps the
/// grey mark of one not given.
class _Person extends StatelessWidget {
  const _Person({required this.attendee, required this.organised});

  final EventAttendee attendee;

  /// See [MeetingPeople.organised].
  final bool organised;

  @override
  Widget build(BuildContext context) {
    final a = attendee;
    final name = a.address.display;
    final said = answerSaid(a.response, organised: organised);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        switch (a.response) {
          EventResponse.accepted ||
          EventResponse.organizer =>
            Icons.check_circle_outline,
          EventResponse.tentative => Icons.help_outline,
          EventResponse.declined => Icons.cancel_outlined,
          _ => Icons.radio_button_unchecked,
        },
        size: 18,
        color: answerColour(a.response, Theme.of(context)),
      ),
      title: Text(name, semanticsLabel: said == null ? null : '$name, $said'),
      subtitle: Text([
        if (a.address.name != null) a.address.email,
        if (a.response == EventResponse.organizer) 'Organiser',
        if (a.optional) 'Optional',
      ].join(' · ')),
    );
  }
}
