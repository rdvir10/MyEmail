import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../domain/synced_contact.dart';
import 'contact_mapping.dart';

// The contact sync's planner: from what both address books hold now, the
// rows the sync keeps, and Ron's queued answers, to what to write. Pure:
// no reads, no writes, no clock of its own, so the first sync's preview is
// the same function as the sync, and every rule of the plan's "Pairing
// contacts", "Merging and clashes", "Deletions and Restore" and "The
// brakes" can be tested without a server.
//
// The runner reads both feeds, confirms what looks deleted (see
// [contactsToConfirm]), calls [planContactSync], then carries the plan
// out: creates (journalled first), updates, deletes (read again and put in
// the bin first), each row saved as its write comes back.

/// More deletions than this in one run are held and asked about.
const contactDeletionBrake = 5;

/// More contacts than this losing or replacing details in one run are held
/// and asked about.
const contactChangeBrake = 10;

/// A complete listing with under half the contacts expected stops the run,
/// when at least this many were expected.
const contactEmptyAnswerFloor = 10;

/// A contact whose Gmail side the sync wrote this recently is never judged
/// by its absence (Google's listings lag behind writes), and an
/// interrupted create is waited for this long before it is made again.
const contactGrace = Duration(hours: 1);

/// Whether a row pairs two contacts or holds one (or both) back.
enum ContactLinkState { paired, held }

/// Why a row is held. [code] is what the row keeps.
enum ContactHeldReason {
  /// Ron's Leave it out, or Keep it only here.
  leftOut('left_out'),

  /// Under Needs a look, not yet answered.
  waiting('waiting'),

  /// A delete that was not done: the other copy changed since, it came in
  /// the first sync, or Ron said Don't delete them. One id: the copy kept.
  kept('kept'),

  /// An Outlook contact moved to another folder. Both ids kept; the pair
  /// comes back if it returns to Contacts.
  movedOut('moved_out'),

  /// A server would not take it. Tried again when it changes, or on Retry.
  refused('refused'),

  /// Held by the deletion brake. One id: the copy that would be deleted.
  deletionBrake('brake_delete'),

  /// Held by the change brake. Both ids, the bases as they were.
  changeBrake('brake_change');

  const ContactHeldReason(this.code);

  final String code;

  static ContactHeldReason? fromCode(String? code) =>
      values.firstWhereOrNull((r) => r.code == code);
}

// ---------------------------------------------------------------------------
// Input.

/// One stored row, in plain fields: the store's own row class maps to it.
@immutable
class ContactLinkInput {
  const ContactLinkInput({
    required this.linkId,
    this.googleName,
    this.graphId,
    this.googleEtag,
    this.graphChangeKey,
    this.googleBase,
    this.graphBase,
    this.state = ContactLinkState.paired,
    this.reason,
    this.googleWrittenAt,
  });

  final int linkId;

  /// The Gmail contact's resource name, where the row has one.
  final String? googleName;

  /// The Outlook contact's immutable id, where the row has one.
  final String? graphId;

  /// Each side's etag or `changeKey` as it was when the contact was last
  /// synced: written by the sync, or a change of it taken in.
  final String? googleEtag;
  final String? graphChangeKey;

  /// Each side's synced details as its server last returned them, in
  /// [SyncedContact.toJson]'s form.
  final Map<String, Object?>? googleBase;
  final Map<String, Object?>? graphBase;

  final ContactLinkState state;
  final ContactHeldReason? reason;

  /// When the sync last wrote the Gmail side, for the hour of grace.
  final DateTime? googleWrittenAt;

  SyncedContact get googleDetails => SyncedContact.fromJson(googleBase);
  SyncedContact get graphDetails => SyncedContact.fromJson(graphBase);
}

/// A create in flight: journalled before it was sent, cleared with the row
/// that records it. One left over means the run stopped in between.
@immutable
class ContactJournalEntry {
  const ContactJournalEntry({
    required this.opId,
    required this.side,
    required this.sourceId,
    required this.startedAt,
  });

  final int opId;

  /// Where the contact was being made.
  final ContactSide side;

  /// The contact it copies, on the other side, which is also the hidden
  /// tag it carries.
  final String sourceId;

  final DateTime startedAt;
}

/// A contact the sync deleted, from Recently deleted.
@immutable
class ContactBinInput {
  const ContactBinInput({
    required this.binId,
    required this.side,
    required this.contactId,
    this.partnerId,
    this.done = true,
    this.raw,
    this.partnerBase,
    this.title = '',
    this.restore = false,
  });

  final int binId;

  /// The side the sync deleted it from.
  final ContactSide side;
  final String contactId;

  /// Its partner, which Ron deleted.
  final String? partnerId;

  /// False while pending: put in the bin, the delete not yet answered.
  final bool done;

  /// The full copy read just before deleting it: a Person, or a Graph
  /// contact.
  final Map<String, Object?>? raw;

  /// The partner's synced details, in [SyncedContact.toJson]'s form.
  final Map<String, Object?>? partnerBase;

  final String title;

  /// Ron pressed Restore.
  final bool restore;
}

/// Ron's answers, queued for the next run, which reads both contacts again
/// first. An answer whose contact has gone since is dropped.
enum ContactAnswerKind {
  /// A contact under Needs a look and its candidate are one person: pair
  /// [ContactAnswer.googleName] with [ContactAnswer.graphId].
  samePerson,

  /// Copy each contact named to the other side.
  copyAnyway,

  /// Hold each contact named as left out.
  leaveOut,

  /// Differing details: write Gmail's [ContactAnswer.fields] (all that
  /// differ, when empty) to Outlook.
  useGoogle,

  /// Differing details: write Outlook's to Gmail.
  useGraph,

  /// A clash's losing value, [ContactAnswer.value], written to both sides.
  useValue,

  /// A kept contact copied back to the side it went from.
  copyBack,

  /// A kept contact (or one left behind by a merge in Gmail) deleted too.
  deleteHereToo,

  /// A kept contact held as left out.
  keepOnlyHere,

  /// The deletion brake: delete them.
  deleteHeld,

  /// The deletion brake: don't delete them.
  keepHeld,

  /// The change brake: apply them.
  applyHeld,

  /// The change brake: copy them back.
  copyHeldBack,

  /// The empty-answers brake: that's right, carry on, for
  /// [ContactAnswer.side].
  carryOn,

  /// A refused contact tried again.
  retry,
}

@immutable
class ContactAnswer {
  const ContactAnswer(
    this.kind, {
    this.googleName,
    this.graphId,
    this.fields = const {},
    this.value,
    this.side,
  });

  final ContactAnswerKind kind;
  final String? googleName;
  final String? graphId;
  final Set<ContactField> fields;

  /// For [ContactAnswerKind.useValue]: the losing value, in
  /// [SyncedContact.toJson]'s form.
  final Map<String, Object?>? value;
  final ContactSide? side;
}

/// Everything one run plans from.
@immutable
class ContactSyncInput {
  const ContactSyncInput({
    this.google = const [],
    this.graph = const [],
    this.googleComplete = false,
    this.graphComplete = false,
    this.links = const [],
    this.firstSync = false,
    this.googleGone = const {},
    this.graphGone = const {},
    this.graphMovedOut = const {},
    this.googleReKeys = const {},
    this.journal = const [],
    this.bin = const [],
    this.answers = const [],
    this.expectedGoogle,
    this.expectedGraph,
    this.phoneRegion,
    required this.now,
  });

  /// Gmail contacts this run read: every page of a full listing, or a
  /// sync-token listing's changes (deleted entries included). The runner
  /// adds, read by name, every contact a queued answer, Restore or
  /// journal entry names that the feed did not bring.
  final List<GoogleContact> google;

  /// Outlook contacts this run read, the same way (tags expanded for
  /// contacts without a row).
  final List<GraphContact> graph;

  /// Whether [google] / [graph] is a full listing.
  final bool googleComplete;
  final bool graphComplete;

  final List<ContactLinkInput> links;

  /// Everything before the first sync is done: nothing is deleted and no
  /// detail that differs is overwritten.
  final bool firstSync;

  /// Contacts confirmed gone: by getBatchGet's NOT_FOUND for Gmail, by a
  /// GET that found nothing, or found it in Deleted Items, for Outlook.
  /// Gmail's own deleted entries in [google] count too.
  final Set<String> googleGone;
  final Set<String> graphGone;

  /// Outlook contacts found in another folder.
  final Set<String> graphMovedOut;

  /// Gmail re-keys found by getBatchGet (old name to new). Those in
  /// `previousResourceNames` are read from [google].
  final Map<String, String> googleReKeys;

  final List<ContactJournalEntry> journal;
  final List<ContactBinInput> bin;
  final List<ContactAnswer> answers;

  /// The counts kept for the empty-answers brake.
  final int? expectedGoogle;
  final int? expectedGraph;

  /// The pair's phone region, an ISO code.
  final String? phoneRegion;

  final DateTime now;
}

// ---------------------------------------------------------------------------
// Output.

/// A write of some details into one side of a pair.
@immutable
class ContactWrite {
  const ContactWrite({
    required this.side,
    required this.fields,
    required this.target,
    this.replaced = const {},
  });

  /// The side written.
  final ContactSide side;
  final Set<ContactField> fields;

  /// What the side should hold for [fields] (other fields as read).
  final SyncedContact target;

  /// Gmail list values Outlook replaced in a slot: see [googlePersonUpdate].
  final Map<ContactField, Map<String, String>> replaced;

  /// The `updateContact` request, from the Person as last read.
  GooglePersonUpdate googleUpdate(
    Map<String, Object?> person, {
    ContactNormaliser? normaliser,
  }) => googlePersonUpdate(
    person,
    target,
    fields,
    replaced: replaced,
    normaliser: normaliser,
  );

  /// The `PATCH` body, from the contact as read just before it.
  Map<String, Object?> graphPatch(Map<String, Object?> current) =>
      graphContactPatch(current, target, fields);
}

/// A contact copied to the other side. The new contact carries the
/// hidden tag naming its source.
@immutable
class ContactCreate {
  const ContactCreate({
    required this.side,
    required this.sourceId,
    required this.details,
  });

  /// Where it is made.
  final ContactSide side;

  /// The contact it copies, on the other side.
  final String sourceId;

  final SyncedContact details;

  String get tag => sourceId;

  Map<String, Object?> get body => side == ContactSide.google
      ? googleCreateBody(details, tag: tag)
      : graphCreateBody(details, tag: tag);
}

/// Why a contact is deleted.
enum ContactDeleteCause {
  /// Its partner was deleted in Gmail.
  deletedInGoogle,

  /// Its partner is gone from Outlook.
  goneFromGraph,

  /// Ron said so.
  answered,
}

/// A contact to delete. The runner reads it again in full first: if its
/// etag or `changeKey` is no longer [expectedVersion], or it has left
/// Contacts, it is kept instead (see [ContactLinkPlan.keptInstead]).
@immutable
class ContactDelete {
  const ContactDelete({
    required this.side,
    required this.contactId,
    required this.cause,
    this.expectedVersion,
    this.title = '',
    this.partnerId,
    this.partnerBase,
  });

  final ContactSide side;
  final String contactId;
  final ContactDeleteCause cause;
  final String? expectedVersion;
  final String title;

  /// The partner that went, and its synced details, for the bin.
  final String? partnerId;
  final SyncedContact? partnerBase;
}

/// One row as the plan leaves it, with the writes that go with it.
@immutable
class ContactLinkPlan {
  const ContactLinkPlan({
    this.linkId,
    this.alsoRemove = const [],
    this.googleName,
    this.graphId,
    this.state = ContactLinkState.paired,
    this.reason,
    this.googleEtag,
    this.graphChangeKey,
    this.googleBase,
    this.graphBase,
    this.googleNow,
    this.graphNow,
    this.googleWrite,
    this.graphWrite,
    this.create,
    this.delete,
    this.removeRow = false,
    this.newPair = false,
    this.fromAnswer = false,
    this.removes = false,
    this.title = '',
  });

  /// The row, or null for a new one.
  final int? linkId;

  /// Rows folded into this one (Same person over two held rows): removed.
  final List<int> alsoRemove;

  final String? googleName;
  final String? graphId;
  final ContactLinkState state;
  final ContactHeldReason? reason;

  /// Each side's version as read (before any write).
  final String? googleEtag;
  final String? graphChangeKey;

  /// Each side's base before any write's answer: the old base, with every
  /// detail taken in that needed no write.
  final SyncedContact? googleBase;
  final SyncedContact? graphBase;

  /// Each side's details as read.
  final SyncedContact? googleNow;
  final SyncedContact? graphNow;

  final ContactWrite? googleWrite;
  final ContactWrite? graphWrite;
  final ContactCreate? create;
  final ContactDelete? delete;

  /// The row goes once the plan is carried out.
  final bool removeRow;

  /// A pair made this run, merged without overwriting.
  final bool newPair;

  /// From Ron's answer: not counted by the brakes.
  final bool fromAnswer;

  /// A write removes or replaces an existing detail: the change brake
  /// counts it.
  final bool removes;

  final String title;

  bool get writes =>
      googleWrite != null ||
      graphWrite != null ||
      create != null ||
      delete != null;

  /// The bases to store once the writes are done. [googleAnswer] and
  /// [graphAnswer] are the details each server sent back for a write
  /// that went through (null for one that failed or was not needed);
  /// [created] is the new contact as its server sent it back.
  ///
  /// Only the details written take a new base, from the answer, so the
  /// server's own formatting never reads as a change; the side they came
  /// from takes its value as read. Every other detail keeps its old base,
  /// so an edit made while the run was going still reads as a change. A
  /// list merged both ways moves on only when both writes went through.
  ({SyncedContact google, SyncedContact graph}) basesAfter({
    SyncedContact? googleAnswer,
    SyncedContact? graphAnswer,
    SyncedContact? created,
  }) {
    var g = googleBase ?? SyncedContact.empty;
    var h = graphBase ?? SyncedContact.empty;
    if (create != null && created != null) {
      if (create!.side == ContactSide.google) {
        g = created;
      } else {
        h = created;
      }
    }
    final toG = googleWrite?.fields ?? const <ContactField>{};
    final toH = graphWrite?.fields ?? const <ContactField>{};
    if (graphAnswer != null) {
      for (final f in toH) {
        if (toG.contains(f) && googleAnswer == null) continue;
        h = h.withValue(f, graphAnswer[f]);
        if (!toG.contains(f)) g = g.withValue(f, googleNow?[f]);
      }
    }
    if (googleAnswer != null) {
      for (final f in toG) {
        if (toH.contains(f) && graphAnswer == null) continue;
        g = g.withValue(f, googleAnswer[f]);
        if (!toH.contains(f)) h = h.withValue(f, graphNow?[f]);
      }
    }
    return (google: g, graph: h);
  }

  /// The row to save when the read just before [delete] finds the contact
  /// changed, or no longer in Contacts: held as kept, the gone side's id
  /// cleared. Its Needs a look item is [keptReview].
  ContactLinkPlan keptInstead() => ContactLinkPlan(
    linkId: linkId,
    googleName: delete?.side == ContactSide.google ? googleName : null,
    graphId: delete?.side == ContactSide.graph ? graphId : null,
    state: ContactLinkState.held,
    reason: ContactHeldReason.kept,
    googleEtag: googleEtag,
    graphChangeKey: graphChangeKey,
    googleBase: delete?.side == ContactSide.google ? googleBase : null,
    graphBase: delete?.side == ContactSide.graph ? graphBase : null,
    title: title,
  );

  ContactReviewItem keptReview() => ContactReviewItem(
    kind: ContactReviewKind.kept,
    reason: ContactReviewReason.changedSince,
    googleName: delete?.side == ContactSide.google ? googleName : null,
    graphId: delete?.side == ContactSide.graph ? graphId : null,
    goneSide: delete?.side.other,
    title: title,
  );
}

/// What a Needs a look item is about.
enum ContactReviewKind {
  /// A new contact the sync could not place safely: Same person, Copy it
  /// anyway, Leave it out.
  newContact,

  /// A new pair whose details differ: Use Gmail's, Use Hadco's, Leave as
  /// they are.
  differing,

  /// The same detail changed on both sides: the newer won, and the losing
  /// value is a tap away.
  clash,

  /// Deleted on one side, kept on the other: Copy it back, Delete it here
  /// too, Keep it only here.
  kept,

  /// Two contacts merged in Gmail: delete the other one in Hadco too, or
  /// keep it only there.
  mergedInGoogle,

  /// A server would not take it: Retry. Made by the runner, not here.
  refused,
}

/// Why, within a kind.
enum ContactReviewReason {
  /// The hidden tag names a contact already paired, or held.
  taggedPaired,

  /// A unique email or mobile names a contact already paired.
  matchPaired,

  /// It names a held contact.
  matchHeld,

  /// It names a contact whose family name is another.
  namesDisagree,

  /// Several contacts share the address (a family email) or the mobile.
  sharedAddress,

  /// Different addresses name different contacts.
  severalMatches,

  /// The same full name and nothing else in common.
  sameName,

  /// The other copy changed after this one was deleted.
  changedSince,

  /// Deleted during the first sync, which deletes nothing.
  firstSync,

  /// Ron said Don't delete them.
  notDeleted,
}

/// One Needs a look item.
@immutable
class ContactReviewItem {
  const ContactReviewItem({
    required this.kind,
    this.reason,
    this.subjectSide,
    this.googleName,
    this.graphId,
    this.candidates = const [],
    this.samePersonOffered = true,
    this.fields = const [],
    this.googleValues,
    this.graphValues,
    this.losing,
    this.losingSide,
    this.goneSide,
    this.title = '',
    this.candidateTitles = const [],
  });

  final ContactReviewKind kind;
  final ContactReviewReason? reason;

  /// For a new contact: its side.
  final ContactSide? subjectSide;

  /// The contacts involved: the subject, and for a pair its partner.
  final String? googleName;
  final String? graphId;

  /// For a new contact: the contacts on the other side it may be.
  final List<String> candidates;

  /// Same person is offered only when some candidate is not paired.
  final bool samePersonOffered;

  /// The details that differ, or the one that clashed.
  final List<ContactField> fields;

  /// For differing details: each side's values.
  final SyncedContact? googleValues;
  final SyncedContact? graphValues;

  /// For a clash: the value that lost, and the side it was on.
  final SyncedContact? losing;
  final ContactSide? losingSide;

  /// For a kept contact: the side it went from.
  final ContactSide? goneSide;

  final String title;
  final List<String> candidateTitles;

  /// What the screen shows, for the stored row.
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'reason': ?reason?.name,
    'subjectSide': ?subjectSide?.name,
    'googleName': ?googleName,
    'graphId': ?graphId,
    if (candidates.isNotEmpty) 'candidates': candidates,
    'samePerson': samePersonOffered,
    if (fields.isNotEmpty) 'fields': [for (final f in fields) f.name],
    'google': ?googleValues?.toJson(),
    'graph': ?graphValues?.toJson(),
    'losing': ?losing?.toJson(),
    'losingSide': ?losingSide?.name,
    'goneSide': ?goneSide?.name,
    'title': title,
    if (candidateTitles.isNotEmpty) 'candidateTitles': candidateTitles,
  };
}

enum ContactBrakeKind { deletions, changes }

/// One contact a brake holds: its name, and where it went or changed.
@immutable
class ContactBrakeItem {
  const ContactBrakeItem({
    required this.title,
    required this.side,
    this.googleName,
    this.graphId,
  });

  final String title;

  /// For deletions, the side it was deleted from; for changes, the side
  /// whose details would be removed or replaced.
  final ContactSide side;
  final String? googleName;
  final String? graphId;

  Map<String, Object?> toJson() => {
    'title': title,
    'side': side.name,
    'googleName': ?googleName,
    'graphId': ?graphId,
  };
}

/// A brake's question, raised this run.
@immutable
class ContactBrake {
  const ContactBrake(this.kind, this.items);

  final ContactBrakeKind kind;
  final List<ContactBrakeItem> items;
}

/// The empty-answers brake: the whole run stops before writing anything.
@immutable
class ContactSyncStop {
  const ContactSyncStop({
    required this.side,
    required this.listed,
    this.expected,
  });

  final ContactSide side;
  final int listed;
  final int? expected;
}

/// A Restore: the contact the sync deleted made again (or found back), and
/// its partner found or made again, the two then paired.
@immutable
class ContactRestorePlan {
  const ContactRestorePlan({
    required this.binId,
    this.alreadyBack = false,
    this.googleName,
    this.graphId,
    this.googleRaw,
    this.graphRaw,
    this.googleDetails,
    this.graphDetails,
    this.title = '',
  });

  final int binId;

  /// Already back and paired: the bin row is dropped.
  final bool alreadyBack;

  /// Contacts already there, to pair rather than make.
  final String? googleName;
  final String? graphId;

  /// A full copy to make again ([googleRestoreBody], [graphRestoreBody]).
  final Map<String, Object?>? googleRaw;
  final Map<String, Object?>? graphRaw;

  /// Synced details to make again from ([googleCreateBody],
  /// [graphCreateBody]): the partner Ron deleted.
  final SyncedContact? googleDetails;
  final SyncedContact? graphDetails;

  final String title;
}

/// The numbers for the preview and the result.
@immutable
class ContactSyncCounts {
  const ContactSyncCounts({
    this.addToGoogle = 0,
    this.addToGraph = 0,
    this.pairUp = 0,
    this.paired = 0,
    this.changeGoogle = 0,
    this.changeGraph = 0,
    this.deleteGoogle = 0,
    this.deleteGraph = 0,
    this.needsALook = 0,
    this.differingPairs = 0,
    this.heldDeletions = 0,
    this.heldChanges = 0,
    this.restores = 0,
  });

  final int addToGoogle;
  final int addToGraph;

  /// Already in both, paired up this run.
  final int pairUp;

  /// Pairs there were before the run.
  final int paired;

  final int changeGoogle;
  final int changeGraph;
  final int deleteGoogle;
  final int deleteGraph;
  final int needsALook;

  /// New pairs with a detail that differs, left as it is on both sides.
  final int differingPairs;

  final int heldDeletions;
  final int heldChanges;
  final int restores;

  Map<String, Object?> toJson() => {
    'addToGoogle': addToGoogle,
    'addToGraph': addToGraph,
    'pairUp': pairUp,
    'paired': paired,
    'changeGoogle': changeGoogle,
    'changeGraph': changeGraph,
    'deleteGoogle': deleteGoogle,
    'deleteGraph': deleteGraph,
    'needsALook': needsALook,
    'differingPairs': differingPairs,
    'heldDeletions': heldDeletions,
    'heldChanges': heldChanges,
    'restores': restores,
  };
}

/// What one run does.
@immutable
class ContactSyncPlan {
  const ContactSyncPlan({
    this.stop,
    this.links = const [],
    this.reviews = const [],
    this.brakes = const [],
    this.reKeys = const {},
    this.graphTagMoves = const {},
    this.journalSettled = const [],
    this.binAlreadyBack = const [],
    this.binNotDue = const [],
    this.restores = const [],
    this.counts = const ContactSyncCounts(),
    this.googleCount = 0,
    this.graphCount = 0,
    this.googleGone = const {},
    this.graphGone = const {},
  });

  /// The empty-answers brake: when set, nothing else is planned.
  final ContactSyncStop? stop;

  /// Every row to save, add or remove, with its writes.
  final List<ContactLinkPlan> links;

  /// New Needs a look items.
  final List<ContactReviewItem> reviews;

  /// Brake questions raised this run.
  final List<ContactBrake> brakes;

  /// Gmail re-keys read this run, old name to new: every place that names
  /// an old name (reviews, the journal, the bin) takes the new one.
  final Map<String, String> reKeys;

  /// Outlook contacts whose hidden tag names a Gmail contact that was
  /// re-keyed: id to the new name, for [graphTagPatch] where it has one.
  final Map<String, String> graphTagMoves;

  /// Journal entries done with: their copy found and paired, or given up.
  final List<int> journalSettled;

  /// Bin rows to drop as Already back.
  final List<int> binAlreadyBack;

  /// Pending bin rows whose contact is no longer due to be deleted:
  /// dropped if it still exists, marked done if it does not.
  final List<int> binNotDue;

  final List<ContactRestorePlan> restores;
  final ContactSyncCounts counts;

  /// The contacts on each side after the read, before this run's writes,
  /// for the empty-answers brake. The runner adds what it creates and
  /// takes away what it deletes.
  final int googleCount;
  final int graphCount;

  /// Contacts gone this run: Needs a look items naming them are dropped.
  final Set<String> googleGone;
  final Set<String> graphGone;

  /// The normaliser this plan compared with, for the pair to store.
  int get normaliserVersion => contactNormaliserVersion;
}

// ---------------------------------------------------------------------------
// Absences.

/// Contacts the runner must look up before planning.
@immutable
class ContactChecks {
  const ContactChecks({this.google = const [], this.graph = const []});

  /// For `people.getBatchGet`: only NOT_FOUND is a deletion; a person
  /// under another name is a re-key; under the same name, still there.
  final List<String> google;

  /// For a GET by immutable id: not found, or found in Deleted Items, is a
  /// deletion; found in another folder, a move out of Contacts.
  final List<String> graph;
}

/// Which contacts with a row to check: those missing from a full listing,
/// and Outlook's `@removed`. A contact whose Gmail side the sync wrote in
/// the last hour is never judged by its absence, because Google's
/// listings lag behind writes. Gmail's own deleted entries need no check.
ContactChecks contactsToConfirm({
  Iterable<GoogleContact> google = const [],
  bool googleComplete = false,
  Iterable<GraphContact> graph = const [],
  bool graphComplete = false,
  Iterable<String> graphRemoved = const [],
  required Iterable<ContactLinkInput> links,
  required DateTime now,
}) {
  final googleSeen = {for (final c in google) c.resourceName};
  final graphSeen = {
    for (final c in graph)
      if (!graphRemoved.contains(c.id)) c.id,
  };
  final checkGoogle = <String>[];
  final checkGraph = <String>{};
  final removed = graphRemoved.toSet();
  for (final link in links) {
    final name = link.googleName;
    if (googleComplete && name != null && !googleSeen.contains(name)) {
      final written = link.googleWrittenAt;
      if (written == null || now.difference(written) >= contactGrace) {
        checkGoogle.add(name);
      }
    }
    final id = link.graphId;
    if (id == null) continue;
    if ((graphComplete && !graphSeen.contains(id)) || removed.contains(id)) {
      checkGraph.add(id);
    }
  }
  return ContactChecks(google: checkGoogle, graph: checkGraph.toList());
}

// ---------------------------------------------------------------------------
// One pair.

/// A detail changed on both sides to different values: the newer edit
/// won, and [losing] is the value that lost, from [losingSide].
@immutable
class ContactClash {
  const ContactClash(this.field, this.losingSide, this.losing);

  final ContactField field;
  final ContactSide losingSide;
  final Object? losing;
}

/// What one pair's comparison comes to.
@immutable
class ContactPairPlan {
  const ContactPairPlan({
    required this.toGoogle,
    required this.toGraph,
    required this.googleTarget,
    required this.graphTarget,
    required this.googleBase,
    required this.graphBase,
    this.googleReplaced = const {},
    this.differing = const [],
    this.clashes = const [],
    this.removes = false,
  });

  final Set<ContactField> toGoogle;
  final Set<ContactField> toGraph;
  final SyncedContact googleTarget;
  final SyncedContact graphTarget;

  /// Each side's base with every detail taken in that needs no write.
  final SyncedContact googleBase;
  final SyncedContact graphBase;

  final Map<ContactField, Map<String, String>> googleReplaced;

  /// Details left as they are on both sides, for Needs a look.
  final List<ContactField> differing;
  final List<ContactClash> clashes;

  /// A write removes or replaces an existing detail.
  final bool removes;

  bool get writes => toGoogle.isNotEmpty || toGraph.isNotEmpty;

  ContactWrite? get googleWrite => toGoogle.isEmpty
      ? null
      : ContactWrite(
          side: ContactSide.google,
          fields: toGoogle,
          target: googleTarget,
          replaced: googleReplaced,
        );

  ContactWrite? get graphWrite => toGraph.isEmpty
      ? null
      : ContactWrite(
          side: ContactSide.graph,
          fields: toGraph,
          target: graphTarget,
        );
}

/// One pair compared, detail by detail, with its bases.
///
/// A detail changed on one side (its raw value differs from that side's
/// base) is written to the other, unless the other already holds the same
/// (a fix to capitals still counts as a change). Changed on both sides to
/// different values, it clashes: the newer edit wins ([googleUpdatedAt]
/// against [graphUpdatedAt]; Gmail when neither is known). Lists merge
/// ([mergeContactList]). A birthday without a year never travels.
///
/// A [newPair] has no bases and is merged without overwriting: an empty
/// detail is filled from the other side, lists are joined, a year is
/// added to a year-less birthday on the same day, and a detail that
/// differs is left as it is on both sides and listed in
/// [ContactPairPlan.differing]. With [firstSync], a pair already made
/// never has a detail that differs overwritten either: a replacement or a
/// clash is listed instead, and lists are only joined.
///
/// [copyBack] is the change brake's Copy them back: a detail removed or
/// replaced on one side is written back from the other. [useSide] writes
/// each named detail from that side to the other, and [useValues] writes
/// its details to both: Ron's answers.
ContactPairPlan planPairedContact({
  required SyncedContact googleNow,
  SyncedContact? googleBase,
  required SyncedContact graphNow,
  SyncedContact? graphBase,
  DateTime? googleUpdatedAt,
  DateTime? graphUpdatedAt,
  required ContactNormaliser normaliser,
  bool newPair = false,
  bool firstSync = false,
  bool copyBack = false,
  Map<ContactField, ContactSide> useSide = const {},
  SyncedContact? useValues,
}) {
  final norm = normaliser;
  final none = SyncedContact.empty;
  final gBase = newPair ? none : googleBase ?? none;
  final hBase = newPair ? none : graphBase ?? none;
  var gTaken = gBase;
  var hTaken = hBase;
  var gTarget = googleNow;
  var hTarget = graphNow;
  final toGoogle = <ContactField>{};
  final toGraph = <ContactField>{};
  final replaced = <ContactField, Map<String, String>>{};
  final differing = <ContactField>[];
  final clashes = <ContactClash>[];
  var removes = false;

  final googleWins =
      graphUpdatedAt == null ||
      (googleUpdatedAt != null && !googleUpdatedAt.isBefore(graphUpdatedAt));

  bool canTravel(ContactField f, Object? v) =>
      !(f == ContactField.birthday && v is ContactBirthday && !v.hasYear);

  void adopt(ContactField f) {
    gTaken = gTaken.withValue(f, googleNow[f]);
    hTaken = hTaken.withValue(f, graphNow[f]);
  }

  void writeGraph(ContactField f, Object? v) {
    toGraph.add(f);
    hTarget = hTarget.withValue(f, v);
  }

  void writeGoogle(ContactField f, Object? v) {
    toGoogle.add(f);
    gTarget = gTarget.withValue(f, v);
  }

  for (final f in ContactField.values) {
    final gN = googleNow[f];
    final hN = graphNow[f];

    if (useValues != null && useValues.values.containsKey(f)) {
      final v = useValues[f];
      if (!norm.equivalent(f, v, gN) && canTravel(f, v)) writeGoogle(f, v);
      if (!norm.equivalent(f, v, hN) && canTravel(f, v)) writeGraph(f, v);
      continue;
    }
    if (useSide[f] case final ContactSide from) {
      final v = from == ContactSide.google ? gN : hN;
      final other = from == ContactSide.google ? hN : gN;
      if (norm.equivalent(f, v, other) || !canTravel(f, v)) {
        adopt(f);
      } else if (from == ContactSide.google) {
        writeGraph(f, v);
      } else {
        writeGoogle(f, v);
      }
      continue;
    }

    final gChanged = !rawEquals(gN, gBase[f]);
    final hChanged = !rawEquals(hN, hBase[f]);
    if (!newPair && !gChanged && !hChanged) continue;

    if (f.isList) {
      final merge = mergeContactList(
        f,
        google: (gN as List<String>?) ?? const [],
        googleBase: gBase.list(f),
        graph: (hN as List<String>?) ?? const [],
        graphBase: hBase.list(f),
        normaliser: norm,
        removals: !newPair && !firstSync && !copyBack,
      );
      final gList = gN ?? const <String>[];
      final hList = hN ?? const <String>[];
      final gMoves = !rawEquals(merge.google, gList);
      final hMoves = !rawEquals(merge.graph, hList);
      if (gMoves) {
        writeGoogle(f, merge.google);
        if (merge.googleReplaced.isNotEmpty) {
          replaced[f] = merge.googleReplaced;
        }
      }
      if (hMoves) writeGraph(f, merge.graph);
      if (!gMoves && !hMoves) adopt(f);
      removes = removes || merge.removes;
      continue;
    }

    if (newPair) {
      if (gN == null && hN == null) continue;
      if (norm.same(f, gN, hN)) {
        // A year-less birthday takes the other side's year.
        if (gN is ContactBirthday && hN is ContactBirthday) {
          if (!gN.hasYear && hN.hasYear) {
            writeGoogle(f, hN);
            continue;
          }
          if (gN.hasYear && !hN.hasYear) {
            writeGraph(f, gN);
            continue;
          }
        }
        adopt(f);
      } else if (gN == null) {
        canTravel(f, hN) ? writeGoogle(f, hN) : adopt(f);
      } else if (hN == null) {
        canTravel(f, gN) ? writeGraph(f, gN) : adopt(f);
      } else {
        differing.add(f);
        adopt(f);
      }
      continue;
    }

    if (gChanged != hChanged) {
      final fromGoogle = gChanged;
      final v = fromGoogle ? gN : hN;
      final other = fromGoogle ? hN : gN;
      if (norm.equivalent(f, v, other)) {
        adopt(f);
      } else if (!canTravel(f, v)) {
        if (!norm.same(f, v, other)) differing.add(f);
        adopt(f);
      } else if (copyBack && other != null) {
        // The side that lost a detail gets it back.
        fromGoogle ? writeGoogle(f, other) : writeGraph(f, other);
      } else if (firstSync && other != null) {
        differing.add(f);
        adopt(f);
      } else {
        fromGoogle ? writeGraph(f, v) : writeGoogle(f, v);
        if (other != null) removes = true;
      }
      continue;
    }

    // Changed on both sides.
    if (norm.same(f, gN, hN)) {
      adopt(f);
      continue;
    }
    if (firstSync) {
      differing.add(f);
      adopt(f);
      continue;
    }
    var winnerGoogle = googleWins;
    if (!canTravel(f, winnerGoogle ? gN : hN)) winnerGoogle = !winnerGoogle;
    if (!canTravel(f, winnerGoogle ? gN : hN)) {
      differing.add(f);
      adopt(f);
      continue;
    }
    if (winnerGoogle) {
      writeGraph(f, gN);
      clashes.add(ContactClash(f, ContactSide.graph, hN));
    } else {
      writeGoogle(f, hN);
      clashes.add(ContactClash(f, ContactSide.google, gN));
    }
    removes = true;
  }

  return ContactPairPlan(
    toGoogle: toGoogle,
    toGraph: toGraph,
    googleTarget: gTarget,
    graphTarget: hTarget,
    googleBase: gTaken,
    graphBase: hTaken,
    googleReplaced: replaced,
    differing: differing,
    clashes: clashes,
    removes: removes && !newPair,
  );
}

// ---------------------------------------------------------------------------
// The run.

/// The plan for one run. The first sync's preview is this same call with
/// [ContactSyncInput.firstSync] set, its writes not carried out.
ContactSyncPlan planContactSync(ContactSyncInput input) =>
    _Planner(input).plan();

/// Where a contact stands while the run is planned.
enum _Status { fresh, paired, held, orphan, leftAlone }

class _Row {
  _Row(this.input)
    : googleName = input.googleName,
      graphId = input.graphId,
      state = input.state,
      reason = input.reason;

  final ContactLinkInput input;
  String? googleName;
  String? graphId;
  ContactLinkState state;
  ContactHeldReason? reason;

  /// Planned this run: later steps leave it alone.
  bool done = false;

  /// A held row whose one contact goes through the new-contact rules
  /// again (a refused contact that changed, or Retry).
  bool reopened = false;

  int get id => input.linkId;
}

/// A contact whose partner went: deleted, unless a new contact on the
/// deleting side is its unique match.
class _Orphan {
  _Orphan(this.row, this.side, this.id, this.cause);

  final _Row row;

  /// The surviving contact's side.
  final ContactSide side;
  final String id;
  final ContactDeleteCause cause;
  bool rescued = false;
}

/// A plan with the Needs a look items that go or stay with it.
class _Planned {
  _Planned(this.plan, [this.reviews = const []]);

  ContactLinkPlan plan;
  List<ContactReviewItem> reviews;
}

class _Planner {
  _Planner(this.input) : norm = ContactNormaliser(region: input.phoneRegion);

  final ContactSyncInput input;
  final ContactNormaliser norm;

  final googleListed = <String, GoogleContact>{};
  final graphListed = <String, GraphContact>{};
  final googleGone = <String>{};
  final graphGone = <String>{};
  final graphMoved = <String>{};
  final reKeys = <String, String>{};
  final tagMoves = <String, String>{};

  final rows = <_Row>[];
  final googleRow = <String, _Row>{};
  final graphRow = <String, _Row>{};

  final googleStatus = <String, _Status>{};
  final graphStatus = <String, _Status>{};

  final orphans = <_Orphan>[];
  final planned = <_Planned>[];
  final otherReviews = <ContactReviewItem>[];
  final brakes = <ContactBrake>[];
  final journalSettled = <int>[];
  final binAlreadyBack = <int>{};
  final restores = <ContactRestorePlan>[];
  var pairUp = 0;
  var differingPairs = 0;

  ContactSyncPlan plan() {
    _read();
    final stop = _emptyAnswers();
    if (stop != null) {
      return ContactSyncPlan(
        stop: stop,
        googleCount: _googleCount(),
        graphCount: _graphCount(),
      );
    }
    _buildRows();
    _settleJournal();
    _answer();
    _restore();
    _rowsPass();
    _newContacts(ContactSide.google);
    _newContacts(ContactSide.graph);
    _orphansLeft();
    _brakes();
    return _result();
  }

  // ---- Reading.

  void _read() {
    final deleted = <String>{};
    final previous = <String, String>{};
    for (final c in input.google) {
      if (c.deleted) {
        deleted.add(c.resourceName);
        continue;
      }
      googleListed[c.resourceName] = c;
      for (final p in c.previousNames) {
        if (p != c.resourceName) previous[p] = c.resourceName;
      }
    }
    for (final c in input.graph) {
      graphListed[c.id] = c;
    }
    final googleBin = {
      for (final b in input.bin)
        if (b.side == ContactSide.google) b.contactId,
    };
    final graphBin = {
      for (final b in input.bin)
        if (b.side == ContactSide.graph) b.contactId,
    };
    // A deleted entry whose name another person lists among its previous
    // names was re-keyed or merged, not deleted; deletions the sync made
    // itself are its own echo.
    googleGone.addAll(
      {...input.googleGone, ...deleted}.where(
        (n) =>
            !previous.containsKey(n) &&
            !googleBin.contains(n) &&
            !googleListed.containsKey(n),
      ),
    );
    graphGone.addAll(
      input.graphGone.where(
        (id) => !graphBin.contains(id) && !graphListed.containsKey(id),
      ),
    );
    graphMoved.addAll(
      input.graphMovedOut.where((id) => !graphListed.containsKey(id)),
    );
    reKeys.addAll(input.googleReKeys);
    reKeys.addAll(previous);
    reKeys.removeWhere((old, now) => old == now);
  }

  bool _accepted(ContactSide side) => input.answers.any(
    (a) => a.kind == ContactAnswerKind.carryOn && a.side == side,
  );

  ContactSyncStop? _emptyAnswers() {
    final anyPaired = input.links.any(
      (l) => l.state == ContactLinkState.paired,
    );
    ContactSyncStop? check(
      ContactSide side,
      bool complete,
      int listed,
      int? expected,
    ) {
      if (!complete || _accepted(side)) return null;
      final tooFew =
          expected != null &&
          expected >= contactEmptyAnswerFloor &&
          listed * 2 < expected;
      if (tooFew || (listed == 0 && anyPaired)) {
        return ContactSyncStop(side: side, listed: listed, expected: expected);
      }
      return null;
    }

    return check(
          ContactSide.google,
          input.googleComplete,
          googleListed.length,
          input.expectedGoogle,
        ) ??
        check(
          ContactSide.graph,
          input.graphComplete,
          graphListed.length,
          input.expectedGraph,
        );
  }

  int _googleCount() {
    if (input.googleComplete) return googleListed.length;
    final known = {
      for (final l in input.links) ?l.googleName,
    };
    final added = googleListed.keys
        .where((n) => !known.contains(n) && !reKeys.containsValue(n))
        .length;
    final gone = googleGone.where(known.contains).length;
    return (input.expectedGoogle ?? 0) + added - gone;
  }

  int _graphCount() {
    if (input.graphComplete) return graphListed.length;
    final known = {
      for (final l in input.links) ?l.graphId,
    };
    final added = graphListed.keys.where((id) => !known.contains(id)).length;
    final gone = graphGone.where(known.contains).length;
    return (input.expectedGraph ?? 0) + added - gone;
  }

  // ---- Rows, re-keys and merges in Gmail.

  String _newName(String name) {
    var current = name;
    for (var i = 0; i < 8; i++) {
      final next = reKeys[current];
      if (next == null) return current;
      current = next;
    }
    return current;
  }

  void _buildRows() {
    rows.addAll(input.links.map(_Row.new));
    final groups = <String, List<_Row>>{};
    for (final row in rows) {
      final name = row.googleName;
      if (name == null) continue;
      final now = _newName(name);
      if (now != name) groups.putIfAbsent(now, () => []).add(row);
    }
    for (final row in rows) {
      final name = row.googleName;
      if (name != null && groups.containsKey(name)) groups[name]!.add(row);
    }
    for (final MapEntry(key: name, value: group) in groups.entries) {
      if (group.length == 1) {
        _rename(group.single, name);
        continue;
      }
      // Ron merged contacts in Gmail: the row whose Outlook contact shares
      // most with the merged one stays paired.
      final merged = googleListed[name]?.details ?? SyncedContact.empty;
      int shared(_Row row) {
        final other = _graphNow(row);
        return ContactField.values
            .where(
              (f) =>
                  merged[f] != null &&
                  other[f] != null &&
                  norm.same(f, merged[f], other[f]),
            )
            .length;
      }

      final ranked = [...group]
        ..sort((a, b) {
          final byShared = shared(b).compareTo(shared(a));
          if (byShared != 0) return byShared;
          final aHere = a.googleName == name ? 0 : 1;
          final bHere = b.googleName == name ? 0 : 1;
          if (aHere != bHere) return aHere.compareTo(bHere);
          return a.id.compareTo(b.id);
        });
      _rename(ranked.first, name);
      for (final loser in ranked.skip(1)) {
        loser
          ..googleName = null
          ..done = true;
        final graphId = loser.graphId;
        final title = _graphNow(loser).title;
        _add(
          ContactLinkPlan(
            linkId: loser.id,
            graphId: graphId,
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
            graphChangeKey: loser.input.graphChangeKey,
            graphBase: loser.input.graphDetails,
            title: title,
          ),
          [
            ContactReviewItem(
              kind: ContactReviewKind.mergedInGoogle,
              googleName: name,
              graphId: graphId,
              title: title,
            ),
          ],
        );
      }
    }
    for (final row in rows) {
      if (row.googleName case final String name) googleRow[name] = row;
      if (row.graphId case final String id) graphRow[id] = row;
      final status = row.state == ContactLinkState.paired
          ? _Status.paired
          : _Status.held;
      if (row.googleName case final String name) googleStatus[name] = status;
      if (row.graphId case final String id) graphStatus[id] = status;
    }
  }

  void _rename(_Row row, String name) {
    if (row.googleName == name) return;
    row.googleName = name;
    if (row.graphId case final String id) tagMoves[id] = name;
  }

  // ---- What each side holds now.

  bool _googleAlive(String? name) =>
      name != null &&
      !googleGone.contains(name) &&
      (googleListed.containsKey(name) || googleRow.containsKey(name));

  bool _graphAlive(String? id) =>
      id != null &&
      !graphGone.contains(id) &&
      (graphListed.containsKey(id) || graphRow.containsKey(id));

  SyncedContact _googleNow(_Row row) =>
      googleListed[row.googleName]?.details ?? row.input.googleDetails;

  SyncedContact _graphNow(_Row row) =>
      graphListed[row.graphId]?.details ?? row.input.graphDetails;

  SyncedContact _detailsOf(ContactSide side, String id) {
    if (side == ContactSide.google) {
      return googleListed[id]?.details ??
          googleRow[id]?.input.googleDetails ??
          SyncedContact.empty;
    }
    return graphListed[id]?.details ??
        graphRow[id]?.input.graphDetails ??
        SyncedContact.empty;
  }

  _Status? _status(ContactSide side, String id) =>
      side == ContactSide.google ? googleStatus[id] : graphStatus[id];

  void _setStatus(ContactSide side, String id, _Status status) {
    if (side == ContactSide.google) {
      googleStatus[id] = status;
    } else {
      graphStatus[id] = status;
    }
  }

  _Row? _rowOf(ContactSide side, String id) =>
      side == ContactSide.google ? googleRow[id] : graphRow[id];

  void _add(
    ContactLinkPlan plan, [
    List<ContactReviewItem> reviews = const [],
  ]) {
    planned.add(_Planned(plan, [...reviews]));
  }

  // ---- Interrupted creates.

  void _settleJournal() {
    for (final entry in input.journal) {
      final sourceSide = entry.side.other;
      final source = sourceSide == ContactSide.google
          ? _newName(entry.sourceId)
          : entry.sourceId;
      final String? copy;
      if (entry.side == ContactSide.google) {
        copy = googleListed.values
            .firstWhereOrNull(
              (c) =>
                  c.tag == entry.sourceId &&
                  !googleRow.containsKey(c.resourceName) &&
                  googleStatus[c.resourceName] == null,
            )
            ?.resourceName;
      } else {
        copy = graphListed.values
            .firstWhereOrNull(
              (c) =>
                  (c.tag == source || c.tag == entry.sourceId) &&
                  !graphRow.containsKey(c.id) &&
                  graphStatus[c.id] == null,
            )
            ?.id;
      }
      final sourceAlive = sourceSide == ContactSide.google
          ? _googleAlive(source)
          : _graphAlive(source);
      if (copy != null) {
        journalSettled.add(entry.opId);
        if (sourceAlive) {
          final g = entry.side == ContactSide.google ? copy : source;
          final h = entry.side == ContactSide.google ? source : copy;
          final row = _rowOf(sourceSide, source);
          _pairNew(g, h, linkId: row?.id);
          row?.done = true;
        } else {
          _strayCopy(entry.side, copy, source);
        }
        continue;
      }
      if (sourceAlive &&
          input.now.difference(entry.startedAt) < contactGrace) {
        // Not in the listing yet, which may only be Google's lag: the
        // source waits rather than be copied twice.
        _setStatus(sourceSide, source, _Status.leftAlone);
        _rowOf(sourceSide, source)?.done = true;
        continue;
      }
      journalSettled.add(entry.opId);
    }
  }

  /// A copy whose create was interrupted, found after its source went: it
  /// is deleted like any partner of a deleted contact.
  void _strayCopy(ContactSide side, String copy, String source) {
    _setStatus(side, copy, _Status.held);
    final details = _detailsOf(side, copy);
    if (input.firstSync) {
      _add(
        ContactLinkPlan(
          googleName: side == ContactSide.google ? copy : null,
          graphId: side == ContactSide.graph ? copy : null,
          state: ContactLinkState.held,
          reason: ContactHeldReason.kept,
          title: details.title,
        ),
        [
          ContactReviewItem(
            kind: ContactReviewKind.kept,
            reason: ContactReviewReason.firstSync,
            googleName: side == ContactSide.google ? copy : null,
            graphId: side == ContactSide.graph ? copy : null,
            goneSide: side.other,
            title: details.title,
          ),
        ],
      );
      return;
    }
    _add(
      ContactLinkPlan(
        googleName: side == ContactSide.google ? copy : null,
        graphId: side == ContactSide.graph ? copy : null,
        removeRow: true,
        title: details.title,
        delete: ContactDelete(
          side: side,
          contactId: copy,
          cause: side == ContactSide.google
              ? ContactDeleteCause.goneFromGraph
              : ContactDeleteCause.deletedInGoogle,
          expectedVersion: side == ContactSide.google
              ? googleListed[copy]?.etag
              : graphListed[copy]?.changeKey,
          title: details.title,
          partnerId: source,
        ),
      ),
    );
  }

  // ---- Ron's answers.

  void _answer() {
    for (final answer in input.answers) {
      final g = answer.googleName == null ? null : _newName(answer.googleName!);
      final h = answer.graphId;
      switch (answer.kind) {
        case ContactAnswerKind.samePerson:
          if (!_googleAlive(g) || !_graphAlive(h)) continue;
          final rg = googleRow[g];
          final rh = graphRow[h];
          bool pairedElsewhere(_Row? r) =>
              r != null &&
              r.state == ContactLinkState.paired &&
              (r.googleName != g || r.graphId != h);
          if (pairedElsewhere(rg) || pairedElsewhere(rh)) continue;
          if (rg?.done == true || rh?.done == true) continue;
          final keep = rg ?? rh;
          final other = rg != null && rh != null && rg != rh ? rh : null;
          _pairNew(
            g!,
            h!,
            linkId: keep?.id,
            alsoRemove: [?other?.id],
            fromAnswer: true,
          );
          rg?.done = true;
          rh?.done = true;
        case ContactAnswerKind.copyAnyway:
          for (final (side, id) in _named(g, h)) {
            final row = _rowOf(side, id);
            if (row?.done == true || row?.state == ContactLinkState.paired) {
              continue;
            }
            _copy(side, id, linkId: row?.id, fromAnswer: true);
            row?.done = true;
          }
        case ContactAnswerKind.leaveOut || ContactAnswerKind.keepOnlyHere:
          for (final (side, id) in _named(g, h)) {
            final row = _rowOf(side, id);
            if (row?.done == true) continue;
            if (row != null && row.state == ContactLinkState.paired) continue;
            _hold(side, id, ContactHeldReason.leftOut, linkId: row?.id);
            row?.done = true;
          }
        case ContactAnswerKind.useGoogle ||
            ContactAnswerKind.useGraph ||
            ContactAnswerKind.useValue:
          final row = g != null ? googleRow[g] : graphRow[h];
          if (row == null ||
              row.done ||
              row.state != ContactLinkState.paired ||
              !_googleAlive(row.googleName) ||
              !_graphAlive(row.graphId)) {
            continue;
          }
          if (answer.kind == ContactAnswerKind.useValue) {
            _pairSync(
              row,
              fromAnswer: true,
              useValues: SyncedContact.fromJson(answer.value),
            );
          } else {
            final from = answer.kind == ContactAnswerKind.useGoogle
                ? ContactSide.google
                : ContactSide.graph;
            final fields = answer.fields.isNotEmpty
                ? answer.fields
                : ContactField.values.where(
                    (f) => !norm.equivalent(
                      f,
                      _googleNow(row)[f],
                      _graphNow(row)[f],
                    ),
                  );
            _pairSync(
              row,
              fromAnswer: true,
              useSide: {for (final f in fields) f: from},
            );
          }
        case ContactAnswerKind.copyBack:
          for (final (side, id) in _named(g, h)) {
            final row = _rowOf(side, id);
            if (row == null || row.done) continue;
            if (row.state == ContactLinkState.paired) continue;
            _copy(side, id, linkId: row.id, fromAnswer: true);
            row.done = true;
          }
        case ContactAnswerKind.deleteHereToo:
          for (final (side, id) in _named(g, h)) {
            final row = _rowOf(side, id);
            if (row == null || row.done) continue;
            if (row.state == ContactLinkState.paired) continue;
            _deleteHeld(row, side, id, ContactDeleteCause.answered);
          }
        case ContactAnswerKind.deleteHeld:
          for (final row in rows) {
            if (row.done || row.reason != ContactHeldReason.deletionBrake) {
              continue;
            }
            final side = row.googleName != null
                ? ContactSide.google
                : ContactSide.graph;
            final id = row.googleName ?? row.graphId;
            if (id == null) continue;
            _deleteHeld(
              row,
              side,
              id,
              side == ContactSide.google
                  ? ContactDeleteCause.goneFromGraph
                  : ContactDeleteCause.deletedInGoogle,
            );
          }
        case ContactAnswerKind.keepHeld:
          for (final row in rows) {
            if (row.done || row.reason != ContactHeldReason.deletionBrake) {
              continue;
            }
            final side = row.googleName != null
                ? ContactSide.google
                : ContactSide.graph;
            final id = row.googleName ?? row.graphId;
            if (id == null) continue;
            row.done = true;
            if (!(side == ContactSide.google
                ? _googleAlive(id)
                : _graphAlive(id))) {
              _add(ContactLinkPlan(linkId: row.id, removeRow: true));
              continue;
            }
            _keep(row, side, id, ContactReviewReason.notDeleted);
          }
        case ContactAnswerKind.applyHeld || ContactAnswerKind.copyHeldBack:
          for (final row in rows) {
            if (row.done || row.reason != ContactHeldReason.changeBrake) {
              continue;
            }
            if (!_googleAlive(row.googleName) || !_graphAlive(row.graphId)) {
              continue;
            }
            _pairSync(
              row,
              fromAnswer: true,
              copyBack: answer.kind == ContactAnswerKind.copyHeldBack,
            );
          }
        case ContactAnswerKind.retry:
          for (final (side, id) in _named(g, h)) {
            final row = _rowOf(side, id);
            if (row == null || row.done) continue;
            if (row.reason != ContactHeldReason.refused) continue;
            _retry(row, fromAnswer: true);
          }
        case ContactAnswerKind.carryOn:
          break;
      }
    }
  }

  List<(ContactSide, String)> _named(String? g, String? h) => [
    if (g != null && _googleAlive(g)) (ContactSide.google, g),
    if (h != null && _graphAlive(h)) (ContactSide.graph, h),
  ];

  void _retry(_Row row, {bool fromAnswer = false}) {
    if (row.googleName != null && row.graphId != null) {
      _pairSync(row, fromAnswer: fromAnswer);
    } else {
      row.reopened = true;
      final id = row.googleName ?? row.graphId!;
      _setStatus(
        row.googleName != null ? ContactSide.google : ContactSide.graph,
        id,
        _Status.fresh,
      );
    }
  }

  // ---- Restore.

  void _restore() {
    for (final bin in input.bin) {
      if (!bin.restore || !bin.done) continue;
      final side = bin.side;
      final other = side.other;
      final contactId = side == ContactSide.google
          ? _newName(bin.contactId)
          : bin.contactId;
      final partnerId = bin.partnerId == null
          ? null
          : other == ContactSide.google
          ? _newName(bin.partnerId!)
          : bin.partnerId;
      final raw = bin.raw ?? const <String, Object?>{};
      final details = side == ContactSide.google
          ? syncedFromPerson(raw)
          : syncedFromGraph(raw);
      final partnerDetails = SyncedContact.fromJson(bin.partnerBase);
      final here = _findBack(side, contactId, partnerId, details);
      final there = _findBack(other, partnerId, contactId, partnerDetails);
      final hereStatus = here == null ? null : _status(side, here);
      if (here != null && hereStatus == _Status.paired) {
        restores.add(
          ContactRestorePlan(binId: bin.binId, alreadyBack: true),
        );
        continue;
      }
      final thereFree =
          there != null &&
          (_status(other, there) == null ||
              _status(other, there) == _Status.fresh);
      final g = side == ContactSide.google ? here : (thereFree ? there : null);
      final h = side == ContactSide.graph ? here : (thereFree ? there : null);
      if (g != null && h != null) {
        // Both back already, by Ron's hand: they are only paired.
        _pairNew(g, h, fromAnswer: true);
        restores.add(
          ContactRestorePlan(binId: bin.binId, alreadyBack: true),
        );
        continue;
      }
      for (final (s, id) in [
        if (g != null) (ContactSide.google, g),
        if (h != null) (ContactSide.graph, h),
      ]) {
        _setStatus(s, id, _Status.paired);
        _rowOf(s, id)?.done = true;
      }
      final partner = partnerDetails.isEmpty ? null : partnerDetails;
      restores.add(
        ContactRestorePlan(
          binId: bin.binId,
          googleName: g,
          graphId: h,
          googleRaw: side == ContactSide.google && g == null ? raw : null,
          graphRaw: side == ContactSide.graph && h == null ? raw : null,
          googleDetails: other == ContactSide.google && g == null
              ? partner
              : null,
          graphDetails: other == ContactSide.graph && h == null
              ? partner
              : null,
          title: bin.title,
        ),
      );
    }
  }

  /// A contact the sync deleted, if it is back: by its own id, by a tag
  /// naming its partner, or by an email or mobile that only it has.
  String? _findBack(
    ContactSide side,
    String? id,
    String? partnerId,
    SyncedContact details,
  ) {
    if (side == ContactSide.google) {
      if (id != null && _googleAlive(id)) return id;
      if (partnerId != null) {
        final tagged = googleListed.values.firstWhereOrNull(
          (c) => c.tag == partnerId,
        );
        if (tagged != null) return tagged.resourceName;
      }
    } else {
      if (id != null && _graphAlive(id)) return id;
      if (partnerId != null) {
        final tagged = graphListed.values.firstWhereOrNull(
          (c) => c.tag == partnerId,
        );
        if (tagged != null) return tagged.id;
      }
    }
    for (final (keys, index) in [
      (_emailKeys(details), _emailIndex),
      (_mobileKeys(details), _mobileIndex),
    ]) {
      for (final key in keys) {
        final owners = [
          for (final o in index[key] ?? const <(ContactSide, String)>[])
            if (o.$1 == side) o.$2,
        ];
        if (owners.length == 1) return owners.single;
      }
    }
    return null;
  }

  // ---- Rows.

  void _rowsPass() {
    for (final row in rows) {
      if (row.done || row.reopened) continue;
      final g = row.googleName;
      final h = row.graphId;
      if (row.state == ContactLinkState.paired) {
        _paired(row);
        continue;
      }
      switch (row.reason) {
        case ContactHeldReason.movedOut:
          if (googleGone.contains(g) && graphListed.containsKey(h)) {
            // Its Gmail partner went while it was away: it comes back as
            // a contact of its own.
            row
              ..googleName = null
              ..reopened = true;
            _setStatus(ContactSide.graph, h!, _Status.fresh);
          } else if (graphListed.containsKey(h) ||
              googleGone.contains(g) ||
              graphGone.contains(h)) {
            _paired(row);
          }
        case ContactHeldReason.changeBrake:
          if (googleGone.contains(g) || graphGone.contains(h)) _paired(row);
        case ContactHeldReason.refused:
          if (!_heldAlive(row)) {
            _add(ContactLinkPlan(linkId: row.id, removeRow: true));
          } else if (_changed(row)) {
            _retry(row);
          }
        default:
          if (!_heldAlive(row)) {
            _add(ContactLinkPlan(linkId: row.id, removeRow: true));
          }
      }
    }
  }

  /// Whether every contact a held row names is still there.
  bool _heldAlive(_Row row) =>
      (row.googleName == null || _googleAlive(row.googleName)) &&
      (row.graphId == null || _graphAlive(row.graphId)) &&
      (row.googleName != null || row.graphId != null);

  /// Whether a contact of the row was listed with another version than the
  /// row's.
  bool _changed(_Row row) {
    final g = googleListed[row.googleName];
    final h = graphListed[row.graphId];
    return (g != null && g.etag != row.input.googleEtag) ||
        (h != null && h.changeKey != row.input.graphChangeKey);
  }

  void _paired(_Row row) {
    final g = row.googleName;
    final h = row.graphId;
    final gGone = g == null || googleGone.contains(g);
    final hGone = h == null || graphGone.contains(h);
    row.done = true;
    if (gGone && hGone) {
      _add(ContactLinkPlan(linkId: row.id, removeRow: true));
      return;
    }
    if (graphMoved.contains(h)) {
      if (gGone) {
        _add(ContactLinkPlan(linkId: row.id, removeRow: true));
        return;
      }
      _add(
        ContactLinkPlan(
          linkId: row.id,
          googleName: g,
          graphId: h,
          state: ContactLinkState.held,
          reason: ContactHeldReason.movedOut,
          googleEtag: row.input.googleEtag,
          graphChangeKey: row.input.graphChangeKey,
          googleBase: row.input.googleDetails,
          graphBase: row.input.graphDetails,
          title: _googleNow(row).title,
        ),
      );
      _setStatus(ContactSide.google, g, _Status.held);
      return;
    }
    if (gGone) {
      orphans.add(
        _Orphan(row, ContactSide.graph, h!, ContactDeleteCause.deletedInGoogle),
      );
      _setStatus(ContactSide.graph, h, _Status.orphan);
      return;
    }
    if (hGone) {
      orphans.add(
        _Orphan(row, ContactSide.google, g, ContactDeleteCause.goneFromGraph),
      );
      _setStatus(ContactSide.google, g, _Status.orphan);
      return;
    }
    _pairSync(row);
  }

  void _pairSync(
    _Row row, {
    bool fromAnswer = false,
    bool copyBack = false,
    Map<ContactField, ContactSide> useSide = const {},
    SyncedContact? useValues,
  }) {
    row.done = true;
    final g = row.googleName!;
    final h = row.graphId!;
    final gc = googleListed[g];
    final hc = graphListed[h];
    _setStatus(ContactSide.google, g, _Status.paired);
    _setStatus(ContactSide.graph, h, _Status.paired);
    final wasPaired = row.input.state == ContactLinkState.paired;
    if (gc == null &&
        hc == null &&
        wasPaired &&
        !fromAnswer &&
        useSide.isEmpty &&
        useValues == null) {
      return;
    }
    final googleNow = _googleNow(row);
    final graphNow = _graphNow(row);
    final pair = planPairedContact(
      googleNow: googleNow,
      googleBase: row.input.googleDetails,
      graphNow: graphNow,
      graphBase: row.input.graphDetails,
      googleUpdatedAt: gc?.updatedAt,
      graphUpdatedAt: hc?.updatedAt,
      normaliser: norm,
      firstSync: input.firstSync,
      copyBack: copyBack,
      useSide: useSide,
      useValues: useValues,
    );
    final title = googleNow.title.isNotEmpty ? googleNow.title : graphNow.title;
    _add(
      ContactLinkPlan(
        linkId: row.id,
        googleName: g,
        graphId: h,
        googleEtag: gc?.etag ?? row.input.googleEtag,
        graphChangeKey: hc?.changeKey ?? row.input.graphChangeKey,
        googleBase: pair.googleBase,
        graphBase: pair.graphBase,
        googleNow: googleNow,
        graphNow: graphNow,
        googleWrite: pair.googleWrite,
        graphWrite: pair.graphWrite,
        fromAnswer: fromAnswer,
        removes: pair.removes,
        title: title,
      ),
      _pairReviews(pair, g, h, title, googleNow, graphNow),
    );
  }

  List<ContactReviewItem> _pairReviews(
    ContactPairPlan pair,
    String g,
    String h,
    String title,
    SyncedContact googleNow,
    SyncedContact graphNow,
  ) => [
    if (pair.differing.isNotEmpty)
      ContactReviewItem(
        kind: ContactReviewKind.differing,
        googleName: g,
        graphId: h,
        fields: pair.differing,
        googleValues: googleNow.withFieldsFrom(
          SyncedContact.empty,
          ContactField.values.whereNot(pair.differing.contains),
        ),
        graphValues: graphNow.withFieldsFrom(
          SyncedContact.empty,
          ContactField.values.whereNot(pair.differing.contains),
        ),
        title: title,
      ),
    for (final clash in pair.clashes)
      ContactReviewItem(
        kind: ContactReviewKind.clash,
        googleName: g,
        graphId: h,
        fields: [clash.field],
        losing: SyncedContact({clash.field: clash.losing}),
        losingSide: clash.losingSide,
        title: title,
      ),
  ];

  /// Two contacts paired this run, merged without overwriting.
  void _pairNew(
    String g,
    String h, {
    int? linkId,
    List<int> alsoRemove = const [],
    bool fromAnswer = false,
  }) {
    final gc = googleListed[g];
    final hc = graphListed[h];
    final googleNow = _detailsOf(ContactSide.google, g);
    final graphNow = _detailsOf(ContactSide.graph, h);
    final pair = planPairedContact(
      googleNow: googleNow,
      graphNow: graphNow,
      normaliser: norm,
      newPair: true,
    );
    _setStatus(ContactSide.google, g, _Status.paired);
    _setStatus(ContactSide.graph, h, _Status.paired);
    googleRow[g]?.done = true;
    graphRow[h]?.done = true;
    pairUp++;
    if (pair.differing.isNotEmpty) differingPairs++;
    _backFromBin(ContactSide.google, g);
    _backFromBin(ContactSide.graph, h);
    final title = googleNow.title.isNotEmpty ? googleNow.title : graphNow.title;
    _add(
      ContactLinkPlan(
        linkId: linkId,
        alsoRemove: alsoRemove,
        googleName: g,
        graphId: h,
        googleEtag: gc?.etag ?? googleRow[g]?.input.googleEtag,
        graphChangeKey: hc?.changeKey ?? graphRow[h]?.input.graphChangeKey,
        googleBase: pair.googleBase,
        graphBase: pair.graphBase,
        googleNow: googleNow,
        graphNow: graphNow,
        googleWrite: pair.googleWrite,
        graphWrite: pair.graphWrite,
        newPair: true,
        fromAnswer: fromAnswer,
        title: title,
      ),
      _pairReviews(pair, g, h, title, googleNow, graphNow),
    );
  }

  /// A contact the sync deleted that Ron brought back himself, now being
  /// paired again: its bin row is Already back.
  void _backFromBin(ContactSide side, String id) {
    for (final b in input.bin) {
      if (b.side == side && b.contactId == id) binAlreadyBack.add(b.binId);
    }
  }

  /// A contact copied to the other side.
  void _copy(
    ContactSide side,
    String id, {
    int? linkId,
    bool fromAnswer = false,
  }) {
    final details = _detailsOf(side, id);
    _setStatus(side, id, _Status.paired);
    _backFromBin(side, id);
    _add(
      ContactLinkPlan(
        linkId: linkId,
        googleName: side == ContactSide.google ? id : null,
        graphId: side == ContactSide.graph ? id : null,
        googleEtag: side == ContactSide.google
            ? googleListed[id]?.etag ?? googleRow[id]?.input.googleEtag
            : null,
        graphChangeKey: side == ContactSide.graph
            ? graphListed[id]?.changeKey ?? graphRow[id]?.input.graphChangeKey
            : null,
        googleBase: side == ContactSide.google ? details : null,
        graphBase: side == ContactSide.graph ? details : null,
        googleNow: side == ContactSide.google ? details : null,
        graphNow: side == ContactSide.graph ? details : null,
        create: ContactCreate(
          side: side.other,
          sourceId: id,
          details: details,
        ),
        fromAnswer: fromAnswer,
        title: details.title,
      ),
    );
  }

  void _hold(
    ContactSide side,
    String id,
    ContactHeldReason reason, {
    int? linkId,
    List<ContactReviewItem> reviews = const [],
  }) {
    final details = _detailsOf(side, id);
    _setStatus(side, id, _Status.held);
    _add(
      ContactLinkPlan(
        linkId: linkId,
        googleName: side == ContactSide.google ? id : null,
        graphId: side == ContactSide.graph ? id : null,
        state: ContactLinkState.held,
        reason: reason,
        googleEtag: side == ContactSide.google
            ? googleListed[id]?.etag ?? googleRow[id]?.input.googleEtag
            : null,
        graphChangeKey: side == ContactSide.graph
            ? graphListed[id]?.changeKey ?? graphRow[id]?.input.graphChangeKey
            : null,
        googleBase: side == ContactSide.google
            ? googleRow[id]?.input.googleDetails
            : null,
        graphBase: side == ContactSide.graph
            ? graphRow[id]?.input.graphDetails
            : null,
        title: details.title,
      ),
      reviews,
    );
  }

  /// A held contact deleted: Ron's Delete them, or Delete it here too.
  void _deleteHeld(
    _Row row,
    ContactSide side,
    String id,
    ContactDeleteCause cause,
  ) {
    row.done = true;
    final alive = side == ContactSide.google
        ? _googleAlive(id)
        : _graphAlive(id);
    if (!alive) {
      _add(ContactLinkPlan(linkId: row.id, removeRow: true));
      return;
    }
    final details = _detailsOf(side, id);
    _setStatus(side, id, _Status.held);
    _add(
      ContactLinkPlan(
        linkId: row.id,
        googleName: side == ContactSide.google ? id : null,
        graphId: side == ContactSide.graph ? id : null,
        removeRow: true,
        fromAnswer: true,
        title: details.title,
        delete: ContactDelete(
          side: side,
          contactId: id,
          cause: cause,
          expectedVersion: side == ContactSide.google
              ? googleListed[id]?.etag ?? row.input.googleEtag
              : graphListed[id]?.changeKey ?? row.input.graphChangeKey,
          title: details.title,
          partnerId: side == ContactSide.google
              ? row.input.graphId
              : row.input.googleName,
          partnerBase: side == ContactSide.google
              ? row.input.graphDetails
              : row.input.googleDetails,
        ),
      ),
    );
  }

  /// A surviving copy held as kept, its gone partner's id cleared.
  void _keep(
    _Row row,
    ContactSide side,
    String id,
    ContactReviewReason why,
  ) {
    final details = _detailsOf(side, id);
    _setStatus(side, id, _Status.held);
    _add(
      ContactLinkPlan(
        linkId: row.id,
        googleName: side == ContactSide.google ? id : null,
        graphId: side == ContactSide.graph ? id : null,
        state: ContactLinkState.held,
        reason: ContactHeldReason.kept,
        googleEtag: side == ContactSide.google ? row.input.googleEtag : null,
        graphChangeKey: side == ContactSide.graph
            ? row.input.graphChangeKey
            : null,
        googleBase: side == ContactSide.google
            ? row.input.googleDetails
            : null,
        graphBase: side == ContactSide.graph ? row.input.graphDetails : null,
        title: details.title,
      ),
      [
        ContactReviewItem(
          kind: ContactReviewKind.kept,
          reason: why,
          googleName: side == ContactSide.google ? id : null,
          graphId: side == ContactSide.graph ? id : null,
          goneSide: side.other,
          title: details.title,
        ),
      ],
    );
  }

  // ---- New contacts.

  late final Map<String, List<(ContactSide, String)>> _emailIndex =
      _index(_emailKeys);
  late final Map<String, List<(ContactSide, String)>> _mobileIndex =
      _index(_mobileKeys);
  late final Map<String, List<(ContactSide, String)>> _nameIndex = _index(
    (d) => [?ContactNormaliser.fullNameKey(d.name)],
  );

  Iterable<String> _emailKeys(SyncedContact d) => {
    for (final e in d.list(ContactField.emails))
      ?norm.itemKey(ContactField.emails, e),
  };

  Iterable<String> _mobileKeys(SyncedContact d) => [
    ?norm.phoneKey(d.text(ContactField.mobile)),
  ];

  /// Every contact still there on either side, by [keys].
  Map<String, List<(ContactSide, String)>> _index(
    Iterable<String> Function(SyncedContact) keys,
  ) {
    final index = <String, List<(ContactSide, String)>>{};
    void add(ContactSide side, String id) {
      for (final k in keys(_detailsOf(side, id))) {
        index.putIfAbsent(k, () => []).add((side, id));
      }
    }

    for (final name in {...googleListed.keys, ...googleRow.keys}) {
      if (_googleAlive(name)) add(ContactSide.google, name);
    }
    for (final id in {...graphListed.keys, ...graphRow.keys}) {
      if (_graphAlive(id)) add(ContactSide.graph, id);
    }
    return index;
  }

  void _newContacts(ContactSide side) {
    final ids = side == ContactSide.google
        ? googleListed.keys.toList()
        : graphListed.keys.toList();
    for (final row in rows) {
      if (!row.reopened || row.done) continue;
      final id = side == ContactSide.google ? row.googleName : row.graphId;
      if (id != null && !ids.contains(id)) ids.add(id);
    }
    for (final id in ids) {
      final row = _rowOf(side, id);
      if (row != null && (!row.reopened || row.done)) continue;
      final status = _status(side, id);
      if (status != null && status != _Status.fresh) continue;
      if (side == ContactSide.google ? !_googleAlive(id) : !_graphAlive(id)) {
        continue;
      }
      _place(side, id, row);
    }
  }

  /// A contact with no row: paired with its match, put under Needs a
  /// look, or copied to the other side.
  void _place(ContactSide side, String id, _Row? row) {
    final other = side.other;
    final details = _detailsOf(side, id);
    final tag = side == ContactSide.google
        ? googleListed[id]?.tag
        : graphListed[id]?.tag;
    row?.done = true;

    // A hidden tag naming a contact on the other side.
    if (tag != null) {
      final target = other == ContactSide.google ? _newName(tag) : tag;
      final alive = other == ContactSide.google
          ? _googleAlive(target)
          : _graphAlive(target);
      if (alive) {
        final status = _status(other, target);
        if (status == null ||
            status == _Status.fresh ||
            status == _Status.orphan) {
          _pair(side, id, target, row);
        } else {
          _review(
            side,
            id,
            row,
            [target],
            ContactReviewReason.taggedPaired,
          );
        }
        return;
      }
    }

    // A unique email address, else a unique mobile.
    for (final (keys, index) in [
      (_emailKeys(details), _emailIndex),
      (_mobileKeys(details), _mobileIndex),
    ]) {
      final unique = <String>{};
      final shared = <String>{};
      for (final key in keys) {
        final owners = (index[key] ?? const [])
            .where((o) => !(o.$1 == side && o.$2 == id))
            .toList();
        final there = owners.where((o) => o.$1 == other).map((o) => o.$2);
        final here = owners.where((o) => o.$1 == side);
        if (there.isEmpty) continue;
        if (there.length == 1 && here.isEmpty) {
          unique.add(there.single);
        } else {
          shared.addAll(there);
        }
      }
      if (unique.length == 1) {
        final match = unique.single;
        final status = _status(other, match);
        final agree = ContactNormaliser.namesAgree(
          details.name,
          _detailsOf(other, match).name,
        );
        if (!agree) {
          // A partner due to be deleted is not offered: it goes.
          if (status == _Status.orphan) break;
          _review(side, id, row, [match], ContactReviewReason.namesDisagree);
          return;
        }
        if (status == null ||
            status == _Status.fresh ||
            status == _Status.orphan) {
          _pair(side, id, match, row);
        } else {
          _review(
            side,
            id,
            row,
            [match],
            status == _Status.paired
                ? ContactReviewReason.matchPaired
                : ContactReviewReason.matchHeld,
          );
        }
        return;
      }
      final offered = [
        for (final c in unique.length > 1 ? unique : shared)
          if (_status(other, c) != _Status.orphan) c,
      ];
      if (offered.isNotEmpty) {
        _review(
          side,
          id,
          row,
          offered,
          unique.length > 1
              ? ContactReviewReason.severalMatches
              : ContactReviewReason.sharedAddress,
        );
        return;
      }
    }

    // The same full name and nothing that pairs them.
    final nameKey = ContactNormaliser.fullNameKey(details.name);
    if (nameKey != null) {
      final same = [
        for (final o in _nameIndex[nameKey] ?? const <(ContactSide, String)>[])
          if (o.$1 == other && _status(other, o.$2) != _Status.orphan) o.$2,
      ];
      if (same.isNotEmpty) {
        _review(side, id, row, same, ContactReviewReason.sameName);
        return;
      }
    }

    _copy(side, id, linkId: row?.id);
  }

  void _pair(ContactSide side, String id, String match, _Row? row) {
    final g = side == ContactSide.google ? id : match;
    final h = side == ContactSide.google ? match : id;
    final orphan = orphans.firstWhereOrNull(
      (o) => !o.rescued && o.side == side.other && o.id == match,
    );
    final matchRow = orphan?.row ?? _rowOf(side.other, match);
    orphan?.rescued = true;
    _pairNew(
      g,
      h,
      linkId: matchRow?.id ?? row?.id,
      alsoRemove: [
        if (matchRow != null && row != null && matchRow.id != row.id) row.id,
      ],
    );
    matchRow?.done = true;
  }

  void _review(
    ContactSide side,
    String id,
    _Row? row,
    List<String> candidates,
    ContactReviewReason reason,
  ) {
    final other = side.other;
    final details = _detailsOf(side, id);
    final statuses = [for (final c in candidates) _status(other, c)];
    final review = ContactReviewItem(
      kind: ContactReviewKind.newContact,
      reason: reason,
      subjectSide: side,
      googleName: side == ContactSide.google ? id : null,
      graphId: side == ContactSide.graph ? id : null,
      candidates: candidates,
      samePersonOffered: statuses.any((s) => s != _Status.paired),
      title: details.title,
      candidateTitles: [
        for (final c in candidates) _detailsOf(other, c).title,
      ],
    );
    _hold(
      side,
      id,
      ContactHeldReason.waiting,
      linkId: row?.id,
      reviews: [review],
    );
    // A candidate that is new too waits under the same item.
    for (final c in candidates) {
      final status = _status(other, c);
      if (status != null && status != _Status.fresh) continue;
      final candidateRow = _rowOf(other, c);
      if (candidateRow != null && !candidateRow.reopened) continue;
      _hold(other, c, ContactHeldReason.waiting, linkId: candidateRow?.id);
      candidateRow?.done = true;
    }
  }

  // ---- Deletions.

  void _orphansLeft() {
    for (final orphan in orphans) {
      if (orphan.rescued) continue;
      final row = orphan.row;
      final side = orphan.side;
      final id = orphan.id;
      final listedVersion = side == ContactSide.google
          ? googleListed[id]?.etag
          : graphListed[id]?.changeKey;
      final storedVersion = side == ContactSide.google
          ? row.input.googleEtag
          : row.input.graphChangeKey;
      if (input.firstSync) {
        _keep(row, side, id, ContactReviewReason.firstSync);
        continue;
      }
      if (listedVersion != null &&
          storedVersion != null &&
          listedVersion != storedVersion) {
        _keep(row, side, id, ContactReviewReason.changedSince);
        continue;
      }
      final details = _detailsOf(side, id);
      _add(
        ContactLinkPlan(
          linkId: row.id,
          googleName: row.input.googleName,
          graphId: row.input.graphId,
          googleEtag: row.input.googleEtag,
          graphChangeKey: row.input.graphChangeKey,
          googleBase: row.input.googleDetails,
          graphBase: row.input.graphDetails,
          removeRow: true,
          title: details.title,
          delete: ContactDelete(
            side: side,
            contactId: id,
            cause: orphan.cause,
            expectedVersion: storedVersion,
            title: details.title,
            partnerId: side == ContactSide.google
                ? row.input.graphId
                : row.input.googleName,
            partnerBase: side == ContactSide.google
                ? row.input.graphDetails
                : row.input.googleDetails,
          ),
        ),
      );
    }
  }

  // ---- The brakes.

  void _brakes() {
    final deletions = [
      for (final p in planned)
        if (p.plan.delete != null && !p.plan.fromAnswer) p,
    ];
    if (deletions.length > contactDeletionBrake) {
      final items = <ContactBrakeItem>[];
      for (final p in deletions) {
        final plan = p.plan;
        final delete = plan.delete!;
        final onGoogle = delete.side == ContactSide.google;
        items.add(
          ContactBrakeItem(
            title: plan.title,
            side: delete.side.other,
            googleName: onGoogle ? delete.contactId : null,
            graphId: onGoogle ? null : delete.contactId,
          ),
        );
        p.plan = ContactLinkPlan(
          linkId: plan.linkId,
          googleName: onGoogle ? delete.contactId : null,
          graphId: onGoogle ? null : delete.contactId,
          state: ContactLinkState.held,
          reason: ContactHeldReason.deletionBrake,
          googleEtag: onGoogle ? plan.googleEtag : null,
          graphChangeKey: onGoogle ? null : plan.graphChangeKey,
          googleBase: onGoogle ? plan.googleBase : null,
          graphBase: onGoogle ? null : plan.graphBase,
          title: plan.title,
        );
        p.reviews = const [];
      }
      brakes.add(ContactBrake(ContactBrakeKind.deletions, items));
    }

    final changes = [
      for (final p in planned)
        if (p.plan.removes && !p.plan.fromAnswer && p.plan.writes) p,
    ];
    if (changes.length > contactChangeBrake) {
      final items = <ContactBrakeItem>[];
      final byId = {for (final r in rows) r.id: r};
      for (final p in changes) {
        final plan = p.plan;
        final row = byId[plan.linkId]!;
        items.add(
          ContactBrakeItem(
            title: plan.title,
            side: plan.googleWrite != null
                ? ContactSide.google
                : ContactSide.graph,
            googleName: plan.googleName,
            graphId: plan.graphId,
          ),
        );
        p.plan = ContactLinkPlan(
          linkId: plan.linkId,
          googleName: plan.googleName,
          graphId: plan.graphId,
          state: ContactLinkState.held,
          reason: ContactHeldReason.changeBrake,
          googleEtag: row.input.googleEtag,
          graphChangeKey: row.input.graphChangeKey,
          googleBase: row.input.googleDetails,
          graphBase: row.input.graphDetails,
          title: plan.title,
        );
        p.reviews = const [];
      }
      brakes.add(ContactBrake(ContactBrakeKind.changes, items));
    }
  }

  // ---- The result.

  ContactSyncPlan _result() {
    final links = [for (final p in planned) p.plan];
    final reviews = [
      for (final p in planned) ...p.reviews,
      ...otherReviews,
    ];
    final deleting = {
      for (final l in links)
        if (l.delete case final ContactDelete d) (d.side, d.contactId),
    };
    final binNotDue = [
      for (final b in input.bin)
        if (!b.done && !deleting.contains((b.side, b.contactId))) b.binId,
    ];
    for (final r in restores) {
      if (r.alreadyBack) binAlreadyBack.add(r.binId);
    }
    int count(bool Function(ContactLinkPlan) test) => links.where(test).length;
    return ContactSyncPlan(
      links: links,
      reviews: reviews,
      brakes: brakes,
      reKeys: Map.unmodifiable(reKeys),
      graphTagMoves: Map.unmodifiable(tagMoves),
      journalSettled: journalSettled,
      binAlreadyBack: binAlreadyBack.toList(),
      binNotDue: binNotDue,
      restores: restores,
      googleCount: _googleCount(),
      graphCount: _graphCount(),
      googleGone: Set.unmodifiable(googleGone),
      graphGone: Set.unmodifiable(graphGone),
      counts: ContactSyncCounts(
        addToGoogle: count((l) => l.create?.side == ContactSide.google),
        addToGraph: count((l) => l.create?.side == ContactSide.graph),
        pairUp: pairUp,
        paired: input.links
            .where((l) => l.state == ContactLinkState.paired)
            .length,
        changeGoogle: count((l) => l.googleWrite != null),
        changeGraph: count((l) => l.graphWrite != null),
        deleteGoogle: count((l) => l.delete?.side == ContactSide.google),
        deleteGraph: count((l) => l.delete?.side == ContactSide.graph),
        needsALook: reviews.length,
        differingPairs: differingPairs,
        heldDeletions: brakes
            .where((b) => b.kind == ContactBrakeKind.deletions)
            .fold(0, (n, b) => n + b.items.length),
        heldChanges: brakes
            .where((b) => b.kind == ContactBrakeKind.changes)
            .fold(0, (n, b) => n + b.items.length),
        restores: restores.where((r) => !r.alreadyBack).length,
      ),
    );
  }
}
