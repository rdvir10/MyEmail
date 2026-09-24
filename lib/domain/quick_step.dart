import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One step in a Quick Step chain.
///
/// [moveTo] carries the destination folder id; the rest carry nothing. A
/// chain runs in order, so "mark read then move" and "move then mark read"
/// are both expressible, and only the first is sensible once the message has
/// left the folder.
enum QuickStepActionType {
  markRead('Mark as read'),
  markUnread('Mark as unread'),
  flag('Flag'),
  unflag('Remove flag'),
  moveTo('Move to'),
  delete('Delete');

  const QuickStepActionType(this.label);

  final String label;

  bool get needsFolder => this == QuickStepActionType.moveTo;

  /// After this action the message is no longer in the list, so anything
  /// after it in the chain would have nothing to act on.
  bool get isTerminal =>
      this == QuickStepActionType.moveTo || this == QuickStepActionType.delete;
}

@immutable
class QuickStepAction {
  const QuickStepAction(this.type, {this.folderId});

  final QuickStepActionType type;

  /// Only for [QuickStepActionType.moveTo].
  final String? folderId;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        if (folderId != null) 'folderId': folderId,
      };

  static QuickStepAction fromJson(Map<String, dynamic> j) => QuickStepAction(
        QuickStepActionType.values.byName(j['type'] as String),
        folderId: j['folderId'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is QuickStepAction &&
      other.type == type &&
      other.folderId == folderId;

  @override
  int get hashCode => Object.hash(type, folderId);
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
      actions.every((a) => !a.type.needsFolder || a.folderId != null);

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
