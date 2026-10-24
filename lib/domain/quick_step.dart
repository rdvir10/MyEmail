import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'follow_up.dart' show FollowUpChoice;

/// One step in a Quick Step chain.
///
/// [moveTo] carries the destination folder id, [forwardTo] and
/// [newMessageTo] an address, [flagFor] when it is due; the rest carry
/// nothing. A chain runs in order, so "mark read then move" and "move then
/// mark read" are both expressible, and only the first is sensible once the
/// message has left the folder.
///
/// New types go at the end: a step is kept by its types' names, and a
/// backup from a newer build that has types this one does not is skipped
/// step by step rather than read wrong.
enum QuickStepActionType {
  markRead('Mark as read'),
  markUnread('Mark as unread'),
  flag('Flag'),
  unflag('Remove flag'),
  moveTo('Move to'),
  delete('Delete'),
  archive('Archive'),
  flagFor('Flag for'),
  forwardTo('Forward to'),
  replyDelete('Reply, then delete'),
  newMessageTo('New message to'),
  meeting('Meeting from it');

  const QuickStepActionType(this.label);

  final String label;

  bool get needsFolder => this == QuickStepActionType.moveTo;

  /// Forward to, and New message to: someone to write to.
  bool get needsAddress =>
      this == QuickStepActionType.forwardTo ||
      this == QuickStepActionType.newMessageTo;

  /// Flag for: when it is due.
  bool get needsWhen => this == QuickStepActionType.flagFor;

  /// After this action the message is no longer in the list, so anything
  /// after it in the chain would have nothing to act on.
  bool get isTerminal =>
      this == QuickStepActionType.moveTo ||
      this == QuickStepActionType.delete ||
      this == QuickStepActionType.archive ||
      this == QuickStepActionType.replyDelete;
}

@immutable
class QuickStepAction {
  const QuickStepAction(this.type, {this.folderId, this.address, this.when});

  final QuickStepActionType type;

  /// Only for [QuickStepActionType.moveTo].
  final String? folderId;

  /// Only for [QuickStepActionType.forwardTo] and
  /// [QuickStepActionType.newMessageTo].
  final String? address;

  /// Only for [QuickStepActionType.flagFor].
  final FollowUpChoice? when;

  /// Whether it has what it needs to run.
  bool get isComplete =>
      (!type.needsFolder || folderId != null) &&
      (!type.needsAddress || (address?.contains('@') ?? false)) &&
      (!type.needsWhen || when != null);

  QuickStepAction withFolder(String folderId) =>
      QuickStepAction(type, folderId: folderId, address: address, when: when);

  /// What it does, as a step's list of them says it: "Move to Receipts",
  /// "Forward to dana@example.com", "Flag for Tomorrow". [folderName]
  /// names a folder by its id.
  String describe(String Function(String folderId) folderName) => switch (
          type) {
        QuickStepActionType.moveTo =>
          '${type.label} ${folderId == null ? '(missing folder)' : folderName(folderId!)}',
        QuickStepActionType.forwardTo ||
        QuickStepActionType.newMessageTo =>
          '${type.label} ${address ?? '(nobody)'}',
        QuickStepActionType.flagFor =>
          '${type.label} ${when?.label ?? '(no day)'}',
        _ => type.label,
      };

  Map<String, dynamic> toJson() => {
        'type': type.name,
        if (folderId != null) 'folderId': folderId,
        if (address != null) 'address': address,
        if (when != null) 'when': when!.name,
      };

  static QuickStepAction fromJson(Map<String, dynamic> j) => QuickStepAction(
        QuickStepActionType.values.byName(j['type'] as String),
        folderId: j['folderId'] as String?,
        address: j['address'] as String?,
        when: j['when'] == null
            ? null
            : FollowUpChoice.values.byName(j['when'] as String),
      );

  @override
  bool operator ==(Object other) =>
      other is QuickStepAction &&
      other.type == type &&
      other.folderId == folderId &&
      other.address == address &&
      other.when == when;

  @override
  int get hashCode => Object.hash(type, folderId, address, when);
}

/// A named chain of actions applied to a message in one tap.
@immutable
class QuickStep {
  const QuickStep({
    required this.id,
    required this.name,
    required this.actions,
  });

  final String id;
  final String name;
  final List<QuickStepAction> actions;

  bool get isValid =>
      name.trim().isNotEmpty &&
      actions.isNotEmpty &&
      actions.every((a) => a.isComplete);

  /// Everything up to and including the first terminal action; anything after
  /// it could never run.
  /// Whether this step can run on a message from [accountId]. A move files
  /// into one account's folder, and mail cannot move between accounts: run
  /// on another's message, the step marked it read or flagged it and then
  /// failed on the move, leaving it half done.
  bool appliesTo(String accountId) => effectiveActions.every((a) =>
      a.type != QuickStepActionType.moveTo ||
      (a.folderId?.startsWith('$accountId:') ?? false));

  List<QuickStepAction> get effectiveActions {
    final result = <QuickStepAction>[];
    for (final a in actions) {
      result.add(a);
      if (a.type.isTerminal) break;
    }
    return result;
  }

  QuickStep copyWith({String? name, List<QuickStepAction>? actions}) {
    return QuickStep(
      id: id,
      name: name ?? this.name,
      actions: actions ?? this.actions,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'actions': [for (final a in actions) a.toJson()],
      };

  static QuickStep fromJson(Map<String, dynamic> j) => QuickStep(
        id: j['id'] as String,
        name: j['name'] as String,
        actions: [
          for (final a in (j['actions'] as List<dynamic>).cast<Map<String, dynamic>>())
            QuickStepAction.fromJson(a),
        ],
      );

  /// Every step in [raw] that this build can read, in order, or null when
  /// [raw] is not a list of steps at all.
  ///
  /// One at a time, so a step this build cannot read costs that step and
  /// not the rest. The usual cause is an action type from a newer version,
  /// arriving in a backup restored onto an older one: the whole list used to
  /// be dropped, and an empty one saved over it.
  ///
  /// A step is kept whole or not at all. Leaving out only the action it did
  /// not know would make it do something other than what it says.
  static List<QuickStep>? listFromJson(String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (json is! List) return null;
    return [for (final j in json) ?_tryFromJson(j)];
  }

  static QuickStep? _tryFromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    try {
      return fromJson(j);
    } on ArgumentError {
      return null; // An action type this build does not have.
    } on TypeError {
      return null; // A field missing, or of the wrong kind.
    }
  }

  @override
  bool operator ==(Object other) => other is QuickStep && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
