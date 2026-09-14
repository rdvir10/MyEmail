import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/mail_engine.dart';
import '../data/ui_state_store.dart';
import '../domain/mail_message.dart';
import '../domain/quick_step.dart';
import 'message_providers.dart';
import 'providers.dart';

/// The user's Quick Steps, in the order they are shown.
///
/// Persisted as JSON beside the rest of the UI state. Steps that name a
/// folder are remapped when it is renamed and dropped when it is deleted,
/// so a Quick Step never silently stops working or moves mail somewhere
/// unexpected.
class QuickSteps extends Notifier<List<QuickStep>> {
  @override
  List<QuickStep> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(
          UiStateKeys.quickSteps,
          jsonEncode([for (final s in next) s.toJson()]),
        ));
    final raw = store.readString(UiStateKeys.quickSteps);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final j in (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>())
          QuickStep.fromJson(j),
      ];
    } on FormatException {
      return const [];
    } on ArgumentError {
      // An action type from a newer version of the app.
      return const [];
    }
  }

  void add(QuickStep step) => state = [...state, step];

  void update(QuickStep step) => state = [
        for (final s in state)
          if (s.id == step.id) step else s,
      ];

  void remove(String id) => state = [
        for (final s in state)
          if (s.id != id) s,
      ];

  /// [newIndex] is the destination after the row has been lifted out, which
  /// is what ReorderableListView.onReorderItem supplies.
  void reorder(int oldIndex, int newIndex) {
    final next = [...state];
    next.insert(newIndex, next.removeAt(oldIndex));
    state = next;
  }

  /// Follow a folder rename through every step that targets it.
  void remapFolder(FolderRename r) => state = [
        for (final s in state)
          s.copyWith(actions: [
            for (final a in s.actions)
              a.folderId == null
                  ? a
                  : QuickStepAction(a.type, folderId: r.remap(a.folderId!)),
          ]),
      ];

  /// Drop steps that would move mail into a folder that no longer exists.
  void dropFoldersIn(Set<String> goneFolderIds) => state = [
        for (final s in state)
          if (!s.actions.any((a) =>
              a.folderId != null && goneFolderIds.contains(a.folderId)))
            s,
      ];

  static String newId() =>
      'qs-${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36)}';
}

final quickStepsProvider =
    NotifierProvider<QuickSteps, List<QuickStep>>(QuickSteps.new);

/// Run a Quick Step against one message, in order, stopping after the action
/// that removes it from the list.
///
/// Takes the notifier rather than a ref, so the chain can be exercised
/// without a widget tree. Each action reuses the same notifier the swipes and
/// menus use, so the optimistic update, the rollback on failure and the
/// invalidations are the same. A failure anywhere stops the chain and is
/// rethrown, since carrying on would leave the message half-done.
Future<void> runQuickStep({
  required QuickStep step,
  required Messages notifier,
  required MailMessage message,
  void Function(String folderId)? onMoved,
}) async {
  for (final action in step.effectiveActions) {
    switch (action.type) {
      case QuickStepActionType.markRead:
        await notifier.setRead(message.id, true);
      case QuickStepActionType.markUnread:
        await notifier.setRead(message.id, false);
      case QuickStepActionType.flag:
        await notifier.setFlagged(message.id, true);
      case QuickStepActionType.unflag:
        await notifier.setFlagged(message.id, false);
      case QuickStepActionType.moveTo:
        final target = action.folderId!;
        await notifier.move([message.id], target);
        onMoved?.call(target);
      case QuickStepActionType.delete:
        await notifier.delete([message.id]);
    }
  }
}
