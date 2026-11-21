import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../domain/contact_sync_types.dart';
import '../../domain/synced_contact.dart';
import 'contact_mapping.dart';

export '../../domain/contact_sync_types.dart';

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
    this.partnerId,
    this.partnerBase,
  });

  final int linkId;

  /// The Gmail contact's resource name, where the row has one.
  final String? googleName;

  /// The Outlook contact's immutable id, where the row has one.
  final String? graphId;

  /// Each side's version as it was when the contact was last synced:
  /// written by the sync, or a change of it taken in. For Gmail the etag
  /// of the contact source ([googleContactEtag] of the Person, as
  /// [GoogleContact.etag] holds it; never the Person's top-level etag),
  /// for Outlook the `changeKey`.
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

  /// For a row held with one id after its partner went (kept, or held by
  /// the deletion brake): that partner's id, on the other side, and its
  /// synced details in [SyncedContact.toJson]'s form, as the row's
  /// [ContactLinkPlan.partnerId] and [ContactLinkPlan.partnerBase] gave
  /// them. A delete of the row's contact after all puts them in the bin,
  /// so Restore makes both sides again and pairs them.
  final String? partnerId;
  final Map<String, Object?>? partnerBase;

  SyncedContact get googleDetails => SyncedContact.fromJson(googleBase);
  SyncedContact get graphDetails => SyncedContact.fromJson(graphBase);

  /// The contact on the other side from [side] that the row pairs, or
  /// paired before it went.
  String? partnerOf(ContactSide side) =>
      (side == ContactSide.google ? graphId : googleName) ?? partnerId;

  /// That contact's synced details.
  SyncedContact partnerDetailsOf(ContactSide side) {
    if (side == ContactSide.google) {
      return graphId != null
          ? graphDetails
          : SyncedContact.fromJson(partnerBase);
    }
    return googleName != null
        ? googleDetails
        : SyncedContact.fromJson(partnerBase);
  }
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
    this.tag,
  });

  final int opId;

  /// Where the contact was being made.
  final ContactSide side;

  /// The contact it copies, on the other side, as the store has it now:
  /// a re-key of the source moves it.
  final String sourceId;

  final DateTime startedAt;

  /// The hidden tag the create wrote on the copy (the store's op tag):
  /// the source's id when it was sent, which a later re-key of the source
  /// does not change on the copy. Null when it is [sourceId]. An Outlook
  /// copy is found by either; a Gmail copy's tag is an Outlook id, which
  /// is never re-keyed.
  final String? tag;
}

/// A contact the sync deleted, from Recently deleted: a pending or done
/// row, never one marked back (see [ContactSyncInput.bin]).
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
    this.held,
  });

  final ContactAnswerKind kind;
  final String? googleName;
  final String? graphId;
  final Set<ContactField> fields;

  /// For [ContactAnswerKind.useValue]: the losing value, in
  /// [SyncedContact.toJson]'s form.
  final Map<String, Object?>? value;
  final ContactSide? side;

  /// For a brake's answer (Delete them, Don't delete them, Apply them,
  /// Copy them back): the items its question listed
  /// ([ContactBrake.items], kept and re-keyed with the question). The
  /// answer then acts only on rows they name: a row a later run held
  /// under that brake stays held, its own question standing. Null acts
  /// on every row the brake holds.
  final List<ContactBrakeItem>? held;
}

/// What became of a queued answer in this run.
enum ContactAnswerOutcome {
  /// Planned: its Needs a look item or brake question is done with.
  applied,

  /// A contact it acts on was not read this run: it stays queued. See
  /// [contactsToRead].
  waiting,

  /// Its contact has gone, or it no longer applies: the item is dropped.
  dropped,
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
    required this.phoneRegion,
    required this.now,
  });

  /// Gmail contacts this run read: every page of a full listing, or a
  /// sync-token listing's changes (deleted entries included), and every
  /// contact [contactsToRead] named, read by name. An entry with no
  /// synced details at all is passed over, as if not read.
  final List<GoogleContact> google;

  /// Outlook contacts this run read, the same way (tags expanded for
  /// contacts without a row). An `@removed` entry, one that lacks a
  /// synced property ([GraphContact.readWhole]) or one with no synced
  /// details is passed over, as if not read: a missing property is never
  /// read as cleared. Those that lack a property, with no whole read of
  /// them beside, are listed in [ContactSyncPlan.graphPassedOver].
  final List<GraphContact> graph;

  /// Whether [google] / [graph] is a full listing.
  final bool googleComplete;
  final bool graphComplete;

  final List<ContactLinkInput> links;

  /// Everything before the first sync is done: nothing is deleted and no
  /// detail that differs is overwritten.
  final bool firstSync;

  /// Contacts confirmed gone: by getBatchGet's NOT_FOUND for Gmail, by a
  /// GET that found nothing, or found it in Deleted Items, for Outlook,
  /// whether looked up for [contactsToConfirm] or [contactsToRead].
  /// Gmail's own deleted entries in [google] count too.
  final Set<String> googleGone;
  final Set<String> graphGone;

  /// Outlook contacts found in another folder.
  final Set<String> graphMovedOut;

  /// Gmail re-keys found by getBatchGet (old name to new). Those in
  /// `previousResourceNames` are read from [google].
  final Map<String, String> googleReKeys;

  final List<ContactJournalEntry> journal;

  /// The store's bin rows that are pending (`done: false`) or done; never
  /// one marked back ([ContactSyncPlan.binToMarkBack]). The planner reads
  /// every id here as a contact the sync deleted itself, and ignores its
  /// deletion signals as their echo; a contact Ron brought back is a live
  /// contact again, and its id here would hide his deleting it again.
  final List<ContactBinInput> bin;
  final List<ContactAnswer> answers;

  /// The counts kept for the empty-answers brake.
  final int? expectedGoogle;
  final int? expectedGraph;

  /// The pair's phone region, an ISO code such as `US`: the phone's
  /// country when the first sync started, stored on the pair. Required:
  /// without it "+1 212 …" and "212 …" are not the same number. An
  /// unknown code is an [ArgumentError] (`ContactNormaliser.isRegion`).
  final String phoneRegion;

  final DateTime now;
}

// ---------------------------------------------------------------------------
// Output.

/// The contact changed after the plan read it: its etag or `changeKey`
/// is no longer the one the plan was made from. Nothing was built. The
/// runner plans that pair again ([ContactLinkPlan.replan]) from what it
/// has just read, with the run's settings, and writes that instead.
class ContactReadStale implements Exception {
  const ContactReadStale(this.side);

  final ContactSide side;

  @override
  String toString() => 'ContactReadStale(${side.name})';
}

/// A write of some details into one side of a pair.
@immutable
class ContactWrite {
  const ContactWrite({
    required this.side,
    required this.fields,
    required this.target,
    this.replaced = const {},
    this.version,
    this.seen,
  });

  /// The side written.
  final ContactSide side;
  final Set<ContactField> fields;

  /// What the side should hold for [fields] (other fields as read).
  final SyncedContact target;

  /// Gmail list values Outlook replaced in a slot: see [googlePersonUpdate].
  final Map<ContactField, Map<String, String>> replaced;

  /// The side's version the plan was made from (Gmail's contact source
  /// etag, [GoogleContact.etag]; Outlook's `changeKey`): the listed one,
  /// or the row's when the feed did not bring the contact. Null when none
  /// is known, and then not checked.
  final String? version;

  /// The side's details the plan was made from.
  final SyncedContact? seen;

  /// The `updateContact` request, from the Person just read. Throws
  /// [ContactReadStale] when its contact source's etag
  /// ([googleContactEtag]) is not [version]: a Person changed since the
  /// plan read it would otherwise be written over with Google's blessing,
  /// that etag matching. The body carries that source and etag (see
  /// [GooglePersonUpdate]). List values the plan never saw survive even so
  /// (see [googlePersonUpdate]).
  GooglePersonUpdate googleUpdate(
    Map<String, Object?> person, {
    required ContactNormaliser normaliser,
  }) {
    if (version != null && googleContactEtag(person) != version) {
      throw ContactReadStale(side);
    }
    return googlePersonUpdate(
      person,
      target,
      fields,
      replaced: replaced,
      normaliser: normaliser,
      seen: seen,
    );
  }

  /// The `PATCH` body, from the contact as read just before it (Graph has
  /// no conditional `PATCH` for contacts). Throws [ContactReadStale] when
  /// its `changeKey` is not [version].
  Map<String, Object?> graphPatch(Map<String, Object?> current) {
    if (version != null && current['changeKey'] != version) {
      throw ContactReadStale(side);
    }
    return graphContactPatch(current, target, fields);
  }
}

/// A contact copied to the other side. The new contact carries the
/// hidden tag naming its source: the wire client writes [tag], given it
/// beside [body].
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
      ? googleCreateBody(details)
      : graphCreateBody(details);
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
/// version is no longer [expectedVersion] (for Gmail [googleContactEtag]
/// of that read, the contact source's etag, which does not change with
/// the fields asked for; for Outlook its `changeKey`), or it has left
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
    this.settings,
    this.partnerId,
    this.partnerBase,
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

  /// What a pair was compared with, for [replan]; null for a plan that
  /// compares no pair (a create, a delete, a held or removed row).
  final ContactPairSettings? settings;

  /// For a row held with one id after its partner went (kept, or held by
  /// the deletion brake): that partner's id and synced details, which the
  /// runner saves with the row and passes back as
  /// [ContactLinkInput.partnerId] and [ContactLinkInput.partnerBase]
  /// (toJson), so that a delete of the row's contact after all can put
  /// its partner in the bin with it.
  final String? partnerId;
  final SyncedContact? partnerBase;

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

  /// This pair planned again from what the runner has just read, when a
  /// write threw [ContactReadStale]: [google] and [graph] are the contacts
  /// read again (null for a side not read again, which keeps the read this
  /// plan was made from). Everything else is repeated from the run: the
  /// first sync or not, a new pair, Ron's Copy them back, Use Gmail's or
  /// Use Hadco's, or Use this one, the bases compared with, the
  /// normaliser, and the row. The runner writes [plan]'s writes and saves
  /// its [basesAfter]; [reviews] are the pair's Needs a look items now,
  /// in place of those the run's plan gave it. The brakes are not counted
  /// again.
  ///
  /// [googleWritten] and [graphWritten] are the contact as its server
  /// answered this plan's write to that side ([googleWrite],
  /// [graphWrite]), when that write already went through this run: it
  /// stands as that side's read (details and version), and the bases move
  /// on as [basesAfter] gives them for that answer, so the sync's own
  /// write never reads as Ron's change, in this plan or in one planned
  /// again from it. Its edit time stays the one read before the write.
  /// A side has a read or a written answer, not both.
  ///
  /// Only a plan with [settings] can be planned again (a [StateError]
  /// otherwise). A read that is no whole contact (Gmail's deleted entry,
  /// Outlook's `@removed` or sparse one, or one with no synced details)
  /// is an [ArgumentError]: what it lacks would read as cleared. So are
  /// a read and a written answer for one side, and a written answer for
  /// a side this plan does not write.
  ({ContactLinkPlan plan, List<ContactReviewItem> reviews}) replan({
    GoogleContact? google,
    GraphContact? graph,
    GoogleContact? googleWritten,
    GraphContact? graphWritten,
  }) {
    final s = settings;
    final g = googleName;
    final h = graphId;
    final gNow = googleNow;
    final hNow = graphNow;
    if (s == null || g == null || h == null || gNow == null || hNow == null) {
      throw StateError('Only a compared pair can be planned again');
    }
    if ((google != null && googleWritten != null) ||
        (graph != null && graphWritten != null)) {
      throw ArgumentError('A side is read again or was written, not both');
    }
    if ((googleWritten != null && googleWrite == null) ||
        (graphWritten != null && graphWrite == null)) {
      throw ArgumentError('A written answer for a side this plan leaves');
    }
    final gRead = google ?? googleWritten;
    final hRead = graph ?? graphWritten;
    if (gRead != null && (gRead.deleted || gRead.details.isEmpty)) {
      throw ArgumentError('The Gmail read is no whole contact');
    }
    if (hRead != null &&
        (hRead.removed || !hRead.readWhole || hRead.details.isEmpty)) {
      throw ArgumentError('The Outlook read is no whole contact');
    }
    var again = s._read(
      googleUpdatedAt: google?.updatedAt,
      graphUpdatedAt: graph?.updatedAt,
    );
    if (googleWritten != null || graphWritten != null) {
      final bases = basesAfter(
        googleAnswer: googleWritten?.details,
        graphAnswer: graphWritten?.details,
      );
      again = again._based(google: bases.google, graph: bases.graph);
    }
    final made = _comparePair(
      settings: again,
      linkId: linkId,
      alsoRemove: alsoRemove,
      googleName: g,
      graphId: h,
      googleNow: gRead?.details ?? gNow,
      graphNow: hRead?.details ?? hNow,
      googleEtag: gRead != null ? gRead.etag : googleEtag,
      graphChangeKey: hRead != null ? hRead.changeKey : graphChangeKey,
      fromAnswer: fromAnswer,
    );
    return (plan: made.plan, reviews: made.reviews);
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
    partnerId: delete?.partnerId,
    partnerBase: delete?.partnerBase,
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

/// What a pair was compared with ([planPairedContact]'s settings), so
/// that [ContactLinkPlan.replan] compares it again the same way.
@immutable
class ContactPairSettings {
  const ContactPairSettings({
    required this.normaliser,
    this.googleBase,
    this.graphBase,
    this.googleUpdatedAt,
    this.graphUpdatedAt,
    this.newPair = false,
    this.firstSync = false,
    this.copyBack = false,
    this.useSide = const {},
    this.useValues,
  });

  /// The pair's, from its phone region.
  final ContactNormaliser normaliser;

  /// The row's bases as stored; null for a new pair.
  final SyncedContact? googleBase;
  final SyncedContact? graphBase;

  /// Each side's last edit as read, for a clash.
  final DateTime? googleUpdatedAt;
  final DateTime? graphUpdatedAt;

  final bool newPair;
  final bool firstSync;

  /// The change brake's Copy them back.
  final bool copyBack;

  /// Ron's Use Gmail's or Use Hadco's.
  final Map<ContactField, ContactSide> useSide;

  /// Ron's Use this one.
  final SyncedContact? useValues;

  /// The same, compared with [google] and [graph] as bases.
  ContactPairSettings _based({
    required SyncedContact google,
    required SyncedContact graph,
  }) => ContactPairSettings(
    normaliser: normaliser,
    googleBase: google,
    graphBase: graph,
    googleUpdatedAt: googleUpdatedAt,
    graphUpdatedAt: graphUpdatedAt,
    newPair: newPair,
    firstSync: firstSync,
    copyBack: copyBack,
    useSide: useSide,
    useValues: useValues,
  );

  /// The same, with the edit times of the sides read again.
  ContactPairSettings _read({
    DateTime? googleUpdatedAt,
    DateTime? graphUpdatedAt,
  }) => ContactPairSettings(
    normaliser: normaliser,
    googleBase: googleBase,
    graphBase: graphBase,
    googleUpdatedAt: googleUpdatedAt ?? this.googleUpdatedAt,
    graphUpdatedAt: graphUpdatedAt ?? this.graphUpdatedAt,
    newPair: newPair,
    firstSync: firstSync,
    copyBack: copyBack,
    useSide: useSide,
    useValues: useValues,
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

  /// It names a contact whose family name is another: a unique email or
  /// mobile does, or MyEmail's own link (the hidden tag) does.
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

  /// An item as [toJson] wrote it; null for anything else.
  static ContactBrakeItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final side = ContactSide.values.firstWhereOrNull(
      (s) => s.name == json['side'],
    );
    if (side == null) return null;
    String? s(String key) => json[key] is String ? json[key] as String : null;
    return ContactBrakeItem(
      title: s('title') ?? '',
      side: side,
      googleName: s('googleName'),
      graphId: s('graphId'),
    );
  }
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
    this.linkId,
    this.alsoRemove = const [],
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

  /// The row of a contact found back but held, which the restored pair
  /// takes over, so no second row names it; and any other such row,
  /// removed.
  final int? linkId;
  final List<int> alsoRemove;

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
    this.passedOver = 0,
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

  /// Outlook entries passed over, unread: see
  /// [ContactSyncPlan.graphPassedOver].
  final int passedOver;

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
    'passedOver': passedOver,
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
    this.binToDrop = const [],
    this.binToMarkBack = const [],
    this.binNotDue = const [],
    this.restores = const [],
    this.counts = const ContactSyncCounts(),
    this.googleCount = 0,
    this.graphCount = 0,
    this.googleGone = const {},
    this.graphGone = const {},
    this.answers = const [],
    this.graphPassedOver = const {},
    this.mergedAway = const [],
  });

  /// The empty-answers brake: when set, nothing else is planned.
  final ContactSyncStop? stop;

  /// Every row to save, add or remove, with its writes.
  final List<ContactLinkPlan> links;

  /// New Needs a look items.
  final List<ContactReviewItem> reviews;

  /// Brake questions raised this run.
  final List<ContactBrake> brakes;

  /// Gmail re-keys read this run, each old name to the name the contact
  /// has last (a chain of re-keys flattened): every place that names an
  /// old name (reviews, the journal, the bin) takes the new one.
  final Map<String, String> reKeys;

  /// Outlook contacts whose hidden tag names a Gmail contact that was
  /// re-keyed: id to the new name, for [graphTagPatch] where it has one.
  final Map<String, String> graphTagMoves;

  /// Journal entries done with: their copy found and paired, or given up.
  final List<int> journalSettled;

  /// Bin rows of Restores that found the contact already back and paired
  /// ([ContactRestorePlan.alreadyBack]): dropped (the store's dropBin).
  final List<int> binToDrop;

  /// Bin rows of contacts Ron brought back himself, with no Restore asked,
  /// found by their own id and paired or copied this run: marked back
  /// (the store's markBinBack), shown as Already back in Recently
  /// deleted, and from then on left out of the planner's bin input
  /// ([ContactSyncInput.bin]). None is also in [binToDrop].
  final List<int> binToMarkBack;

  /// Both: [binToDrop] and [binToMarkBack].
  @Deprecated('Drop binToDrop, mark binToMarkBack back')
  List<int> get binAlreadyBack => [...binToDrop, ...binToMarkBack];

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

  /// What became of each of the input's answers, in the same order. Empty
  /// when the run stopped.
  ///
  /// The runner removes the Needs a look item (and the answer) of every
  /// answer applied or dropped before it saves this plan's [reviews]: a
  /// contact a dropped answer names is placed again, and the item that
  /// raises can have the same kind and ids as the dropped one, which the
  /// store's saveReview would fold into the old item, keeping its old
  /// answer, so it would run again and be dropped again. A waiting
  /// answer and its item stay.
  final List<ContactAnswerOutcome> answers;

  /// Outlook contacts whose only read this run left out a synced property
  /// ([GraphContact.readWhole]): passed over, as if not read, and never
  /// read as cleared, so a change they carry is not synced. The runner
  /// logs how many ([ContactSyncCounts.passedOver]) and reads them whole
  /// by id, for this run or the next, since the delta link has moved on.
  /// Set on a stopped run too.
  final Set<String> graphPassedOver;

  /// Rows folded away by a merge in Gmail: each losing row's old Gmail
  /// name and, where the row had one, its Outlook id. Before applying
  /// [reKeys] (which would move them onto the merged contact), the
  /// runner drops every Needs a look item naming that Gmail name, and,
  /// where [graphId] is given, that Outlook id with it. A losing row with
  /// an Outlook contact gets a "merged in Gmail" item of its own in
  /// [reviews].
  final List<({String googleName, String? graphId})> mergedAway;

  /// The normaliser this plan compared with, for the pair to store.
  int get normaliserVersion => contactNormaliserVersion;
}

// ---------------------------------------------------------------------------
// Absences.

/// Contacts the runner must look up by id before planning: see
/// [contactsToConfirm] and [contactsToRead].
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

/// Contacts the runner must read by id before planning, because the plan
/// acts on them and a feed brings only what changed: the contacts of
/// queued answers (both sides of a pair, and of every pair the change
/// brake holds when it is answered), every contact held as a candidate,
/// the source of every journal entry, and both sides of every Restore.
/// Found, each goes into the listing; not found (Gmail's NOT_FOUND; for
/// Outlook a 404 or Deleted Items), into the gone sets; elsewhere, as a
/// move or a re-key. An answer whose contacts were not read stays queued
/// ([ContactAnswerOutcome.waiting]).
ContactChecks contactsToRead({
  required Iterable<ContactLinkInput> links,
  Iterable<ContactAnswer> answers = const [],
  Iterable<ContactJournalEntry> journal = const [],
  Iterable<ContactBinInput> bin = const [],
}) {
  final google = <String>{};
  final graph = <String>{};
  void both(ContactLinkInput? link) {
    if (link == null) return;
    if (link.googleName case final String n) google.add(n);
    if (link.graphId case final String id) graph.add(id);
  }

  ContactLinkInput? linkOf(String? g, String? h) => links.firstWhereOrNull(
    (l) =>
        (g != null && l.googleName == g) || (h != null && l.graphId == h),
  );

  for (final answer in answers) {
    final g = answer.googleName;
    final h = answer.graphId;
    switch (answer.kind) {
      case ContactAnswerKind.samePerson ||
          ContactAnswerKind.copyAnyway ||
          ContactAnswerKind.copyBack:
        if (g != null) google.add(g);
        if (h != null) graph.add(h);
      case ContactAnswerKind.useGoogle ||
          ContactAnswerKind.useGraph ||
          ContactAnswerKind.useValue ||
          ContactAnswerKind.retry:
        if (g != null) google.add(g);
        if (h != null) graph.add(h);
        both(linkOf(g, h));
      case ContactAnswerKind.applyHeld || ContactAnswerKind.copyHeldBack:
        for (final link in links) {
          if (link.reason == ContactHeldReason.changeBrake) both(link);
        }
      default:
        break;
    }
  }
  for (final entry in journal) {
    (entry.side == ContactSide.google ? graph : google).add(entry.sourceId);
  }
  // Contacts held as candidates are placed again each run, which needs
  // them read (see ContactHeldReason.candidate).
  for (final link in links) {
    if (link.reason == ContactHeldReason.candidate) both(link);
  }
  for (final b in bin) {
    if (!b.restore) continue;
    (b.side == ContactSide.google ? google : graph).add(b.contactId);
    if (b.partnerId case final String partner) {
      (b.side == ContactSide.google ? graph : google).add(partner);
    }
  }
  return ContactChecks(google: google.toList(), graph: graph.toList());
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
    required this.googleSeen,
    required this.graphSeen,
    this.googleReplaced = const {},
    this.differing = const [],
    this.clashes = const [],
    this.removes = false,
  });

  /// Each side's details as compared: what the writes are built on.
  final SyncedContact googleSeen;
  final SyncedContact graphSeen;

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

  /// The write into Gmail, if any, built only on [version]: the etag of
  /// the Person compared (see [ContactWrite.googleUpdate]).
  ContactWrite? googleWrite({String? version}) => toGoogle.isEmpty
      ? null
      : ContactWrite(
          side: ContactSide.google,
          fields: toGoogle,
          target: googleTarget,
          replaced: googleReplaced,
          version: version,
          seen: googleSeen,
        );

  /// The write into Outlook, if any, built only on [version]: the
  /// `changeKey` of the contact compared.
  ContactWrite? graphWrite({String? version}) => toGraph.isEmpty
      ? null
      : ContactWrite(
          side: ContactSide.graph,
          fields: toGraph,
          target: graphTarget,
          version: version,
          seen: graphSeen,
        );
}

/// One pair compared, detail by detail, with its bases.
///
/// A detail changed on one side (its raw value differs from that side's
/// base) is written to the other, unless the other already holds the same
/// (a fix to capitals still counts as a change). Changed on both sides to
/// different values, it clashes: the newer edit wins ([googleUpdatedAt]
/// against [graphUpdatedAt]; Gmail when neither is known). Lists merge
/// ([mergeContactList]). A birthday without a year never travels. A
/// display name that is only an email or the company is no name to copy
/// ([SyncedContact.copyableName]): it is compared and copied as no name,
/// the bases keep it raw, and a change from one such display name to
/// another is no change.
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
    // The values compared and copied; for the name, only a name (see
    // SyncedContact.copyableName). The bases keep the raw values.
    final gN = _copied(googleNow, f);
    final hN = _copied(graphNow, f);

    if (useValues != null && useValues.values.containsKey(f)) {
      final v = useValues[f];
      if (!norm.equivalent(f, v, gN) && canTravel(f, v)) writeGoogle(f, v);
      if (!norm.equivalent(f, v, hN) && canTravel(f, v)) writeGraph(f, v);
      continue;
    }
    // Use Gmail's or Use Hadco's: only a single detail that is there and
    // can travel. A list is never replaced whole (it would drop what
    // Outlook cannot hold), and an empty one never clears the other side;
    // those follow the usual rules.
    final from = useSide[f];
    final fromValue = from == ContactSide.google ? gN : hN;
    if (from != null &&
        !f.isList &&
        fromValue != null &&
        canTravel(f, fromValue)) {
      final other = from == ContactSide.google ? hN : gN;
      if (norm.equivalent(f, fromValue, other)) {
        adopt(f);
      } else if (from == ContactSide.google) {
        writeGraph(f, fromValue);
      } else {
        writeGoogle(f, fromValue);
      }
      continue;
    }

    final gChanged = _changedSince(googleNow, gBase, f);
    final hChanged = _changedSince(graphNow, hBase, f);
    if (!newPair && !gChanged && !hChanged) {
      // A display name that is no name remade as another (Outlook showing
      // a new address or company) is no change, but it is taken into the
      // base: kept, the old one would later read as a name the contact
      // once had, and a name typed on the other side would clash with it.
      if (f == ContactField.name) adopt(f);
      continue;
    }

    if (f.isList) {
      if (firstSync && !newPair && !copyBack) {
        // A value gone from one side would go from the other: the first
        // sync never removes, nor puts back what Ron took out, so the
        // whole list waits, its bases as they were, until it is done.
        final trial = mergeContactList(
          f,
          google: (gN as List<String>?) ?? const [],
          googleBase: gBase.list(f),
          graph: (hN as List<String>?) ?? const [],
          graphBase: hBase.list(f),
          normaliser: norm,
        );
        if (trial.removes) continue;
      }
      final merge = mergeContactList(
        f,
        google: (gN as List<String>?) ?? const [],
        googleBase: gBase.list(f),
        graph: (hN as List<String>?) ?? const [],
        graphBase: hBase.list(f),
        normaliser: norm,
        removals: !newPair && !copyBack,
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
      if (gN == null && hN == null) {
        // Nothing to copy; a display name that is no name is still taken
        // into the base as it is.
        adopt(f);
        continue;
      }
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
        final addsYear =
            v is ContactBirthday &&
            other is ContactBirthday &&
            !other.hasYear &&
            v.sameDay(other);
        if (other != null && !addsYear) removes = true;
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
    googleSeen: googleNow,
    graphSeen: graphNow,
    googleReplaced: replaced,
    differing: differing,
    clashes: clashes,
    removes: removes && !newPair,
  );
}

/// [contact]'s value of [f] as it would be copied: for the name, only one
/// that is a name ([SyncedContact.copyableName]).
Object? _copied(SyncedContact contact, ContactField f) =>
    f == ContactField.name ? contact.copyableName : contact[f];

/// Whether a side changed [f] since its [base]: its raw value differs.
/// For the name, a change between two display names that are no names
/// (an email or the company, shown for want of a name, which Outlook
/// remakes when they are edited) is no change.
bool _changedSince(SyncedContact now, SyncedContact base, ContactField f) {
  if (rawEquals(now[f], base[f])) return false;
  return f != ContactField.name ||
      now.copyableName != null ||
      base.copyableName != null;
}

/// One pair compared ([planPairedContact]) with [settings], as the row
/// to save with its writes and the pair's Needs a look items. The run and
/// [ContactLinkPlan.replan] both plan a pair this way.
({ContactPairPlan pair, ContactLinkPlan plan, List<ContactReviewItem> reviews})
_comparePair({
  required ContactPairSettings settings,
  int? linkId,
  List<int> alsoRemove = const [],
  required String googleName,
  required String graphId,
  required SyncedContact googleNow,
  required SyncedContact graphNow,
  String? googleEtag,
  String? graphChangeKey,
  bool fromAnswer = false,
}) {
  final s = settings;
  final pair = planPairedContact(
    googleNow: googleNow,
    googleBase: s.googleBase,
    graphNow: graphNow,
    graphBase: s.graphBase,
    googleUpdatedAt: s.googleUpdatedAt,
    graphUpdatedAt: s.graphUpdatedAt,
    normaliser: s.normaliser,
    newPair: s.newPair,
    firstSync: s.firstSync,
    copyBack: s.copyBack,
    useSide: s.useSide,
    useValues: s.useValues,
  );
  final title = googleNow.title.isNotEmpty ? googleNow.title : graphNow.title;
  return (
    pair: pair,
    plan: ContactLinkPlan(
      linkId: linkId,
      alsoRemove: alsoRemove,
      googleName: googleName,
      graphId: graphId,
      googleEtag: googleEtag,
      graphChangeKey: graphChangeKey,
      googleBase: pair.googleBase,
      graphBase: pair.graphBase,
      googleNow: googleNow,
      graphNow: graphNow,
      googleWrite: pair.googleWrite(version: googleEtag),
      graphWrite: pair.graphWrite(version: graphChangeKey),
      newPair: s.newPair,
      fromAnswer: fromAnswer,
      removes: pair.removes,
      title: title,
      settings: s,
    ),
    reviews: [
      if (pair.differing.isNotEmpty)
        ContactReviewItem(
          kind: ContactReviewKind.differing,
          googleName: googleName,
          graphId: graphId,
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
          googleName: googleName,
          graphId: graphId,
          fields: [clash.field],
          losing: SyncedContact({clash.field: clash.losing}),
          losingSide: clash.losingSide,
          title: title,
        ),
    ],
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

/// Copies of one person: see `_Planner._copies`.
class _Copies {
  _Copies(this.members, this.name);

  final Set<(ContactSide, String)> members;

  /// Their full name, as [ContactNormaliser.fullNameKey] gives it.
  final String name;
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
  final graphPassedOver = <String>{};
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
  final mergedAway = <({String googleName, String? graphId})>[];
  /// Bin rows of contacts paired or copied this run (see
  /// [ContactSyncPlan.binToMarkBack]).
  final broughtBack = <int>{};
  final restores = <ContactRestorePlan>[];
  final answerOutcomes = <ContactAnswerOutcome>[];

  /// Contacts under a Needs a look item of their own still waiting for
  /// Ron.
  final waitingSubjects = <(ContactSide, String)>{};
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
        graphPassedOver: Set.unmodifiable(graphPassedOver),
        counts: ContactSyncCounts(passedOver: graphPassedOver.length),
      );
    }
    _buildRows();
    _settleJournal();
    _answer();
    _restore();
    _rowsPass();
    _placeCopies();
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
      for (final p in c.previousNames) {
        if (p != c.resourceName) previous[p] = c.resourceName;
      }
      // Nothing synced at all is no read of a contact: taken as one, it
      // would clear every detail of its partner.
      if (c.details.isEmpty) continue;
      googleListed[c.resourceName] = c;
    }
    final sparse = <String>{};
    final whole = <String>{};
    for (final c in input.graph) {
      // An @removed entry is only a reason to look the contact up, and a
      // sparse one is read whole first: neither is read as cleared. One
      // still sparse is passed over, and counted.
      if (c.removed) continue;
      if (!c.readWhole) {
        sparse.add(c.id);
        continue;
      }
      whole.add(c.id);
      if (c.details.isEmpty) continue;
      graphListed[c.id] = c;
    }
    graphPassedOver.addAll(sparse.difference(whole));
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
    // Each old name straight to the last one: a chain (a to b from
    // getBatchGet, b to c from the listing) applied entry by entry, in no
    // set order, could leave a journal entry, review or bin row under b.
    final last = {for (final old in reKeys.keys) old: _newName(old)};
    reKeys
      ..addAll(last)
      ..removeWhere((old, now) => old == now);
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

    // With no count stored yet, the rows naming that side stand in for it.
    return check(
          ContactSide.google,
          input.googleComplete,
          googleListed.length,
          input.expectedGoogle ??
              input.links.where((l) => l.googleName != null).length,
        ) ??
        check(
          ContactSide.graph,
          input.graphComplete,
          graphListed.length,
          input.expectedGraph ??
              input.links.where((l) => l.graphId != null).length,
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
      // most with the merged one stays paired, and a row with an Outlook
      // contact always before one held with none.
      final merged = googleListed[name]?.details ?? SyncedContact.empty;
      int shared(_Row row) {
        final other = _graphNow(row);
        return ContactField.values
            .where(
              (f) =>
                  _copied(merged, f) != null &&
                  _copied(other, f) != null &&
                  norm.same(f, _copied(merged, f), _copied(other, f)),
            )
            .length;
      }

      final ranked = [...group]
        ..sort((a, b) {
          final byShared = shared(b).compareTo(shared(a));
          if (byShared != 0) return byShared;
          final aPaired = a.graphId != null ? 0 : 1;
          final bPaired = b.graphId != null ? 0 : 1;
          if (aPaired != bPaired) return aPaired.compareTo(bPaired);
          final aHere = a.googleName == name ? 0 : 1;
          final bHere = b.googleName == name ? 0 : 1;
          if (aHere != bHere) return aHere.compareTo(bHere);
          return a.id.compareTo(b.id);
        });
      _rename(ranked.first, name);
      for (final loser in ranked.skip(1)) {
        mergedAway.add((googleName: loser.googleName!, graphId: loser.graphId));
        loser
          ..googleName = null
          ..done = true;
        final graphId = loser.graphId;
        if (graphId == null) {
          // A Gmail contact held with no Outlook one, merged away: nothing
          // is left for its row to name (the store refuses a row naming
          // no contact), and nothing to ask about.
          _add(ContactLinkPlan(linkId: loser.id, removeRow: true));
          continue;
        }
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
      if (row.state == ContactLinkState.held &&
          row.reason == ContactHeldReason.waiting) {
        if (row.googleName case final String name) {
          waitingSubjects.add((ContactSide.google, name));
        }
        if (row.graphId case final String id) {
          waitingSubjects.add((ContactSide.graph, id));
        }
      }
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

  bool _alive(ContactSide side, String? id) =>
      side == ContactSide.google ? _googleAlive(id) : _graphAlive(id);

  /// Read this run, and not gone.
  bool _wasRead(ContactSide side, String? id) =>
      id != null &&
      (side == ContactSide.google
          ? googleListed.containsKey(id) && !googleGone.contains(id)
          : graphListed.containsKey(id) && !graphGone.contains(id));

  bool _isGone(ContactSide side, String? id) =>
      id != null &&
      (side == ContactSide.google
          ? googleGone.contains(id)
          : graphGone.contains(id));

  /// An Outlook contact found in another folder, and not back in Contacts.
  bool _movedOut(ContactSide side, String? id) =>
      side == ContactSide.graph && id != null && graphMoved.contains(id);

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

  /// The source an interrupted create copies, under its name now.
  String _journalSource(ContactJournalEntry entry) =>
      entry.side == ContactSide.graph
          ? _newName(entry.sourceId)
          : entry.sourceId;

  /// The copy an interrupted create made, if it is there with no row and
  /// not yet placed this run: found by its hidden tag.
  ({String id, String? tag})? _journalCopy(
    ContactJournalEntry entry,
    String source,
  ) {
    if (entry.side == ContactSide.google) {
      final c = googleListed.values.firstWhereOrNull(
        (c) =>
            // An Outlook id is never re-keyed: the tag is the id.
            c.tag == entry.sourceId &&
            !googleRow.containsKey(c.resourceName) &&
            googleStatus[c.resourceName] == null,
      );
      return c == null ? null : (id: c.resourceName, tag: c.tag);
    }
    bool free(GraphContact c) =>
        !graphRow.containsKey(c.id) && graphStatus[c.id] == null;
    // Its own tag first (the name it was written under), so that another
    // create's copy tagged with the source's name now is never taken.
    final own = {entry.sourceId, ?entry.tag};
    final c =
        graphListed.values.firstWhereOrNull(
          (c) => free(c) && own.contains(c.tag),
        ) ??
        graphListed.values.firstWhereOrNull(
          (c) => free(c) && c.tag == source,
        );
    return c == null ? null : (id: c.id, tag: c.tag);
  }

  /// The contact on [side] paired this run with [source], on the other.
  String? _pairedThisRun(ContactSide side, String source) {
    for (final p in planned) {
      final plan = p.plan;
      if (plan.removeRow || plan.state != ContactLinkState.paired) continue;
      if (side == ContactSide.graph && plan.googleName == source) {
        return plan.graphId;
      }
      if (side == ContactSide.google && plan.graphId == source) {
        return plan.googleName;
      }
    }
    return null;
  }

  void _settleJournal() {
    // Two copies can settle onto one source: Ron merged in Gmail two
    // contacts whose copies were both being made. The copy tagged with
    // the surviving name is paired, else the oldest op's, and the other
    // is held like any copy whose source has a partner already (below).
    int rank(ContactJournalEntry entry) {
      final source = _journalSource(entry);
      return _journalCopy(entry, source)?.tag == source ? 0 : 1;
    }

    final entries = [...input.journal]
      ..sort((a, b) {
        final byTag = rank(a).compareTo(rank(b));
        if (byTag != 0) return byTag;
        final byAge = a.startedAt.compareTo(b.startedAt);
        if (byAge != 0) return byAge;
        return a.opId.compareTo(b.opId);
      });
    for (final entry in entries) {
      final sourceSide = entry.side.other;
      final source = _journalSource(entry);
      final copy = _journalCopy(entry, source)?.id;
      // Only a source confirmed gone is gone: one merely not read this
      // run is still there, and its copy is not to be deleted.
      final sourceGone = _isGone(sourceSide, source);
      final sourceAlive = _alive(sourceSide, source);
      if (copy != null) {
        if (sourceGone) {
          journalSettled.add(entry.opId);
          _strayCopy(entry.side, copy, source);
        } else if (sourceAlive) {
          journalSettled.add(entry.opId);
          final g = entry.side == ContactSide.google ? copy : source;
          final h = entry.side == ContactSide.google ? source : copy;
          final row = _rowOf(sourceSide, source);
          final partner =
              (entry.side == ContactSide.google
                  ? row?.googleName
                  : row?.graphId) ??
              _pairedThisRun(entry.side, source);
          if (partner != null && partner != copy) {
            // The source has another contact on the copy's side already:
            // its row names one, paired or held with it (moved out, held
            // by the change brake), or another copy was paired with it
            // this run. Ron merged it in Gmail into a contact that had a
            // partner, or merged two being copied. The row and the pair
            // are not taken from that partner.
            _copyOfPaired(entry.side, copy, source);
            continue;
          }
          _pairNew(g, h, linkId: row?.id);
          row?.done = true;
          // An Outlook copy whose tag names the source's old name has it
          // moved on, as a re-key moves the tag of a partner with a row.
          if (entry.side == ContactSide.graph &&
              graphListed[copy]?.tag != source) {
            tagMoves[copy] = source;
          }
        } else {
          // The source was not read: both wait for a run that reads it.
          _setStatus(entry.side, copy, _Status.leftAlone);
        }
        continue;
      }
      if (sourceGone) {
        journalSettled.add(entry.opId);
        continue;
      }
      if (!sourceAlive ||
          input.now.difference(entry.startedAt) < contactGrace) {
        // Not in the listing yet, which may only be Google's lag, or the
        // source was not read: the source waits rather than be copied
        // twice.
        _setStatus(sourceSide, source, _Status.leftAlone);
        _rowOf(sourceSide, source)?.done = true;
        continue;
      }
      journalSettled.add(entry.opId);
    }
  }

  /// A copy whose create was interrupted, found after its source came to
  /// have another contact on the copy's side. An Outlook copy is
  /// held under a "merged in Gmail" item, as a merge's other Outlook
  /// contact is (delete it in Hadco too, or keep it only there); a Gmail
  /// copy goes through the new-contact rules, its tag naming a paired
  /// contact.
  void _copyOfPaired(ContactSide side, String copy, String source) {
    if (side == ContactSide.google) return;
    final details = _detailsOf(side, copy);
    _setStatus(side, copy, _Status.held);
    _add(
      ContactLinkPlan(
        graphId: copy,
        state: ContactLinkState.held,
        reason: ContactHeldReason.waiting,
        graphChangeKey: graphListed[copy]?.changeKey,
        graphBase: details,
        title: details.title,
      ),
      [
        ContactReviewItem(
          kind: ContactReviewKind.mergedInGoogle,
          googleName: source,
          graphId: copy,
          title: details.title,
        ),
      ],
    );
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
      final outcome = _answerOne(answer);
      answerOutcomes.add(outcome);
      if (outcome == ContactAnswerOutcome.dropped) _placeAgain(answer);
    }
  }

  /// A dropped answer's item goes, so a contact it names that waited
  /// under that item would be held with nothing on screen for good: the
  /// rows pass keeps a waiting row until its contact is gone. It goes
  /// through the new-contact rules again instead: now, if it was read
  /// this run, else as a candidate, which every run reads and places.
  /// The item raised again may have the dropped one's kind and ids, so
  /// the runner removes the dropped answer's item before saving this
  /// plan's (see [ContactSyncPlan.answers]).
  void _placeAgain(ContactAnswer answer) {
    final g = answer.googleName == null ? null : _newName(answer.googleName!);
    for (final (side, id) in [
      if (g != null) (ContactSide.google, g),
      if (answer.graphId case final String h) (ContactSide.graph, h),
    ]) {
      final row = _rowOf(side, id);
      if (row == null ||
          row.done ||
          row.state != ContactLinkState.held ||
          row.reason != ContactHeldReason.waiting ||
          !_alive(side, id)) {
        continue;
      }
      waitingSubjects.remove((side, id));
      if (_wasRead(side, id)) {
        row.reopened = true;
        _setStatus(side, id, _Status.fresh);
      } else {
        _hold(side, id, ContactHeldReason.candidate, linkId: row.id);
        row.done = true;
      }
    }
  }

  /// One answer, planned only from contacts read this run: never from a
  /// stored base, which may be out of date or, for a new contact, empty.
  ContactAnswerOutcome _answerOne(ContactAnswer answer) {
    const applied = ContactAnswerOutcome.applied;
    const waiting = ContactAnswerOutcome.waiting;
    const dropped = ContactAnswerOutcome.dropped;
    final g = answer.googleName == null ? null : _newName(answer.googleName!);
    final h = answer.graphId;
    final named = [
      if (g != null) (ContactSide.google, g),
      if (h != null) (ContactSide.graph, h),
    ];

    // Gone wins over unread: an answer whose contact has gone is dropped.
    // So is one whose Outlook contact has moved out of Contacts, which no
    // run reads while it is away: waiting, the answer would wait for ever.
    // The plan's moved-out rule (both ids kept, the pair back when it
    // returns) is for a pair, and the rows pass applies it to the row; a
    // contact with one id held as moved out would read, on its return, as
    // a pair whose Gmail side went, and be deleted. Copy it anyway and
    // Copy it back are the exception ([waitWhileAway]): Ron's choice is
    // kept, and done when the contact is back, rather than dropped and
    // asked again (a kept row goes through no rules again at all).
    ContactAnswerOutcome? unread(
      List<(ContactSide, String?)> contacts, {
      bool waitWhileAway = false,
    }) {
      for (final (side, id) in contacts) {
        if (_isGone(side, id)) return dropped;
        if (_movedOut(side, id)) return waitWhileAway ? waiting : dropped;
      }
      for (final (side, id) in contacts) {
        if (id != null && !_wasRead(side, id)) return waiting;
      }
      return null;
    }

    switch (answer.kind) {
      case ContactAnswerKind.samePerson:
        if (g == null || h == null) return dropped;
        if (unread(named) case final ContactAnswerOutcome o) return o;
        final rg = googleRow[g];
        final rh = graphRow[h];
        bool pairedElsewhere(_Row? r) =>
            r != null &&
            r.state == ContactLinkState.paired &&
            (r.googleName != g || r.graphId != h);
        if (pairedElsewhere(rg) || pairedElsewhere(rh)) return dropped;
        if (rg?.done == true || rh?.done == true) return dropped;
        final keep = rg ?? rh;
        final other = rg != null && rh != null && rg != rh ? rh : null;
        _pairNew(
          g,
          h,
          linkId: keep?.id,
          alsoRemove: [?other?.id],
          fromAnswer: true,
        );
        rg?.done = true;
        rh?.done = true;
        _answered(named);
        return applied;
      case ContactAnswerKind.copyAnyway || ContactAnswerKind.copyBack:
        if (unread(named, waitWhileAway: true)
            case final ContactAnswerOutcome o) {
          return o;
        }
        var any = false;
        for (final (side, id) in named) {
          final row = _rowOf(side, id);
          if (row?.done == true || row?.state == ContactLinkState.paired) {
            continue;
          }
          if (answer.kind == ContactAnswerKind.copyBack && row == null) {
            continue;
          }
          _copy(side, id, linkId: row?.id, fromAnswer: true);
          row?.done = true;
          any = true;
        }
        _answered(named);
        return any ? applied : dropped;
      case ContactAnswerKind.leaveOut || ContactAnswerKind.keepOnlyHere:
        var any = false;
        for (final (side, id) in named) {
          if (!_alive(side, id) && !_wasRead(side, id)) continue;
          final row = _rowOf(side, id);
          if (row?.done == true) continue;
          if (row != null && row.state == ContactLinkState.paired) continue;
          _hold(side, id, ContactHeldReason.leftOut, linkId: row?.id);
          row?.done = true;
          any = true;
        }
        _answered(named);
        return any ? applied : dropped;
      case ContactAnswerKind.useGoogle ||
          ContactAnswerKind.useGraph ||
          ContactAnswerKind.useValue:
        final row = g != null ? googleRow[g] : graphRow[h];
        if (row == null || row.done || row.state != ContactLinkState.paired) {
          return dropped;
        }
        if (unread([
              (ContactSide.google, row.googleName),
              (ContactSide.graph, row.graphId),
            ])
            case final ContactAnswerOutcome o) {
          return o;
        }
        if (answer.kind == ContactAnswerKind.useValue) {
          _pairSync(
            row,
            fromAnswer: true,
            useValues: SyncedContact.fromJson(answer.value),
          );
          return applied;
        }
        final from = answer.kind == ContactAnswerKind.useGoogle
            ? ContactSide.google
            : ContactSide.graph;
        final googleNow = _googleNow(row);
        final graphNow = _graphNow(row);
        // With no details named, those the differing item lists: single
        // details there on both sides and not the same.
        final fields = answer.fields.isNotEmpty
            ? answer.fields
            : ContactField.values.where(
                (f) =>
                    !f.isList &&
                    _copied(googleNow, f) != null &&
                    _copied(graphNow, f) != null &&
                    !norm.same(f, _copied(googleNow, f), _copied(graphNow, f)),
              );
        _pairSync(
          row,
          fromAnswer: true,
          useSide: {for (final f in fields) f: from},
        );
        return applied;
      case ContactAnswerKind.deleteHereToo:
        var any = false;
        for (final (side, id) in named) {
          final row = _rowOf(side, id);
          if (row == null || row.done) continue;
          if (row.state == ContactLinkState.paired) continue;
          _deleteHeld(row, side, id, ContactDeleteCause.answered);
          any = true;
        }
        _answered(named);
        return any ? applied : dropped;
      case ContactAnswerKind.deleteHeld:
        var any = false;
        for (final row in rows) {
          if (row.done ||
              row.reason != ContactHeldReason.deletionBrake ||
              !_covers(answer, row)) {
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
          any = true;
        }
        return any ? applied : dropped;
      case ContactAnswerKind.keepHeld:
        var any = false;
        for (final row in rows) {
          if (row.done ||
              row.reason != ContactHeldReason.deletionBrake ||
              !_covers(answer, row)) {
            continue;
          }
          final side = row.googleName != null
              ? ContactSide.google
              : ContactSide.graph;
          final id = row.googleName ?? row.graphId;
          if (id == null) continue;
          row.done = true;
          any = true;
          if (!_alive(side, id)) {
            _add(ContactLinkPlan(linkId: row.id, removeRow: true));
            continue;
          }
          _keep(row, side, id, ContactReviewReason.notDeleted);
        }
        return any ? applied : dropped;
      case ContactAnswerKind.applyHeld || ContactAnswerKind.copyHeldBack:
        var any = false;
        var unreadRows = false;
        for (final row in rows) {
          if (row.done ||
              row.reason != ContactHeldReason.changeBrake ||
              !_covers(answer, row)) {
            continue;
          }
          if (!_alive(ContactSide.google, row.googleName) ||
              !_alive(ContactSide.graph, row.graphId)) {
            continue;
          }
          if (answer.kind == ContactAnswerKind.applyHeld &&
              _movedOut(ContactSide.graph, row.graphId)) {
            // Apply them: not read while it is away, it would keep the
            // answer waiting, so the pair is held as moved out instead and
            // comes back, planned as usual (the changes applied), when the
            // contact returns. Copy them back cannot be kept that way (the
            // usual plan would apply the changes), so for it the answer
            // waits for the contact's return, below.
            _paired(row);
            continue;
          }
          if (!_wasRead(ContactSide.google, row.googleName) ||
              !_wasRead(ContactSide.graph, row.graphId)) {
            // Held still, its changes not lost: the answer stays queued
            // for the next run that reads it.
            unreadRows = true;
            continue;
          }
          _pairSync(
            row,
            fromAnswer: true,
            copyBack: answer.kind == ContactAnswerKind.copyHeldBack,
          );
          any = true;
        }
        if (unreadRows) return waiting;
        return any ? applied : dropped;
      case ContactAnswerKind.retry:
        var any = false;
        for (final (side, id) in named) {
          final row = _rowOf(side, id);
          if (row == null || row.done) continue;
          if (row.reason != ContactHeldReason.refused) continue;
          if (unread([
                (ContactSide.google, row.googleName),
                (ContactSide.graph, row.graphId),
              ])
              case final ContactAnswerOutcome o) {
            return o;
          }
          _retry(row, fromAnswer: true);
          any = true;
        }
        return any ? applied : dropped;
      case ContactAnswerKind.carryOn:
        return applied;
    }
  }

  /// Whether a brake's answer acts on [row]: every row its brake holds,
  /// or, with [ContactAnswer.held], only those its question listed (a
  /// Gmail name there may since have been re-keyed).
  bool _covers(ContactAnswer answer, _Row row) {
    final held = answer.held;
    if (held == null) return true;
    return held.any(
      (item) =>
          (item.googleName != null &&
              _newName(item.googleName!) == row.googleName) ||
          (item.graphId != null && item.graphId == row.graphId),
    );
  }

  /// Contacts an answer has acted on are no longer waiting for Ron.
  void _answered(List<(ContactSide, String)> contacts) {
    waitingSubjects.removeAll(contacts);
  }

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
      // Only its own id or tag says it is back; an address it shares may
      // be someone else's, and the bin holds the only copy.
      if (here != null &&
          here.exact &&
          _status(side, here.id) == _Status.paired) {
        restores.add(
          ContactRestorePlan(binId: bin.binId, alreadyBack: true),
        );
        continue;
      }
      // Found by an address, it is back when Ron made it again and the
      // sync copied it: its match and the partner's are paired with each
      // other, and each is the same person as the one deleted on its side
      // ([_samePerson]). Dropping the bin row drops the only copy, so a
      // name that merely agrees is not enough: John Roe holding the Info
      // Desk's address is not the Info Desk back, nor Bob Cole, sharing a
      // family address, Ann Cole.
      bool named(
        ({String id, bool exact}) found,
        ContactSide s,
        SyncedContact deleted,
      ) => found.exact || _samePerson(deleted, _detailsOf(s, found.id));
      if (here != null &&
          there != null &&
          _pairedWith(side, here.id, there.id) &&
          named(here, side, details) &&
          named(there, other, partnerDetails)) {
        restores.add(
          ContactRestorePlan(binId: bin.binId, alreadyBack: true),
        );
        continue;
      }
      // A contact found back is used, held or not, unless it is paired
      // with another, or was found only by an address and is not the same
      // person: Bob Cole's left-out contact on Ann's family address would
      // otherwise take her row and be filled with her details, and Ann
      // never be made again.
      String? usable(
        ContactSide s,
        ({String id, bool exact})? found,
        SyncedContact deleted,
      ) {
        if (found == null) return null;
        if (!named(found, s, deleted)) return null;
        if (_status(s, found.id) == _Status.paired) return null;
        final row = _rowOf(s, found.id);
        if (row != null && row.googleName != null && row.graphId != null) {
          return null;
        }
        return found.id;
      }

      final hereId = usable(side, here, details);
      final thereId = usable(other, there, partnerDetails);
      final g = side == ContactSide.google ? hereId : thereId;
      final h = side == ContactSide.graph ? hereId : thereId;
      final googleRowFound = g == null ? null : googleRow[g];
      final graphRowFound = h == null ? null : graphRow[h];
      final keep = googleRowFound ?? graphRowFound;
      final alsoRemove = [
        if (googleRowFound != null &&
            graphRowFound != null &&
            googleRowFound != graphRowFound)
          graphRowFound.id,
      ];
      if (g != null && h != null) {
        // Both back already, by Ron's hand: they are only paired.
        _pairNew(
          g,
          h,
          linkId: keep?.id,
          alsoRemove: alsoRemove,
          fromAnswer: true,
        );
        googleRowFound?.done = true;
        graphRowFound?.done = true;
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
        waitingSubjects.remove((s, id));
      }
      final partner = partnerDetails.isEmpty ? null : partnerDetails;
      restores.add(
        ContactRestorePlan(
          binId: bin.binId,
          linkId: keep?.id,
          alsoRemove: alsoRemove,
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

  /// A contact the sync deleted, if it is back: by its own id or by a tag
  /// naming its partner ([exact]), else by an email or mobile as the
  /// new-contact rules would match it: the only contact on that side with
  /// it, at most one on the other, and family names that agree.
  ({String id, bool exact})? _findBack(
    ContactSide side,
    String? id,
    String? partnerId,
    SyncedContact details,
  ) {
    if (side == ContactSide.google) {
      if (id != null && _googleAlive(id)) return (id: id, exact: true);
      if (partnerId != null) {
        final tagged = googleListed.values.firstWhereOrNull(
          (c) => c.tag == partnerId,
        );
        if (tagged != null) return (id: tagged.resourceName, exact: true);
      }
    } else {
      if (id != null && _graphAlive(id)) return (id: id, exact: true);
      if (partnerId != null) {
        final tagged = graphListed.values.firstWhereOrNull(
          (c) => c.tag == partnerId,
        );
        if (tagged != null) return (id: tagged.id, exact: true);
      }
    }
    for (final (keys, index) in [
      (_emailKeys(details), _emailIndex),
      (_mobileKeys(details), _mobileIndex),
    ]) {
      for (final key in keys) {
        final owners = index[key] ?? const <(ContactSide, String)>[];
        final here = [
          for (final o in owners)
            if (o.$1 == side) o.$2,
        ];
        final there = owners.where((o) => o.$1 != side).length;
        if (here.length != 1 || there > 1) continue;
        if (!ContactNormaliser.namesAgree(
          details.name,
          _detailsOf(side, here.single).name,
        )) {
          continue;
        }
        return (id: here.single, exact: false);
      }
    }
    return null;
  }

  /// Whether [found], matched by an address to [deleted], is the same
  /// person: the same name, part by part ([ContactNormaliser.same]); or,
  /// with no name on either (an email or the company shown for want of
  /// one is none), the same company, or none on both. Stricter than the
  /// matching's "names agree", because a Restore that takes a match for
  /// the deleted contact drops, or never makes again, the only copy: a
  /// family member sharing the address, or John Roe Jr. for Sr., is not
  /// it. A name that differs makes the contact again (a double at worst).
  bool _samePerson(SyncedContact deleted, SyncedContact found) {
    final a = deleted.copyableName;
    final b = found.copyableName;
    if (a != null && b != null) return norm.same(ContactField.name, a, b);
    if (a != null || b != null) return false;
    return ContactNormaliser.textKey(deleted.text(ContactField.company)) ==
        ContactNormaliser.textKey(found.text(ContactField.company));
  }

  /// Whether [id] on [side] and [partner] on the other side are paired
  /// with each other: by their row, or by a pair made earlier this run.
  bool _pairedWith(ContactSide side, String id, String partner) {
    final g = side == ContactSide.google ? id : partner;
    final h = side == ContactSide.google ? partner : id;
    if (_status(ContactSide.google, g) != _Status.paired ||
        _status(ContactSide.graph, h) != _Status.paired) {
      return false;
    }
    final row = googleRow[g];
    if (row != null &&
        row.state == ContactLinkState.paired &&
        row.graphId == h) {
      return true;
    }
    return planned.any(
      (p) =>
          p.plan.state == ContactLinkState.paired &&
          !p.plan.removeRow &&
          p.plan.googleName == g &&
          p.plan.graphId == h,
    );
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
          if (googleGone.contains(g)) {
            if (graphListed.containsKey(h)) {
              // Its Gmail partner went while it was away: back in
              // Contacts, it is a contact of its own.
              row
                ..googleName = null
                ..reopened = true;
              _setStatus(ContactSide.graph, h!, _Status.fresh);
            } else {
              // Out of Contacts, the copy is not the sync's to delete:
              // only the row goes.
              row.done = true;
              _add(ContactLinkPlan(linkId: row.id, removeRow: true));
            }
          } else if (graphListed.containsKey(h) || graphGone.contains(h)) {
            _paired(row);
          }
        case ContactHeldReason.candidate:
          if (!_heldAlive(row)) {
            _add(ContactLinkPlan(linkId: row.id, removeRow: true));
          } else {
            row.reopened = true;
            final side = g != null ? ContactSide.google : ContactSide.graph;
            _setStatus(side, (g ?? h)!, _Status.fresh);
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
    final made = _comparePair(
      settings: ContactPairSettings(
        normaliser: norm,
        googleBase: row.input.googleDetails,
        graphBase: row.input.graphDetails,
        googleUpdatedAt: gc?.updatedAt,
        graphUpdatedAt: hc?.updatedAt,
        firstSync: input.firstSync,
        copyBack: copyBack,
        useSide: useSide,
        useValues: useValues,
      ),
      linkId: row.id,
      googleName: g,
      graphId: h,
      googleNow: _googleNow(row),
      graphNow: _graphNow(row),
      googleEtag: gc?.etag ?? row.input.googleEtag,
      graphChangeKey: hc?.changeKey ?? row.input.graphChangeKey,
      fromAnswer: fromAnswer,
    );
    _add(made.plan, made.reviews);
  }

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
    final made = _comparePair(
      settings: ContactPairSettings(
        normaliser: norm,
        googleUpdatedAt: gc?.updatedAt,
        graphUpdatedAt: hc?.updatedAt,
        newPair: true,
      ),
      linkId: linkId,
      alsoRemove: alsoRemove,
      googleName: g,
      graphId: h,
      googleNow: _detailsOf(ContactSide.google, g),
      graphNow: _detailsOf(ContactSide.graph, h),
      googleEtag: gc?.etag ?? googleRow[g]?.input.googleEtag,
      graphChangeKey: hc?.changeKey ?? graphRow[h]?.input.graphChangeKey,
      fromAnswer: fromAnswer,
    );
    _setStatus(ContactSide.google, g, _Status.paired);
    _setStatus(ContactSide.graph, h, _Status.paired);
    googleRow[g]?.done = true;
    graphRow[h]?.done = true;
    pairUp++;
    if (made.pair.differing.isNotEmpty) differingPairs++;
    _backFromBin(ContactSide.google, g);
    _backFromBin(ContactSide.graph, h);
    _add(made.plan, made.reviews);
  }

  /// A contact the sync deleted that Ron brought back himself, now being
  /// paired again: its bin row is Already back.
  void _backFromBin(ContactSide side, String id) {
    for (final b in input.bin) {
      if (b.side == side && b.contactId == id) broughtBack.add(b.binId);
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
        // A held contact's base is what was read of it, so that a later
        // run that does not read it can still see what it holds: a
        // candidate re-placed then finds the contact it waits on.
        googleBase: side == ContactSide.google ? details : null,
        graphBase: side == ContactSide.graph ? details : null,
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
          partnerId: row.input.partnerOf(side),
          partnerBase: row.input.partnerDetailsOf(side),
        ),
      ),
    );
  }

  /// A surviving copy held as kept, its gone partner's id cleared (and
  /// kept as the row's partner, for a delete after all).
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
        partnerId: row.input.partnerOf(side),
        partnerBase: row.input.partnerDetailsOf(side),
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

  // ---- Copies of one person.

  /// Copies of one person (R1): contacts joined by a shared email or
  /// mobile key, every one of them, on both sides, with a name to copy
  /// and the same full name, with more than one on a side (counting the
  /// partner a member is paired with). A contact with no name never joins
  /// one, and a contact of another name on the keys (a family on one
  /// address) leaves the whole set to the usual rules. Built from what
  /// each contact holds now: its read, or its row's base.
  late final List<_Copies> _copies = _findCopies();

  late final Map<(ContactSide, String), _Copies> _copiesByContact = {
    for (final group in _copies)
      for (final member in group.members) member: group,
  };

  /// Whether [a] and [b], both on [side], are copies of one person.
  bool _copiesWith(ContactSide side, String a, String b) {
    final group = _copiesByContact[(side, a)];
    return group != null && identical(group, _copiesByContact[(side, b)]);
  }

  List<_Copies> _findCopies() {
    final keysOf = <(ContactSide, String), List<String>>{};
    final byKey = <String, List<(ContactSide, String)>>{};
    for (final (prefix, index) in [('e', _emailIndex), ('m', _mobileIndex)]) {
      for (final MapEntry(:key, :value) in index.entries) {
        final k = '$prefix:$key';
        byKey[k] = value;
        for (final owner in value) {
          keysOf.putIfAbsent(owner, () => []).add(k);
        }
      }
    }
    final seen = <(ContactSide, String)>{};
    final groups = <_Copies>[];
    for (final start in keysOf.keys) {
      if (!seen.add(start)) continue;
      final members = <(ContactSide, String)>{start};
      final queue = [start];
      while (queue.isNotEmpty) {
        final next = queue.removeLast();
        for (final k in keysOf[next]!) {
          for (final owner in byKey[k]!) {
            if (seen.add(owner)) {
              members.add(owner);
              queue.add(owner);
            }
          }
        }
      }
      if (members.length < 2) continue;
      final names = {
        for (final (side, id) in members)
          ContactNormaliser.fullNameKey(_detailsOf(side, id).copyableName),
      };
      if (names.length != 1 || names.single == null) continue;
      // Copies on a side: the members there, and the partners there of
      // members paired across.
      final googles = {
        for (final (side, id) in members)
          if (side == ContactSide.google)
            id
          else if (_rowOf(side, id) case final row?
              when row.state == ContactLinkState.paired &&
                  row.googleName != null)
            row.googleName!,
      };
      final graphs = {
        for (final (side, id) in members)
          if (side == ContactSide.graph)
            id
          else if (_rowOf(side, id) case final row?
              when row.state == ContactLinkState.paired && row.graphId != null)
            row.graphId!,
      };
      if (googles.length < 2 && graphs.length < 2) continue;
      groups.add(_Copies(members, names.single!));
    }
    return groups;
  }

  /// How complete a copy is: its synced detail values, each list item
  /// counted.
  int _completeness(ContactSide side, String id) {
    var n = 0;
    for (final value in _detailsOf(side, id).values.values) {
      n += value is List ? value.length : 1;
    }
    return n;
  }

  /// [ids] on [side], the most complete first, ties by id.
  List<String> _mostComplete(ContactSide side, Iterable<String> ids) =>
      [...ids]..sort((a, b) {
        final byValues = _completeness(side, b).compareTo(
          _completeness(side, a),
        );
        return byValues != 0 ? byValues : a.compareTo(b);
      });

  /// Copies of one person, placed (R2, R3): one copy each side synced,
  /// the rest held as duplicates, never copied, written, deleted or asked
  /// about. A member already paired keeps its pair, and every other copy
  /// read this run is held. With no pair, the most complete copy read on
  /// each side (one Ron's own link joins first, a copy due to be deleted
  /// first of all) is paired like any new pair; with copies on one side
  /// only, its most complete goes through the usual rules alone (its
  /// copies are no other person to them), the rest held. A member held
  /// for another reason, or not read, is left as it is.
  void _placeCopies() {
    for (final group in _copies) {
      final members = group.members;
      bool open((ContactSide, String) m) {
        final (side, id) = m;
        final row = _rowOf(side, id);
        final status = _status(side, id);
        return (status == null || status == _Status.fresh) &&
            _wasRead(side, id) &&
            (row == null || (row.reopened && !row.done));
      }

      final paired = members.any((m) => _status(m.$1, m.$2) == _Status.paired);
      final waiting = [for (final m in members) if (open(m)) m];
      if (!paired) {
        // A copy due to be deleted (its partner gone) is paired first, so
        // it is kept; it is no copy to place on its own.
        List<String> due(ContactSide side) => _mostComplete(side, [
          for (final (s, id) in members)
            if (s == side && _status(s, id) == _Status.orphan) id,
        ]);
        List<String> unplaced(ContactSide side) => _mostComplete(side, [
          for (final (s, id) in waiting)
            if (s == side) id,
        ]);
        final gs = [
          ...due(ContactSide.google),
          ...unplaced(ContactSide.google),
        ];
        final hs = [
          ...due(ContactSide.graph),
          ...unplaced(ContactSide.graph),
        ];
        final pairs =
            gs.isNotEmpty &&
            hs.isNotEmpty &&
            (unplaced(ContactSide.google).isNotEmpty ||
                unplaced(ContactSide.graph).isNotEmpty);
        if (pairs) {
          var (g, h) = (gs.first, hs.first);
          linked:
          for (final gc in gs) {
            for (final hc in hs) {
              final hTag = graphListed[hc]?.tag;
              if ((hTag != null && _newName(hTag) == gc) ||
                  googleListed[gc]?.tag == hc) {
                (g, h) = (gc, hc);
                break linked;
              }
            }
          }
          final gRow = _rowOf(ContactSide.google, g);
          final hRow = _rowOf(ContactSide.graph, h);
          if (_status(ContactSide.google, g) == _Status.orphan) {
            _pair(ContactSide.graph, h, g, hRow);
          } else {
            _pair(ContactSide.google, g, h, gRow);
          }
          gRow?.done = true;
          hRow?.done = true;
          _moveTag(ContactSide.google, g, h);
          waiting.removeWhere(
            (m) =>
                (m.$1 == ContactSide.google && m.$2 == g) ||
                (m.$1 == ContactSide.graph && m.$2 == h),
          );
        } else {
          // Copies to place on one side only: the most complete is placed
          // by the usual rules, after this.
          final gOpen = unplaced(ContactSide.google);
          final side = gOpen.isNotEmpty
              ? ContactSide.google
              : ContactSide.graph;
          final first = unplaced(side).firstOrNull;
          waiting.removeWhere((m) => m.$1 == side && m.$2 == first);
        }
      }
      for (final (side, id) in waiting) {
        final row = _rowOf(side, id);
        _hold(side, id, ContactHeldReason.duplicate, linkId: row?.id);
        row?.done = true;
      }
    }
  }

  // ---- New contacts.

  late final Map<String, List<(ContactSide, String)>> _emailIndex =
      _index(_emailKeys);
  late final Map<String, List<(ContactSide, String)>> _mobileIndex =
      _index(_mobileKeys);
  late final Map<String, List<(ContactSide, String)>> _nameIndex = _index(
    (d) => [?ContactNormaliser.fullNameKey(d.copyableName)],
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
      // Placed only from what was read this run: a contact known only by
      // its row waits, as it is, for a run that reads it.
      if (!_wasRead(side, id)) continue;
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

    // A hidden tag naming a contact on the other side. It pairs them only
    // while they are plainly one person still: names that agree, or an
    // email or mobile in common. A copy Ron has since typed another
    // person over keeps the tag, and is asked about instead.
    if (tag != null) {
      final target = other == ContactSide.google ? _newName(tag) : tag;
      final alive = other == ContactSide.google
          ? _googleAlive(target)
          : _graphAlive(target);
      final status = alive ? _status(other, target) : null;
      final free =
          status == null || status == _Status.fresh || status == _Status.orphan;
      final agrees = alive && _onePerson(details, _detailsOf(other, target));
      if (alive && free && !agrees) {
        // A contact due to be deleted is not offered: the usual rules.
        if (status != _Status.orphan) {
          _review(side, id, row, [target], ContactReviewReason.namesDisagree);
          return;
        }
      } else if (alive) {
        if (free) {
          _pair(side, id, target, row);
          _moveTag(side, id, target);
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

    // A contact on the other side whose hidden tag names this one: the
    // sync's copy of it, from before a reinstall or a lost store. Placed
    // first, this contact would otherwise never look at it, and one with
    // no email or mobile would go under Needs a look. Only one that is
    // free (not paired, held or due to be deleted), and only when one is.
    final tagging = other == ContactSide.graph
        ? [
            for (final c in graphListed.values)
              if (c.tag != null && _newName(c.tag!) == id) c.id,
          ]
        : [
            for (final c in googleListed.values)
              if (c.tag == id) c.resourceName,
          ];
    final taggedHere = [
      for (final t in tagging)
        if ((_status(other, t) ?? _Status.fresh) == _Status.fresh &&
            _wasRead(other, t))
          t,
    ];
    // Only while they are plainly one person still (see above); else the
    // usual rules, which a stronger match may win.
    if (taggedHere.length == 1 &&
        _onePerson(details, _detailsOf(other, taggedHere.single))) {
      _pair(side, id, taggedHere.single, row);
      _moveTag(side, id, taggedHere.single);
      return;
    }

    // A unique email address, else a unique mobile.
    for (final (keys, index) in [
      (_emailKeys(details), _emailIndex),
      (_mobileKeys(details), _mobileIndex),
    ]) {
      final unique = <String>{};
      final shared = <String>{};
      for (final key in keys) {
        // Its own copies on its side are no other person.
        final owners = (index[key] ?? const [])
            .where(
              (o) =>
                  o.$1 != side ||
                  (o.$2 != id && !_copiesWith(side, id, o.$2)),
            )
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
    final nameKey = ContactNormaliser.fullNameKey(details.copyableName);
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

  /// Whether two contacts a hidden tag links are plainly one person
  /// still: both have a name, and the same family name or, where either
  /// has none, the same full name; or they share an email or a mobile.
  /// Not [ContactNormaliser.namesAgree], which takes a missing family
  /// name, or no name at all, for agreement: a hand copy retyped as
  /// "Bob", or as a company only, is no longer the contact it copied.
  bool _onePerson(SyncedContact a, SyncedContact b) {
    final na = a.copyableName;
    final nb = b.copyableName;
    if (na != null && nb != null) {
      final fa = ContactNormaliser.textKey(na.family);
      final fb = ContactNormaliser.textKey(nb.family);
      if (fa != null && fb != null) {
        if (fa == fb) return true;
      } else {
        final full = ContactNormaliser.fullNameKey(na);
        if (full != null && full == ContactNormaliser.fullNameKey(nb)) {
          return true;
        }
      }
    }
    final emails = _emailKeys(a).toSet();
    if (_emailKeys(b).any(emails.contains)) return true;
    final mobiles = _mobileKeys(a).toSet();
    return _mobileKeys(b).any(mobiles.contains);
  }

  /// After a pair made by a hidden tag: an Outlook tag that names another
  /// Gmail name than the one paired (a name since re-keyed, a contact
  /// since merged) is moved on to it.
  void _moveTag(ContactSide side, String id, String match) {
    final g = side == ContactSide.google ? id : match;
    final h = side == ContactSide.google ? match : id;
    final tag = graphListed[h]?.tag;
    if (tag != null && tag != g) tagMoves[h] = g;
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
    if (row != null &&
        row.reason == ContactHeldReason.candidate &&
        candidates.every(
          (c) => waitingSubjects.contains((other, c)) && _alive(other, c),
        )) {
      // Already under those items, which are still waiting for Ron.
      row.done = true;
      _setStatus(side, id, _Status.held);
      return;
    }
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
    waitingSubjects.add((side, id));
    // A candidate that is new too waits under the same item, held as a
    // candidate: once the item is answered or dropped it is placed by the
    // new-contact rules (see ContactHeldReason.candidate).
    for (final c in candidates) {
      final status = _status(other, c);
      if (status != null && status != _Status.fresh) continue;
      final candidateRow = _rowOf(other, c);
      if (candidateRow != null && !candidateRow.reopened) continue;
      _hold(other, c, ContactHeldReason.candidate, linkId: candidateRow?.id);
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
      // Versions are compared as they are, a Gmail re-key included: the
      // version is the contact source's etag, so a re-key that leaves it
      // as it was is no change, and one that moves it (as a merge, which
      // changes the contact, does; whether Google's other re-keys do is
      // not known) keeps the contact as changed since. A re-key is not
      // taken for no change on its own: Ron is asked rather than a
      // changed contact deleted.
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
          partnerId: delete.partnerId,
          partnerBase: delete.partnerBase,
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
    // A Restore found already back drops its row, even where the run
    // also paired the contact it names.
    final toDrop = {
      for (final r in restores)
        if (r.alreadyBack) r.binId,
    };
    // A tag is moved only on an Outlook contact a row still names once
    // the plan is carried out: not one gone, deleted, or left without a
    // row.
    final touched = {
      for (final l in links) ...[?l.linkId, ...l.alsoRemove],
    };
    final stillNamed = {
      for (final l in links)
        if (!l.removeRow) ?l.graphId,
      for (final r in input.links)
        if (!touched.contains(r.linkId)) ?r.graphId,
    };
    int count(bool Function(ContactLinkPlan) test) => links.where(test).length;
    return ContactSyncPlan(
      links: links,
      reviews: reviews,
      brakes: brakes,
      reKeys: Map.unmodifiable(reKeys),
      graphTagMoves: Map.unmodifiable({
        for (final MapEntry(:key, :value) in tagMoves.entries)
          if (stillNamed.contains(key)) key: value,
      }),
      journalSettled: journalSettled,
      binToDrop: toDrop.toList(),
      binToMarkBack: broughtBack.difference(toDrop).toList(),
      binNotDue: binNotDue,
      restores: restores,
      googleCount: _googleCount(),
      graphCount: _graphCount(),
      googleGone: Set.unmodifiable(googleGone),
      graphGone: Set.unmodifiable(graphGone),
      answers: answerOutcomes,
      graphPassedOver: Set.unmodifiable(graphPassedOver),
      mergedAway: List.unmodifiable(mergedAway),
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
        passedOver: graphPassedOver.length,
      ),
    );
  }
}
