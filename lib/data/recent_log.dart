import 'dart:collection';

import 'package:flutter/foundation.dart';

/// The last few hundred lines the app said to its log, kept in memory so a
/// phone away from any computer can still show what it has been doing.
///
/// Read through Settings, About, Recent log, and copied or shared from
/// there: the way to see, from the phone alone, what a sync found or why
/// something was refused. Only this isolate's lines are here; the
/// background worker runs in one of its own, with a log nothing here sees.
class RecentLog {
  RecentLog({this.capacity = 400, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// The one the app writes to; see [keepRecentLog].
  static final RecentLog instance = RecentLog();

  /// How many lines are kept. Older ones go as new ones come.
  final int capacity;

  final DateTime Function() _clock;
  final _lines = ListQueue<String>();

  /// Keep [line], stamped with the time of day it arrived.
  void add(String line) {
    final t = _clock();
    _lines.addLast('${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)} $line');
    while (_lines.length > capacity) {
      _lines.removeFirst();
    }
  }

  /// Oldest first.
  List<String> get lines => List.unmodifiable(_lines);

  String get text => _lines.join('\n');

  void clear() => _lines.clear();

  static String _two(int n) => n.toString().padLeft(2, '0');
}

bool _keeping = false;

/// From now on, everything handed to [debugPrint] is kept in
/// [RecentLog.instance] as well as printed. Once, at startup; a second call
/// does nothing.
void keepRecentLog() {
  if (_keeping) return;
  _keeping = true;
  final print = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) RecentLog.instance.add(message);
    print(message, wrapWidth: wrapWidth);
  };
}
