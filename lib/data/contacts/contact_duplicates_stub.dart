import 'package:flutter/foundation.dart' show immutable;

import 'contact_sync_planner.dart';

// Stand-ins for the planner's round on copies of one person (the
// duplicates hand-out, R7), so the runner can be written against its
// names before that round is merged. This file goes when it is: the
// planner then defines ContactDuplicateGroup, ContactSyncPlan.duplicates
// and ContactSyncCounts.duplicateCopies itself.

/// One person held more than once (R7's shape).
@immutable
class ContactDuplicateGroup {
  const ContactDuplicateGroup({
    this.title,
    this.googleSynced,
    this.graphSynced,
    this.googleCopies = const [],
    this.graphCopies = const [],
  });

  /// The person's name, for show.
  final String? title;

  /// The synced copy on each side, if any.
  final String? googleSynced;
  final String? graphSynced;

  /// The held copies on each side.
  final List<String> googleCopies;
  final List<String> graphCopies;
}

/// Until the planner plans them: none.
extension ContactSyncPlanDuplicates on ContactSyncPlan {
  List<ContactDuplicateGroup> get duplicates => const [];
}

/// Until the planner counts them: none.
extension ContactSyncCountsDuplicates on ContactSyncCounts {
  int get duplicateCopies => 0;
}
