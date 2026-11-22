import 'package:flutter/foundation.dart' show immutable;

import '../../domain/synced_contact.dart' show ContactField;
import 'contact_sync_planner.dart';

// Stand-ins for the planner's round on what a held change would do (the
// details hand-out), so the runner can be written against its names
// before that round is merged. This file goes when it is: the planner
// then defines ContactDetailChange, ContactBrakeItem.changes and
// ContactBrakeItem.hint itself, in toJson and fromJson.

/// One detail a held change would remove or replace (the hand-out's
/// shape).
@immutable
class ContactDetailChange {
  const ContactDetailChange({required this.field, this.before, this.after});

  final ContactField field;

  /// On the side that would lose it, as shown.
  final String? before;

  /// What it would become; null when it would be removed.
  final String? after;
}

/// Until the planner gives them: none.
extension ContactBrakeItemDetails on ContactBrakeItem {
  List<ContactDetailChange> get changes => const [];
  String? get hint => null;
}
