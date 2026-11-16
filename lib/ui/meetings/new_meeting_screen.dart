import 'scheduling_assistant.dart';
import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../data/auth/oauth_token.dart';
import '../../data/mail_engine.dart';
import '../../domain/account.dart';
import '../../domain/calendar_change.dart';
import '../../domain/calendar_event.dart';
import '../../domain/error_report.dart';
import '../../domain/mail_message.dart';
import '../../domain/meeting.dart';
import '../../domain/meeting_link.dart';
import '../../domain/new_meeting_defaults.dart';
import '../../domain/recurrence.dart';
import '../../domain/series_repeat.dart';
import '../../domain/text_direction.dart';
import '../../state/calendar_providers.dart';
import '../../state/calendar_view_providers.dart'
    show calendarRefreshProvider, keptAccountCalendarsProvider;
import '../../state/compose_providers.dart'
    show addressesLookValid, formatAddresses, parseAddresses;
import '../../state/meeting_providers.dart';
import '../../state/providers.dart';
import '../accounts/google_sign_in_screen.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import '../common/bottom_message.dart';
import '../common/problem_view.dart';
import '../compose/header_fields.dart';
import '../shell/put_away.dart';
import '../../domain/found_dates.dart' show readQuickMeeting;
import '../../domain/time_zones.dart';
import '../../state/date_providers.dart' show dateFinderProvider;
import '../messages/date_format.dart' show formatClock, formatDay;
import 'meeting_options.dart';

/// Open the new-meeting screen.
///
/// [accountId] presets From. Without one it is the account of the folder on
/// screen, or the first account where that is the unified Inbox. [title],
/// [notes] and [attendees] prefill the rest, for a meeting made out of a
/// message.
Future<void> openNewMeeting(
  BuildContext context,
  WidgetRef ref, {
  String? accountId,
  String title = '',
  String notes = '',
  List<MailAddress> attendees = const [],
  DateTime? start,
  String location = '',
  Duration? length,
  bool allDay = false,
}) async {
  final accounts = ref.read(accountsProvider).value ?? const <Account>[];
  final chosen = accountId ??
      ref.read(accountOnScreenProvider) ??
      accounts.firstOrNull?.id;
  // A shared mailbox has no calendar here: its meetings are made on the
  // account it is shared with.
  final resolved =
      accounts.where((a) => a.id == chosen).firstOrNull?.sharedVia ?? chosen;
  if (resolved == null) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        duration: kBottomMessage,
        content: Text('Add an account first.'),
      ));
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => NewMeetingScreen(
        accountId: resolved,
        title: title,
        notes: notes,
        attendees: attendees,
        start: start,
        location: location,
        length: length,
        allDay: allDay,
      ),
    ),
  );
}

/// The new-meeting screen filled in from a message: its subject as the
/// title, its text as the notes, everyone on it as the attendees, from the
/// account it came to. For the mail that says "let's meet Thursday" without
/// sending an invitation; Outlook's Reply with Meeting.
Future<void> openNewMeetingFromMessage(
  BuildContext context,
  WidgetRef ref,
  MailMessage message,
  MailBody body, {
  DateTime? start,
  bool allDay = false,
}) {
  final text = body.text.trim();
  // Cut, as a body can run to pages; the message itself stays where it is.
  final notes = text.length > 2000 ? '${text.substring(0, 2000)}…' : text;
  return openNewMeeting(
    context,
    ref,
    accountId: message.accountId,
    title: message.subject,
    notes: '$notes\n\nFrom: ${message.from.display}',
    attendees: meetingAttendeesFor(
      message,
      own: {
        for (final a in ref.read(accountsProvider).value ?? const <Account>[])
          a.emailAddress.trim().toLowerCase(),
      },
    ),
    start: start,
    allDay: allDay,
  );
}

/// Who a meeting made out of [message] invites: whoever a reply goes to
/// (Reply-To over From, as a reply has it, or a contact form's no-reply
/// sender is asked instead of the customer), then everyone it went to and
/// was copied to, each once, and never yourself ([own] is every address of
/// yours, in lower case).
///
/// Only what looks like an address: "undisclosed-recipients", a group's
/// name or an Exchange path left the invitation unsendable, with nothing
/// to say which entry was wrong.
@visibleForTesting
List<MailAddress> meetingAttendeesFor(
  MailMessage message, {
  required Set<String> own,
}) {
  final answer = replyToBesidesSender(message.replyTo, message.from);
  final seen = <String>{...own};
  return [
    for (final a in [
      ...(answer.isEmpty ? [message.from] : answer),
      ...message.to,
      ...message.cc,
    ])
      if (addressesLookValid(
              [MailAddress(email: a.email.trim(), name: a.name)]) &&
          seen.add(a.email.trim().toLowerCase()))
        a,
  ];
}

/// Set up a meeting: from which account, what, who is asked, and when.
///
/// The shape of the compose screen, because it is the same act, writing to
/// people from one of the accounts, with a time in place of a body. Send
/// puts the event on the account's own calendar, which sends the
/// invitations and keeps the answers. Where the account has no calendar the
/// app can reach, the meeting goes to the phone's calendar app instead,
/// attendees and all; where Microsoft has not yet allowed the app the
/// calendar, the sign-in that asks for it is offered here rather than in
/// Settings. Where the account's calendar holds meetings online, Teams or
/// Google Meet, a switch asks for a link with the invitation; where there
/// is a choice, a Microsoft account with a Gmail account signed in with
/// Google beside it, a menu says which.
///
/// The link is made as the switch goes on, not at Send, so that what the
/// invitation will say about joining (the Teams block, the Meet link) is
/// under the notes while they are written, as Outlook has it; see
/// [PreparedMeeting]. It is undone when the switch goes off, From changes,
/// or the screen is left without sending.
///
/// With meeting links kept in Settings (Ron's Zoom room, say: see
/// [MeetingLink]), the menu lists them under Teams and Meet, and the switch
/// is there for every account once it has answered, an account whose own
/// calendar holds none among them. Nothing is made for such a link: the
/// meeting goes with it in the place, where none was typed, and as the
/// notes' last line, which the screen shows under the notes and puts in
/// what it sends, never in the fields.
///
/// How long a new meeting lasts, and whether its switch starts on, are as
/// Settings, Calendar, New meetings say ([NewMeetingDefaults]); a meeting
/// being changed keeps what it has.
class NewMeetingScreen extends ConsumerStatefulWidget {
  const NewMeetingScreen({
    super.key,
    required this.accountId,
    this.title = '',
    this.notes = '',
    this.attendees = const [],
    this.start,
    this.location = '',
    this.length,
    this.allDay = false,
    this.editing,
    this.asWritten,
    this.failure,
  });

  final String accountId;
  final String title;
  final String notes;

  /// Who is asked, to begin with: everyone on the message it was made from.
  final List<MailAddress> attendees;

  /// When it starts. The next whole hour when null; the end is [length]
  /// on, or where that is null as long as Settings say a new meeting lasts
  /// (an hour until chosen; see [NewMeetingDefaults]).
  final DateTime? start;
  final String location;
  final Duration? length;
  final bool allDay;

  /// A meeting already on a calendar, being changed: Edit on its sheet.
  /// Everything is filled in from it, From is its account, and Save sends
  /// the change in place of Send. Its link, if it has one, stays as it is.
  final EventEdit? editing;

  /// The screen as it stood at a Send or Save that failed after it was
  /// left, opened again with everything as it was, and [failure] said.
  final MeetingAsWritten? asWritten;
  final Object? failure;

  @override
  ConsumerState<NewMeetingScreen> createState() => _NewMeetingScreenState();
}

/// What a meeting screen held at Send or Save: kept so that one that fails
/// after the screen was left opens again as it was written, with the same
/// key for the calendar and the Sends that failed, so trying again is the
/// same meeting (see [MeetingDraft.transactionId]), not a second set of
/// invitations.
@immutable
class MeetingAsWritten {
  const MeetingAsWritten({
    required this.accountId,
    required this.calendarId,
    required this.title,
    required this.attendees,
    required this.location,
    required this.notes,
    required this.start,
    required this.end,
    required this.allDay,
    required this.options,
    required this.online,
    required this.onlineKind,
    required this.prepared,
    required this.transactionId,
    required this.failedSends,
    this.savedLink,
    this.optional = const {},
  });

  final String accountId;
  final String calendarId;
  final String title;

  /// As the Attendees field had them.
  final String attendees;

  /// Who of them was optional, by address in lower case.
  final Set<String> optional;
  final String location;
  final String notes;

  /// The instants the screen keeps; see `_shown`.
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final MeetingOptions options;
  final bool online;
  final OnlineMeetingKind? onlineKind;

  /// The link made ahead, which the screen opened again holds now: still
  /// on the ledger, as one a screen holds is.
  final PreparedMeeting? prepared;
  final String transactionId;
  final List<MeetingDraft> failedSends;

  /// The meeting link picked from the Online menu, where one was.
  final MeetingLink? savedLink;
}

class _NewMeetingScreenState extends ConsumerState<NewMeetingScreen>
    with GuardsPutAway<NewMeetingScreen> {
  /// A meeting has nowhere to be saved, so one with anything typed or
  /// picked in it stays when the app is put away; an untouched one closes.
  @override
  Future<bool> whenPutAway() async => _untouched;

  /// Which account the meeting is from. Starts as the one it was opened
  /// for, and can be changed from the header: Ron asked to choose the
  /// account before anything else about an invitation, and the calendar
  /// it lands on follows from it.
  late String _accountId = widget.asWritten?.accountId ??
      widget.editing?.event.accountId ??
      widget.accountId;

  /// Which of the account's calendars it goes on: its main one unless
  /// another is chosen. A meeting being changed stays where it is.
  late String _calendarId =
      widget.asWritten?.calendarId ?? CalendarEvent.mainCalendar;

  /// What the screen opened with again, after a Send or Save that failed
  /// once it was left.
  MeetingAsWritten? get _written => widget.asWritten;

  EventEdit? get _editing => widget.editing;

  late final String _titleToBegin = _editing?.event.title ?? widget.title;
  late final String _notesToBegin = _editing?.notes.text ?? widget.notes;
  late final String _locationToBegin =
      _editing?.event.location ?? widget.location;

  late final _title =
      TextEditingController(text: _written?.title ?? _titleToBegin);
  late final _attendees =
      TextEditingController(text: _written?.attendees ?? _attendeesToBegin);

  /// The attendees as the field starts, a bubble each. A meeting being
  /// changed has its own, less its organiser and the account itself.
  late final String _attendeesToBegin = () {
    final people = _editing == null
        ? widget.attendees
        : _peopleOn(_editing!.event);
    return formatAddresses(people);
  }();

  /// Who of the attendees is asked as optional, by address in lower case
  /// (calendar idea #56): chosen from a bubble's menu, and for a meeting
  /// being changed, those its calendar has as optional to begin with. Only
  /// those still on the field at Send or Save count.
  late final ValueNotifier<Set<String>> _optional =
      ValueNotifier(_written?.optional ?? _optionalToBegin);
  late final Set<String> _optionalToBegin = {
    for (final a in _editing?.event.attendees ?? const <EventAttendee>[])
      if (a.optional) a.address.email.trim().toLowerCase(),
  };

  /// Who of [people] is optional now.
  Set<String> _optionalOf(List<MailAddress> people) => {
        for (final a in people)
          if (_optional.value.contains(a.email.trim().toLowerCase()))
            a.email.trim().toLowerCase(),
      };

  /// Who [event] is with, as the attendees field lists them.
  List<MailAddress> _peopleOn(CalendarEvent event) {
    final own = (ref
                .read(accountsProvider)
                .value
                ?.where((a) => a.id == event.accountId)
                .firstOrNull
                ?.emailAddress ??
            '')
        .trim()
        .toLowerCase();
    return [
      for (final a in event.attendees)
        if (a.response != EventResponse.organizer &&
            a.address.email.trim().toLowerCase() != own)
          a.address,
    ];
  }

  late final _location =
      TextEditingController(text: _written?.location ?? _locationToBegin);
  late final _notes =
      TextEditingController(text: _written?.notes ?? _notesToBegin);

  /// How a new meeting starts, as Settings, Calendar, New meetings have it
  /// (calendar idea #61): read once, as the screen opens. A meeting being
  /// changed never starts from them.
  late final NewMeetingDefaults _defaults =
      ref.read(newMeetingDefaultsProvider);

  /// How long a new meeting is where nothing says: the length chosen in
  /// Settings, less the minutes it ends early. An hour for a meeting being
  /// changed, as it always was.
  Duration get _defaultLength =>
      _editing == null ? _defaults.length : const Duration(hours: 1);

  /// The times as the screen opened, kept to tell a time picked from one
  /// left alone. A whole day ends on its last day here, where a calendar
  /// counts the day after.
  late final DateTime _startToBegin = _editing?.event.start ??
      widget.start ??
      _nextHour(DateTime.now());
  late final DateTime _endToBegin = switch (_editing?.event) {
    final e? => e.allDay ? DateTime(e.end.year, e.end.month, e.end.day - 1) : e.end,
    null => widget.allDay
        ? _startToBegin
        : _startToBegin.add(widget.length ?? _defaultLength),
  };
  late final bool _allDayToBegin = _editing?.event.allDay ?? widget.allDay;

  late DateTime _start = _written?.start ?? _startToBegin;
  late DateTime _end = _written?.end ?? _endToBegin;
  late bool _allDay = _written?.allDay ?? _allDayToBegin;
  bool _sending = false;

  /// More's choices: the repeat, reminder, show as, privacy and zone. A
  /// meeting being changed starts from how it shows and its privacy, its
  /// reminder as it is, and every meeting of a series from its repeat.
  late final MeetingOptions _optionsToBegin = switch (_editing?.event) {
    final e? => MeetingOptions(
        showAs: e.showAs,
        isPrivate: e.isPrivate,
        repeat: _repeatToBegin,
      ),
    null => const MeetingOptions(),
  };
  late MeetingOptions _options = _written?.options ?? _optionsToBegin;

  /// How the series repeats, as its calendar has it, where every meeting
  /// of one is being changed (calendar idea #55); null otherwise.
  SeriesRepeat? get _series =>
      _editing?.wholeSeries ?? false ? _editing!.notes.repeat : null;

  /// Whether More offers Repeat: on a new meeting; on a meeting on its own
  /// being changed, to make it a series; and on every meeting of a series
  /// whose repeat New meeting has words for. Never on one meeting of a
  /// series, which repeats as its series does; nor on a timed meeting
  /// whose zone its calendar does not name, as a repeat is written in the
  /// zone it was set in (see [forSeries]).
  bool get _canRepeat => switch (_editing) {
        null => true,
        final e when !_zoneKnown(e.event) => false,
        final e when e.wholeSeries => _series?.repeat != null,
        final e => e.event.seriesId == null,
      };

  /// Whether a repeat can be written for [event] on its own clock: its
  /// zone known, or a whole day, which no zone moves.
  static bool _zoneKnown(CalendarEvent event) =>
      event.allDay || ownZoneOf(event) != null;

  /// The day the account's calendar counts a series' weeks from: Sunday
  /// for Outlook, Monday for Google, as each writes every other week.
  int get _weekStart => _account?.provider == MailProvider.gmail
      ? DateTime.monday
      : DateTime.sunday;

  /// The series' repeat as Repeat starts: as read, and Every working day
  /// where it is the work week's days every week, which is how New meeting
  /// sends that.
  late final Recurrence? _repeatToBegin = () {
    final read = _series?.repeat;
    final work = ref.read(workWeekProvider);
    if (read != null &&
        read.kind == RepeatKind.weekly &&
        read.interval == 1 &&
        setEquals(read.days, work)) {
      return Recurrence(RepeatKind.workDays,
          days: work, until: read.until, count: read.count);
    }
    return read;
  }();

  /// Whether Repeat was changed on a meeting being changed.
  bool get _repeatChanged =>
      _editing != null && _options.repeat != _optionsToBegin.repeat;

  /// The first meeting, as Repeat names it: for every meeting of a series,
  /// at the first day on or after the series' own that its repeat, as now
  /// chosen, falls on, where the series starts again once saved.
  DateTime get _repeatStart {
    final shown = _shown(_start);
    final from = _series?.firstDay;
    final repeat = _options.repeat;
    if (from == null || repeat == null) return shown;
    final day = firstDayOf(repeat, from, weekStart: _weekStart);
    return DateTime(day.year, day.month, day.day, shown.hour, shown.minute);
  }

  /// The day of the last meeting the repeat, as now chosen, makes, where
  /// it ends; null where it goes on.
  DateTime? get _lastMeeting {
    final repeat = _options.repeat;
    if (repeat == null) return null;
    return lastMeetingOf(repeat, _repeatStart, weekStart: _weekStart);
  }

  /// Whether that last meeting is already past: every meeting after it
  /// would come off everyone's calendar, which Save asks about first.
  bool get _endsInThePast {
    if (!_repeatChanged) return false;
    final last = _lastMeeting;
    final now = DateTime.now();
    return last != null &&
        last.isBefore(DateTime(now.year, now.month, now.day));
  }

  /// Whether anyone besides the account is on the meeting, as the screen
  /// has it, or was: who a change is sent to.
  bool get _anyoneOn =>
      parseAddresses(_attendees.text).isNotEmpty ||
      (_editing?.event.attendees.any(
              (a) => a.response != EventResponse.organizer) ??
          false);

  /// The sentence that says the last meeting is already past.
  String _pastWords(DateTime last) =>
      "The series' last meeting is then ${dayInWords(last)}, already past: "
      "every meeting after it comes off everyone's calendar.";

  /// What saving a new repeat does, said before Save (#55), or null where
  /// Repeat is as it was.
  ///
  /// A series is changed whole, past meetings too: neither calendar keeps
  /// a series' past apart from its pattern. What becomes of a meeting of
  /// it changed on its own is each calendar's: Outlook drops such changes
  /// when a series' pattern changes, in its own app at least, and Google
  /// keeps a change to a meeting whose day is still in the series. Neither
  /// was seen on a live account, so the screen says "may".
  ///
  /// The last meeting is named where the repeat ends, and an end already
  /// past says what it does: the series is stopped there, and every
  /// meeting after it comes off everyone's calendar. Nobody is said to be
  /// sent anything where nobody else is on it.
  String? get _repeatNote {
    final edit = _editing;
    if (edit == null || !_repeatChanged) return null;
    final told = _anyoneOn ? ', and everyone on it is sent the change' : '';
    final last = _lastMeeting;
    final past = _endsInThePast && last != null;
    if (!edit.wholeSeries) {
      final ends = last == null
          ? ''
          : past
              ? ' ${_pastWords(last)}'
              : ' Its last meeting is then ${dayInWords(last)}.';
      return 'It becomes a series from this meeting on$told.$ends';
    }
    final before = _optionsToBegin.repeat;
    final now = _options.repeat;
    final endOnly = before != null &&
        now != null &&
        before.ending(day: now.until, times: now.count) == now;
    final String what;
    if (past) {
      what = endOnly
          ? _pastWords(last)
          : 'Every meeting in the series follows the new repeat, past ones '
              'too$told. ${_pastWords(last)}';
    } else if (endOnly) {
      what = last == null
          ? 'The series now goes on with no end$told.'
          : "The series' last meeting is then ${dayInWords(last)}$told.";
    } else {
      what = 'Every meeting in the series follows the new repeat, past ones '
          'too$told.${last == null ? '' : ' Its last meeting is then '
              '${dayInWords(last)}.'}';
    }
    final own = _account?.provider == MailProvider.outlook
        ? ' Any meeting you changed on its own, or deleted, may go back to '
            'how the series has it.'
        : endOnly
            ? ''
            : ' Any meeting you changed on its own may stay where it was.';
    return '$what$own';
  }

  /// Asked before Save sends a repeat whose last meeting is already past
  /// (#55): true to send it.
  Future<bool> _endInThePastAsked() async {
    final last = _lastMeeting;
    if (!_endsInThePast || last == null) return true;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End the series in the past?'),
        content: Text(_pastWords(last)),
        actions: [
          TextButton(
            key: const ValueKey('repeat-past-keep'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            key: const ValueKey('repeat-past-save'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  /// More, in its sheet.
  void _openMore() => showMeetingOptions(
        context,
        options: _options,
        start: _shown(_start),
        allDay: _allDay,
        workWeek: ref.read(workWeekProvider),
        editing: _editing != null,
        freeOrBusy: _account?.provider == MailProvider.gmail,
        repeats: _canRepeat,
        seriesFrom: _canRepeat ? _series?.firstDay : null,
        seriesWeekStart: _weekStart,
        seriesCount: _optionsToBegin.repeat?.count,
        onChanged: (o) => setState(() => _options = o),
      );

  /// The line a meeting is typed in, "Lunch with Dana Thursday 1pm", and
  /// whether it is being read.
  final _quick = TextEditingController();
  bool _reading = false;

  /// [instant] as the times are set: on the clock of the zone More chose,
  /// where it chose one. A whole day is its dates, whatever the zone.
  DateTime _shown(DateTime instant) {
    final zone = _options.zone;
    return zone == null || _allDay ? instant : wallClockIn(instant, zone);
  }

  /// A time picked on that clock, as the instant the screen keeps.
  DateTime _unshown(DateTime wall) {
    final zone = _options.zone;
    return zone == null || _allDay ? wall : instantIn(wall, zone);
  }

  /// The kinds a meeting from this account can be held online as, empty
  /// while it has not said, or where there is none: the switch is on the
  /// screen only with an answer. Asked when the screen opens and again
  /// when From changes.
  List<OnlineMeetingKind> _onlineKinds = const [];

  /// Which of them, where there is a choice: a Microsoft account with
  /// Teams and, through the Gmail account, Google Meet. The first unless
  /// one was chosen, and the choice kept through a change of From where
  /// the account now can hold it too.
  late OnlineMeetingKind? _onlineKind = _written?.onlineKind;

  /// Whether [_onlineKind] was chosen from the menu, rather than being the
  /// first of an account's: only a choice is kept through From. Without
  /// one, Hadco's Teams, on by default (#61), came back as Meet once From
  /// had been the Gmail account, whose only kind it is.
  late bool _kindChosen = _written?.onlineKind != null;

  /// Whether a link was asked for. Honoured only where the account's
  /// calendar holds meetings online: the switch keeps its setting through
  /// a change of From, and a meeting from an account with nowhere to hold
  /// one goes without.
  ///
  /// On to begin with for an account Settings start online (#61), and
  /// following From's own setting until the switch, a kind or a meeting
  /// link is chosen here ([_onlineChosen]).
  late bool _online = _written?.online ??
      (_editing == null && _defaults.onlineFor(_accountId));

  /// Whether the switch was set here, by hand, rather than by Settings: it
  /// then stays as set whatever From becomes.
  late bool _onlineChosen = _written != null;

  /// Which ask is the current one. From can change while an answer is on
  /// its way, and the answer for the account before must not label the
  /// switch for the account now.
  int _onlineAsk = 0;

  /// Whether the account now in From has answered that ask. With meeting
  /// links kept, the switch is there once it has, whatever it answered.
  bool _onlineAnswered = false;

  /// A meeting link picked from the menu (see [MeetingLink]), Ron's Zoom
  /// room say, or null while the menu is on the account's own kind. Kept
  /// through a change of From: the room is Ron's whichever account
  /// invites to it.
  late MeetingLink? _pickedLink = _written?.savedLink;

  /// The meeting links kept in Settings, Calendar. Read through the app's
  /// container, as a Send may still be finishing once the screen is gone.
  List<MeetingLink> get _links => _container.read(meetingLinksProvider);

  /// The meeting link the switch holds: the one picked, while it is still
  /// kept, or else the first for an account that has answered and holds
  /// none of its own. Null on Teams or Meet, and with no link kept.
  MeetingLink? get _linkChoice {
    final links = _links;
    if (links.contains(_pickedLink)) return _pickedLink;
    if (!_onlineAnswered || _onlineKinds.contains(_onlineKind)) return null;
    return links.firstOrNull;
  }

  /// Something the person can correct on the screen: no title, an end
  /// before the start, an address with a typo. Not a failure.
  String? _invalid;

  /// A way things went that is neither theirs to correct nor worth
  /// reporting, said in a sentence: Microsoft wanting a consent, or nowhere
  /// to hand the meeting to.
  String? _notice;

  /// The Gmail account offered a sign-in under [_notice], when it is that
  /// account, not the meeting's, that has to allow the app something:
  /// making Meet links, for a meeting from a Microsoft account.
  String? _offerMeet;

  /// Whether a sign-in that asks Microsoft for the calendar is offered
  /// under [_notice], and whether it is the administrator being asked.
  ///
  /// Offered even when only an administrator can give it. The sign-in
  /// cannot succeed then, but Microsoft's page is where the request to
  /// the administrator is made: it offers "Request approval", the
  /// administrator is told, and the mail permissions were granted this
  /// way the first time. Kept off it, there was no way to ask.
  bool _offerConsent = false;
  bool _askAdministrator = false;

  /// Something that went wrong out of their hands. Worth reporting.
  ProblemReport? _problem;

  /// The online meeting made for the switch, whose text is under the
  /// notes. Null while there is none, or while it is on its way.
  late PreparedMeeting? _prepared = _written?.prepared;

  /// Its making, while it is on its way: Send waits for it, so that the
  /// invitation carries what the screen showed.
  Future<void>? _preparing;

  /// Which making is the current one. An answer for one dropped since is
  /// undone when it comes.
  int _prepareAsk = 0;

  /// Whether the last making came to nothing, so the screen says the link
  /// comes at Send instead.
  bool _prepareFailed = false;

  /// Whether the consent a notice offers is for making the link, so that
  /// signing in makes it rather than sending the meeting.
  bool _consentToPrepare = false;

  /// Set once the meeting is sent. What was made ahead is the meeting now,
  /// and leaving must not undo it.
  bool _sent = false;

  /// Set while the calendar is sending it, or Save the change. Leaving then
  /// must not undo what is being sent either: Send puts it back on the
  /// ledger if it did not go, and the next start deletes it then. Nor can
  /// it be called back, so Back no longer offers to discard it.
  bool _sendingMeeting = false;

  /// The question on leaving, while it is up: Send waits for its answer
  /// before the calendar is asked, since it says nothing has been sent.
  Future<bool>? _askingToLeave;

  /// Either question on leaving, while it is up, so that how the meeting
  /// went takes down that and nothing else.
  Route<bool>? _question;

  /// Set once the screen is being left, by Back or by Send's own close. It
  /// stays mounted while it slides away, and nothing may be sent, nor any
  /// page closed, for it then.
  bool _left = false;

  bool get _gone => _left || !mounted;

  /// Where a Send or Save says how it went, taken as it starts: it is said
  /// even if the screen was left while it was on its way.
  ScaffoldMessengerState? _messenger;

  /// Where the screen was, and what it held, at Send or Save: a failure
  /// after the screen was left opens it there again, as it was written.
  NavigatorState? _navigator;
  MeetingAsWritten? _atSend;

  /// This meeting's key for the calendar, the same through every Send: a
  /// Send that failed after the calendar had made the meeting after all,
  /// tapped again, is the same meeting, not a second set of invitations.
  late final String _transactionId =
      _written?.transactionId ?? MeetingDraft.newTransactionId();

  /// The meeting of each Send that failed, as it stood. The calendar may
  /// have made any one of them after all, so a Send of a meeting unlike
  /// any of these asks for the one it answers with to be brought up to
  /// date; see [MeetingDraft.changedSinceFailedSend]. Each, not only the
  /// first: a second Send that failed may have made its meeting in place
  /// of the first's.
  late final List<MeetingDraft> _failedSends = [...?_written?.failedSends];

  /// The app's container, taken while the screen is there: a meeting made
  /// ahead is undone as the screen goes, when its own ref no longer reads.
  late final ProviderContainer _container;

  static DateTime _nextHour(DateTime now) =>
      DateTime(now.year, now.month, now.day, now.hour + 1);

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    // A meeting being changed keeps the link it has: there is no switch.
    if (_editing == null) _askOnline();
    // Said, so that Edit offering no Repeat on a device can be told apart
    // from a series not read (#55).
    if (_editing case final edit? when !_zoneKnown(edit.event)) {
      debugPrint('[myemail] no Repeat on Edit: the calendar names no time '
          'zone for this meeting');
    }
    // Opened again after a Send or Save that failed once it was left: why,
    // as it would have been said had the screen stayed.
    if (widget.failure case final failure?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sayFailed(failure);
      });
    }
  }

  /// Ask how a meeting from this account can be held online, and show the
  /// switch for it, labelled so, once it answers. Gone for an account that
  /// has no way.
  Future<void> _askOnline() async {
    final ask = ++_onlineAsk;
    final kinds =
        await ref.read(mailEngineProvider).onlineMeetingsFor(_accountId);
    if (!mounted || ask != _onlineAsk) return;
    setState(() {
      _onlineKinds = kinds;
      _onlineAnswered = true;
      _onlineKind = _kindChosen && kinds.contains(_onlineKind)
          ? _onlineKind
          : kinds.firstOrNull;
    });
    // From changed with the switch on: this account's link, and its text.
    if (_online && _prepared == null && _preparing == null) {
      unawaited(_prepare());
    }
  }

  /// Make the online meeting for the switch as it now stands, and put what
  /// its invitation says under the notes. Any made before is undone first.
  Future<void> _prepare() async {
    _dropPrepared();
    final kind = _onlineKind;
    if (!_online || kind == null || !_onlineKinds.contains(kind)) return;
    // Held in a room of Ron's own instead: there is nothing to make.
    if (_linkChoice != null) return;
    // Made ahead on the main calendar alone; on another, Send makes the
    // link as it makes the meeting.
    if (_calendarId != CalendarEvent.mainCalendar) return;
    final ask = ++_prepareAsk;
    final done = Completer<void>();
    setState(() {
      _preparing = done.future;
      _prepareFailed = false;
    });
    try {
      final draft = await _draft(const []);
      final made =
          await _container.read(mailEngineProvider).prepareOnlineMeeting(draft);
      // On the ledger at once, whatever comes of it: undone below or later,
      // it is the next start's to delete should undoing it fail. A ledger
      // that cannot be written to is no reason to lose the meeting.
      if (made != null) {
        try {
          await _container.read(preparedMeetingLedgerProvider).record(made);
        } catch (e) {
          debugPrint('[myemail] could not keep the meeting made ahead: $e');
        }
      }
      if (_gone || ask != _prepareAsk) {
        // Switched off, From changed, or the screen left, while it was
        // being made.
        if (made != null) unawaited(_discard(made));
        return;
      }
      setState(() {
        _prepared = made;
        _prepareFailed = made == null;
      });
    } catch (error) {
      // An event made and not undone: the next start deletes it.
      var e = error;
      if (e is PreparedMeetingLeft) {
        try {
          await _container
              .read(preparedMeetingLedgerProvider)
              .record(e.leftover);
        } catch (_) {
          // Nowhere to keep it; said below with the rest.
        }
        e = e.cause;
      }
      if (_gone || ask != _prepareAsk) return;
      // A sign-in that has not allowed it yet is offered here, as at Send.
      // Anything else leaves the link to Send, which makes it as it always
      // did and says what went wrong if it goes wrong again.
      if (!_askForConsent(e, toPrepare: true)) {
        debugPrint('[myemail] could not make the meeting link ahead: $e');
      }
      setState(() => _prepareFailed = true);
    } finally {
      done.complete();
      if (mounted && ask == _prepareAsk) setState(() => _preparing = null);
    }
  }

  /// Undo the meeting made for the switch, and any on its way, with any
  /// sign-in the making asked for: the kind or account that needed it is
  /// no longer the one wanted. The caller sets the state.
  void _dropPrepared() {
    _prepareAsk++;
    final made = _prepared;
    _prepared = null;
    _preparing = null;
    _prepareFailed = false;
    if (_consentToPrepare) {
      _consentToPrepare = false;
      _notice = null;
      _offerMeet = null;
      _offerConsent = false;
      _askAdministrator = false;
    }
    if (made != null) unawaited(_discard(made));
  }

  /// Delete it, telling nobody, and take it off the ledger once that is
  /// done. Where it could not be done now, it stays there, and the next
  /// start tries again.
  Future<void> _discard(PreparedMeeting made) async {
    try {
      final done = await _container
          .read(mailEngineProvider)
          .discardPreparedMeeting(made);
      if (done) {
        await _container.read(preparedMeetingLedgerProvider).forget(made);
      }
    } catch (_) {
      // Never thrown on purpose; the ledger has it either way.
    }
  }

  @override
  void dispose() {
    if (!_sent && !_sendingMeeting) _dropPrepared();
    _title.dispose();
    _attendees.dispose();
    _optional.dispose();
    _location.dispose();
    _notes.dispose();
    _quick.dispose();
    super.dispose();
  }

  Account? get _account => ref
      .read(accountsProvider)
      .value
      ?.where((a) => a.id == _accountId)
      .firstOrNull;

  /// Whether leaving loses nothing: the screen is as it opened, and what it
  /// opened with can be had again.
  ///
  /// A time picked counts, and so do All day and another From: a meeting
  /// made out of a message comes with everything else filled in, and they
  /// can be all that was done before a look at the calendar app. The
  /// Online switch alone does not: its link is undone with the screen, and
  /// made again as easily.
  ///
  /// Opened again after a Send that failed, what it holds is nowhere else.
  bool get _untouched =>
      _written == null &&
      _accountId == (_editing?.event.accountId ?? widget.accountId) &&
      _start == _startToBegin &&
      _end == _endToBegin &&
      _allDay == _allDayToBegin &&
      _title.text == _titleToBegin &&
      _attendees.text == _attendeesToBegin &&
      setEquals(_optional.value, _optionalToBegin) &&
      _location.text == _locationToBegin &&
      _notes.text == _notesToBegin &&
      _options == _optionsToBegin &&
      _quick.text.isEmpty;

  /// Move the start, and the end with it, so the meeting keeps its length:
  /// a meeting moved to Tuesday is still an hour long.
  void _setStart(DateTime next) {
    final length = _end.difference(_start);
    setState(() {
      _start = next;
      _end = next.add(length.isNegative ? _defaultLength : length);
    });
  }

  Future<void> _pickDate(DateTime at, ValueChanged<DateTime> set) async {
    final day = await showDatePicker(
      context: context,
      initialDate: at,
      firstDate: DateTime(at.year - 1),
      lastDate: DateTime(at.year + 10),
    );
    if (day == null) return;
    set(DateTime(day.year, day.month, day.day, at.hour, at.minute));
  }

  Future<void> _pickTime(DateTime at, ValueChanged<DateTime> set) async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(at),
    );
    if (time == null) return;
    set(DateTime(at.year, at.month, at.day, time.hour, time.minute));
  }

  /// What the screen holds, as a meeting, with the device's zone so the
  /// calendar knows what clock the times are on, and said to be changed
  /// where it is unlike a Send that failed.
  Future<MeetingDraft> _draft(List<MailAddress> attendees) async {
    String? zone;
    try {
      zone = await ref.read(deviceCalendarProvider).timeZoneId();
    } catch (_) {
      // Then the times go as UTC, which every calendar reads.
    }
    DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);
    // Set in another zone: the times on its clock, and its name beside
    // them, so a 10:00 New York call stays New York's 10:00.
    final elsewhere = _allDay ? null : _options.zone;
    // Held in a room of Ron's own: its link where a person pasting it
    // would put it, the place where none was typed and the notes' last
    // line, as Graph is given a Meet link made elsewhere. Every calendar
    // takes it so, the phone's calendar app too, and none is asked for a
    // link of its own. The fields keep what Ron typed.
    final room = _online ? _linkChoice : null;
    final place = _location.text.trim();
    MeetingDraft draft({bool changed = false}) => MeetingDraft(
          accountId: _accountId,
          title: _title.text.trim(),
          attendees: attendees,
          optional: _optionalOf(attendees),
          start: _allDay ? day(_start) : _shown(_start),
          end: _allDay ? day(_end) : _shown(_end),
          allDay: _allDay,
          location: room != null && place.isEmpty ? room.url : place,
          notes: room?.endOf(_notes.text.trim()) ?? _notes.text.trim(),
          timeZone: elsewhere ?? zone,
          online: _online && room == null ? _onlineKind : null,
          prepared: _online &&
                  room == null &&
                  _calendarId == CalendarEvent.mainCalendar
              ? _prepared
              : null,
          calendarId: _calendarId,
          transactionId: _transactionId,
          changedSinceFailedSend: changed,
          recurrence: _editing == null ? _options.repeat : null,
          reminder: _options.reminder,
          showAs: _options.showAs,
          isPrivate: _options.isPrivate,
        );
    final now = draft();
    return _failedSends.any((tried) => !tried.sameMeetingAs(now))
        ? draft(changed: true)
        : now;
  }

  Future<void> _send() async {
    if (_editing case final edit?) return _save(edit);
    final attendees = parseAddresses(_attendees.text);
    if (!addressesLookValid(attendees)) {
      setState(() => _invalid = 'One of the addresses does not look right.');
      return;
    }
    _messenger = ScaffoldMessenger.maybeOf(context);
    _navigator = Navigator.of(context);
    // A link still being made is waited for, so that the invitation goes
    // with the one whose text is on the screen.
    final making = _preparing;
    if (making != null) {
      setState(() => _sending = true);
      await making;
      if (_gone) return;
    }
    final meeting = await _draft(attendees);
    // The room it holds, if one of Ron's own, as the draft was made, for
    // the message that says it went. Not said after a Send that asked the
    // calendar for a link of its own and failed, where a place was typed:
    // that Send may have made its meeting after all, with only the answer
    // lost, and the calendar then answers this one with it, keeps its
    // Teams body and takes the place typed, so the room is nowhere in it.
    final room = _online ? _linkChoice : null;
    final roomSaid = room != null &&
            (meeting.location == room.url ||
                !_failedSends.any((tried) => tried.online != null))
        ? room
        : null;
    if (_gone) return;
    final problem = meeting.problem;
    if (problem != null) {
      setState(() {
        _invalid = problem;
        _sending = false;
      });
      return;
    }

    setState(() {
      _sending = true;
      _invalid = null;
      _notice = null;
      _offerConsent = false;
      _offerMeet = null;
      _problem = null;
    });
    if (await _leavingAsked()) return;
    _atSend = _asWritten(prepared: meeting.preparedHere);
    // Where it is held, for the message that says what went out.
    final held = meeting.online;
    final ledger = _container.read(preparedMeetingLedgerProvider);
    final prepared = meeting.preparedHere;
    // Off the ledger before it goes: an app closed from here on must not
    // have the next start deleting a meeting that was sent.
    _sendingMeeting = true;
    try {
      if (prepared != null) await ledger.forget(prepared);
      final created =
          await _container.read(mailEngineProvider).createMeeting(meeting);
      _sent = true;
      _container.read(calendarRefreshProvider.notifier).now();
      // The one made ahead could not be used (deleted meanwhile, or its
      // calendar dropped the link) and the calendar made another: the old
      // one is undone, once more if need be, and the link shown, which may
      // have been copied, is said to be a new one.
      final remade = prepared?.eventId != null && created.id != prepared!.eventId;
      if (remade) {
        unawaited(ledger
            .record(prepared)
            .then((_) => _discard(prepared))
            .catchError((_) {}));
      }
      // Said whether the screen is still there or was left meanwhile. A
      // room by Ron's own name for it: this is said to him alone, where
      // the invitation names only the service (MeetingLink.line).
      final link = held == null
          ? roomSaid == null
              ? ''
              : ', with the ${roomSaid.name} link'
          : remade
              ? ', with a new ${held.link.replaceFirst(RegExp('^an? '), '')}: '
                  'the one shown could not be used'
              : ', with ${held.link}';
      _leave(meeting.hasAttendees
          ? 'Invitation sent$link'
          : 'Added to your calendar$link');
    } on CalendarUnavailable catch (e) {
      // Handed to the calendar app only while the screen is there to
      // hand it from.
      if (_gone) return _reopen(e);
      _closeQuestion();
      await _handToDevice(meeting, e);
    } catch (e) {
      // Any Send may have made its meeting with only the answer lost, but
      // not one turned away for want of a sign-in: nothing was asked.
      if (e is! SignInNeedsConsent && e is! MeetLinkNeedsConsent) {
        _failedSends.add(meeting);
      }
      if (_gone) return _reopen(e);
      _closeQuestion();
      _sayFailed(e);
    } finally {
      _sendingMeeting = false;
      // Not sent: still made, and still the ledger's to clear up.
      if (!_sent && prepared != null) {
        unawaited(ledger.record(prepared).catchError((_) {}));
      }
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Send the change made to [edit]'s meeting: only what differs from how
  /// it was, so a change of the people alone writes to them alone.
  Future<void> _save(EventEdit edit) async {
    final attendees = parseAddresses(_attendees.text);
    if (!addressesLookValid(attendees)) {
      setState(() => _invalid = 'One of the addresses does not look right.');
      return;
    }
    if (_title.text.trim().isEmpty) {
      setState(() => _invalid = 'Give the meeting a title.');
      return;
    }
    DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);
    if (_allDay ? day(_end).isBefore(day(_start)) : !_end.isAfter(_start)) {
      setState(() => _invalid = _allDay
          ? 'The last day cannot be before the first.'
          : 'The meeting has to end after it starts.');
      return;
    }
    // A repeat changed here, as New meeting asks of one.
    final repeat = _repeatChanged ? _options.repeat : null;
    final last = repeat?.until;
    if (last != null && last.isBefore(day(_repeatStart))) {
      setState(() => _invalid =
          'The repeat has to end on the first meeting or after it.');
      return;
    }
    // An end already past stops the series there, for everyone: asked
    // once (#55).
    if (!await _endInThePastAsked() || !mounted) return;
    _messenger = ScaffoldMessenger.maybeOf(context);
    _navigator = Navigator.of(context);
    setState(() {
      _sending = true;
      _invalid = null;
      _notice = null;
      _offerConsent = false;
      _problem = null;
    });
    String? zone;
    try {
      zone = await ref.read(deviceCalendarProvider).timeZoneId();
    } catch (_) {
      // Then the times go as UTC, which every calendar reads.
    }
    if (await _leavingAsked()) return;
    _atSend = _asWritten();
    final change = EventChange.between(
      edit.event,
      notesBefore: edit.notes,
      title: _title.text,
      start: _allDay ? day(_start) : _start,
      end: _allDay ? dayAfter(day(_end)) : _end,
      allDay: _allDay,
      location: _location.text,
      notes: _notes.text,
      attendees: attendees,
      optional: _optionalOf(attendees),
      timeZone: zone,
      reminder: _options.reminder,
      showAs: _options.showAs,
      isPrivate: _options.isPrivate,
      repeat: repeat,
    );
    _sendingMeeting = true;
    try {
      if (!change.isEmpty) {
        await _container
            .read(mailEngineProvider)
            .updateEvent(edit.event, change, wholeSeries: edit.wholeSeries);
        _container.read(calendarRefreshProvider.notifier).now();
      }
      // Said whether the screen is still there or was left meanwhile.
      final told = attendees.isNotEmpty || edit.event.attendees.isNotEmpty;
      _leave(change.isEmpty
          ? 'Nothing was changed.'
          : told
              ? 'Saved. Everyone on it is sent the change.'
              : 'Saved.');
    } catch (e) {
      if (_gone) return _reopen(e);
      _closeQuestion();
      _sayFailed(e);
    } finally {
      _sendingMeeting = false;
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Ask for the meeting in a line, then read it.
  Future<void> _askQuickAdd() async {
    final line = await showDialog<String>(
      context: context,
      builder: (_) => _QuickAddDialog(controller: _quick),
    );
    if (line == null || line.trim().isEmpty || !mounted) return;
    await _quickAdd();
  }

  /// The meeting typed in a line, read on the phone and put into the
  /// fields: the title, the day and time, and a place after "at".
  Future<void> _quickAdd() async {
    final line = _quick.text.trim();
    if (line.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final finder = ref.read(dateFinderProvider);
    setState(() => _reading = true);
    final found = await finder.find(line);
    if (!mounted) return;
    final read = readQuickMeeting(
      line,
      found,
      length: _allDay ? _defaultLength : _end.difference(_start),
    );
    setState(() {
      _reading = false;
      if (read.title.isNotEmpty) _title.text = read.title;
      if (read.location.isNotEmpty) _location.text = read.location;
      if (read.start case final start?) {
        _allDay = read.allDay;
        _start = start;
        _end = read.end ?? start.add(_defaultLength);
      }
      _quick.clear();
    });
    if (read.start == null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          duration: kBottomMessage,
          content: Text('No day or time found in that: set them below. '
              'The line is read in English.'),
        ));
    }
  }

  /// Say what a sign-in has not yet allowed, with the sign-in that allows
  /// it, or false for any other failure. [toPrepare] is whether it came
  /// from making the link, so signing in makes it again rather than
  /// sending the meeting.
  bool _askForConsent(Object e, {required bool toPrepare}) {
    switch (e) {
      case MeetLinkNeedsConsent():
        // The Gmail account's sign-in is from before the app asked for
        // Meet. Offered here, as the Microsoft one is, and named: it is not
        // the account the meeting is from.
        setState(() {
          _notice = 'Google has not yet allowed the app to make Meet links '
              'with ${e.emailAddress}. Sign in with Google again to allow '
              'it; nothing cached is lost.';
          _offerMeet = e.accountId;
          _consentToPrepare = toPrepare;
        });
        return true;
      case SignInNeedsConsent():
        // In words of its own rather than Microsoft's, which send the
        // person to Settings for the sign-in that is offered right here.
        setState(() {
          _notice = e.needsAdministrator
              ? "Microsoft has not allowed the app to use this account's "
                  "calendar, and only the organisation's administrator can "
                  "allow it. Sign in below: Microsoft's page will offer to "
                  'send them the request. Once they approve, tap Send again.'
              : "Microsoft has not yet allowed the app to use this account's "
                  'calendar. Sign in again to allow it; nothing cached is '
                  'lost.';
          _offerConsent = true;
          _askAdministrator = e.needsAdministrator;
          _consentToPrepare = toPrepare;
        });
        return true;
      default:
        return false;
    }
  }

  /// The account has no calendar the app can reach, so the phone's calendar
  /// app takes the meeting, attendees and all, and invites them from there.
  Future<void> _handToDevice(MeetingDraft meeting, CalendarUnavailable why) async {
    final ok = await ref.read(deviceCalendarProvider).insertEvent(
          title: meeting.title,
          description: meeting.notes.isEmpty ? null : meeting.notes,
          location: meeting.location.isEmpty ? null : meeting.location,
          // The instants the screen keeps: the meeting's own may be on
          // another zone's clock.
          start: meeting.allDay ? meeting.start : _start,
          // Exclusive, which is how the calendar provider counts the end of
          // a whole day.
          end: meeting.allDay ? dayAfter(meeting.end) : _end,
          allDay: meeting.allDay,
          attendees: [for (final a in meeting.attendees) a.email],
          rule: meeting.recurrence
              ?.toRule(meeting.start, allDay: meeting.allDay),
          free: meeting.showAs == EventShowAs.free,
          private: meeting.isPrivate,
        );
    if (ok) {
      _leave("Handed to your calendar app: this account's calendar cannot be "
          'reached from here.');
      return;
    }
    final notice = '${why.message} There is no calendar app on this phone to '
        'hand it to either.';
    if (_gone) return _reopen(why);
    setState(() => _notice = notice);
  }

  /// A sign-in that asks Microsoft for the calendar beside the mail, then
  /// the meeting again.
  Future<void> _allowCalendar() async {
    final account = _account;
    if (account == null) return;
    final token = await MicrosoftSignInScreen.show(
      context,
      loginHint: account.emailAddress,
      scopes: [...MicrosoftOAuth.scopes, ...MicrosoftOAuth.calendarScopes],
    );
    if (token == null || !mounted) return;
    await _signedInAgain(account, token);
  }

  /// A sign-in with Google that asks for Meet beside the mail, for the
  /// Gmail account that makes the link, then the meeting again.
  Future<void> _allowMeet() async {
    final maker = ref
        .read(accountsProvider)
        .value
        ?.where((a) => a.id == _offerMeet)
        .firstOrNull;
    if (maker == null) return;
    final result = await GoogleSignInScreen.show(
      context,
      loginHint: maker.emailAddress,
    );
    if (result == null || !mounted) return;
    await _signedInAgain(
      maker,
      result.token,
      signedInAs: result.identity?.email,
    );
  }

  /// Keep the sign-in [account] just made, then Send again. The account
  /// keeps everything cached: this is the same sign-in again that Settings
  /// offers, brought to where it is needed.
  Future<void> _signedInAgain(
    Account account,
    OAuthToken token, {
    String? signedInAs,
  }) async {
    setState(() {
      _sending = true;
      _notice = null;
      _offerConsent = false;
      _offerMeet = null;
    });
    try {
      await ref.read(accountsProvider.notifier).signInAgain(
            accountId: account.id,
            token: token,
            signedInAs: signedInAs,
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _problem = ProblemReport(
          doing: 'Signing in again to ${account.emailAddress}',
          error: e,
          account: account,
        );
      });
      return;
    }
    if (_gone) return;
    if (_consentToPrepare) {
      setState(() => _sending = false);
      await _prepare();
    } else {
      await _send();
    }
  }

  /// Close this screen, with whatever of its own is over it (the question
  /// on leaving, a sheet), and say [message] along the bottom. Only said,
  /// where the screen was left while it was sending.
  void _leave(String message) {
    if (!_gone) {
      _left = true;
      _closeQuestion();
      _closeScreen();
    }
    _tell(message);
  }

  /// Take down the question on leaving, if it is up: it says the meeting is
  /// on its way, or that nothing has been sent, and neither holds once it
  /// has gone or failed. Only that: a page something else put over this
  /// screen is not this screen's to close.
  void _closeQuestion() {
    final question = _question;
    if (question != null && question.isActive) {
      question.navigator?.removeRoute(question, false);
    }
  }

  /// Take this screen away, and only it: popped where it is on top, taken
  /// out from under a page put over it otherwise, and left alone once it
  /// is going already.
  void _closeScreen() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// [message] along the bottom, through the messenger taken at Send.
  void _tell(String message) {
    final messenger =
        _messenger ?? (mounted ? ScaffoldMessenger.maybeOf(context) : null);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(message)));
  }

  /// A Send or Save that failed, said on the screen: a sign-in to make
  /// where one is wanted, otherwise the problem, kept whole for a report.
  /// Every failure the calendars throw on purpose already carries a
  /// sentence written for a person.
  void _sayFailed(Object e) {
    if (_askForConsent(e, toPrepare: false)) return;
    setState(() => _problem = ProblemReport(
          doing: _editing == null ? 'Creating a meeting' : 'Changing a meeting',
          error: e,
          account: _account,
        ));
  }

  /// The screen as it stands, for [MeetingAsWritten]: [prepared] is the
  /// link a Send hands the calendar. The Sends that failed are the list
  /// itself, so one that fails after this is among them.
  MeetingAsWritten _asWritten({PreparedMeeting? prepared}) =>
      MeetingAsWritten(
        accountId: _accountId,
        calendarId: _calendarId,
        title: _title.text,
        attendees: _attendees.text,
        optional: _optional.value,
        location: _location.text,
        notes: _notes.text,
        start: _start,
        end: _end,
        allDay: _allDay,
        options: _options,
        online: _online,
        onlineKind: _onlineKind,
        prepared: prepared,
        transactionId: _transactionId,
        failedSends: _failedSends,
        savedLink: _pickedLink,
      );

  /// A Send or Save that failed once the screen was left: the screen again,
  /// where it was, as it was written, and why. What was written is nowhere
  /// else, and the calendar may have made the meeting with only its answer
  /// lost, so it is not left to be typed again as a new one. As a held
  /// message that fails opens again (see ComposeScreen).
  void _reopen(Object failure) {
    final written = _atSend;
    final navigator = _navigator;
    // The link made ahead is the new screen's to hold, or to undo.
    _prepared = null;
    if (written == null || navigator == null) return;
    _whenInFront(() {
      if (!navigator.mounted) {
        final why = failure is ReadableError ? ' ${failure.message}' : '';
        return _tell(_editing == null
            ? 'Could not send the meeting.$why'
            : 'Could not change the meeting.$why');
      }
      navigator.push(MaterialPageRoute<void>(
        builder: (_) => NewMeetingScreen(
          accountId: written.accountId,
          editing: widget.editing,
          asWritten: written,
          failure: failure,
        ),
      ));
    });
  }

  /// Whether the screen is being left: the question on leaving, if it is
  /// up, answered Discard, or the screen going. Asked just before the
  /// calendar is, since the question says nothing has been sent.
  Future<bool> _leavingAsked() async {
    final asking = _askingToLeave;
    if (asking != null && await asking) return true;
    return _gone;
  }

  /// Backing out of a half-written meeting. There is no draft to keep it
  /// in, so the question is only whether to lose it; an untouched screen
  /// asks nothing, unless Send is waiting, which the question holds back.
  /// Once the calendar has it, it cannot be called back: the question then
  /// is whether to wait here for how it went. True to leave, and from then
  /// on the screen counts as gone.
  Future<bool> _mayLeave() async {
    final leave = _sendingMeeting
        ? await _ask(
            title: _editing == null ? 'Still sending' : 'Still saving',
            words: '${_editing == null ? 'The meeting' : 'The change'} is on '
                'its way and cannot be stopped now. Leave, and you are told '
                'how it went.',
            stay: 'Stay',
            leave: 'Leave',
          )
        : (!_sending && _untouched) ||
            await _ask(
              title: _editing == null
                  ? 'Discard this meeting?'
                  : 'Discard these changes?',
              words: _editing == null
                  ? 'Nothing has been sent.'
                  : 'The meeting stays as it was.',
              stay: 'Keep writing',
              leave: 'Discard',
              heldFor: true,
            );
    if (leave) _left = true;
    return leave;
  }

  /// A question on leaving, kept in [_question] while it is up; with
  /// [heldFor], one Send waits for (see [_askingToLeave]).
  Future<bool> _ask({
    required String title,
    required String words,
    required String stay,
    required String leave,
    bool heldFor = false,
  }) {
    final asking = showDialog<bool>(
      context: context,
      builder: (context) {
        _question = ModalRoute.of<bool>(context);
        return AlertDialog(
          title: Text(title),
          content: Text(words),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(stay),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(leave),
            ),
          ],
        );
      },
    ).then((answer) => answer ?? false).whenComplete(() {
      _question = null;
      _askingToLeave = null;
    });
    if (heldFor) _askingToLeave = asking;
    return asking;
  }

  /// The kind chosen from the Online menu: the switch on, the link of that
  /// kind made unless it is made already, and any meeting link let go.
  void _chooseKind(OnlineMeetingKind kind) {
    final same = _online &&
        kind == _onlineKind &&
        (_prepared != null || _preparing != null);
    setState(() {
      _pickedLink = null;
      _onlineKind = kind;
      _kindChosen = true;
      _online = true;
      _onlineChosen = true;
    });
    if (!same) unawaited(_prepare());
  }

  /// The Online menu with meeting links kept: the account's own kinds, then
  /// the links by name, or the one there is as a label, a menu with one
  /// entry being a puzzle. Choosing a link is asking for it, and nothing
  /// is made: whatever was made for the account's own kind is undone.
  Widget _onlineMenu(ThemeData theme, List<MeetingLink> links) {
    final choices = <Object>[..._onlineKinds, ...links];
    String label(Object choice) => switch (choice) {
          final MeetingLink link => link.name,
          final OnlineMeetingKind kind => kind.label,
          _ => '',
        };
    if (choices.length == 1) {
      return Text(
        label(choices.single),
        style: theme.textTheme.bodyMedium,
        overflow: TextOverflow.ellipsis,
      );
    }
    return DropdownButton<Object>(
      key: const ValueKey('meeting-online-kind'),
      value: _linkChoice ?? _onlineKind,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      style: theme.textTheme.bodyMedium,
      items: [
        for (final choice in choices)
          DropdownMenuItem<Object>(
            value: choice,
            child: Text(label(choice), overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _sending
          ? null
          : (choice) {
              switch (choice) {
                case final OnlineMeetingKind kind:
                  _chooseKind(kind);
                case final MeetingLink link:
                  setState(() {
                    _dropPrepared();
                    _pickedLink = link;
                    _online = true;
                    _onlineChosen = true;
                  });
              }
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final account = accounts.where((a) => a.id == _accountId).firstOrNull;
    final links = ref.watch(meetingLinksProvider);
    // A meeting link the switch holds, shown under the notes as it goes.
    final room = _online ? _linkChoice : null;
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _mayLeave() && context.mounted) _closeScreen();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_editing == null ? 'New meeting' : 'Edit meeting'),
          centerTitle: false,
          actions: [
            if (_editing == null)
              IconButton(
                key: const ValueKey('meeting-quick-open'),
                tooltip: 'Type it in a line',
                icon: _reading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_outlined),
                onPressed: _sending || _reading ? null : _askQuickAdd,
              ),
            IconButton(
              key: const ValueKey('meeting-more'),
              tooltip: _editing == null
                  ? 'Repeat, reminder, show as, private, time zone'
                  : _canRepeat
                      ? 'Repeat, reminder, show as, private'
                      : 'Reminder, show as, private',
              icon: const Icon(Icons.tune),
              onPressed: _sending ? null : _openMore,
            ),
            IconButton(
              key: const ValueKey('meeting-send'),
              tooltip: _editing == null ? 'Send' : 'Save',
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_editing == null ? Icons.send : Icons.check),
              onPressed: _sending ? null : _send,
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            // As the compose screen has it: with one account there is
            // nothing to choose, and a menu with one entry is a puzzle. A
            // meeting being changed stays on its calendar.
            if (accounts.length > 1 && _editing == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                child: Row(
                  children: [
                    SizedBox(width: 64, child: Text('From', style: muted)),
                    Expanded(
                      child: DropdownButton<String>(
                        key: const ValueKey('meeting-from-account'),
                        value: account?.id,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        style: theme.textTheme.bodyMedium,
                        items: [
                          for (final a in accounts)
                            if (!a.isShared)
                              DropdownMenuItem(
                                value: a.id,
                                child: Text(
                                  a.emailAddress,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                        ],
                        onChanged: _sending
                            ? null
                            : (id) {
                                if (id == null || id == _accountId) return;
                                setState(() {
                                  // The old account's link goes with it;
                                  // the new one's is made once it answers.
                                  _dropPrepared();
                                  _accountId = id;
                                  _calendarId = CalendarEvent.mainCalendar;
                                  // Unknown again until this account has
                                  // answered for itself; the kind chosen
                                  // waits to see whether it can too.
                                  _onlineKinds = const [];
                                  _onlineAnswered = false;
                                  // Online as Settings start this account,
                                  // unless the switch was set here (#61).
                                  if (!_onlineChosen) {
                                    _online = _defaults.onlineFor(id);
                                  }
                                });
                                _askOnline();
                              },
                      ),
                    ),
                  ],
                ),
              )
            else if (account != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _editing == null
                        ? 'From ${account.emailAddress}'
                        : _editing!.wholeSeries
                            ? 'Every meeting in the series, on '
                                '${account.emailAddress}'
                            : 'On ${account.emailAddress}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            if (_editing == null)
              _CalendarChoice(
                accountId: _accountId,
                chosen: _calendarId,
                muted: muted,
                onChanged: _sending
                    ? null
                    : (id) {
                        if (id == _calendarId) return;
                        setState(() {
                          _dropPrepared();
                          _calendarId = id;
                        });
                        if (_online) unawaited(_prepare());
                      },
              ),
            HeaderField(
              key: const ValueKey('meeting-title'),
              label: 'Title',
              controller: _title,
              enabled: !_sending,
              // A meeting from a message has its title; the cursor is
              // better off with the people then.
              autofocus: widget.title.isEmpty && _editing == null,
            ),
            RecipientField(
              key: const ValueKey('meeting-attendees'),
              label: 'Attendees',
              controller: _attendees,
              optional: _optional,
              enabled: !_sending,
              autofocus: widget.title.isNotEmpty && _editing == null,
            ),
            _WhenRow(
              label: 'Start',
              at: _shown(_start),
              allDay: _allDay,
              enabled: !_sending,
              dateEnabled: !(_editing?.wholeSeries ?? false),
              keyPrefix: 'start',
              onDate: () =>
                  _pickDate(_shown(_start), (at) => _setStart(_unshown(at))),
              onTime: () =>
                  _pickTime(_shown(_start), (at) => _setStart(_unshown(at))),
            ),
            _WhenRow(
              label: 'End',
              at: _shown(_end),
              allDay: _allDay,
              enabled: !_sending,
              dateEnabled: !(_editing?.wholeSeries ?? false),
              keyPrefix: 'end',
              onDate: () => _pickDate(_shown(_end),
                  (at) => setState(() => _end = _unshown(at))),
              onTime: () => _pickTime(_shown(_end),
                  (at) => setState(() => _end = _unshown(at))),
            ),
            if (_options.zone case final zone? when !_allDay)
              Padding(
                padding: const EdgeInsets.fromLTRB(80, 0, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${placeOf(zone)} time. Yours: ${formatDay(_start)}, '
                    '${formatClock(_start, use24h: MediaQuery.alwaysUse24HourFormatOf(context))}–'
                    '${formatClock(_end, use24h: MediaQuery.alwaysUse24HourFormatOf(context))}',
                    key: const ValueKey('meeting-your-time'),
                    style: muted,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  SizedBox(width: 64, child: Text('All day', style: muted)),
                  Switch(
                    key: const ValueKey('meeting-all-day'),
                    value: _allDay,
                    onChanged: _sending
                        ? null
                        : (on) => setState(() => _allDay = on),
                  ),
                  // Who is free, where the account has a calendar to ask:
                  // in this row, since the notes need the height.
                  if (!_allDay &&
                      account != null &&
                      (account.provider == MailProvider.outlook ||
                          account.authMethod == AuthMethod.oauth))
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: WhoIsFree(
                          key: ValueKey('who-is-free:$_accountId'),
                          accountId: _accountId,
                          ownEmail: account.emailAddress,
                          attendees: _attendees,
                          start: _start,
                          end: _end,
                          onPick: _sending ? (_) {} : _setStart,
                          enabled: !_sending,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Only once the account has said how a meeting from it can be
            // held online, and named where: the switch says what it does,
            // a Teams link or a Meet link, rather than promising one that
            // cannot be made. With a choice, a menu in the label's place;
            // choosing from it is asking for a link.
            if (_editing?.event.joinUrl != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Online: it keeps its link as it is.',
                    style: muted,
                  ),
                ),
              ),
            // With meeting links kept, for every account once it has said,
            // one whose calendar holds none among them: a link needs
            // nothing of the calendar.
            if ((_onlineKinds.isNotEmpty ||
                    (_onlineAnswered && links.isNotEmpty)) &&
                _editing == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                child: Row(
                  children: [
                    SizedBox(width: 64, child: Text('Online', style: muted)),
                    Switch(
                      key: const ValueKey('meeting-online'),
                      value: _online,
                      onChanged: _sending
                          ? null
                          : (on) {
                              setState(() {
                                _online = on;
                                _onlineChosen = true;
                                if (!on) _dropPrepared();
                              });
                              if (on) unawaited(_prepare());
                            },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: links.isNotEmpty
                          ? _onlineMenu(theme, links)
                          // With no meeting link kept, as it always was.
                          : _onlineKinds.length > 1
                          ? DropdownButton<OnlineMeetingKind>(
                              key: const ValueKey('meeting-online-kind'),
                              value: _onlineKind,
                              isExpanded: true,
                              underline: const SizedBox.shrink(),
                              style: theme.textTheme.bodyMedium,
                              items: [
                                for (final kind in _onlineKinds)
                                  DropdownMenuItem(
                                    value: kind,
                                    child: Text(
                                      kind.label,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: _sending
                                  ? null
                                  : (kind) {
                                      if (kind != null) _chooseKind(kind);
                                    },
                            )
                          : Text(
                              _onlineKinds.single.label,
                              style: theme.textTheme.bodyMedium,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                  ],
                ),
              ),
            HeaderField(
              key: const ValueKey('meeting-location'),
              label: 'Location',
              controller: _location,
              enabled: !_sending,
            ),
            // What More holds, in a line, once anything is chosen there.
            if (_options.summary(_repeatStart, editing: _editing != null)
                case final summary when summary.isNotEmpty)
              InkWell(
                key: const ValueKey('meeting-more-summary'),
                onTap: _sending ? null : _openMore,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Row(
                    children: [
                      Icon(Icons.tune, size: 16, color: muted?.color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // What a new repeat does, before Save (#55).
            if (_repeatNote case final words?)
              _Notice(words, key: const ValueKey('meeting-repeat-note')),
            if (_invalid != null)
              Container(
                width: double.infinity,
                color: theme.colorScheme.errorContainer,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  _invalid!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            if (_notice != null)
              _Notice(
                _notice!,
                action: _offerMeet != null
                    ? FilledButton.tonal(
                        onPressed: _sending ? null : _allowMeet,
                        child: const Text('Sign in with Google'),
                      )
                    : _offerConsent
                        ? FilledButton.tonal(
                            onPressed: _sending ? null : _allowCalendar,
                            child: Text(_askAdministrator
                                ? 'Ask the administrator'
                                : 'Allow the calendar'),
                          )
                        : null,
              ),
            if (_problem != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: ProblemView(problem: _problem!),
              ),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      // As the header rows: the way its first letter reads.
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _notes,
                        builder: (context, value, _) => TextField(
                          key: const ValueKey('meeting-notes'),
                          controller: _notes,
                          enabled: !_sending,
                          maxLines: null,
                          expands: true,
                          textAlignVertical: TextAlignVertical.top,
                          style: theme.textTheme.bodyMedium,
                          textDirection: firstStrongDirection(value.text) ??
                              Directionality.of(context),
                          decoration: const InputDecoration(
                            hintText: 'Notes',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.all(16),
                          ),
                        ),
                      ),
                    ),
                    // Below the notes, as Outlook puts the Teams block,
                    // and no more than half of them. Only where there is
                    // room for its heading and two lines and some notes,
                    // and three times that with the keyboard up: on a phone
                    // the notes are then what is being written, and a
                    // sliver of block would take their room to show nothing.
                    if (_online &&
                        (room != null ||
                            (_onlineKind != null &&
                                _onlineKinds.contains(_onlineKind))) &&
                        box.maxHeight >=
                            // The screen's own context: the Scaffold
                            // takes the keyboard out of what its body sees.
                            (MediaQuery.viewInsetsOf(this.context).bottom > 0
                                    ? 3
                                    : 1.5) *
                                (12 +
                                    MediaQuery.textScalerOf(context)
                                        .scale(40) +
                                    2 *
                                        MediaQuery.textScalerOf(context)
                                            .scale(16)))
                      ConstrainedBox(
                        constraints:
                            BoxConstraints(maxHeight: box.maxHeight / 2),
                        child: room != null
                            ? _InviteText.room(room)
                            : _InviteText(
                                kind: _onlineKind!,
                                prepared: _prepared,
                                making: _preparing != null,
                                failed: _prepareFailed,
                              ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the invitation will say about joining, under the notes: the Teams
/// block, or the Meet link and dial-in, as the calendar made them.
///
/// Shown, not written in. Exchange drops the Teams meeting from an event
/// whose block comes back changed, and Google adds its own block to every
/// invitation, so an edited copy would not be what went out. The link can
/// be copied, to paste somewhere the invitation does not go.
class _InviteText extends StatelessWidget {
  const _InviteText({
    required OnlineMeetingKind this.kind,
    required this.prepared,
    required this.making,
    required this.failed,
  }) : room = null;

  /// A meeting link of Ron's own: the line the notes end with as the
  /// meeting goes, with nothing made for it. Kept out of the notes field
  /// so that nothing Ron wrote is ever taken out with it.
  const _InviteText.room(MeetingLink this.room)
      : kind = null,
        prepared = null,
        making = false,
        failed = false;

  final OnlineMeetingKind? kind;
  final PreparedMeeting? prepared;
  final bool making;
  final bool failed;
  final MeetingLink? room;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final text = room?.line ?? prepared?.inviteText.trim() ?? '';
    final joinUrl = room?.url ?? prepared?.joinUrl;
    final said = kind?.link ?? '';
    final link =
        said.isEmpty ? '' : said[0].toUpperCase() + said.substring(1);
    return Container(
      key: const ValueKey('meeting-invite-text'),
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
      child: making
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Making $said…', style: muted)),
                ],
              ),
            )
          : joinUrl == null || text.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    failed
                        ? '$link is added when you send.'
                        : '$link goes with the invitation.',
                    style: muted,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Goes with the invitation',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('meeting-copy-link'),
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            await Clipboard.setData(
                              ClipboardData(text: joinUrl),
                            );
                            messenger
                              ..hideCurrentSnackBar()
                              ..showSnackBar(const SnackBar(
                                duration: kBottomMessage,
                                content: Text('Link copied'),
                              ));
                          },
                          icon: const Icon(Icons.link, size: 18),
                          label: const Text('Copy link'),
                        ),
                      ],
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        child: SelectableText(
                          text,
                          style: muted,
                          textDirection: firstStrongDirection(text) ??
                              Directionality.of(context),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// A day and, unless the meeting is a whole day, a time, each a button
/// that opens the picker for it.
class _WhenRow extends StatelessWidget {
  const _WhenRow({
    required this.label,
    required this.at,
    required this.allDay,
    required this.enabled,
    this.dateEnabled = true,
    required this.keyPrefix,
    required this.onDate,
    required this.onTime,
  });

  final String label;
  final DateTime at;
  final bool allDay;
  final bool enabled;

  /// False for every meeting of a series, which keep their days.
  final bool dateEnabled;
  final String keyPrefix;
  final VoidCallback onDate;
  final VoidCallback onTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            key: ValueKey('$keyPrefix-date'),
            onPressed: enabled && dateEnabled ? onDate : null,
            child: Text(formatDay(at)),
          ),
          if (!allDay)
            TextButton(
              key: ValueKey('$keyPrefix-time'),
              onPressed: enabled ? onTime : null,
              child: Text(formatClock(
                at,
                use24h: MediaQuery.alwaysUse24HourFormatOf(context),
              )),
            ),
        ],
      ),
    );
  }
}

/// A quiet band of explanation, distinct from the error band above it,
/// with the one thing to do about it beside the words when there is one.
class _Notice extends StatelessWidget {
  const _Notice(this.text, {super.key, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          if (action != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 24),
              child: action,
            ),
        ],
      ),
    );
  }
}

/// The meeting in a line: "Lunch with Dana Thursday 1pm at Café Noir". The
/// line stays in [controller], the screen's, so it outlives the dialog's
/// closing.
class _QuickAddDialog extends StatelessWidget {
  const _QuickAddDialog({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Type it in a line'),
        content: TextField(
          key: const ValueKey('meeting-quick'),
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.of(context).pop(v),
          decoration: const InputDecoration(
            hintText: 'Lunch with Dana Thursday 1pm at Café Noir',
            helperText: 'Read on the phone, in English',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('meeting-quick-go'),
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Fill it in'),
          ),
        ],
      );
}

/// Which of the account's calendars a new meeting goes on, Outlook's
/// Calendar box: shown only where it has more than one that takes
/// meetings, the main one first.
class _CalendarChoice extends ConsumerWidget {
  const _CalendarChoice({
    required this.accountId,
    required this.chosen,
    required this.muted,
    required this.onChanged,
  });

  final String accountId;
  final String chosen;
  final TextStyle? muted;
  final void Function(String calendarId)? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calendars = [
      for (final c in ref.watch(keptAccountCalendarsProvider(accountId)).value ??
          const <CalendarInfo>[])
        if (c.canEdit) c,
    ];
    if (calendars.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final account = (ref.watch(accountsProvider).value ?? const <Account>[])
        .where((a) => a.id == accountId)
        .firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          SizedBox(width: 64, child: Text('Calendar', style: muted)),
          Expanded(
            child: DropdownButton<String>(
              key: const ValueKey('meeting-calendar'),
              value: calendars.any((c) => c.id == chosen)
                  ? chosen
                  : calendars.first.id,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              style: theme.textTheme.bodyMedium,
              items: [
                for (final c in calendars)
                  DropdownMenuItem(
                    key: ValueKey('meeting-calendar:${c.id}'),
                    value: c.id,
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 5,
                          backgroundColor: Color(
                            c.colour ?? account?.colorValue ?? 0xFF888888,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(c.name, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
              ],
              onChanged: onChanged == null
                  ? null
                  : (id) {
                      if (id != null) onChanged!(id);
                    },
            ),
          ),
        ],
      ),
    );
  }
}

/// [then] now if the app is in front, or once it is back: a screen pushed
/// while the app is out of sight is not built until then, so it has no
/// guard yet (see [GuardsPutAway]), and a put-away closing what is open
/// meanwhile would take it away unasked. ComposeScreen waits the same way.
void _whenInFront(void Function() then) {
  // Where nothing has said, as under test, it is taken to be in front.
  if (isInFront() || WidgetsBinding.instance.lifecycleState == null) {
    then();
    return;
  }
  late final AppLifecycleListener back;
  back = AppLifecycleListener(onResume: () {
    back.dispose();
    then();
  });
}
