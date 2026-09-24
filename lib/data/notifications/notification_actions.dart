import '../../domain/account.dart';
import '../../domain/draft.dart';
import '../../domain/mail_message.dart';
import '../../domain/signature.dart';
import '../compose/reply_draft.dart';
import '../mail_engine.dart';

/// What the buttons on a new-mail notification do.
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
  });

  final MailEngine engine;

  /// Signatures by account id, read from where the app keeps them.
  final Map<String, Signature> signatures;

  /// Every account, so reply-all can leave the person's own addresses off.
  final List<Account> accounts;

  /// The ids Android sends back. Stable strings: they are baked into
  /// notifications that may still be on screen after an update.
  static const replyId = 'mailtree.reply';
  static const replyAllId = 'mailtree.reply-all';
  static const deleteId = 'mailtree.delete';

  static bool isKnown(String? actionId) =>
      actionId == replyId || actionId == replyAllId || actionId == deleteId;

  /// Carry out [actionId] on [messageId], with whatever was typed into the
  /// shade. Never throws: this runs where there is nobody to catch it.
  Future<ActionOutcome> perform(
    String actionId,
    String messageId,
    String? typed,
  ) async =>
      switch (actionId) {
        deleteId => _delete(messageId),
        replyId => _reply(messageId, typed, all: false),
        replyAllId => _reply(messageId, typed, all: true),
        _ => Future.value(ActionOutcome.unknown),
      };

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
  }) async {
    final text = (typed ?? '').trim();
    if (text.isEmpty) return ActionOutcome.nothingTyped;

    final MailMessage? original;
    try {
      original = await engine.cachedMessage(messageId);
    } catch (_) {
      return ActionOutcome.notKept;
    }
    // Deleted from another device between the notification and the reply.
    if (original == null) return ActionOutcome.gone;

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

    try {
      await engine.sendDraft(draft);
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
  failed,

  /// No connection. Nothing is wrong with the press: it waits for one.
  offline,

  /// A reply that could be neither sent nor saved. What was typed is kept
  /// in the queue to try again, and shown if it is finally given up on.
  notKept,
  unknown;

  /// Whether the press should go back in the queue rather than be dropped.
  bool get worthRetrying => this == failed || this == offline || this == notKept;

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
        failed => 'That did not work. The message is where it was.',
        offline => null,
        notKept => 'Your reply could not be sent, or kept in Drafts.',
      };
}
