import 'dart:convert';

import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';

/// [store], or a new one, with Undo Send off: for a test of what Send
/// does, which would otherwise wait out the hold before anything went.
MemoryUiStateStore sendAtOnce([MemoryUiStateStore? store]) {
  final settings = store ?? MemoryUiStateStore();
  settings.writeString(
    UiStateKeys.display,
    jsonEncode(const DisplaySettings(undoSend: UndoSend.off).toJson()),
  );
  return settings;
}
