import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/draft.dart';
import 'compose_providers.dart' show sendWith;

/// One message held after Send: Outlook's Undo send.
class HeldSend {
  HeldSend._(this.draft, this._owner);

  final Draft draft;
  final HeldSends _owner;
  Timer? _timer;
  bool _gone = false;

  /// Whether it is still waiting, so Undo still has something to take back.
  bool get waiting => !_gone;

  /// Take it back, if it has not gone yet: true when it was in time, and
  /// the message was not sent.
  bool undo() => _owner._undo(this);
}

/// Undo Send: each message held for a few seconds after Send, Undo on the
/// bar meanwhile, then sent as Send always sent it.
///
/// Held here rather than in the compose window, which has closed by then:
/// the message is in memory and nowhere else while it waits, so the app
/// going out of sight sends everything held at once. Android may stop the
/// app soon after, and a message that waited for a timer then would go
/// only when the app was next opened, or not at all.
class HeldSends extends Notifier<List<HeldSend>> {
  AppLifecycleListener? _lifecycle;

  @override
  List<HeldSend> build() {
    ref.onDispose(() => _lifecycle?.dispose());
    return const [];
  }

  /// Hold [draft] for [hold], then send it. [onSent] and [onFailed] say
  /// how it went, for the bar; neither is called for one taken back.
  HeldSend hold(
    Draft draft,
    Duration hold, {
    void Function()? onSent,
    void Function(Object error)? onFailed,
  }) {
    _lifecycle ??= AppLifecycleListener(onPause: flush);
    final held = HeldSend._(draft, this);
    held._timer = Timer(hold, () => _send(held, onSent, onFailed));
    _sendNow[held] = () => _send(held, onSent, onFailed);
    state = [...state, held];
    return held;
  }

  /// What sends each held message now, for [flush].
  final _sendNow = <HeldSend, void Function()>{};

  /// Send everything held, now: the app is going out of sight.
  void flush() {
    for (final held in [...state]) {
      _sendNow[held]?.call();
    }
  }

  bool _undo(HeldSend held) {
    if (held._gone) return false;
    held._gone = true;
    held._timer?.cancel();
    _sendNow.remove(held);
    state = [
      for (final h in state)
        if (!identical(h, held)) h,
    ];
    return true;
  }

  Future<void> _send(
    HeldSend held,
    void Function()? onSent,
    void Function(Object error)? onFailed,
  ) async {
    if (held._gone) return;
    held._gone = true;
    held._timer?.cancel();
    _sendNow.remove(held);
    state = [
      for (final h in state)
        if (!identical(h, held)) h,
    ];
    try {
      await sendWith(
        read: ref.read,
        invalidate: ref.invalidate,
        alive: () => ref.mounted,
        draft: held.draft,
      );
      onSent?.call();
    } catch (e) {
      debugPrint('[myemail] a held message did not go: $e');
      onFailed?.call(e);
    }
  }
}

final heldSendsProvider =
    NotifierProvider<HeldSends, List<HeldSend>>(HeldSends.new);
