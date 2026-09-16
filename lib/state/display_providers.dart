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
