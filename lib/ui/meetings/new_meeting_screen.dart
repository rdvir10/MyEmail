import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../data/auth/oauth_token.dart';
import '../../data/mail_engine.dart';
import '../../domain/account.dart';
import '../../domain/error_report.dart';
import '../../domain/mail_message.dart';
import '../../domain/meeting.dart';
import '../../domain/text_direction.dart';
import '../../state/calendar_providers.dart';
import '../../state/compose_providers.dart'
    show addressesLookValid, formatAddresses, parseAddresses;
import '../../state/meeting_providers.dart';
import '../../state/providers.dart';
import '../accounts/google_sign_in_screen.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import '../common/bottom_message.dart';
import '../common/problem_view.dart';
import '../compose/header_fields.dart';
import '../messages/date_format.dart' show formatClock, formatDay;

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
}) async {
  final resolved = accountId ??
      ref.read(accountOnScreenProvider) ??
      ref.read(accountsProvider).value?.firstOrNull?.id;
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
  MailBody body,
) {
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
class NewMeetingScreen extends ConsumerStatefulWidget {
  const NewMeetingScreen({
    super.key,
    required this.accountId,
    this.title = '',
    this.notes = '',
    this.attendees = const [],
    this.start,
  });

  final String accountId;
  final String title;
  final String notes;

  /// Who is asked, to begin with: everyone on the message it was made from.
  final List<MailAddress> attendees;

  /// When it starts. The next whole hour when null; the end is an hour on.
  final DateTime? start;

  @override
  ConsumerState<NewMeetingScreen> createState() => _NewMeetingScreenState();
}

class _NewMeetingScreenState extends ConsumerState<NewMeetingScreen> {
  /// Which account the meeting is from. Starts as the one it was opened
  /// for, and can be changed from the header: Ron asked to choose the
  /// account before anything else about an invitation, and the calendar
  /// it lands on follows from it.
  late String _accountId = widget.accountId;

  late final _title = TextEditingController(text: widget.title);
  late final _attendees =
      TextEditingController(text: _attendeesToBegin);

  /// The attendees as the field starts, with a separator after them so the
  /// next address can be typed straight on.
  late final String _attendeesToBegin = widget.attendees.isEmpty
      ? ''
      : '${formatAddresses(widget.attendees)}, ';
  final _location = TextEditingController();
  late final _notes = TextEditingController(text: widget.notes);

  late DateTime _start = widget.start ?? _nextHour(DateTime.now());
  late DateTime _end = _start.add(const Duration(hours: 1));
  bool _allDay = false;
  bool _sending = false;

  /// The kinds a meeting from this account can be held online as, empty
  /// while it has not said, or where there is none: the switch is on the
  /// screen only with an answer. Asked when the screen opens and again
  /// when From changes.
  List<OnlineMeetingKind> _onlineKinds = const [];

  /// Which of them, where there is a choice: a Microsoft account with
  /// Teams and, through the Gmail account, Google Meet. The first unless
  /// one was chosen, and the choice kept through a change of From where
  /// the account now can hold it too.
  OnlineMeetingKind? _onlineKind;

  /// Whether a link was asked for. Honoured only where the account's
  /// calendar holds meetings online: the switch keeps its setting through
  /// a change of From, and a meeting from an account with nowhere to hold
  /// one goes without.
  bool _online = false;

  /// Which ask is the current one. From can change while an answer is on
  /// its way, and the answer for the account before must not label the
  /// switch for the account now.
  int _onlineAsk = 0;

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
  PreparedMeeting? _prepared;

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

  /// Set while the calendar is sending it. Leaving then must not undo what
  /// is being sent either: Send puts it back on the ledger if it did not
  /// go, and the next start deletes it then.
  bool _sendingMeeting = false;

  /// The app's container, taken while the screen is there: a meeting made
  /// ahead is undone as the screen goes, when its own ref no longer reads.
  late final ProviderContainer _container;

  static DateTime _nextHour(DateTime now) =>
      DateTime(now.year, now.month, now.day, now.hour + 1);

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _askOnline();
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
      _onlineKind =
          kinds.contains(_onlineKind) ? _onlineKind : kinds.firstOrNull;
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
      if (!mounted || ask != _prepareAsk) {
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
      if (!mounted || ask != _prepareAsk) return;
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
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  Account? get _account => ref
      .read(accountsProvider)
      .value
      ?.where((a) => a.id == _accountId)
      .firstOrNull;

  /// Whether leaving loses nothing: the screen is as it opened, and what it
  /// opened with can be had again.
  bool get _untouched =>
      _title.text == widget.title &&
      _attendees.text == _attendeesToBegin &&
      _location.text.isEmpty &&
      _notes.text == widget.notes;

  /// Move the start, and the end with it, so the meeting keeps its length:
  /// a meeting moved to Tuesday is still an hour long.
  void _setStart(DateTime next) {
    final length = _end.difference(_start);
    setState(() {
      _start = next;
      _end = next.add(length.isNegative ? const Duration(hours: 1) : length);
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
  /// calendar knows what clock the times are on.
  Future<MeetingDraft> _draft(List<MailAddress> attendees) async {
    String? zone;
    try {
      zone = await ref.read(deviceCalendarProvider).timeZoneId();
    } catch (_) {
      // Then the times go as UTC, which every calendar reads.
    }
    DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);
    return MeetingDraft(
      accountId: _accountId,
      title: _title.text.trim(),
      attendees: attendees,
      start: _allDay ? day(_start) : _start,
      end: _allDay ? day(_end) : _end,
      allDay: _allDay,
      location: _location.text.trim(),
      notes: _notes.text.trim(),
      timeZone: zone,
      online: _online ? _onlineKind : null,
      prepared: _online ? _prepared : null,
    );
  }

  Future<void> _send() async {
    final attendees = parseAddresses(_attendees.text);
    if (!addressesLookValid(attendees)) {
      setState(() => _invalid = 'One of the addresses does not look right.');
      return;
    }
    // A link still being made is waited for, so that the invitation goes
    // with the one whose text is on the screen.
    final making = _preparing;
    if (making != null) {
      setState(() => _sending = true);
      await making;
      if (!mounted) return;
    }
    final meeting = await _draft(attendees);
    if (!mounted) return;
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
      if (!mounted) return;
      final link = held == null
          ? ''
          : remade
              ? ', with a new ${held.link.replaceFirst(RegExp('^an? '), '')}: '
                  'the one shown could not be used'
              : ', with ${held.link}';
      _leave(meeting.hasAttendees
          ? 'Invitation sent$link'
          : 'Added to your calendar$link');
    } on CalendarUnavailable catch (e) {
      await _handToDevice(meeting, e);
    } catch (e) {
      if (!mounted) return;
      // Every failure the calendars throw on purpose already carries a
      // sentence written for a person; the rest is kept whole for a report.
      if (!_askForConsent(e, toPrepare: false)) {
        setState(() => _problem = ProblemReport(
              doing: 'Creating a meeting',
              error: e,
              account: _account,
            ));
      }
    } finally {
      _sendingMeeting = false;
      // Not sent: still made, and still the ledger's to clear up.
      if (!_sent && prepared != null) {
        unawaited(ledger.record(prepared).catchError((_) {}));
      }
      if (mounted) setState(() => _sending = false);
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
          start: meeting.start,
          // Exclusive, which is how the calendar provider counts the end of
          // a whole day.
          end: meeting.allDay ? dayAfter(meeting.end) : meeting.end,
          allDay: meeting.allDay,
          attendees: [for (final a in meeting.attendees) a.email],
        );
    if (!mounted) return;
    if (ok) {
      _leave("Handed to your calendar app: this account's calendar cannot be "
          'reached from here.');
    } else {
      setState(() => _notice =
          '${why.message} There is no calendar app on this phone to hand it '
          'to either.');
    }
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
    if (!mounted) return;
    if (_consentToPrepare) {
      setState(() => _sending = false);
      await _prepare();
    } else {
      await _send();
    }
  }

  void _leave(String message) {
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(message)));
  }

  /// Backing out of a half-written meeting. There is no draft to keep it
  /// in, so the question is only whether to lose it; an untouched screen
  /// asks nothing.
  Future<bool> _mayLeave() async {
    if (_untouched) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this meeting?'),
        content: const Text('Nothing has been sent.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep writing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final account = accounts.where((a) => a.id == _accountId).firstOrNull;
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _mayLeave() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('New meeting'),
          centerTitle: false,
          actions: [
            IconButton(
              tooltip: 'Send',
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              onPressed: _sending ? null : _send,
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            // As the compose screen has it: with one account there is
            // nothing to choose, and a menu with one entry is a puzzle.
            if (accounts.length > 1)
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
                                  // Unknown again until this account has
                                  // answered for itself; the kind chosen
                                  // waits to see whether it can too.
                                  _onlineKinds = const [];
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
                    'From ${account.emailAddress}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            HeaderField(
              key: const ValueKey('meeting-title'),
              label: 'Title',
              controller: _title,
              enabled: !_sending,
              // A meeting from a message has its title; the cursor is
              // better off with the people then.
              autofocus: widget.title.isEmpty,
            ),
            RecipientField(
              key: const ValueKey('meeting-attendees'),
              label: 'Attendees',
              controller: _attendees,
              enabled: !_sending,
              autofocus: widget.title.isNotEmpty,
            ),
            _WhenRow(
              label: 'Start',
              at: _start,
              allDay: _allDay,
              enabled: !_sending,
              keyPrefix: 'start',
              onDate: () => _pickDate(_start, _setStart),
              onTime: () => _pickTime(_start, _setStart),
            ),
            _WhenRow(
              label: 'End',
              at: _end,
              allDay: _allDay,
              enabled: !_sending,
              keyPrefix: 'end',
              onDate: () => _pickDate(_end, (at) => setState(() => _end = at)),
              onTime: () => _pickTime(_end, (at) => setState(() => _end = at)),
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
                ],
              ),
            ),
            // Only once the account has said how a meeting from it can be
            // held online, and named where: the switch says what it does,
            // a Teams link or a Meet link, rather than promising one that
            // cannot be made. With a choice, a menu in the label's place;
            // choosing from it is asking for a link.
            if (_onlineKinds.isNotEmpty)
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
                                if (!on) _dropPrepared();
                              });
                              if (on) unawaited(_prepare());
                            },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _onlineKinds.length > 1
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
                                      if (kind == null) return;
                                      final same = _online &&
                                          kind == _onlineKind &&
                                          (_prepared != null ||
                                              _preparing != null);
                                      setState(() {
                                        _onlineKind = kind;
                                        _online = true;
                                      });
                                      if (!same) unawaited(_prepare());
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
                        _onlineKind != null &&
                        _onlineKinds.contains(_onlineKind) &&
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
                        child: _InviteText(
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
    required this.kind,
    required this.prepared,
    required this.making,
    required this.failed,
  });

  final OnlineMeetingKind kind;
  final PreparedMeeting? prepared;
  final bool making;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final text = prepared?.inviteText.trim() ?? '';
    final link = kind.link[0].toUpperCase() + kind.link.substring(1);
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
                  Expanded(child: Text('Making ${kind.link}…', style: muted)),
                ],
              ),
            )
          : prepared == null || text.isEmpty
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
                              ClipboardData(text: prepared!.joinUrl),
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
    required this.keyPrefix,
    required this.onDate,
    required this.onTime,
  });

  final String label;
  final DateTime at;
  final bool allDay;
  final bool enabled;
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
            onPressed: enabled ? onDate : null,
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
  const _Notice(this.text, {this.action});

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
