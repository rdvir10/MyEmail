import 'package:collection/collection.dart';

// The kinds contact sync's planner and its store both name: what a stored
// row is, and why a held one is held. Here, in a file of their own, so
// that the store keeps the planner's codes without importing the planner.
// The planner exports this file; which side a contact is on is
// `ContactSide`, in synced_contact.dart.

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
