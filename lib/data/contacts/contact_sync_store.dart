import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../domain/contact_sync_types.dart';
import '../../domain/synced_contact.dart' show ContactSide;
import '../cache/mail_database.dart';

// The sides, a row's state and why it is held are the planner's kinds
// (ContactSide, ContactLinkState, ContactHeldReason), kept by their codes,
// so its rows and the planner's inputs are one vocabulary.
export '../../domain/contact_sync_types.dart';
export '../../domain/synced_contact.dart' show ContactSide;

/// A bin row's state: written before the delete is sent, done once the
/// server has it, or back because Ron brought the contact back himself.
enum ContactBinState { pending, done, back }

/// One Gmail account's contacts synced with one Microsoft account's, and
/// where each side's feed has got to.
///
/// Times are UTC. The JSON fields are kept as the runner writes them: the
/// store neither reads nor checks them.
@immutable
class ContactPair {
  const ContactPair({
    required this.pairId,
    required this.googleAccountId,
    required this.googleAddress,
    required this.graphAccountId,
    required this.graphAddress,
    this.graphFolderId,
    this.phoneRegion,
    this.googleSyncToken,
    this.googleMask,
    this.googleFullAt,
    this.graphDeltaLink,
    this.graphMask,
    this.normaliser,
    this.googleCount,
    this.graphCount,
    this.firstStartedAt,
    this.firstDoneAt,
    this.lastAttemptAt,
    this.lastDoneAt,
    this.lastResult,
    this.held,
    this.detachedAt,
  });

  final int pairId;
  final String googleAccountId;

  /// Lower-cased, as the store keeps it.
  final String googleAddress;
  final String graphAccountId;
  final String graphAddress;

  /// The id of the mailbox's main Contacts folder, once known.
  final String? graphFolderId;

  /// The region numbers without a country code are read in, fixed when the
  /// first sync starts.
  final String? phoneRegion;

  /// Google's `nextSyncToken`, the version of the field mask it was taken
  /// with, and when the full listing that started it was taken.
  final String? googleSyncToken;
  final int? googleMask;
  final DateTime? googleFullAt;

  /// Graph's `@odata.deltaLink`, and the version of the `$select` in it.
  final String? graphDeltaLink;
  final int? graphMask;

  /// The version of the normaliser the bases were last compared with.
  final int? normaliser;

  /// How many contacts each side has, kept current for the empty-answers
  /// brake and the screen.
  final int? googleCount;
  final int? graphCount;

  /// The first sync: started by Start, done when it finished. Everything
  /// before [firstDoneAt] is first-sync mode, which deletes nothing.
  final DateTime? firstStartedAt;
  final DateTime? firstDoneAt;
  final DateTime? lastAttemptAt;
  final DateTime? lastDoneAt;

  /// JSON: the last run's counts, or the kind of error that stopped it.
  final String? lastResult;

  /// JSON: the open questions the brakes asked.
  final String? held;

  /// When one of the two accounts was removed. A detached pair runs no
  /// more, and is dropped after [ContactSyncStore.detachedFor].
  final DateTime? detachedAt;

  bool get isDetached => detachedAt != null;

  String accountIdOn(ContactSide side) =>
      side == ContactSide.google ? googleAccountId : graphAccountId;

  String addressOn(ContactSide side) =>
      side == ContactSide.google ? googleAddress : graphAddress;

  /// [pairId] cannot be changed. A field left out keeps its value; a
  /// nullable one given null is cleared.
  ContactPair copyWith({
    String? googleAccountId,
    String? googleAddress,
    String? graphAccountId,
    String? graphAddress,
    Object? graphFolderId = _keep,
    Object? phoneRegion = _keep,
    Object? googleSyncToken = _keep,
    Object? googleMask = _keep,
    Object? googleFullAt = _keep,
    Object? graphDeltaLink = _keep,
    Object? graphMask = _keep,
    Object? normaliser = _keep,
    Object? googleCount = _keep,
    Object? graphCount = _keep,
    Object? firstStartedAt = _keep,
    Object? firstDoneAt = _keep,
    Object? lastAttemptAt = _keep,
    Object? lastDoneAt = _keep,
    Object? lastResult = _keep,
    Object? held = _keep,
    Object? detachedAt = _keep,
  }) =>
      ContactPair(
        pairId: pairId,
        googleAccountId: googleAccountId ?? this.googleAccountId,
        googleAddress: googleAddress ?? this.googleAddress,
        graphAccountId: graphAccountId ?? this.graphAccountId,
        graphAddress: graphAddress ?? this.graphAddress,
        graphFolderId: _or(graphFolderId, this.graphFolderId),
        phoneRegion: _or(phoneRegion, this.phoneRegion),
        googleSyncToken: _or(googleSyncToken, this.googleSyncToken),
        googleMask: _or(googleMask, this.googleMask),
        googleFullAt: _or(googleFullAt, this.googleFullAt),
        graphDeltaLink: _or(graphDeltaLink, this.graphDeltaLink),
        graphMask: _or(graphMask, this.graphMask),
        normaliser: _or(normaliser, this.normaliser),
        googleCount: _or(googleCount, this.googleCount),
        graphCount: _or(graphCount, this.graphCount),
        firstStartedAt: _or(firstStartedAt, this.firstStartedAt),
        firstDoneAt: _or(firstDoneAt, this.firstDoneAt),
        lastAttemptAt: _or(lastAttemptAt, this.lastAttemptAt),
        lastDoneAt: _or(lastDoneAt, this.lastDoneAt),
        lastResult: _or(lastResult, this.lastResult),
        held: _or(held, this.held),
        detachedAt: _or(detachedAt, this.detachedAt),
      );

  List<Object?> get _fields => [
        pairId,
        googleAccountId,
        googleAddress,
        graphAccountId,
        graphAddress,
        graphFolderId,
        phoneRegion,
        googleSyncToken,
        googleMask,
        googleFullAt,
        graphDeltaLink,
        graphMask,
        normaliser,
        googleCount,
        graphCount,
        firstStartedAt,
        firstDoneAt,
        lastAttemptAt,
        lastDoneAt,
        lastResult,
        held,
        detachedAt,
      ];

  @override
  bool operator ==(Object other) =>
      other is ContactPair && _sameFields(_fields, other._fields);

  @override
  int get hashCode => Object.hashAll(_fields);

  /// No tokens, links or addresses: this ends up in logs.
  @override
  String toString() => 'ContactPair($pairId'
      '${isDetached ? ', detached' : ''})';
}

/// A contact contact sync has decided about: paired with its partner, or
/// held, with a reason.
///
/// Each side's etag or `changeKey`, and its synced details as raw JSON
/// (the base), are as they were when that contact was last synced: written
/// by the sync, or a change of it taken in. A paired link names both sides;
/// a held one names at least one.
@immutable
class ContactLink {
  const ContactLink({
    this.linkId,
    required this.pairId,
    this.googleName,
    this.graphId,
    this.googleEtag,
    this.graphChangeKey,
    this.googleBase,
    this.graphBase,
    required this.state,
    this.reason,
    this.googleWrittenAt,
    this.updatedAt,
  });

  /// Null until the store has saved it.
  final int? linkId;
  final int pairId;

  /// The Google contact's resource name (`people/c...`).
  final String? googleName;

  /// The Microsoft contact's immutable id.
  final String? graphId;
  final String? googleEtag;
  final String? graphChangeKey;

  /// Raw JSON of each side's synced details, as its server last returned
  /// them.
  final String? googleBase;
  final String? graphBase;
  final ContactLinkState state;

  /// Why it is held; null when paired. Kept as its [ContactHeldReason.code].
  final ContactHeldReason? reason;

  /// When the sync last wrote the Google side: for the hour in which an
  /// absence from Google's listing is not taken as a deletion.
  final DateTime? googleWrittenAt;

  /// When it was last saved. Stamped by the store.
  final DateTime? updatedAt;

  bool get isPaired => state == ContactLinkState.paired;

  String? idOn(ContactSide side) =>
      side == ContactSide.google ? googleName : graphId;

  /// [linkId], [pairId] and [updatedAt] cannot be changed. A field left out
  /// keeps its value; a nullable one given null is cleared.
  ContactLink copyWith({
    Object? googleName = _keep,
    Object? graphId = _keep,
    Object? googleEtag = _keep,
    Object? graphChangeKey = _keep,
    Object? googleBase = _keep,
    Object? graphBase = _keep,
    ContactLinkState? state,
    Object? reason = _keep,
    Object? googleWrittenAt = _keep,
  }) =>
      ContactLink(
        linkId: linkId,
        pairId: pairId,
        googleName: _or(googleName, this.googleName),
        graphId: _or(graphId, this.graphId),
        googleEtag: _or(googleEtag, this.googleEtag),
        graphChangeKey: _or(graphChangeKey, this.graphChangeKey),
        googleBase: _or(googleBase, this.googleBase),
        graphBase: _or(graphBase, this.graphBase),
        state: state ?? this.state,
        reason: _or(reason, this.reason),
        googleWrittenAt: _or(googleWrittenAt, this.googleWrittenAt),
        updatedAt: updatedAt,
      );

  /// Paired: both ids and no reason. Held: a reason and at least one id.
  /// Anything else is the runner's mistake, and saving it would leave a
  /// row the planner cannot read.
  void _check() {
    if (googleName == null && graphId == null) {
      throw ArgumentError('A contact link names no contact.');
    }
    switch (state) {
      case ContactLinkState.paired:
        if (googleName == null || graphId == null) {
          throw ArgumentError('A paired contact link needs both ids.');
        }
        if (reason != null) {
          throw ArgumentError('A paired contact link is not held.');
        }
      case ContactLinkState.held:
        if (reason == null) {
          throw ArgumentError('A held contact link needs a reason.');
        }
    }
  }

  ContactLink _saved(int linkId, DateTime at) => ContactLink(
        linkId: linkId,
        pairId: pairId,
        googleName: googleName,
        graphId: graphId,
        googleEtag: googleEtag,
        graphChangeKey: graphChangeKey,
        googleBase: googleBase,
        graphBase: graphBase,
        state: state,
        reason: reason,
        googleWrittenAt: _kept(googleWrittenAt),
        updatedAt: at,
      );

  List<Object?> get _fields => [
        linkId,
        pairId,
        googleName,
        graphId,
        googleEtag,
        graphChangeKey,
        googleBase,
        graphBase,
        state,
        reason,
        googleWrittenAt,
        updatedAt,
      ];

  @override
  bool operator ==(Object other) =>
      other is ContactLink && _sameFields(_fields, other._fields);

  @override
  int get hashCode => Object.hashAll(_fields);

  /// No ids or details: this ends up in logs.
  @override
  String toString() => 'ContactLink($linkId, ${state.name}'
      '${reason == null ? '' : ', ${reason!.name}'})';
}

/// A create sent, or about to be, that has no link saved yet: journalled
/// before it goes, cleared in the same transaction that saves its link
/// ([ContactSyncStore.completeCreates]). One left over after a crash is
/// settled by its [tag] once the feeds are read.
@immutable
class ContactSyncOp {
  const ContactSyncOp({
    required this.opId,
    required this.pairId,
    required this.side,
    required this.sourceKey,
    required this.tag,
    required this.startedAt,
  });

  final int opId;
  final int pairId;

  /// The side the contact is created on.
  final ContactSide side;

  /// The id, on the other side, of the contact being copied.
  final String sourceKey;

  /// The hidden tag written into the create, as it was sent. A re-key of
  /// the source moves [sourceKey] but not this, which is what the server
  /// holds.
  final String tag;
  final DateTime startedAt;

  List<Object?> get _fields => [opId, pairId, side, sourceKey, tag, startedAt];

  @override
  bool operator ==(Object other) =>
      other is ContactSyncOp && _sameFields(_fields, other._fields);

  @override
  int get hashCode => Object.hashAll(_fields);

  @override
  String toString() => 'ContactSyncOp($opId, ${side.name})';
}

/// One item under Needs a look, and Ron's answer once given, queued for
/// the next run.
///
/// [kind], [data] and [answer] are the runner's: the store keeps them as
/// they are. The ids are the contacts it is about, kept here rather than in
/// [data] so that a re-key reaches them.
@immutable
class ContactReview {
  const ContactReview({
    this.reviewId,
    required this.pairId,
    required this.kind,
    this.googleName,
    this.graphId,
    required this.data,
    this.createdAt,
    this.answer,
    this.answeredAt,
  });

  /// Null until the store has saved it.
  final int? reviewId;
  final int pairId;
  final String kind;
  final String? googleName;
  final String? graphId;

  /// JSON: what the screen shows.
  final String data;

  /// Stamped by the store when the review is first saved.
  final DateTime? createdAt;
  final String? answer;

  /// Stamped by the store when [answer] is given.
  final DateTime? answeredAt;

  bool get isAnswered => answer != null;

  ContactReview copyWith({
    String? kind,
    Object? googleName = _keep,
    Object? graphId = _keep,
    String? data,
    Object? answer = _keep,
  }) =>
      ContactReview(
        reviewId: reviewId,
        pairId: pairId,
        kind: kind ?? this.kind,
        googleName: _or(googleName, this.googleName),
        graphId: _or(graphId, this.graphId),
        data: data ?? this.data,
        createdAt: createdAt,
        answer: _or(answer, this.answer),
        answeredAt: answeredAt,
      );

  List<Object?> get _fields => [
        reviewId,
        pairId,
        kind,
        googleName,
        graphId,
        data,
        createdAt,
        answer,
        answeredAt,
      ];

  @override
  bool operator ==(Object other) =>
      other is ContactReview && _sameFields(_fields, other._fields);

  @override
  int get hashCode => Object.hashAll(_fields);

  /// No ids or what is shown: names are in [data].
  @override
  String toString() => 'ContactReview($reviewId, $kind'
      '${isAnswered ? ', answered' : ''})';
}

/// A contact contact sync deleted, as read in full just before: for
/// Recently deleted, and for Restore.
@immutable
class ContactBinEntry {
  const ContactBinEntry({
    this.binId,
    required this.pairId,
    required this.side,
    required this.contactId,
    this.partnerId,
    this.state = ContactBinState.pending,
    this.deletedAt,
    required this.raw,
    this.partnerBase,
    required this.title,
    this.restore = false,
  });

  /// Null until the store has saved it.
  final int? binId;
  final int pairId;

  /// The side it was deleted from.
  final ContactSide side;
  final String contactId;

  /// Its partner on the other side, whose deletion it followed: where
  /// Restore looks first for whether that one is back.
  final String? partnerId;
  final ContactBinState state;

  /// Stamped by the store when the entry is written.
  final DateTime? deletedAt;

  /// The contact in full, raw JSON as its server returned it.
  final String raw;

  /// The partner's synced details, raw JSON, from its link.
  final String? partnerBase;

  /// The name shown in Recently deleted.
  final String title;

  /// Restore asked for, to be done in the next run.
  final bool restore;

  List<Object?> get _fields => [
        binId,
        pairId,
        side,
        contactId,
        partnerId,
        state,
        deletedAt,
        raw,
        partnerBase,
        title,
        restore,
      ];

  ContactBinEntry copyWith({
    Object? partnerId = _keep,
    ContactBinState? state,
    String? raw,
    Object? partnerBase = _keep,
    String? title,
    bool? restore,
  }) =>
      ContactBinEntry(
        binId: binId,
        pairId: pairId,
        side: side,
        contactId: contactId,
        partnerId: _or(partnerId, this.partnerId),
        state: state ?? this.state,
        deletedAt: deletedAt,
        raw: raw ?? this.raw,
        partnerBase: _or(partnerBase, this.partnerBase),
        title: title ?? this.title,
        restore: restore ?? this.restore,
      );

  @override
  bool operator ==(Object other) =>
      other is ContactBinEntry && _sameFields(_fields, other._fields);

  @override
  int get hashCode => Object.hashAll(_fields);

  /// No ids, details or name.
  @override
  String toString() => 'ContactBinEntry($binId, ${side.name}, ${state.name}'
      '${restore ? ', restore' : ''})';
}

/// A create about to be sent, for [ContactSyncStore.journalCreates]: the
/// contact it copies, and the hidden tag it carries. (The planner's
/// `ContactCreate` is the create itself.)
typedef ContactCreateEntry = ({String sourceKey, String tag});

/// What contact sync keeps between runs: the pairs, the links, the creates
/// in flight, Needs a look and the bin.
///
/// Each device keeps its own, which is why only one device syncs. Kept in
/// the database beside the cache ([DriftContactSyncStore]); the engine
/// falls back to [MemoryContactSyncStore] where there is none, and then the
/// sync forgets everything at a restart.
///
/// Rows of a pair are never shared with another. Lists come back in the
/// order the rows were first saved. Times are stamped from the store's
/// clock where the store writes them (a link saved, a create journalled, a
/// review raised or answered, a contact binned); the run's own times are
/// the runner's, set through [updatePair]. Every method that writes more
/// than one row writes all of them or none; writes of several methods that
/// must land together go in one [transaction].
abstract class ContactSyncStore {
  /// How long Recently deleted keeps a contact.
  static const keptFor = Duration(days: 30);

  /// How long a pair whose account was removed is kept for that account to
  /// be added again.
  static const detachedFor = Duration(days: 30);

  /// Run [body], whose calls to this store land together or not at all: if
  /// it throws, everything it wrote is undone and the error passes on.
  /// For writes that must not be parted by a crash, such as links held by
  /// a brake and its question on the pair, or an answer's links saved and
  /// its review dropped. Calls inside may be any of this store's, a
  /// [transaction] among them; one that throws and is caught inside
  /// [body] undoes only its own writes. [body] holds store calls only,
  /// never a network request: in the database it holds the file, and the
  /// mail cache's writes and the background worker's wait until it ends.
  Future<T> transaction<T>(Future<T> Function() body);

  // --- pairs ----------------------------------------------------------------

  Future<List<ContactPair>> pairs();

  Future<ContactPair?> pair(int pairId);

  /// The attached pair of these two accounts, if there is one.
  Future<ContactPair?> pairFor({
    required String googleAccountId,
    required String graphAccountId,
  });

  /// The pair of these two accounts: the attached one there is; else a
  /// detached one of the same two addresses, attached again under these
  /// account ids, carrying on where it stopped; else a new one.
  Future<ContactPair> ensurePair({
    required String googleAccountId,
    required String googleAddress,
    required String graphAccountId,
    required String graphAddress,
  });

  /// Read, change and write a pair as one step, so that an answer saved
  /// from the screen and a run's own writes cannot undo each other. Null
  /// when there is no such pair. [change] cannot change the pair's id, and
  /// the addresses it gives are lower-cased.
  Future<ContactPair?> updatePair(
    int pairId,
    ContactPair Function(ContactPair pair) change,
  );

  /// An account removed: every attached pair naming it is detached, keeping
  /// all it holds. How many were.
  Future<int> detachAccount(String accountId);

  /// An account added: every detached pair with [address] on [side] takes
  /// [accountId] there, and is attached again if its other side's account
  /// is among [liveAccountIds]. The pairs that took the account.
  Future<List<ContactPair>> reattachAccount({
    required ContactSide side,
    required String accountId,
    required String address,
    required Iterable<String> liveAccountIds,
  });

  /// Drop every pair detached for [detachedFor], with everything in it.
  /// How many went.
  Future<int> dropDetached();

  /// Drop a pair with everything in it.
  Future<void> dropPair(int pairId);

  // --- links ----------------------------------------------------------------

  Future<List<ContactLink>> links(int pairId);

  /// The link naming this contact on [side], if any.
  Future<ContactLink?> linkFor(int pairId, ContactSide side, String contactId);

  /// Save a link, adding it when it has no id yet. Throws [ArgumentError]
  /// for a link that breaks [ContactLink]'s rules, and [StateError] when
  /// another link of the pair already names one of its contacts, or when
  /// it has an id whose row has gone since it was read (dropped with its
  /// pair, or by a finished delete): saved again it would come back as a
  /// stray row with a new id.
  Future<ContactLink> saveLink(ContactLink link);

  /// Save several, as [saveLink], together.
  Future<List<ContactLink>> saveLinks(List<ContactLink> links);

  Future<void> deleteLinks(Iterable<int> linkIds);

  // --- creates in flight ----------------------------------------------------

  Future<List<ContactSyncOp>> ops(int pairId);

  /// Journal creates on [side] before they are sent. One for a contact
  /// already journalled on that side (a create given up and sent again)
  /// replaces it, with a new start time.
  Future<List<ContactSyncOp>> journalCreates(
    int pairId,
    ContactSide side,
    List<ContactCreateEntry> creates,
  );

  /// Creates that have landed: each op cleared and its link saved, all in
  /// one transaction. An op already gone is passed by; its link is saved
  /// all the same. Throws as [saveLinks] does, and then nothing changes.
  Future<List<ContactLink>> completeCreates(Map<int, ContactLink> linksByOp);

  /// Clear ops without saving a link: a create found not to have landed,
  /// to be journalled again when it is sent again.
  Future<void> dropOps(Iterable<int> opIds);

  // --- Needs a look ---------------------------------------------------------

  Future<List<ContactReview>> reviews(int pairId);

  /// Save a review. One with no id replaces the review of the pair with
  /// the same kind and ids, if there is one, taking its [ContactReview.data]
  /// and keeping its time and any answer queued; otherwise it is added.
  Future<ContactReview> saveReview(ContactReview review);

  /// Queue Ron's answer for the next run. Null when the review has gone.
  Future<ContactReview?> answerReview(int reviewId, String answer);

  Future<void> dropReviews(Iterable<int> reviewIds);

  // --- Recently deleted -----------------------------------------------------

  Future<List<ContactBinEntry>> bin(int pairId);

  Future<ContactBinEntry?> binEntry(
    int pairId,
    ContactSide side,
    String contactId,
  );

  /// Bin a contact, pending, before its delete is sent. One already binned
  /// for the same side and contact is replaced.
  Future<ContactBinEntry> addToBin(ContactBinEntry entry);

  /// The delete has landed (a 204 or a 404): the entry is done and, in the
  /// same transaction, [dropLinkId]'s link goes.
  Future<ContactBinEntry?> markBinDone(int binId, {int? dropLinkId});

  /// Ron brought the contact back himself.
  Future<ContactBinEntry?> markBinBack(int binId);

  /// Queue Restore for the next run, or take it back.
  Future<ContactBinEntry?> askRestore(int binId, {bool restore = true});

  Future<void> dropBin(Iterable<int> binIds);

  /// Drop the pair's entries binned more than [keptFor] ago. How many went.
  Future<int> pruneBin(int pairId);

  // --- re-keys --------------------------------------------------------------

  /// A contact's id changed on [side] (Google's re-keys): every place in
  /// the pair that names [oldId] names [newId] instead, together: links,
  /// reviews, the source of creates on the other side, and the bin, where
  /// it is the contact or a partner. Throws [StateError], changing nothing,
  /// when a link or a bin entry of the pair already names [newId] on that
  /// side, or a create on the other side already copies [newId] (two
  /// creates in flight whose sources Ron then merged).
  Future<void> rekey(
    int pairId,
    ContactSide side,
    String oldId,
    String newId,
  );
}

/// [ContactSyncStore] in the database, beside the cache.
class DriftContactSyncStore implements ContactSyncStore {
  DriftContactSyncStore(this.db, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final MailDatabase db;
  final DateTime Function() _clock;

  DateTime _now() => _kept(_clock())!;

  @override
  Future<T> transaction<T>(Future<T> Function() body) =>
      db.transaction(body);

  // --- pairs ----------------------------------------------------------------

  @override
  Future<List<ContactPair>> pairs() async => [
        for (final r in await (db.select(db.contactPairs)
              ..orderBy([(t) => OrderingTerm.asc(t.pairId)]))
            .get())
          _pairOf(r),
      ];

  @override
  Future<ContactPair?> pair(int pairId) async {
    final r = await (db.select(db.contactPairs)
          ..where((t) => t.pairId.equals(pairId)))
        .getSingleOrNull();
    return r == null ? null : _pairOf(r);
  }

  @override
  Future<ContactPair?> pairFor({
    required String googleAccountId,
    required String graphAccountId,
  }) async {
    final rows = await (db.select(db.contactPairs)
          ..where((t) =>
              t.googleAccountId.equals(googleAccountId) &
              t.graphAccountId.equals(graphAccountId) &
              t.detachedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.pairId)]))
        .get();
    return rows.isEmpty ? null : _pairOf(rows.first);
  }

  @override
  Future<ContactPair> ensurePair({
    required String googleAccountId,
    required String googleAddress,
    required String graphAccountId,
    required String graphAddress,
  }) =>
      db.transaction(() async {
        final attached = await pairFor(
          googleAccountId: googleAccountId,
          graphAccountId: graphAccountId,
        );
        if (attached != null) return attached;
        final google = googleAddress.toLowerCase();
        final graph = graphAddress.toLowerCase();
        final detached = await (db.select(db.contactPairs)
              ..where((t) =>
                  t.googleAddress.equals(google) &
                  t.graphAddress.equals(graph) &
                  t.detachedAt.isNotNull())
              ..orderBy([(t) => OrderingTerm.desc(t.pairId)]))
            .get();
        if (detached.isNotEmpty) {
          final back = _pairOf(detached.first).copyWith(
            googleAccountId: googleAccountId,
            graphAccountId: graphAccountId,
            detachedAt: null,
          );
          await _writePair(back);
          return back;
        }
        final id = await db.into(db.contactPairs).insert(
              ContactPairsCompanion.insert(
                googleAccountId: googleAccountId,
                googleAddress: google,
                graphAccountId: graphAccountId,
                graphAddress: graph,
              ),
            );
        return (await pair(id))!;
      });

  @override
  Future<ContactPair?> updatePair(
    int pairId,
    ContactPair Function(ContactPair pair) change,
  ) =>
      db.transaction(() async {
        final before = await pair(pairId);
        if (before == null) return null;
        final after = _asKept(pairId, change(before));
        await _writePair(after);
        return after;
      });

  Future<void> _writePair(ContactPair p) async {
    await (db.update(db.contactPairs)
          ..where((t) => t.pairId.equals(p.pairId)))
        .write(ContactPairsCompanion(
      googleAccountId: Value(p.googleAccountId),
      googleAddress: Value(p.googleAddress),
      graphAccountId: Value(p.graphAccountId),
      graphAddress: Value(p.graphAddress),
      graphFolderId: Value(p.graphFolderId),
      phoneRegion: Value(p.phoneRegion),
      googleSyncToken: Value(p.googleSyncToken),
      googleMask: Value(p.googleMask),
      googleFullAt: Value(_ms(p.googleFullAt)),
      graphDeltaLink: Value(p.graphDeltaLink),
      graphMask: Value(p.graphMask),
      normaliser: Value(p.normaliser),
      googleCount: Value(p.googleCount),
      graphCount: Value(p.graphCount),
      firstStartedAt: Value(_ms(p.firstStartedAt)),
      firstDoneAt: Value(_ms(p.firstDoneAt)),
      lastAttemptAt: Value(_ms(p.lastAttemptAt)),
      lastDoneAt: Value(_ms(p.lastDoneAt)),
      lastResult: Value(p.lastResult),
      held: Value(p.held),
      detachedAt: Value(_ms(p.detachedAt)),
    ));
  }

  @override
  Future<int> detachAccount(String accountId) =>
      (db.update(db.contactPairs)
            ..where((t) =>
                (t.googleAccountId.equals(accountId) |
                    t.graphAccountId.equals(accountId)) &
                t.detachedAt.isNull()))
          .write(ContactPairsCompanion(
        detachedAt: Value(_now().millisecondsSinceEpoch),
      ));

  @override
  Future<List<ContactPair>> reattachAccount({
    required ContactSide side,
    required String accountId,
    required String address,
    required Iterable<String> liveAccountIds,
  }) =>
      db.transaction(() async {
        final lower = address.toLowerCase();
        final live = liveAccountIds.toSet();
        final rows = await (db.select(db.contactPairs)
              ..where((t) =>
                  (side == ContactSide.google
                      ? t.googleAddress.equals(lower)
                      : t.graphAddress.equals(lower)) &
                  t.detachedAt.isNotNull())
              ..orderBy([(t) => OrderingTerm.asc(t.pairId)]))
            .get();
        final taken = <ContactPair>[];
        for (final r in rows) {
          final p = _reattached(_pairOf(r), side, accountId, live);
          await _writePair(p);
          taken.add(p);
        }
        return taken;
      });

  @override
  Future<int> dropDetached() => db.transaction(() async {
        final before = _now()
            .subtract(ContactSyncStore.detachedFor)
            .millisecondsSinceEpoch;
        final rows = await (db.select(db.contactPairs)
              ..where((t) => t.detachedAt.isSmallerOrEqualValue(before)))
            .get();
        for (final r in rows) {
          await _dropPair(r.pairId);
        }
        return rows.length;
      });

  @override
  Future<void> dropPair(int pairId) =>
      db.transaction(() => _dropPair(pairId));

  Future<void> _dropPair(int pairId) async {
    await (db.delete(db.contactLinks)..where((t) => t.pairId.equals(pairId)))
        .go();
    await (db.delete(db.contactSyncOps)..where((t) => t.pairId.equals(pairId)))
        .go();
    await (db.delete(db.contactReviews)..where((t) => t.pairId.equals(pairId)))
        .go();
    await (db.delete(db.contactBin)..where((t) => t.pairId.equals(pairId)))
        .go();
    await (db.delete(db.contactPairs)..where((t) => t.pairId.equals(pairId)))
        .go();
  }

  // --- links ----------------------------------------------------------------

  @override
  Future<List<ContactLink>> links(int pairId) async => [
        for (final r in await (db.select(db.contactLinks)
              ..where((t) => t.pairId.equals(pairId))
              ..orderBy([(t) => OrderingTerm.asc(t.linkId)]))
            .get())
          _linkOf(r),
      ];

  @override
  Future<ContactLink?> linkFor(
    int pairId,
    ContactSide side,
    String contactId,
  ) async {
    final r = await (db.select(db.contactLinks)
          ..where((t) =>
              t.pairId.equals(pairId) &
              (side == ContactSide.google
                  ? t.googleName.equals(contactId)
                  : t.graphId.equals(contactId))))
        .getSingleOrNull();
    return r == null ? null : _linkOf(r);
  }

  @override
  Future<ContactLink> saveLink(ContactLink link) async =>
      (await saveLinks([link])).single;

  @override
  Future<List<ContactLink>> saveLinks(List<ContactLink> links) async {
    for (final l in links) {
      l._check();
    }
    return db.transaction(() async {
      final at = _now();
      return [for (final l in links) await _saveLink(l, at)];
    });
  }

  /// One link written, inside a transaction the caller holds.
  Future<ContactLink> _saveLink(ContactLink link, DateTime at) async {
    for (final side in ContactSide.values) {
      final id = link.idOn(side);
      if (id == null) continue;
      final other = await linkFor(link.pairId, side, id);
      if (other != null && other.linkId != link.linkId) {
        throw StateError(
          'Another contact link of the pair names this ${side.name} contact.',
        );
      }
    }
    final row = ContactLinksCompanion(
      pairId: Value(link.pairId),
      googleName: Value(link.googleName),
      graphId: Value(link.graphId),
      googleEtag: Value(link.googleEtag),
      graphChangeKey: Value(link.graphChangeKey),
      googleBase: Value(link.googleBase),
      graphBase: Value(link.graphBase),
      state: Value(link.state.name),
      reason: Value(link.reason?.code),
      googleWrittenAt: Value(_ms(link.googleWrittenAt)),
      updatedAt: Value(at.millisecondsSinceEpoch),
    );
    final linkId = link.linkId;
    if (linkId != null) {
      final changed = await (db.update(db.contactLinks)
            ..where((t) => t.linkId.equals(linkId)))
          .write(row);
      if (changed == 0) throw _linkGone();
      return link._saved(linkId, at);
    }
    final id = await db.into(db.contactLinks).insert(row);
    return link._saved(id, at);
  }

  @override
  Future<void> deleteLinks(Iterable<int> linkIds) async {
    final ids = linkIds.toList();
    if (ids.isEmpty) return;
    await (db.delete(db.contactLinks)..where((t) => t.linkId.isIn(ids))).go();
  }

  // --- creates in flight ----------------------------------------------------

  @override
  Future<List<ContactSyncOp>> ops(int pairId) async => [
        for (final r in await (db.select(db.contactSyncOps)
              ..where((t) => t.pairId.equals(pairId))
              ..orderBy([(t) => OrderingTerm.asc(t.opId)]))
            .get())
          ?_opOf(r),
      ];

  @override
  Future<List<ContactSyncOp>> journalCreates(
    int pairId,
    ContactSide side,
    List<ContactCreateEntry> creates,
  ) =>
      db.transaction(() async {
        final at = _now();
        final journalled = <ContactSyncOp>[];
        for (final c in creates) {
          await (db.delete(db.contactSyncOps)
                ..where((t) =>
                    t.pairId.equals(pairId) &
                    t.side.equals(side.name) &
                    t.sourceKey.equals(c.sourceKey)))
              .go();
          final id = await db.into(db.contactSyncOps).insert(
                ContactSyncOpsCompanion.insert(
                  pairId: pairId,
                  side: side.name,
                  sourceKey: c.sourceKey,
                  tag: c.tag,
                  startedAt: at.millisecondsSinceEpoch,
                ),
              );
          journalled.add(ContactSyncOp(
            opId: id,
            pairId: pairId,
            side: side,
            sourceKey: c.sourceKey,
            tag: c.tag,
            startedAt: at,
          ));
        }
        return journalled;
      });

  @override
  Future<List<ContactLink>> completeCreates(
    Map<int, ContactLink> linksByOp,
  ) async {
    for (final l in linksByOp.values) {
      l._check();
    }
    return db.transaction(() async {
      final at = _now();
      final saved = <ContactLink>[];
      for (final MapEntry(key: opId, value: link) in linksByOp.entries) {
        await (db.delete(db.contactSyncOps)..where((t) => t.opId.equals(opId)))
            .go();
        saved.add(await _saveLink(link, at));
      }
      return saved;
    });
  }

  @override
  Future<void> dropOps(Iterable<int> opIds) async {
    final ids = opIds.toList();
    if (ids.isEmpty) return;
    await (db.delete(db.contactSyncOps)..where((t) => t.opId.isIn(ids))).go();
  }

  // --- Needs a look ---------------------------------------------------------

  @override
  Future<List<ContactReview>> reviews(int pairId) async => [
        for (final r in await (db.select(db.contactReviews)
              ..where((t) => t.pairId.equals(pairId))
              ..orderBy([(t) => OrderingTerm.asc(t.reviewId)]))
            .get())
          _reviewOf(r),
      ];

  @override
  Future<ContactReview> saveReview(ContactReview review) =>
      db.transaction(() async {
        final at = _now();
        final reviewId = review.reviewId;
        if (reviewId != null) {
          final before = await _review(reviewId);
          if (before != null) {
            final after = ContactReview(
              reviewId: reviewId,
              pairId: before.pairId,
              kind: review.kind,
              googleName: review.googleName,
              graphId: review.graphId,
              data: review.data,
              createdAt: before.createdAt,
              answer: review.answer,
              answeredAt: review.answer == null
                  ? null
                  : review.answer == before.answer
                      ? before.answeredAt
                      : at,
            );
            await _writeReview(after);
            return after;
          }
        }
        final same = await (db.select(db.contactReviews)
              ..where((t) =>
                  t.pairId.equals(review.pairId) &
                  t.kind.equals(review.kind) &
                  t.googleName.equalsNullable(review.googleName) &
                  t.graphId.equalsNullable(review.graphId))
              ..orderBy([(t) => OrderingTerm.asc(t.reviewId)]))
            .get();
        if (same.isNotEmpty) {
          final after = _reviewOf(same.first).copyWith(data: review.data);
          await _writeReview(after);
          return after;
        }
        final answeredAt = review.answer == null ? null : at;
        final id = await db.into(db.contactReviews).insert(
              ContactReviewsCompanion.insert(
                pairId: review.pairId,
                kind: review.kind,
                googleName: Value(review.googleName),
                graphId: Value(review.graphId),
                data: review.data,
                createdAt: at.millisecondsSinceEpoch,
                answer: Value(review.answer),
                answeredAt: Value(_ms(answeredAt)),
              ),
            );
        return ContactReview(
          reviewId: id,
          pairId: review.pairId,
          kind: review.kind,
          googleName: review.googleName,
          graphId: review.graphId,
          data: review.data,
          createdAt: at,
          answer: review.answer,
          answeredAt: answeredAt,
        );
      });

  Future<ContactReview?> _review(int reviewId) async {
    final r = await (db.select(db.contactReviews)
          ..where((t) => t.reviewId.equals(reviewId)))
        .getSingleOrNull();
    return r == null ? null : _reviewOf(r);
  }

  Future<void> _writeReview(ContactReview r) async {
    await (db.update(db.contactReviews)
          ..where((t) => t.reviewId.equals(r.reviewId!)))
        .write(ContactReviewsCompanion(
      kind: Value(r.kind),
      googleName: Value(r.googleName),
      graphId: Value(r.graphId),
      data: Value(r.data),
      answer: Value(r.answer),
      answeredAt: Value(_ms(r.answeredAt)),
    ));
  }

  @override
  Future<ContactReview?> answerReview(int reviewId, String answer) =>
      db.transaction(() async {
        final before = await _review(reviewId);
        if (before == null) return null;
        final after = ContactReview(
          reviewId: reviewId,
          pairId: before.pairId,
          kind: before.kind,
          googleName: before.googleName,
          graphId: before.graphId,
          data: before.data,
          createdAt: before.createdAt,
          answer: answer,
          answeredAt: _now(),
        );
        await _writeReview(after);
        return after;
      });

  @override
  Future<void> dropReviews(Iterable<int> reviewIds) async {
    final ids = reviewIds.toList();
    if (ids.isEmpty) return;
    await (db.delete(db.contactReviews)..where((t) => t.reviewId.isIn(ids)))
        .go();
  }

  // --- Recently deleted -----------------------------------------------------

  @override
  Future<List<ContactBinEntry>> bin(int pairId) async => [
        for (final r in await (db.select(db.contactBin)
              ..where((t) => t.pairId.equals(pairId))
              ..orderBy([(t) => OrderingTerm.asc(t.binId)]))
            .get())
          ?_binOf(r),
      ];

  @override
  Future<ContactBinEntry?> binEntry(
    int pairId,
    ContactSide side,
    String contactId,
  ) async {
    final r = await (db.select(db.contactBin)
          ..where((t) =>
              t.pairId.equals(pairId) &
              t.side.equals(side.name) &
              t.contactId.equals(contactId)))
        .getSingleOrNull();
    return r == null ? null : _binOf(r);
  }

  Future<ContactBinEntry?> _binById(int binId) async {
    final r = await (db.select(db.contactBin)
          ..where((t) => t.binId.equals(binId)))
        .getSingleOrNull();
    return r == null ? null : _binOf(r);
  }

  @override
  Future<ContactBinEntry> addToBin(ContactBinEntry entry) =>
      db.transaction(() async {
        final at = _now();
        await (db.delete(db.contactBin)
              ..where((t) =>
                  t.pairId.equals(entry.pairId) &
                  t.side.equals(entry.side.name) &
                  t.contactId.equals(entry.contactId)))
            .go();
        final id = await db.into(db.contactBin).insert(
              ContactBinCompanion.insert(
                pairId: entry.pairId,
                side: entry.side.name,
                contactId: entry.contactId,
                partnerId: Value(entry.partnerId),
                state: entry.state.name,
                deletedAt: at.millisecondsSinceEpoch,
                raw: entry.raw,
                partnerBase: Value(entry.partnerBase),
                title: entry.title,
                restore: Value(entry.restore),
              ),
            );
        return (await _binById(id))!;
      });

  Future<ContactBinEntry?> _changeBin(
    int binId,
    ContactBinCompanion change,
  ) async {
    final changed = await (db.update(db.contactBin)
          ..where((t) => t.binId.equals(binId)))
        .write(change);
    return changed == 0 ? null : _binById(binId);
  }

  @override
  Future<ContactBinEntry?> markBinDone(int binId, {int? dropLinkId}) =>
      db.transaction(() async {
        final done = await _changeBin(
          binId,
          ContactBinCompanion(state: Value(ContactBinState.done.name)),
        );
        if (dropLinkId != null) await deleteLinks([dropLinkId]);
        return done;
      });

  @override
  Future<ContactBinEntry?> markBinBack(int binId) => _changeBin(
        binId,
        ContactBinCompanion(state: Value(ContactBinState.back.name)),
      );

  @override
  Future<ContactBinEntry?> askRestore(int binId, {bool restore = true}) =>
      _changeBin(binId, ContactBinCompanion(restore: Value(restore)));

  @override
  Future<void> dropBin(Iterable<int> binIds) async {
    final ids = binIds.toList();
    if (ids.isEmpty) return;
    await (db.delete(db.contactBin)..where((t) => t.binId.isIn(ids))).go();
  }

  @override
  Future<int> pruneBin(int pairId) {
    final before =
        _now().subtract(ContactSyncStore.keptFor).millisecondsSinceEpoch;
    return (db.delete(db.contactBin)
          ..where((t) =>
              t.pairId.equals(pairId) & t.deletedAt.isSmallerThanValue(before)))
        .go();
  }

  // --- re-keys --------------------------------------------------------------

  @override
  Future<void> rekey(
    int pairId,
    ContactSide side,
    String oldId,
    String newId,
  ) =>
      db.transaction(() async {
        if (oldId == newId) return;
        final copied = await (db.select(db.contactSyncOps)
              ..where((t) =>
                  t.pairId.equals(pairId) &
                  t.side.equals(side.other.name) &
                  t.sourceKey.equals(newId)))
            .get();
        if (await linkFor(pairId, side, newId) != null ||
            await binEntry(pairId, side, newId) != null ||
            copied.isNotEmpty) {
          throw _rekeyClash(side);
        }
        final google = side == ContactSide.google;
        await (db.update(db.contactLinks)
              ..where((t) =>
                  t.pairId.equals(pairId) &
                  (google
                      ? t.googleName.equals(oldId)
                      : t.graphId.equals(oldId))))
            .write(google
                ? ContactLinksCompanion(googleName: Value(newId))
                : ContactLinksCompanion(graphId: Value(newId)));
        await (db.update(db.contactReviews)
              ..where((t) =>
                  t.pairId.equals(pairId) &
                  (google
                      ? t.googleName.equals(oldId)
                      : t.graphId.equals(oldId))))
            .write(google
                ? ContactReviewsCompanion(googleName: Value(newId))
                : ContactReviewsCompanion(graphId: Value(newId)));
        // A create on the other side copies this contact.
        await (db.update(db.contactSyncOps)
              ..where((t) =>
                  t.pairId.equals(pairId) &
                  t.side.equals(side.other.name) &
                  t.sourceKey.equals(oldId)))
            .write(ContactSyncOpsCompanion(sourceKey: Value(newId)));
        await (db.update(db.contactBin)
              ..where((t) =>
                  t.pairId.equals(pairId) &
                  t.side.equals(side.name) &
                  t.contactId.equals(oldId)))
            .write(ContactBinCompanion(contactId: Value(newId)));
        await (db.update(db.contactBin)
              ..where((t) =>
                  t.pairId.equals(pairId) &
                  t.side.equals(side.other.name) &
                  t.partnerId.equals(oldId)))
            .write(ContactBinCompanion(partnerId: Value(newId)));
      });

  // --- rows -----------------------------------------------------------------

  static ContactPair _pairOf(ContactPairRow r) => ContactPair(
        pairId: r.pairId,
        googleAccountId: r.googleAccountId,
        googleAddress: r.googleAddress,
        graphAccountId: r.graphAccountId,
        graphAddress: r.graphAddress,
        graphFolderId: r.graphFolderId,
        phoneRegion: r.phoneRegion,
        googleSyncToken: r.googleSyncToken,
        googleMask: r.googleMask,
        googleFullAt: _time(r.googleFullAt),
        graphDeltaLink: r.graphDeltaLink,
        graphMask: r.graphMask,
        normaliser: r.normaliser,
        googleCount: r.googleCount,
        graphCount: r.graphCount,
        firstStartedAt: _time(r.firstStartedAt),
        firstDoneAt: _time(r.firstDoneAt),
        lastAttemptAt: _time(r.lastAttemptAt),
        lastDoneAt: _time(r.lastDoneAt),
        lastResult: r.lastResult,
        held: r.held,
        detachedAt: _time(r.detachedAt),
      );

  static ContactLink _linkOf(ContactLinkRow r) {
    final state = ContactLinkState.values.asNameMap()[r.state];
    final reason = ContactHeldReason.fromCode(r.reason);
    return _linkRead(
      linkId: r.linkId,
      pairId: r.pairId,
      googleName: r.googleName,
      graphId: r.graphId,
      googleEtag: r.googleEtag,
      graphChangeKey: r.graphChangeKey,
      googleBase: r.googleBase,
      graphBase: r.graphBase,
      state: state,
      reason: reason,
      googleWrittenAt: _time(r.googleWrittenAt),
      updatedAt: _time(r.updatedAt),
    );
  }

  static ContactSyncOp? _opOf(ContactSyncOpRow r) {
    final side = ContactSide.values.asNameMap()[r.side];
    if (side == null) return null;
    return ContactSyncOp(
      opId: r.opId,
      pairId: r.pairId,
      side: side,
      sourceKey: r.sourceKey,
      tag: r.tag,
      startedAt: _time(r.startedAt)!,
    );
  }

  static ContactReview _reviewOf(ContactReviewRow r) => ContactReview(
        reviewId: r.reviewId,
        pairId: r.pairId,
        kind: r.kind,
        googleName: r.googleName,
        graphId: r.graphId,
        data: r.data,
        createdAt: _time(r.createdAt),
        answer: r.answer,
        answeredAt: _time(r.answeredAt),
      );

  static ContactBinEntry? _binOf(ContactBinRow r) {
    final side = ContactSide.values.asNameMap()[r.side];
    if (side == null) return null;
    return ContactBinEntry(
      binId: r.binId,
      pairId: r.pairId,
      side: side,
      contactId: r.contactId,
      partnerId: r.partnerId,
      // A state this build does not know, from a later one, reads as done:
      // nothing is sent again for it.
      state: ContactBinState.values.asNameMap()[r.state] ??
          ContactBinState.done,
      deletedAt: _time(r.deletedAt),
      raw: r.raw,
      partnerBase: r.partnerBase,
      title: r.title,
      restore: r.restore,
    );
  }
}

/// [ContactSyncStore] in memory, for tests and for a build with no
/// database. Everything goes when the process does.
class MemoryContactSyncStore implements ContactSyncStore {
  MemoryContactSyncStore({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  DateTime _now() => _kept(_clock())!;

  // Each by its id, which only ever rises, so a map's order is the order
  // the rows were added in.
  final Map<int, ContactPair> _pairs = {};
  final Map<int, ContactLink> _links = {};
  final Map<int, ContactSyncOp> _ops = {};
  final Map<int, ContactReview> _reviews = {};
  final Map<int, ContactBinEntry> _bin = {};
  int _lastId = 0;

  int _nextId() => ++_lastId;

  /// Everything is put back as it was before [body] if it throws, nested
  /// ones each to their own start. Writes made meanwhile by a caller
  /// outside [body] are undone with it: unlike the database, nothing
  /// here makes them wait. The tests that use this store do not race it.
  @override
  Future<T> transaction<T>(Future<T> Function() body) async {
    final pairs = Map.of(_pairs);
    final links = Map.of(_links);
    final ops = Map.of(_ops);
    final reviews = Map.of(_reviews);
    final bin = Map.of(_bin);
    final lastId = _lastId;
    try {
      return await body();
    } catch (_) {
      void restore<V>(Map<int, V> into, Map<int, V> from) => into
        ..clear()
        ..addAll(from);
      restore(_pairs, pairs);
      restore(_links, links);
      restore(_ops, ops);
      restore(_reviews, reviews);
      restore(_bin, bin);
      _lastId = lastId;
      rethrow;
    }
  }

  // --- pairs ----------------------------------------------------------------

  @override
  Future<List<ContactPair>> pairs() async => _pairs.values.toList();

  @override
  Future<ContactPair?> pair(int pairId) async => _pairs[pairId];

  ContactPair? _attached(String googleAccountId, String graphAccountId) =>
      _pairs.values.lastWhereOrNull((p) =>
          p.googleAccountId == googleAccountId &&
          p.graphAccountId == graphAccountId &&
          !p.isDetached);

  @override
  Future<ContactPair?> pairFor({
    required String googleAccountId,
    required String graphAccountId,
  }) async =>
      _attached(googleAccountId, graphAccountId);

  @override
  Future<ContactPair> ensurePair({
    required String googleAccountId,
    required String googleAddress,
    required String graphAccountId,
    required String graphAddress,
  }) async {
    final attached = _attached(googleAccountId, graphAccountId);
    if (attached != null) return attached;
    final google = googleAddress.toLowerCase();
    final graph = graphAddress.toLowerCase();
    final detached = _pairs.values.lastWhereOrNull((p) =>
        p.googleAddress == google && p.graphAddress == graph && p.isDetached);
    if (detached != null) {
      return _pairs[detached.pairId] = detached.copyWith(
        googleAccountId: googleAccountId,
        graphAccountId: graphAccountId,
        detachedAt: null,
      );
    }
    final id = _nextId();
    return _pairs[id] = ContactPair(
      pairId: id,
      googleAccountId: googleAccountId,
      googleAddress: google,
      graphAccountId: graphAccountId,
      graphAddress: graph,
    );
  }

  @override
  Future<ContactPair?> updatePair(
    int pairId,
    ContactPair Function(ContactPair pair) change,
  ) async {
    final before = _pairs[pairId];
    if (before == null) return null;
    return _pairs[pairId] = _asKept(pairId, change(before));
  }

  @override
  Future<int> detachAccount(String accountId) async {
    final at = _now();
    var count = 0;
    for (final p in _pairs.values.toList()) {
      if (p.isDetached) continue;
      if (p.googleAccountId != accountId && p.graphAccountId != accountId) {
        continue;
      }
      _pairs[p.pairId] = p.copyWith(detachedAt: at);
      count++;
    }
    return count;
  }

  @override
  Future<List<ContactPair>> reattachAccount({
    required ContactSide side,
    required String accountId,
    required String address,
    required Iterable<String> liveAccountIds,
  }) async {
    final lower = address.toLowerCase();
    final live = liveAccountIds.toSet();
    final taken = <ContactPair>[];
    for (final p in _pairs.values.toList()) {
      if (!p.isDetached || p.addressOn(side) != lower) continue;
      final back = _reattached(p, side, accountId, live);
      _pairs[p.pairId] = back;
      taken.add(back);
    }
    return taken;
  }

  @override
  Future<int> dropDetached() async {
    final before = _now().subtract(ContactSyncStore.detachedFor);
    final doomed = [
      for (final p in _pairs.values)
        if (p.detachedAt case final at? when !at.isAfter(before)) p.pairId,
    ];
    doomed.forEach(_dropPair);
    return doomed.length;
  }

  @override
  Future<void> dropPair(int pairId) async => _dropPair(pairId);

  void _dropPair(int pairId) {
    _links.removeWhere((_, l) => l.pairId == pairId);
    _ops.removeWhere((_, o) => o.pairId == pairId);
    _reviews.removeWhere((_, r) => r.pairId == pairId);
    _bin.removeWhere((_, b) => b.pairId == pairId);
    _pairs.remove(pairId);
  }

  // --- links ----------------------------------------------------------------

  @override
  Future<List<ContactLink>> links(int pairId) async =>
      [for (final l in _links.values) if (l.pairId == pairId) l];

  ContactLink? _linkFor(
    Map<int, ContactLink> links,
    int pairId,
    ContactSide side,
    String contactId,
  ) =>
      links.values.firstWhereOrNull(
          (l) => l.pairId == pairId && l.idOn(side) == contactId);

  @override
  Future<ContactLink?> linkFor(
    int pairId,
    ContactSide side,
    String contactId,
  ) async =>
      _linkFor(_links, pairId, side, contactId);

  @override
  Future<ContactLink> saveLink(ContactLink link) async =>
      (await saveLinks([link])).single;

  @override
  Future<List<ContactLink>> saveLinks(List<ContactLink> links) async {
    for (final l in links) {
      l._check();
    }
    // Written into a copy and swapped in at the end, so a clash part way
    // leaves nothing changed, as the database's transaction does.
    final next = Map.of(_links);
    final at = _now();
    final saved = [for (final l in links) _saveLink(next, l, at)];
    _links
      ..clear()
      ..addAll(next);
    return saved;
  }

  ContactLink _saveLink(
    Map<int, ContactLink> links,
    ContactLink link,
    DateTime at,
  ) {
    for (final side in ContactSide.values) {
      final id = link.idOn(side);
      if (id == null) continue;
      final other = _linkFor(links, link.pairId, side, id);
      if (other != null && other.linkId != link.linkId) {
        throw StateError(
          'Another contact link of the pair names this ${side.name} contact.',
        );
      }
    }
    final known = link.linkId;
    if (known != null && !links.containsKey(known)) throw _linkGone();
    final id = known ?? _nextId();
    return links[id] = link._saved(id, at);
  }

  @override
  Future<void> deleteLinks(Iterable<int> linkIds) async {
    for (final id in linkIds) {
      _links.remove(id);
    }
  }

  // --- creates in flight ----------------------------------------------------

  @override
  Future<List<ContactSyncOp>> ops(int pairId) async =>
      [for (final o in _ops.values) if (o.pairId == pairId) o];

  @override
  Future<List<ContactSyncOp>> journalCreates(
    int pairId,
    ContactSide side,
    List<ContactCreateEntry> creates,
  ) async {
    final at = _now();
    return [
      for (final c in creates) _journal(pairId, side, c, at),
    ];
  }

  ContactSyncOp _journal(
    int pairId,
    ContactSide side,
    ContactCreateEntry create,
    DateTime at,
  ) {
    _ops.removeWhere((_, o) =>
        o.pairId == pairId &&
        o.side == side &&
        o.sourceKey == create.sourceKey);
    final id = _nextId();
    return _ops[id] = ContactSyncOp(
      opId: id,
      pairId: pairId,
      side: side,
      sourceKey: create.sourceKey,
      tag: create.tag,
      startedAt: at,
    );
  }

  @override
  Future<List<ContactLink>> completeCreates(
    Map<int, ContactLink> linksByOp,
  ) async {
    final saved = await saveLinks(linksByOp.values.toList());
    linksByOp.keys.forEach(_ops.remove);
    return saved;
  }

  @override
  Future<void> dropOps(Iterable<int> opIds) async =>
      opIds.forEach(_ops.remove);

  // --- Needs a look ---------------------------------------------------------

  @override
  Future<List<ContactReview>> reviews(int pairId) async =>
      [for (final r in _reviews.values) if (r.pairId == pairId) r];

  @override
  Future<ContactReview> saveReview(ContactReview review) async {
    final at = _now();
    final known = review.reviewId == null ? null : _reviews[review.reviewId];
    if (known != null) {
      return _reviews[known.reviewId!] = ContactReview(
        reviewId: known.reviewId,
        pairId: known.pairId,
        kind: review.kind,
        googleName: review.googleName,
        graphId: review.graphId,
        data: review.data,
        createdAt: known.createdAt,
        answer: review.answer,
        answeredAt: review.answer == null
            ? null
            : review.answer == known.answer
                ? known.answeredAt
                : at,
      );
    }
    final same = _reviews.values.firstWhereOrNull((r) =>
        r.pairId == review.pairId &&
        r.kind == review.kind &&
        r.googleName == review.googleName &&
        r.graphId == review.graphId);
    if (same != null) {
      return _reviews[same.reviewId!] = same.copyWith(data: review.data);
    }
    final id = _nextId();
    return _reviews[id] = ContactReview(
      reviewId: id,
      pairId: review.pairId,
      kind: review.kind,
      googleName: review.googleName,
      graphId: review.graphId,
      data: review.data,
      createdAt: at,
      answer: review.answer,
      answeredAt: review.answer == null ? null : at,
    );
  }

  @override
  Future<ContactReview?> answerReview(int reviewId, String answer) async {
    final before = _reviews[reviewId];
    if (before == null) return null;
    return _reviews[reviewId] = ContactReview(
      reviewId: reviewId,
      pairId: before.pairId,
      kind: before.kind,
      googleName: before.googleName,
      graphId: before.graphId,
      data: before.data,
      createdAt: before.createdAt,
      answer: answer,
      answeredAt: _now(),
    );
  }

  @override
  Future<void> dropReviews(Iterable<int> reviewIds) async =>
      reviewIds.forEach(_reviews.remove);

  // --- Recently deleted -----------------------------------------------------

  @override
  Future<List<ContactBinEntry>> bin(int pairId) async =>
      [for (final b in _bin.values) if (b.pairId == pairId) b];

  @override
  Future<ContactBinEntry?> binEntry(
    int pairId,
    ContactSide side,
    String contactId,
  ) async =>
      _binEntry(pairId, side, contactId);

  ContactBinEntry? _binEntry(int pairId, ContactSide side, String contactId) =>
      _bin.values.firstWhereOrNull((b) =>
          b.pairId == pairId && b.side == side && b.contactId == contactId);

  @override
  Future<ContactBinEntry> addToBin(ContactBinEntry entry) async {
    _bin.removeWhere((_, b) =>
        b.pairId == entry.pairId &&
        b.side == entry.side &&
        b.contactId == entry.contactId);
    final id = _nextId();
    return _bin[id] = ContactBinEntry(
      binId: id,
      pairId: entry.pairId,
      side: entry.side,
      contactId: entry.contactId,
      partnerId: entry.partnerId,
      state: entry.state,
      deletedAt: _now(),
      raw: entry.raw,
      partnerBase: entry.partnerBase,
      title: entry.title,
      restore: entry.restore,
    );
  }

  @override
  Future<ContactBinEntry?> markBinDone(int binId, {int? dropLinkId}) async {
    final before = _bin[binId];
    if (dropLinkId != null) _links.remove(dropLinkId);
    if (before == null) return null;
    return _bin[binId] = before.copyWith(state: ContactBinState.done);
  }

  @override
  Future<ContactBinEntry?> markBinBack(int binId) async {
    final before = _bin[binId];
    if (before == null) return null;
    return _bin[binId] = before.copyWith(state: ContactBinState.back);
  }

  @override
  Future<ContactBinEntry?> askRestore(int binId, {bool restore = true}) async {
    final before = _bin[binId];
    if (before == null) return null;
    return _bin[binId] = before.copyWith(restore: restore);
  }

  @override
  Future<void> dropBin(Iterable<int> binIds) async =>
      binIds.forEach(_bin.remove);

  @override
  Future<int> pruneBin(int pairId) async {
    final before = _now().subtract(ContactSyncStore.keptFor);
    final doomed = [
      for (final b in _bin.values)
        if (b.pairId == pairId && b.deletedAt!.isBefore(before)) b.binId!,
    ];
    doomed.forEach(_bin.remove);
    return doomed.length;
  }

  // --- re-keys --------------------------------------------------------------

  @override
  Future<void> rekey(
    int pairId,
    ContactSide side,
    String oldId,
    String newId,
  ) async {
    if (oldId == newId) return;
    if (_linkFor(_links, pairId, side, newId) != null ||
        _binEntry(pairId, side, newId) != null ||
        _ops.values.any((o) =>
            o.pairId == pairId &&
            o.side == side.other &&
            o.sourceKey == newId)) {
      throw _rekeyClash(side);
    }
    final google = side == ContactSide.google;
    for (final l in _links.values.toList()) {
      if (l.pairId != pairId || l.idOn(side) != oldId) continue;
      _links[l.linkId!] = google
          ? l.copyWith(googleName: newId)
          : l.copyWith(graphId: newId);
    }
    for (final r in _reviews.values.toList()) {
      if (r.pairId != pairId) continue;
      if (google ? r.googleName != oldId : r.graphId != oldId) continue;
      _reviews[r.reviewId!] =
          google ? r.copyWith(googleName: newId) : r.copyWith(graphId: newId);
    }
    for (final o in _ops.values.toList()) {
      if (o.pairId != pairId || o.side != side.other) continue;
      if (o.sourceKey != oldId) continue;
      _ops[o.opId] = ContactSyncOp(
        opId: o.opId,
        pairId: o.pairId,
        side: o.side,
        sourceKey: newId,
        tag: o.tag,
        startedAt: o.startedAt,
      );
    }
    for (final b in _bin.values.toList()) {
      if (b.pairId != pairId) continue;
      if (b.side == side && b.contactId == oldId) {
        _bin[b.binId!] = ContactBinEntry(
          binId: b.binId,
          pairId: b.pairId,
          side: b.side,
          contactId: newId,
          partnerId: b.partnerId,
          state: b.state,
          deletedAt: b.deletedAt,
          raw: b.raw,
          partnerBase: b.partnerBase,
          title: b.title,
          restore: b.restore,
        );
      } else if (b.side == side.other && b.partnerId == oldId) {
        _bin[b.binId!] = b.copyWith(partnerId: newId);
      }
    }
  }
}

/// [pair] as [change] left it, as both stores keep it: under its own id,
/// its addresses lower-cased and its times UTC to the millisecond.
ContactPair _asKept(int pairId, ContactPair pair) => ContactPair(
      pairId: pairId,
      googleAccountId: pair.googleAccountId,
      googleAddress: pair.googleAddress.toLowerCase(),
      graphAccountId: pair.graphAccountId,
      graphAddress: pair.graphAddress.toLowerCase(),
      graphFolderId: pair.graphFolderId,
      phoneRegion: pair.phoneRegion,
      googleSyncToken: pair.googleSyncToken,
      googleMask: pair.googleMask,
      googleFullAt: _kept(pair.googleFullAt),
      graphDeltaLink: pair.graphDeltaLink,
      graphMask: pair.graphMask,
      normaliser: pair.normaliser,
      googleCount: pair.googleCount,
      graphCount: pair.graphCount,
      firstStartedAt: _kept(pair.firstStartedAt),
      firstDoneAt: _kept(pair.firstDoneAt),
      lastAttemptAt: _kept(pair.lastAttemptAt),
      lastDoneAt: _kept(pair.lastDoneAt),
      lastResult: pair.lastResult,
      held: pair.held,
      detachedAt: _kept(pair.detachedAt),
    );

/// [pair] with [accountId] on [side], attached again when its other side's
/// account is still here.
ContactPair _reattached(
  ContactPair pair,
  ContactSide side,
  String accountId,
  Set<String> live,
) {
  final taken = side == ContactSide.google
      ? pair.copyWith(googleAccountId: accountId)
      : pair.copyWith(graphAccountId: accountId);
  return live.contains(taken.accountIdOn(side.other))
      ? taken.copyWith(detachedAt: null)
      : taken;
}

/// A link as read back, where a state or reason this build does not know
/// (from a later one) reads as held and waiting: nothing syncs for it, and
/// it is under Needs a look rather than lost.
ContactLink _linkRead({
  required int linkId,
  required int pairId,
  required String? googleName,
  required String? graphId,
  required String? googleEtag,
  required String? graphChangeKey,
  required String? googleBase,
  required String? graphBase,
  required ContactLinkState? state,
  required ContactHeldReason? reason,
  required DateTime? googleWrittenAt,
  required DateTime? updatedAt,
}) {
  final paired = state == ContactLinkState.paired &&
      googleName != null &&
      graphId != null;
  return ContactLink(
    linkId: linkId,
    pairId: pairId,
    googleName: googleName,
    graphId: graphId,
    googleEtag: googleEtag,
    graphChangeKey: graphChangeKey,
    googleBase: googleBase,
    graphBase: graphBase,
    state: paired ? ContactLinkState.paired : ContactLinkState.held,
    reason: paired ? null : reason ?? ContactHeldReason.waiting,
    googleWrittenAt: googleWrittenAt,
    updatedAt: updatedAt,
  );
}

StateError _linkGone() =>
    StateError('This contact link has gone since it was read.');

StateError _rekeyClash(ContactSide side) => StateError(
      'A re-key landed on a ${side.name} contact the pair already has.',
    );

DateTime? _time(int? ms) =>
    ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

/// A time as the database gives it back: UTC, to the millisecond. The
/// memory store keeps times this way too, so the two answer alike.
DateTime? _kept(DateTime? at) => _time(_ms(at));

int? _ms(DateTime? at) => at?.millisecondsSinceEpoch;

T? _or<T>(Object? given, T? kept) =>
    identical(given, _keep) ? kept : given as T?;

bool _sameFields(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const _keep = Object();
