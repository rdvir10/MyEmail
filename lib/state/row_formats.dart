import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_state_store.dart';
import '../domain/row_format.dart';
import 'providers.dart';

/// Settings, View, Conditional formatting: the rules, in order of
/// precedence, kept across restarts and in the settings backup.
class RowFormats extends Notifier<List<RowFormat>> {
  @override
  List<RowFormat> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(
          UiStateKeys.rowFormats,
          jsonEncode([for (final r in next) r.toJson()]),
        ));
    final raw = store.readString(UiStateKeys.rowFormats);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded) ?RowFormat.fromJson(entry),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// [rule] in place of the one with its id, or at the end if it is new.
  void save(RowFormat rule) {
    final at = state.indexWhere((r) => r.id == rule.id);
    state = at < 0
        ? [...state, rule]
        : [
            for (final (i, r) in state.indexed) i == at ? rule : r,
          ];
  }

  void remove(String id) => state = [
        for (final r in state)
          if (r.id != id) r,
      ];

  /// One place up or down the order, which is the order of precedence.
  void move(String id, int by) {
    final from = state.indexWhere((r) => r.id == id);
    if (from < 0) return;
    final to = (from + by).clamp(0, state.length - 1);
    if (to == from) return;
    final next = [...state];
    final rule = next.removeAt(from);
    next.insert(to, rule);
    state = next;
  }
}

final rowFormatsProvider =
    NotifierProvider<RowFormats, List<RowFormat>>(RowFormats.new);
