import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/display_settings.dart';
import 'display_providers.dart';

/// When a message the person opened is marked read: at once, after a few
/// seconds, when they move on, or never, as Settings, View says. Outlook's
/// Reading Pane options.
///
/// One place, because a message is opened from two: a tap on its row, and
/// the reading pane coming up for it. Both tell this, the same message
/// twice is the same opening, and the rule decides once.
class ReadMarker {
  ReadMarker(this._ref);

  final Ref _ref;

  /// The message open now, as far as this knows.
  String? _open;

  /// Waiting out [MarkReadWhen.delay] for [_open].
  Timer? _timer;

  /// What marks [_open] read when it is left, under [MarkReadWhen.leaving].
  Future<void> Function()? _onLeave;

  /// [messageId] was opened by the person. [mark] marks it read, and is
  /// null for a message already read: opening it still counts as moving on
  /// from the one before.
  void opened(String messageId, {Future<void> Function()? mark}) {
    if (messageId == _open) return;
    _leaveCurrent();
    _open = messageId;
    if (mark == null) return;
    switch (_ref.read(displayProvider).markRead) {
      case MarkReadWhen.opened:
        unawaited(mark());
      case MarkReadWhen.afterDelay:
        _timer = Timer(MarkReadWhen.delay, () {
          _timer = null;
          unawaited(mark());
        });
      case MarkReadWhen.leaving:
        _onLeave = mark;
      case MarkReadWhen.never:
        break;
    }
  }

  /// [messageId] is no longer open: its screen or pane has gone. Left
  /// before its seconds were up, it stays unread, as in Outlook.
  void left(String messageId) {
    if (messageId != _open) return;
    _leaveCurrent();
    _open = null;
  }

  void _leaveCurrent() {
    _timer?.cancel();
    _timer = null;
    final onLeave = _onLeave;
    _onLeave = null;
    if (onLeave != null) unawaited(onLeave());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

final readMarkerProvider = Provider<ReadMarker>((ref) {
  final marker = ReadMarker(ref);
  ref.onDispose(marker.dispose);
  return marker;
});
