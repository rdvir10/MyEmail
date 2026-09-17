import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_state_store.dart';
import '../domain/display_settings.dart';
import 'providers.dart';

/// Settings, View. Persisted the moment they change, because every one of
/// them is a preference the user expects to still be there tomorrow.
class Display extends Notifier<DisplaySettings> {
  @override
  DisplaySettings build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(
          UiStateKeys.display,
          jsonEncode(next.toJson()),
        ));
    final raw = store.readString(UiStateKeys.display);
    if (raw == null || raw.isEmpty) return const DisplaySettings();
    try {
      return DisplaySettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return const DisplaySettings();
    } on TypeError {
      return const DisplaySettings();
    }
  }

  void setReadingPane(ReadingPanePosition position) =>
      state = state.copyWith(readingPane: position);

  void setDensity(ListDensity density) =>
      state = state.copyWith(density: density);

  void setConversations(bool on) => state = state.copyWith(conversations: on);
}

final displayProvider =
    NotifierProvider<Display, DisplaySettings>(Display.new);

/// The density alone, so a message row rebuilds when that changes and not
/// when some unrelated view setting does.
final listDensityProvider =
    Provider<ListDensity>((ref) => ref.watch(displayProvider).density);

/// Whether the folder pane is on screen at all.
///
/// Outlook's collapse-the-folder-pane, and wanted for the same reason: once
/// you know where your mail lives, the tree is 300 points of screen doing
/// nothing, and a message reads better with them. Persisted, because it is a
/// standing preference about the shape of the app rather than a peek.
///
/// Only the two-pane and three-pane layouts have a pane to hide. On a phone
/// the tree is already a drawer, which is hidden by definition.
class FolderPaneVisible extends Notifier<bool> {
  @override
  bool build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) =>
        store.writeString(UiStateKeys.folderPane, next ? 'shown' : 'hidden'));
    return store.readString(UiStateKeys.folderPane) != 'hidden';
  }

  void toggle() => state = !state;
  void set(bool value) => state = value;
}

final folderPaneVisibleProvider =
    NotifierProvider<FolderPaneVisible, bool>(FolderPaneVisible.new);

/// Which conversations are open, by conversation id.
///
/// Deliberately not persisted, unlike the folder tree's expand state. A
/// folder is still the same folder tomorrow; a conversation's identity is its
/// oldest cached message, which moves as the window slides, so restoring
/// yesterday's set would open arbitrary threads.
class ExpandedConversations extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String id) => state = {
        for (final existing in state)
          if (existing != id) existing,
        if (!state.contains(id)) id,
      };

  void collapseAll() => state = const {};
}

final expandedConversationsProvider =
    NotifierProvider<ExpandedConversations, Set<String>>(
  ExpandedConversations.new,
);
