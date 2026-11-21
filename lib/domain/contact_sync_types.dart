import 'dart:convert';

import 'package:collection/collection.dart';

import 'synced_contact.dart' show ContactSide;

// What contact sync's planner and its store both know: what a stored row
// is, why a held one is held, and where the JSON kept beside the rows
// names a contact. Here, in a file of their own, so that the store keeps
// the planner's codes without importing the planner. The planner exports
// this file; which side a contact is on is `ContactSide`, in
// synced_contact.dart.

/// Whether a row pairs two contacts or holds one (or both) back.
enum ContactLinkState { paired, held }

/// Why a row is held. [code] is what the row keeps.
enum ContactHeldReason {
  /// Ron's Leave it out, or Keep it only here.
  leftOut('left_out'),

  /// Under Needs a look, not yet answered.
  waiting('waiting'),

  /// New, and held only as a candidate under another contact's Needs a
  /// look item, with no item of its own. Each run it goes through the
  /// new-contact rules again: it stays as it is while every contact it
  /// could be is still waiting for Ron, and is placed (paired, copied or
  /// given its own item) once that item is answered or dropped.
  candidate('candidate'),

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

/// [json], JSON contact sync keeps beside its rows, with every id of a
/// contact on [side] that is [oldId] made [newId]: Google has re-keyed the
/// contact. The store's re-key runs it over the brakes' questions on the
/// pair and over each Needs a look item's data and queued answer, in the
/// same transaction as the rows, so nothing names the old id afterwards.
///
/// The ids are where the planner's `ContactReviewItem.toJson` and
/// `ContactBrakeItem.toJson` put them, at any depth: a contact under
/// `googleName` or `graphId`, and a new contact's candidates under
/// `candidates`, which are on the other side from its `subjectSide`. A
/// queued answer is found the same way when it is kept under the same
/// keys. Null, text that is not JSON, and JSON naming no such id come
/// back as they are, the same string.
String? rekeyContactJson(
  String? json,
  ContactSide side,
  String oldId,
  String newId,
) {
  if (json == null || oldId == newId) return json;
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return json;
  }
  final idKey = side == ContactSide.google ? 'googleName' : 'graphId';
  var changed = false;

  Object? walk(Object? node) {
    if (node is List) return [for (final e in node) walk(e)];
    if (node is! Map) return node;
    final out = <String, Object?>{
      for (final MapEntry(:key, :value) in node.entries) '$key': walk(value),
    };
    if (out[idKey] == oldId) {
      out[idKey] = newId;
      changed = true;
    }
    final candidates = out['candidates'];
    if (out['subjectSide'] == side.other.name &&
        candidates is List &&
        candidates.contains(oldId)) {
      changed = true;
      final titles = out['candidateTitles'];
      final keepTitles =
          titles is List && titles.length == candidates.length;
      final ids = <Object?>[];
      final named = <Object?>[];
      for (var i = 0; i < candidates.length; i++) {
        final id = candidates[i] == oldId ? newId : candidates[i];
        // Two candidates Google has merged into one are one candidate.
        if (id == newId && ids.contains(newId)) continue;
        ids.add(id);
        if (keepTitles) named.add(titles[i]);
      }
      out['candidates'] = ids;
      if (keepTitles) out['candidateTitles'] = named;
    }
    return out;
  }

  final rekeyed = walk(decoded);
  return changed ? jsonEncode(rekeyed) : json;
}
