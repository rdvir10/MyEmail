import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A notification button that has been pressed but not yet carried out.
class PendingAction {
  const PendingAction({
    required this.actionId,
    required this.messageId,
    this.typed,
  });

  final String actionId;
  final String messageId;

  /// What was typed into the notification, for a reply.
  final String? typed;

  Map<String, Object?> toJson() => {
        'action': actionId,
        'message': messageId,
        if (typed != null) 'typed': typed,
      };

  static PendingAction? fromJson(Object? value) {
    if (value is! Map) return null;
    final action = value['action'];
    final message = value['message'];
    if (action is! String || message is! String) return null;
    if (action.isEmpty || message.isEmpty) return null;
    return PendingAction(
      actionId: action,
      messageId: message,
      typed: value['typed'] is String ? value['typed'] as String : null,
    );
  }
}

/// The queue of pressed notification buttons, waiting to be carried out.
///
/// This exists because of how short a life Android gives the isolate it
/// starts for a notification action. The plugin's callback returns `void`,
/// so nothing waits for the work inside it, and deleting a message means a
/// round trip to the mail server — a second or two, which the isolate does
/// not reliably survive. Pressing Delete therefore appeared to do nothing:
/// the notification went away, because Android dismisses it, and the message
/// stayed where it was.
///
/// So the press is written down first, which takes no time and cannot fail
/// halfway, and the work is done by something with a proper lifetime: the
/// WorkManager job, or the app the next time it is opened. Either way it
/// happens once — whoever drains the queue takes it.
///
/// [SharedPreferencesAsync] rather than the cached kind, for the same reason
/// the sync state uses it: a cache is loaded once, and two isolates each
/// holding their own copy would not see the other's writes.
class PendingActions {
  PendingActions([SharedPreferencesAsync? prefs])
      : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  static const key = 'notify.pending.v1';

  Future<void> add(PendingAction action) async {
    final queue = await _read();
    queue.add(action);
    await _prefs.setString(
      key,
      jsonEncode([for (final a in queue) a.toJson()]),
    );
  }

  /// Everything waiting, cleared as it is handed over.
  ///
  /// Taken rather than read, so two drains racing cannot both act on the
  /// same press. Losing one to a crash between the clear and the work is
  /// the lesser evil: doing a delete twice is worse than not doing it, and
  /// the mail is still there to delete by hand.
  Future<List<PendingAction>> take() async {
    final queue = await _read();
    if (queue.isNotEmpty) await _prefs.remove(key);
    return queue;
  }

  Future<List<PendingAction>> _read() async {
    final raw = await _prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [for (final entry in list) ?PendingAction.fromJson(entry)];
    } on FormatException {
      return [];
    }
  }
}
