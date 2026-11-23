import 'dart:convert';

import 'package:cryptography/dart.dart' show DartSha256;
import 'package:flutter/foundation.dart' show immutable;

import '../../domain/error_report.dart';
import '../../domain/synced_contact.dart' show ContactField, ContactSide;
import 'contact_sync_planner.dart' show ContactReviewKind, ContactReviewReason;

export '../../domain/synced_contact.dart' show ContactField, ContactSide;
export 'contact_sync_planner.dart' show ContactReviewKind, ContactReviewReason;

// Contact sync as the screen and the shell see it: what the engine's runner
// (ContactSync) offers through MailEngine.contactSync. Plain state objects,
// read from what this device keeps, and calls that queue an answer or start
// a run. Nothing here holds a name, address or number but the titles shown
// in the preview's lists, the brakes' questions, Needs a look and Recently
// deleted, which are the only places the plan shows names.

/// Contact sync between one Gmail account and one Microsoft account, kept
/// by this device. One pair at a time: [choose] picks it.
///
/// Whether sync is switched on for this device is not the service's: it is
/// a UiStateKeys entry the screen and the shell read. With it off, nothing
/// starts a run ([startIfDue] is not called) and the screen calls [stop].
abstract interface class ContactSyncService {
  /// Where contact sync stands, from what this device keeps. Cheap, and
  /// never a request to a server, whatever the switch: it may be read at
  /// every [changed] for the app's life.
  Future<ContactSyncStatus> status();

  /// Fires whenever [status] may have changed: a run starting, moving on
  /// (at most four times a second) or ending, which is when a notice
  /// appears; a pair chosen; an answer queued; [noticeSeen].
  Stream<void> get changed;

  /// Whether [accountId] allows contact sync, asked now (a token for the
  /// contacts permission). Never throws: what went wrong is a state.
  /// [ContactSyncAccessState.notPossible] for an account not there, a
  /// shared mailbox, and a Gmail account only when it signs in with an
  /// app password.
  Future<ContactSyncAccess> access(String accountId);

  /// Sync [googleAccountId] (a Gmail account signed in with Google) with
  /// [graphAccountId] (a Microsoft account's own mailbox).
  ///
  /// The pair's own two accounts again change nothing and announce
  /// nothing, even while a run goes: the screen may choose before every
  /// action. Two others: the pair these two had before, detached when
  /// another was chosen or an account removed, is taken up again intact
  /// (its first sync, rows, Needs a look and Recently deleted) if that was
  /// within `ContactSyncStore.detachedFor` (30 days); another pair naming
  /// either account is detached, keeping all it holds, since an account
  /// syncs with one other only. Throws [ContactSyncRefused] for accounts
  /// that cannot sync, or for a change while a run is going.
  Future<void> choose({
    required String googleAccountId,
    required String graphAccountId,
  });

  /// What the first sync would do, for the pair chosen last: both address
  /// books read in full, nothing written or kept. Throws a
  /// [ReadableError] (typed as the clients' failures are: [NeedsSignIn],
  /// [Retryable]), or [ContactSyncRefused] with no pair chosen.
  Future<ContactSyncPreview> preview();

  /// Both address books of the pair chosen last, read in full, as the two
  /// backup files: exactly two, Google's first (a vCard Google Contacts
  /// imports), then Microsoft's (a CSV Outlook on the web imports), one
  /// per [ContactSyncBackupFile.side]. With [only], that side's file
  /// alone, the other side not read: the merge of Hadco's copies saves
  /// Hadco's, with no Gmail read and none of Google's quota spent. Throws
  /// as [preview].
  Future<List<ContactSyncBackupFile>> backup({ContactSide? only});

  /// Start: the first sync, from Start only. Sets
  /// [ContactSyncStatus.firstStartedAt] before anything that can stop the
  /// run (access, the other device, the network), so a stop shows as a
  /// stop of a started first sync. A second Start while the first is going
  /// joins it. Completes when the run ends, and never throws: how it went
  /// is in [status]. The runner does not ask for the preview or the
  /// backup first: the screen keeps Start for after both.
  Future<void> start();

  /// Sync now: a run at once, or the one already going. Completes when it
  /// ends, and never throws. Never starts a first sync that Start has not:
  /// with none started it does nothing.
  Future<void> syncNow();

  /// The shell's start when MyEmail is opened or comes back: a run, only
  /// when one is due (the first sync started; the last completed run over
  /// [ContactSyncStatus.dueAfter] ago, or the first sync unfinished; no
  /// stop but a put-away in the last [ContactSyncStatus.failedPause],
  /// unless the account has signed in again since; Google's daily quota
  /// not spent; none going). True when one started. Never throws. Whether
  /// sync is switched on for this device is the shell's to check: this
  /// does not know the switch.
  Future<bool> startIfDue();

  /// MyEmail was put away, or the switch turned off: the run going finishes
  /// the write in hand and stops. Not a failure, and nothing is lost: the
  /// next run reads the same changes again. Completes once it has stopped.
  Future<void> stop();

  /// Ron's answer to a brake's question, queued for a run, which starts at
  /// once (or straight after the one going). It acts only on the contacts
  /// that question lists: a brake raised since holds its own under a
  /// question of its own. [ContactSyncChoice.keepWaiting] queues nothing,
  /// and the question stays.
  ///
  /// With [items] (their [ContactSyncQuestionItem.key]s), only those
  /// contacts are answered, each showing its answer
  /// ([ContactSyncQuestionItem.answer]) until a run carries it out; the
  /// rest of the question stays open. The screen names the items it
  /// shows, for one contact and for its "for all" buttons alike, so an
  /// item raised after it last read the status is never answered unseen.
  /// Named with others, an item that already has an answer of its own
  /// keeps it (a "for all" tapped before the screen showed that answer);
  /// named alone, it takes the new one. Should a key name no item of the
  /// question any more (its contact gone, or its answer carried out),
  /// nothing is answered and [ContactSyncRefused] says so ("That question
  /// has changed since it was shown. Look at it again."), for the screen
  /// to read the status again. Without [items] (for a caller that cannot
  /// name them), every item not answered on its own, those raised since
  /// included. The choices are the question's own
  /// ([ContactSyncQuestion.choices]), for one contact as for all.
  Future<void> answerQuestion(
    ContactSyncQuestionKind kind,
    ContactSyncChoice choice, {
    Set<String>? items,
  });

  /// Ron's answer to one Needs a look item ([ContactSyncLook.id]), one of
  /// its [ContactSyncLook.choices], queued for a run that starts at once.
  /// [candidateId] says which candidate Same person means where there are
  /// several. Leave as they are, and keeping a clash's newer value, need no
  /// run: the item just goes. Delete it here too and Keep it only here act
  /// on the contact that is left: the one on the other side from
  /// [ContactSyncLook.side].
  Future<void> answerLook(
    int lookId,
    ContactSyncChoice choice, {
    String? candidateId,
  });

  /// The same answer (Use Gmail's, Use Hadco's, Leave as they are) for the
  /// new pairs whose details differ that the screen showed ([looks]: each
  /// one's [ContactSyncLook.id] to the [ContactSyncLook.version] shown),
  /// all saved in one step and queued for a run that starts at once
  /// (Leave as they are needs none: the items just go). Only those still
  /// listed, with no answer yet, and as they were shown, are answered: an
  /// answer given to one item stands, and an item listed since the screen
  /// was drawn, or planned again since with other details, is never
  /// answered by it. Throws [ContactSyncRefused] when none could be
  /// answered, for the screen to read the status again.
  Future<void> answerAllDiffering(
    ContactSyncChoice choice,
    Map<int, String> looks,
  );

  /// Restore a contact from Recently deleted ([ContactSyncDeleted.id]),
  /// queued for a run that starts at once.
  Future<void> restore(int deletedId);

  /// Sync here although another device has been syncing: a run starts at
  /// once and takes the claim over from its start, and goes on taking it
  /// until a run of this device's completes. Like [syncNow], never starts
  /// a first sync that Start has not.
  Future<void> syncHere();

  /// The shell showed [ContactSyncStatus.notice]: it is not shown again.
  /// Fires [changed].
  Future<void> noticeSeen(DateTime at);

  /// Merge the Microsoft side's copies of one person
  /// ([ContactSyncStatus.copies]), queued for a run that starts at once:
  /// for each person whose synced Microsoft copy is paired and has held
  /// copies beside it, the synced copy stays, takes any detail only
  /// another copy has, and the other copies are deleted (Graph's ordinary
  /// delete: Outlook keeps them for a while, in Deleted Items or among the
  /// mailbox's recoverable items; which of the two is not yet checked).
  /// People whose copies differ are listed ([ContactSyncCopies.differing])
  /// and touched only on Ron's answer. Gmail's copies are not touched.
  /// The screen calls this only once Hadco's backup file is saved. Before
  /// the first sync is done, or with nothing to merge, it does nothing.
  Future<void> mergeCopies();

  /// Ron's answer for a person whose copies differ
  /// ([ContactSyncCopiesPerson.key]), given on the differences shown
  /// ([version], the person's [ContactSyncCopiesPerson.version]) and
  /// queued for a run that starts at once: [keep] a copy's key
  /// ([ContactSyncCopy.key]) to keep that copy's details (the synced
  /// copy's, or another's, whose values win where it has one; the details
  /// only some copy has are still added), or null to leave them as they
  /// are: the person goes off the list, and later merges pass it over
  /// until its copies change. Throws [ContactSyncRefused] when the person
  /// or the copy is no longer listed, or the person is listed with other
  /// differences than [version], for the screen to read the status again:
  /// an answer never lands on differences Ron did not see. Should the
  /// copies change before a run carries it out, the person is listed
  /// again as it is, the answer dropped.
  Future<void> answerCopies(String person, String? keep, String version);

  /// Keep the synced copy's details for the people the screen showed
  /// ([people]: each one's [ContactSyncCopiesPerson.key] to the
  /// [ContactSyncCopiesPerson.version] shown), queued for a run that
  /// starts at once: each still listed, with no answer yet, and at that
  /// version. The others are left as they are, and a person listed since
  /// the screen was drawn is never answered by it. Throws
  /// [ContactSyncRefused] when none could be answered.
  Future<void> answerAllCopies(Map<String, String> people);
}

/// A [ContactSyncService] that has nothing to sync: the browser preview's,
/// and any engine without contact sync.
class NoContactSync implements ContactSyncService {
  const NoContactSync();

  @override
  Future<ContactSyncStatus> status() async => const ContactSyncStatus();

  @override
  Stream<void> get changed => const Stream.empty();

  @override
  Future<ContactSyncAccess> access(String accountId) async =>
      const ContactSyncAccess(ContactSyncAccessState.notPossible);

  @override
  Future<void> choose({
    required String googleAccountId,
    required String graphAccountId,
  }) async => throw const ContactSyncRefused(_unavailable);

  @override
  Future<ContactSyncPreview> preview() async =>
      throw const ContactSyncRefused(_unavailable);

  @override
  Future<List<ContactSyncBackupFile>> backup({ContactSide? only}) async =>
      throw const ContactSyncRefused(_unavailable);

  @override
  Future<void> start() async {}

  @override
  Future<void> syncNow() async {}

  @override
  Future<bool> startIfDue() async => false;

  @override
  Future<void> stop() async {}

  @override
  Future<void> answerQuestion(
    ContactSyncQuestionKind kind,
    ContactSyncChoice choice, {
    Set<String>? items,
  }) async {}

  @override
  Future<void> answerLook(
    int lookId,
    ContactSyncChoice choice, {
    String? candidateId,
  }) async {}

  @override
  Future<void> answerAllDiffering(
    ContactSyncChoice choice,
    Map<int, String> looks,
  ) async {}

  @override
  Future<void> restore(int deletedId) async {}

  @override
  Future<void> syncHere() async {}

  @override
  Future<void> noticeSeen(DateTime at) async {}

  @override
  Future<void> mergeCopies() async {}

  @override
  Future<void> answerCopies(
    String person,
    String? keep,
    String version,
  ) async {}

  @override
  Future<void> answerAllCopies(Map<String, String> people) async {}

  static const _unavailable = 'Contact sync is not available here.';
}

// ---------------------------------------------------------------------------
// Access.

/// Whether an account allows contact sync.
enum ContactSyncAccessState {
  /// Its contacts can be read and changed.
  allowed,

  /// Not allowed yet: a sign-in that asks for it does it, and where the
  /// organisation has to approve, sends them the request. Microsoft gives
  /// the same refusal either way, so this is also Hadco's "not approved
  /// yet"; once they approve, it turns to [allowed] with no new sign-in.
  needsSignIn,

  /// The organisation lets no one allow it; only its administrator can.
  needsAdministrator,

  /// Signed in with an app password, or a shared mailbox: no contact sync
  /// is possible. A Gmail account offers the switch to Google sign-in.
  notPossible,

  /// Could not be asked just now: no connection, or the sign-in itself
  /// needs repairing in Settings, Accounts.
  unknown,
}

@immutable
class ContactSyncAccess {
  const ContactSyncAccess(this.state, [this.message]);

  final ContactSyncAccessState state;

  /// What went wrong, in a sentence, where something did.
  final String? message;

  bool get allowed => state == ContactSyncAccessState.allowed;
}

// ---------------------------------------------------------------------------
// Status.

/// Where contact sync stands.
@immutable
class ContactSyncStatus {
  const ContactSyncStatus({
    this.googleAccountId,
    this.graphAccountId,
    this.firstStartedAt,
    this.firstDoneAt,
    this.lastAttemptAt,
    this.lastDoneAt,
    this.running,
    this.last,
    this.halt,
    this.questions = const [],
    this.needsALook = const [],
    this.recentlyDeleted = const [],
    this.googleCount,
    this.graphCount,
    this.notice,
    this.duplicates = const [],
    this.copies = const ContactSyncCopies(),
  });

  /// A run is due when the last completed one is this old.
  static const dueAfter = Duration(hours: 1);

  /// After a failed run, the shell waits this long before starting another.
  static const failedPause = Duration(minutes: 5);

  /// The pair's accounts; null when none is chosen. Either may have been
  /// removed since: the screen counts only accounts that still exist.
  final String? googleAccountId;
  final String? graphAccountId;

  /// The first sync: started by Start, done when it finished. Before it is
  /// done nothing is deleted and no detail that differs is overwritten.
  final DateTime? firstStartedAt;
  final DateTime? firstDoneAt;

  /// When a run last began, and when one last completed.
  final DateTime? lastAttemptAt;
  final DateTime? lastDoneAt;

  /// The run going, if one is.
  final ContactSyncProgress? running;

  /// What the last run did: a completed run's numbers ("Synced at 10:42: 2
  /// added, 1 changed, none deleted"), or how far an unfinished first sync
  /// got.
  final ContactSyncTally? last;

  /// Why the last run stopped short, if it did. Cleared by a run that
  /// completes.
  final ContactSyncHalt? halt;

  /// The brakes' open questions.
  final List<ContactSyncQuestion> questions;

  /// Needs a look.
  final List<ContactSyncLook> needsALook;

  /// Recently deleted: what the sync deleted in the last 30 days.
  final List<ContactSyncDeleted> recentlyDeleted;

  /// How many contacts each side has, as the sync counts them: for
  /// checking against Google Contacts and Outlook on the web.
  final int? googleCount;
  final int? graphCount;

  /// The one-line message to show once when MyEmail is opened: a run
  /// stopped, or held something back. Null once [ContactSyncService
  /// .noticeSeen] has been told, and when there is nothing to say.
  final ContactSyncNotice? notice;

  /// Copies of one person: for each person held more than once, how many
  /// copies each side holds and whether one on each is synced. One copy
  /// on each side is synced and the others are left as they are, for Ron
  /// to merge when he likes ("Duplicates to merge when you like").
  /// Rebuilt by every run, kept between runs and app restarts, and read
  /// here with no network, as the rest of the status is. Empty when there
  /// are none, and before the first run.
  final List<ContactSyncDuplicates> duplicates;

  /// The merge of the Microsoft side's copies of one person: how many
  /// people it would act on, whether one is asked, the people whose
  /// copies differ, and what the last one did. Always there: zeros when
  /// there is nothing to merge. Kept between runs and app restarts, and
  /// read here with no network.
  final ContactSyncCopies copies;

  bool get chosen => googleAccountId != null && graphAccountId != null;
  bool get firstStarted => firstStartedAt != null;
  bool get firstDone => firstDoneAt != null;
  bool get isRunning => running != null;

  /// The first sync was started and has not finished: it carries on the
  /// next time MyEmail is open.
  bool get firstUnfinished => firstStarted && !firstDone;
}

/// What a run is doing.
enum ContactSyncStep {
  /// Checking access and the other device, reading both address books.
  reading,

  /// Carrying out the plan, one write at a time.
  writing,

  /// Merging the Microsoft side's copies of one person, a person at a
  /// time ([ContactSyncService.mergeCopies]).
  merging,
}

@immutable
class ContactSyncProgress {
  const ContactSyncProgress({
    required this.step,
    this.done = 0,
    this.total = 0,
    this.firstSync = false,
  });

  final ContactSyncStep step;

  /// Writes done of [total], while [step] is writing; people done of
  /// [total], while it is merging.
  final int done;
  final int total;

  /// The run is (part of) the first sync.
  final bool firstSync;
}

/// One run's numbers.
@immutable
class ContactSyncTally {
  const ContactSyncTally({
    required this.at,
    this.complete = true,
    this.firstSync = false,
    this.addedToGoogle = 0,
    this.addedToGraph = 0,
    this.changedGoogle = 0,
    this.changedGraph = 0,
    this.deletedGoogle = 0,
    this.deletedGraph = 0,
    this.paired = 0,
    this.restored = 0,
    this.refused = 0,
    this.needsALook = 0,
    this.heldDeletions = 0,
    this.heldChanges = 0,
    this.passedOver = 0,
    this.planned = 0,
    this.done = 0,
  });

  /// When the run ended.
  final DateTime at;

  /// False for a run that stopped before the end (put away, or a failure):
  /// [done] of [planned] writes were made.
  final bool complete;
  final bool firstSync;

  final int addedToGoogle;
  final int addedToGraph;
  final int changedGoogle;
  final int changedGraph;
  final int deletedGoogle;
  final int deletedGraph;

  /// Contacts already on both sides, paired up.
  final int paired;
  final int restored;

  /// Contacts a server would not take ("Could not copy to Hadco").
  final int refused;

  /// New Needs a look items.
  final int needsALook;

  /// Held by the brakes this run.
  final int heldDeletions;
  final int heldChanges;

  /// Outlook contacts that could not be read whole, left for later.
  final int passedOver;

  /// Writes planned, and made.
  final int planned;
  final int done;

  int get added => addedToGoogle + addedToGraph;
  int get changed => changedGoogle + changedGraph;
  int get deleted => deletedGoogle + deletedGraph;
}

/// Why a run stopped short.
enum ContactSyncHaltKind {
  /// An account has not allowed contact sync (or its sign-in needs
  /// repairing): [ContactSyncHalt.side] says which.
  notAllowed,

  /// Another device synced in the last 7 days: "Contact sync is on on your
  /// other device", with Sync here.
  otherDevice,

  /// A complete listing of [ContactSyncHalt.side] had far fewer contacts
  /// than expected: the empty-answers question.
  emptyAnswer,

  /// Google's daily limit on contact changes is spent until
  /// [ContactSyncHalt.until].
  quota,

  /// Anything else: no connection, a server in trouble. [ContactSyncHalt
  /// .error] says what.
  failed,

  /// MyEmail was put away, or the switch turned off. Not a failure.
  putAway,
}

@immutable
class ContactSyncHalt {
  const ContactSyncHalt({
    required this.kind,
    required this.at,
    this.side,
    this.error,
    this.until,
    this.claimedAt,
  });

  final ContactSyncHaltKind kind;
  final DateTime at;

  /// The account's side, where it is about one: always set for
  /// [ContactSyncHaltKind.notAllowed] and [ContactSyncHaltKind.emptyAnswer]
  /// (and Google's for [ContactSyncHaltKind.quota]).
  final ContactSide? side;

  /// The failure, typed for ProblemView: [ContactSyncNeedsSignIn] for
  /// [ContactSyncHaltKind.notAllowed]; for [ContactSyncHaltKind.failed]
  /// either a [ContactSyncFailed] ([Retryable]: no connection, a server in
  /// trouble) or a [ContactSyncRefused], which is not (the People API
  /// switched off, a request a server would not take): trying again may
  /// not help, so the screen offers Sync now itself for that one.
  final Exception? error;

  /// For [ContactSyncHaltKind.quota]: when Google's quota is renewed.
  final DateTime? until;

  /// For [ContactSyncHaltKind.otherDevice]: when the other device last
  /// completed a run.
  final DateTime? claimedAt;

  /// Anything but MyEmail being put away: the shell starts no run for
  /// [ContactSyncStatus.failedPause] after it, so a stop that will happen
  /// again is not met at every opening.
  bool get pausesRuns => kind != ContactSyncHaltKind.putAway;
}

/// The one-line message for when MyEmail is next opened.
@immutable
class ContactSyncNotice {
  const ContactSyncNotice({
    required this.at,
    this.halt,
    this.heldDeletions = 0,
    this.heldChanges = 0,
  });

  /// Identifies the notice: [ContactSyncService.noticeSeen] is told it.
  final DateTime at;

  /// The run stopped.
  final ContactSyncHalt? halt;

  /// Or held these back, asking first.
  final int heldDeletions;
  final int heldChanges;
}

// ---------------------------------------------------------------------------
// Questions and answers.

/// A brake's question.
enum ContactSyncQuestionKind {
  /// More than 5 deletions in one run: Delete them, or Don't delete them.
  deletions,

  /// More than 10 contacts losing or replacing details: Apply them, or
  /// Copy them back.
  changes,

  /// A side listed far fewer contacts than expected: That's right, carry
  /// on, or Keep waiting.
  emptyAnswer,
}

/// Every button an answer can be.
enum ContactSyncChoice {
  // A new contact the sync could not place.
  samePerson,
  copyAnyway,
  leaveOut,

  // A new pair whose details differ.
  useGoogle,
  useGraph,
  leaveAsTheyAre,

  // A clash: the value that lost, or the newer one kept.
  useOther,
  keepNewer,

  // A contact kept when its partner went, or one left by a merge in Gmail.
  copyBack,
  deleteHereToo,
  keepOnlyHere,

  // A contact a server would not take.
  retry,

  // The deletion brake.
  deleteThem,
  dontDelete,

  // The change brake.
  applyThem,
  copyThemBack,

  // The empty-answers brake.
  carryOn,
  keepWaiting,
}

@immutable
class ContactSyncQuestion {
  const ContactSyncQuestion({
    required this.kind,
    this.items = const [],
    this.side,
    this.listed,
    this.expected,
    this.answer,
  });

  /// An [ContactSyncHaltKind.emptyAnswer] stop always comes with its open
  /// question of this kind, there until a run completes (Keep waiting
  /// leaves it).
  final ContactSyncQuestionKind kind;

  /// The contacts held, with where each went or changed.
  final List<ContactSyncQuestionItem> items;

  /// For [ContactSyncQuestionKind.emptyAnswer]: the side, how many it
  /// listed and how many were expected.
  final ContactSide? side;
  final int? listed;
  final int? expected;

  /// The answer queued for the whole question, waiting for a run. It
  /// covers every item not answered on its own.
  final ContactSyncChoice? answer;

  List<ContactSyncChoice> get choices => switch (kind) {
    ContactSyncQuestionKind.deletions => const [
      ContactSyncChoice.deleteThem,
      ContactSyncChoice.dontDelete,
    ],
    ContactSyncQuestionKind.changes => const [
      ContactSyncChoice.applyThem,
      ContactSyncChoice.copyThemBack,
    ],
    ContactSyncQuestionKind.emptyAnswer => const [
      ContactSyncChoice.carryOn,
      ContactSyncChoice.keepWaiting,
    ],
  };
}

@immutable
class ContactSyncQuestionItem {
  const ContactSyncQuestionItem({
    required this.title,
    required this.side,
    this.key = '',
    this.changes = const [],
    this.hint,
    this.answer,
    this.answerProblem,
  });

  final String title;

  /// For deletions, the side it was deleted from ("deleted in Gmail",
  /// "gone from Hadco"); for changes, the side that would lose details.
  final ContactSide side;

  /// Names this contact within its question, for
  /// [ContactSyncService.answerQuestion]'s items: minted once when the
  /// item is raised and never changed, whatever happens to its contacts'
  /// ids (a Gmail re-key). The runner always sets it.
  final String key;

  /// For changes: each detail that would be removed or replaced, with
  /// what is there now and what it would become. They can be on both
  /// sides, each saying its own ([ContactSyncDetailChange.side]): Gmail's
  /// first, then Hadco's, each in the order of the contact's details, one
  /// change for each value of a list. Empty for deletions, and for an
  /// item whose contacts no run has read since it was held.
  final List<ContactSyncDetailChange> changes;

  /// For deletions: enough to tell the contact apart, its first email,
  /// else its mobile. Null for changes, and where it has neither.
  final String? hint;

  /// The answer given to this item on its own, waiting for a run that
  /// carries it out; null when it has none (the question's answer, if
  /// any, covers it).
  final ContactSyncChoice? answer;

  /// Why the answer given to this item (its own, or the question's) was
  /// not carried out at the last run, a sentence to show as it is under
  /// it: "Could not be read just now: it is carried out when it can be."
  /// The answer stays given, and a later run carries it out. Null when
  /// nothing held it up.
  final String? answerProblem;
}

/// One detail a held change would remove or replace, on the side that
/// would lose it. Contact data: shown on screen and kept on this device,
/// never written to a log.
@immutable
class ContactSyncDetailChange {
  const ContactSyncDetailChange({
    required this.field,
    this.before,
    this.after,
    this.side,
    this.clash = false,
  });

  final ContactField field;

  /// The value there now, as shown. Null only for a value too long to
  /// show here (a note of more than a line): then [after] is 'changed', or
  /// null when it would be removed.
  final String? before;

  /// What it would become, as shown; null when it would be removed.
  final String? after;

  /// The side this change lands on; null means its contact's side, the
  /// item's.
  final ContactSide? side;

  /// A detail changed on both sides: Copy back does not undo it, the newer
  /// edit stays.
  final bool clash;
}

/// One Needs a look item.
@immutable
class ContactSyncLook {
  const ContactSyncLook({
    required this.id,
    required this.kind,
    this.reason,
    this.side,
    this.title = '',
    this.candidates = const [],
    this.fields = const [],
    this.googleValues = const {},
    this.graphValues = const {},
    this.losing,
    this.losingSide,
    this.choices = const [],
    this.answer,
    this.createdAt,
  });

  final int id;
  final ContactReviewKind kind;
  final ContactReviewReason? reason;

  /// For a new contact, its side; for one a server refused, the side that
  /// refused it. For a kept contact, the side it went from, and for one
  /// merged away in Gmail, Google: always set for both, and what Delete it
  /// here too and Keep it only here act on is the contact on the other
  /// side.
  final ContactSide? side;
  final String title;

  /// For a new contact: who on the other side it may be.
  final List<ContactSyncCandidate> candidates;

  /// The details that differ, or the one that clashed.
  final List<ContactField> fields;

  /// Each side's value of [fields], as one line each.
  final Map<ContactField, String> googleValues;
  final Map<ContactField, String> graphValues;

  /// For a clash: the value that lost, as one line, and its side.
  final String? losing;
  final ContactSide? losingSide;

  /// The buttons to offer, in order.
  final List<ContactSyncChoice> choices;

  /// The answer queued, waiting for a run.
  final ContactSyncChoice? answer;
  final DateTime? createdAt;

  /// What the item shows, in a short stable form (the first 16 hex of a
  /// SHA-256, so no contact's values are in it): an answer for every pair
  /// whose details differ ([ContactSyncService.answerAllDiffering]) counts
  /// only on an item still as it was shown, never on one planned again
  /// since with other details or other values.
  String get version {
    final shown = jsonEncode([
      kind.name,
      reason?.name,
      side?.name,
      title,
      for (final c in candidates) [c.id, c.title],
      for (final f in fields) [f.name, googleValues[f], graphValues[f]],
      losing,
      losingSide?.name,
    ]);
    final hash = const DartSha256().hashSync(utf8.encode(shown));
    return [
      for (final b in hash.bytes.take(8)) b.toRadixString(16).padLeft(2, '0'),
    ].join();
  }
}

@immutable
class ContactSyncCandidate {
  const ContactSyncCandidate({required this.id, required this.title});

  final String id;
  final String title;
}

/// What a deleted contact's entry in Recently deleted is doing.
enum ContactSyncDeletedState {
  /// Read and kept, the delete not yet answered.
  deleting,
  deleted,

  /// Ron brought it back himself: "Already back".
  back,
}

/// One entry in Recently deleted.
@immutable
class ContactSyncDeleted {
  const ContactSyncDeleted({
    required this.id,
    required this.title,
    required this.side,
    required this.state,
    this.deletedAt,
    this.restoreAsked = false,
    this.restoreProblem,
  });

  final int id;
  final String title;

  /// The side the sync deleted it from.
  final ContactSide side;
  final ContactSyncDeletedState state;
  final DateTime? deletedAt;

  /// Restore pressed, waiting for a run.
  final bool restoreAsked;

  /// Why the last Restore could not be done, a sentence to show as it is:
  /// "Could not restore. Google would not take the contact (HTTP 400,
  /// INVALID_ARGUMENT)." (or Microsoft). The Restore is taken back
  /// ([restoreAsked] false); pressing Restore again clears this and tries
  /// once more. Null when nothing went wrong.
  final String? restoreProblem;
}

// ---------------------------------------------------------------------------
// The preview and the backup.

/// What the first sync would do.
@immutable
class ContactSyncPreview {
  const ContactSyncPreview({
    this.googleListed = 0,
    this.graphListed = 0,
    this.addToGoogle = 0,
    this.addToGraph = 0,
    this.pairUp = 0,
    this.needsALook = 0,
    this.differingPairs = 0,
    this.deletions = 0,
    this.duplicateCopies = 0,
  });

  /// How many contacts each side has now.
  final int googleListed;
  final int graphListed;

  final int addToGoogle;
  final int addToGraph;

  /// Already in both, to be paired up.
  final int pairUp;
  final int needsALook;

  /// Of [pairUp], pairs with a detail that differs, left as it is.
  final int differingPairs;

  /// Always none: the first sync deletes nothing ("Deleted: none").
  final int deletions;

  /// Copies of the same person beyond the one synced on each side, both
  /// sides together: left as they are ("Copies of the same person, left
  /// as they are: N"). Not among [needsALook], [addToGoogle] or
  /// [addToGraph].
  final int duplicateCopies;
}

/// One person held more than once: one copy on each side is synced (where
/// a side has one), and the other copies are left as they are, neither
/// copied, changed nor deleted, until Ron merges them. Whichever copy he
/// removes, the sync moves to one that is left.
@immutable
class ContactSyncDuplicates {
  const ContactSyncDuplicates({
    required this.title,
    this.googleCopies = 0,
    this.graphCopies = 0,
    this.googleSynced = false,
    this.graphSynced = false,
  });

  /// The person's name, for show.
  final String title;

  /// How many copies each side holds, the synced one included.
  final int googleCopies;
  final int graphCopies;

  /// Whether one copy on each side is synced (the pair). Both, for a
  /// person on both sides; one side only while its copy waits to be made
  /// on the other.
  final bool googleSynced;
  final bool graphSynced;
}

/// The merge of the Microsoft side's copies of one person
/// ([ContactSyncService.mergeCopies]).
@immutable
class ContactSyncCopies {
  const ContactSyncCopies({
    this.people = 0,
    this.extras = 0,
    this.notSynced = 0,
    this.asked = false,
    this.shortStops = 0,
    this.last,
    this.differing = const [],
  });

  /// The people a merge would act on: a synced Microsoft copy, paired,
  /// with held copies beside it.
  final int people;

  /// Their other copies on the Microsoft side.
  final int extras;

  /// People with copies on the Microsoft side that a merge leaves as they
  /// are: there is no synced copy there, or a copy shares only the name
  /// with it (no email or mobile joins them).
  final int notSynced;

  /// A merge is queued or running: from [ContactSyncService.mergeCopies]
  /// until one pass has dealt with every person.
  final bool asked;

  /// How many passes in a row stopped short because Hadco could not be
  /// read, while the merge is asked. After one, the next pass waits the
  /// usual hour; after three, the merge is given up
  /// ([ContactSyncCopiesResult.stoppedShort]).
  final int shortStops;

  /// What the last merge did, if one has run.
  final ContactSyncCopiesResult? last;

  /// The people whose copies differ, for Ron to choose
  /// ([ContactSyncService.answerCopies]).
  final List<ContactSyncCopiesPerson> differing;
}

/// What a merge did.
@immutable
class ContactSyncCopiesResult {
  const ContactSyncCopiesResult({
    required this.at,
    this.people = 0,
    this.deleted = 0,
    this.added = 0,
    this.differing = 0,
    this.failed = 0,
    this.passedOver = 0,
    this.stoppedShort = false,
  });

  /// When it ended.
  final DateTime at;

  /// People merged: their other copies deleted.
  final int people;

  /// Copies deleted.
  final int deleted;

  /// Details added to synced copies.
  final int added;

  /// People whose copies differ, listed for Ron and not yet answered when
  /// the pass ended.
  final int differing;

  /// People the pass could not finish: a write failed (nothing of theirs
  /// deleted), or a delete failed (the copies left are as they were). The
  /// next merge tries them again.
  final int failed;

  /// People the pass left for the next merge: a copy changed in Outlook
  /// while the merge went, a photo that could not be read, a contact no
  /// longer in Contacts, or Hadco not read again just then. Nothing of
  /// theirs was deleted, though details may already have been added to
  /// the synced copy.
  final int passedOver;

  /// The merge was given up: three passes in a row stopped short because
  /// Hadco could not be read. Merging again starts afresh.
  final bool stoppedShort;
}

/// A person whose copies on the Microsoft side differ.
@immutable
class ContactSyncCopiesPerson {
  const ContactSyncCopiesPerson({
    required this.key,
    required this.title,
    this.copies = const [],
    this.answer,
    this.version = '',
  });

  /// [answer] when Ron chose to leave them as they are.
  static const leave = 'leave';

  /// Names the person for [ContactSyncService.answerCopies].
  final String key;

  /// The person's name, for show.
  final String title;

  /// The copies, the synced one first.
  final List<ContactSyncCopy> copies;

  /// Ron's answer, waiting for a run: the key of the copy whose details he
  /// keeps, or [leave]. Null when he has not answered.
  final String? answer;

  /// The differences as listed, a short stable form of them: an answer
  /// ([ContactSyncService.answerCopies], [ContactSyncService
  /// .answerAllCopies]) counts only on these.
  final String version;
}

/// One copy of a person whose copies differ.
@immutable
class ContactSyncCopy {
  const ContactSyncCopy({
    required this.key,
    this.synced = false,
    this.details = const [],
  });

  /// Names the copy for [ContactSyncService.answerCopies].
  final String key;

  /// The copy the sync keeps paired (it always stays).
  final bool synced;

  /// Its values of the details that differ, in the same order on every
  /// copy of the person. Contact data: shown on screen and kept on this
  /// device, never written to a log.
  final List<ContactSyncCopyDetail> details;
}

/// One detail that differs between the copies, as one copy holds it.
@immutable
class ContactSyncCopyDetail {
  const ContactSyncCopyDetail({required this.label, this.value});

  /// The detail's name, as the screen names details ("Job title").
  final String label;

  /// As shown, on one line; null when this copy has none.
  final String? value;
}

/// One of the two backup files, for `BackupFiles.save`.
@immutable
class ContactSyncBackupFile {
  const ContactSyncBackupFile({
    required this.side,
    required this.fileName,
    required this.mimeType,
    required this.contents,
    required this.count,
  });

  /// Whose contacts: Google's as a vCard, Microsoft's as Outlook's CSV.
  final ContactSide side;
  final String fileName;
  final String mimeType;
  final String contents;

  /// How many contacts it holds.
  final int count;
}

// ---------------------------------------------------------------------------
// Failures.

/// An account has not allowed contact sync: which one, like
/// MeetLinkNeedsConsent, so the screen can offer its Allow.
@immutable
class ContactSyncNeedsSignIn implements Exception, NeedsSignIn, ReadableError {
  const ContactSyncNeedsSignIn({
    required this.side,
    required this.accountId,
    required this.message,
    this.needsAdministrator = false,
  });

  final ContactSide side;
  final String accountId;

  @override
  final String message;

  @override
  final bool needsAdministrator;

  @override
  String toString() => message;
}

/// A run that failed in a way worth trying again: no connection, a server
/// in trouble, a throttle that outlasted its waits.
@immutable
class ContactSyncFailed implements Exception, Retryable, ReadableError {
  const ContactSyncFailed(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

/// What cannot be done, as it stands: accounts that cannot sync, a run
/// going, a setting to change in a Cloud project.
@immutable
class ContactSyncRefused implements Exception, ReadableError {
  const ContactSyncRefused(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}
