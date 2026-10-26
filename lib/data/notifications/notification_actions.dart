import '../../domain/account.dart';
import '../../domain/calendar_invite.dart';
import '../../domain/draft.dart';
import '../../domain/mail_message.dart';
import '../../domain/meeting_alerts.dart' show MeetingRef;
import '../../domain/signature.dart';
import '../calendar/calendar_upkeep.dart' show findKeptMeeting;
import '../calendar/running_late.dart';
import '../compose/reply_draft.dart';
import '../imap/imap_mapping.dart' show splitFolderId, splitMessageId;
import '../mail_engine.dart';

/// What the buttons on a new-mail notification do, and those on a
/// meeting's reminder.
///
/// Free of the app on purpose. Android hands a notification action to
/// whichever isolate is to hand: the running app if there is one, or a second
/// one it starts for the purpose, which shares nothing with the app — no
/// providers, no widget tree, not even the same database connection. So this
/// takes what it needs rather than reaching for it, and the same code answers
/// either way.
///
/// A reply from the shade is a real reply: the same quoted original, the same
/// attribution line and the same signature rule as one written in the app,
/// because both go through [draftFor].
class NotificationActions {
  const NotificationActions({
    required this.engine,
    this.signatures = const {},
    this.accounts = const [],
    this.clock = DateTime.now,
    this.deleteAnswered = false,
  });

  final MailEngine engine;

  /// Signatures by account id, read from where the app keeps them.
  final Map<String, Signature> signatures;

  /// Every account, so reply-all can leave the person's own addresses off.
  final List<Account> accounts;

  final DateTime Function() clock;

  /// An invitation answered goes to Deleted Items, as Outlook sends it:
  /// Settings, Calendar's choice, read where the press is carried out.
  final bool deleteAnswered;

  /// The ids Android sends back. Stable strings: they are baked into
  /// notifications that may still be on screen after an update.
  static const replyId = 'mailtree.reply';
  static const replyAllId = 'mailtree.reply-all';
  static const deleteId = 'mailtree.delete';

  /// An invitation's.
  static const acceptId = 'mailtree.accept';
  static const declineId = 'mailtree.decline';

  /// A meeting reminder's. Join brings the app forward, which opens the
  /// meeting's link; Snooze needs no mail, and is done where it is
  /// pressed (see `snoozeMeetingReminder`). Running late is written down
  /// and carried out with the rest.
  static const joinId = 'mailtree.join';
  static const lateId = 'mailtree.late';
  static const snoozeId = 'mailtree.snooze';

  /// Whether [actionId] is a press to write down and carry out here.
  static bool isKnown(String? actionId) =>
      actionId == replyId ||
      actionId == replyAllId ||
      actionId == deleteId ||
      actionId == acceptId ||
      actionId == declineId ||
      actionId == lateId;

  /// Carry out [actionId] on [messageId], with whatever was typed into the
  /// shade. Never throws: this runs where there is nobody to catch it.
  ///
  /// For Running late, [messageId] is the reminder's payload, the meeting
  /// (`MeetingRef.payload`), and what was typed the minutes.
  ///
  /// For a reply, [beforeSend] is called just before the send, so the queue
  /// can write down that a send was begun, and [sendStarted] says one was
  /// begun on an earlier try and never heard back from: see
  /// [ActionOutcome.maybeSent]. Whatever [beforeSend] throws is not caught
  /// here: it means the send must not happen, and nothing else either.
  Future<ActionOutcome> perform(
    String actionId,
    String messageId,
    String? typed, {
    bool sendStarted = false,
    Future<void> Function()? beforeSend,
  }) async =>
      switch (actionId) {
        deleteId => _delete(messageId),
        replyId => _reply(messageId, typed,
            all: false, sendStarted: sendStarted, beforeSend: beforeSend),
        replyAllId => _reply(messageId, typed,
            all: true, sendStarted: sendStarted, beforeSend: beforeSend),
        acceptId => _answer(messageId, InviteResponse.accepted),
        declineId => _answer(messageId, InviteResponse.declined),
        lateId => _late(messageId, typed,
            sendStarted: sendStarted, beforeSend: beforeSend),
        _ => Future.value(ActionOutcome.unknown),
      };

  /// Answer the invitation in [messageId] as its card would: on the
  /// calendar where the account has one, and by mail to the organiser
  /// otherwise, from the account it came to.
  Future<ActionOutcome> _answer(
    String messageId,
    InviteResponse response,
  ) async {
    final CalendarInvite? invite;
    try {
      final body = await engine.loadMessageBody(messageId);
      invite = CalendarInvite.parse(body.calendar ?? '');
    } on ConnectionFailed {
      return ActionOutcome.offline;
    } catch (_) {
      return ActionOutcome.gone;
    }
    if (invite == null || !invite.isRequest) return ActionOutcome.notAnswerable;
    try {
      await engine.respondToInvite(messageId, invite, response);
    } on ConnectionFailed {
      return ActionOutcome.offline;
    } catch (_) {
      return ActionOutcome.notAnswered;
    }
    // Answered is dealt with: to Deleted Items, as Outlook sends it, or
    // read, as a reply leaves it. Best-effort, the answer having gone.
    try {
      if (deleteAnswered) {
        await engine.deleteMessages([messageId]);
      } else {
        await engine.setRead(messageId, true);
      }
    } catch (_) {
      // Never mind.
    }
    return ActionOutcome.answered;
  }

  /// Tell the people on the meeting in [payload] that it starts late for
  /// you, by the minutes picked or typed into its reminder: the message the
  /// meeting's sheet sends.
  Future<ActionOutcome> _late(
    String payload,
    String? typed, {
    bool sendStarted = false,
    Future<void> Function()? beforeSend,
  }) async {
    final meeting = MeetingRef.fromPayload(payload);
    if (meeting == null) return ActionOutcome.unknown;
    // Begun on an earlier try and never heard back from: not twice.
    if (sendStarted) return ActionOutcome.toldLate;
    if (!clock().isBefore(meeting.end)) return ActionOutcome.meetingOver;
    final event = await findKeptMeeting(engine, meeting);
    if (event == null) return ActionOutcome.lateNotSent;
    final own = accounts
            .where((a) => a.id == event.accountId)
            .map((a) => a.emailAddress)
            .firstOrNull ??
        '';
    final draft = runningLateDraft(
      event,
      ownEmail: own,
      minutes: lateMinutesIn(typed),
    );
    if (draft == null) return ActionOutcome.nobodyToTell;
    await beforeSend?.call();
    try {
      await engine.sendDraft(draft);
      return ActionOutcome.toldLate;
    } on SendMayHaveGone {
      return ActionOutcome.toldLate;
    } on ConnectionFailed {
      return ActionOutcome.offline;
    } catch (_) {
      return ActionOutcome.lateNotSent;
    }
  }

  Future<ActionOutcome> _delete(String messageId) async {
    try {
      await engine.deleteMessages([messageId]);
      return ActionOutcome.deleted;
    } on ConnectionFailed {
      return ActionOutcome.offline;
    } catch (_) {
      return ActionOutcome.failed;
    }
  }

  /// Send what was typed as a reply, and keep it as a draft if it cannot go.
  ///
  /// Losing what someone has written is the one outcome worth going to any
  /// length to avoid: they typed it into a notification and moved on, and
  /// there is no window left holding it. A send that fails therefore falls
  /// back to the Drafts folder rather than reporting and dropping it.
  Future<ActionOutcome> _reply(
    String messageId,
    String? typed, {
    required bool all,
    bool sendStarted = false,
    Future<void> Function()? beforeSend,
  }) async {
    final text = (typed ?? '').trim();
    if (text.isEmpty) return ActionOutcome.nothingTyped;

    // Begun on an earlier try by a drain that never came back: it may have
    // gone. Not again; the person is told, with what they wrote.
    if (sendStarted) return ActionOutcome.maybeSent;

    final MailMessage? original;
    try {
      original = await engine.cachedMessage(messageId);
    } catch (_) {
      return ActionOutcome.notKept;
    }
    // Moved or deleted elsewhere between the notification and the reply.
    // What was typed is kept as a draft of its own rather than dropped.
    if (original == null) return _keepWithoutOriginal(messageId, text);

    MailBody? body;
    try {
      body = await engine.loadMessageBody(messageId);
    } catch (_) {
      // Offline, or the message is gone from the server: quote the preview,
      // which is what the notification itself was showing.
      body = MailBody(text: original.preview);
    }

    final draft = draftFor(
      kind: all ? ComposeKind.replyAll : ComposeKind.reply,
      accountId: original.accountId,
      original: original,
      body: body,
      signature: signatures[original.accountId],
      selfEmail: accounts
              .where((a) => a.id == original!.accountId)
              .map((a) => a.emailAddress)
              .firstOrNull ??
          '',
      otherAccountEmails: [for (final a in accounts) a.emailAddress],
      typedText: text,
    );

    await beforeSend?.call();
    try {
      await engine.sendDraft(draft);
    } on SendMayHaveGone {
      // Handed over and never answered. Sending again could make two, and
      // saving a draft could lead to a second by hand; the report says to
      // check Sent, with the words.
      return ActionOutcome.maybeSent;
    } catch (sending) {
      try {
        // An account with no Drafts folder throws, so reaching the return
        // means it is there, even where saveDraft could not say which
        // message it became.
        await engine.saveDraft(draft);
        return ActionOutcome.savedAsDraft;
      } catch (_) {
        // Neither went. What was typed is still in the queue; see below.
      }
      return sending is ConnectionFailed
          ? ActionOutcome.offline
          : ActionOutcome.notKept;
    }

    // Answered mail is read mail. Best-effort: the reply has gone, and
    // failing to mark it is not worth reporting over the top of that.
    try {
      await engine.setRead(messageId, true);
    } catch (_) {
      // Never mind.
    }
    return ActionOutcome.sent;
  }

  /// A reply whose message is no longer on the device: the words go to
  /// Drafts as a message of their own, since there is nothing left to
  /// answer.
  Future<ActionOutcome> _keepWithoutOriginal(
    String messageId,
    String text,
  ) async {
    final String accountId;
    try {
      accountId = splitFolderId(splitMessageId(messageId).$1).$1;
    } catch (_) {
      return ActionOutcome.gone;
    }
    try {
      await engine.saveDraft(Draft(
        accountId: accountId,
        kind: ComposeKind.newMessage,
        htmlBody: asParagraphs(text),
      ));
      return ActionOutcome.goneKeptAsDraft;
    } on ConnectionFailed {
      return ActionOutcome.offline;
    } catch (_) {
      return ActionOutcome.gone;
    }
  }
}

/// What happened, in the terms the shade has to report back.
enum ActionOutcome {
  sent,
  deleted,
  savedAsDraft,

  /// The input came back empty, so there is nothing to send and nothing to
  /// say about it.
  nothingTyped,

  /// The message is no longer on this device: answered or deleted elsewhere.
  gone,

  /// A reply to a message no longer on this device, kept in Drafts.
  goneKeptAsDraft,

  /// A reply that was handed over and never answered, or whose drain died
  /// mid-send. It may have gone, so it is not sent again.
  maybeSent,
  failed,

  /// No connection. Nothing is wrong with the press: it waits for one.
  offline,

  /// An invitation answered, from its notification.
  answered,

  /// Not an invitation that can be answered: a cancellation, say, or one
  /// whose meeting could not be read.
  notAnswerable,

  /// An invitation whose answer did not go.
  notAnswered,

  /// The people on a meeting told it starts late for you.
  toldLate,
  nobodyToTell,
  lateNotSent,

  /// Running late pressed, and carried out, after the meeting was over.
  meetingOver,

  /// A reply that could be neither sent nor saved. What was typed is kept
  /// in the queue to try again, and shown if it is finally given up on.
  notKept,
  unknown;

  /// Whether the press should go back in the queue rather than be dropped.
  bool get worthRetrying => this == failed || this == offline || this == notKept;

  /// Whether the report has to carry what was typed, because it is kept
  /// nowhere else: the reply neither went for certain nor was saved.
  bool get keepsWords => this == notKept || this == gone || this == maybeSent;

  /// What to tell the person, or null where silence is the right answer.
  ///
  /// Success is silent for a reply and a delete alike: the notification goes
  /// away, which is the confirmation. Only the cases that need doing
  /// something about say anything.
  String? get message => switch (this) {
        sent => null,
        deleted => null,
        nothingTyped => null,
        unknown => null,
        savedAsDraft => 'Your reply could not be sent. It is in Drafts.',
        gone => 'That message is no longer here.',
        goneKeptAsDraft =>
          'That message is no longer here, so your reply is in Drafts.',
        maybeSent => 'Your reply may or may not have gone. Check Sent before '
            'sending it again.',
        failed => 'That did not work. The message is where it was.',
        offline => null,
        notKept => 'Your reply could not be sent, or kept in Drafts.',
        answered => null,
        notAnswerable =>
          'That invitation cannot be answered from here. Open it in MyEmail.',
        notAnswered => 'Your answer did not go. Open the invitation in '
            'MyEmail to answer it.',
        toldLate => null,
        nobodyToTell => 'There is nobody on that meeting to tell.',
        lateNotSent => 'Your running-late message could not be sent.',
        meetingOver => 'That meeting is over, so nobody was told.',
      };
}
