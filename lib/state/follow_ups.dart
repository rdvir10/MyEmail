import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_state_store.dart';
import '../domain/follow_up.dart';
import '../domain/mail_message.dart';
import 'providers.dart';
import 'sync_providers.dart' show mailNotifierProvider;

/// Follow-ups as this device keeps them, by [followUpKey]: the due day
/// where the account keeps none, and the reminders, each one a notification
/// set with Android for its time. Kept across restarts; not in the backup,
/// since a reminder belongs to the phone that will show it.
class FollowUps extends Notifier<Map<String, FollowUpRecord>> {
  @override
  Map<String, FollowUpRecord> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(
          UiStateKeys.followUps,
          jsonEncode({
            for (final MapEntry(:key, :value) in next.entries)
              key: value.toJson(),
          }),
        ));
    final raw = store.readString(UiStateKeys.followUps);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return const {};
      return {
        for (final MapEntry(:key, :value) in json.entries)
          '$key': ?FollowUpRecord.fromJson(value),
      };
    } on FormatException {
      return const {};
    }
  }

  /// [message]'s follow-up, if this device keeps one.
  FollowUpRecord? of(MailMessage message) => state[followUpKey(message)];

  /// Flagged for [due] (null for no date), keeping any reminder.
  void setDue(MailMessage message, DateTime? due) {
    final key = followUpKey(message);
    final was = state[key];
    _put(key, (was ?? _recordFor(message)).copyWith(
      due: due,
      messageId: message.id,
    ));
  }

  /// A reminder at [at] for [message], set with Android; null takes it off.
  Future<bool> setReminder(MailMessage message, DateTime? at) async {
    final key = followUpKey(message);
    final record = (state[key] ?? _recordFor(message))
        .copyWith(remindAt: at, messageId: message.id);
    _put(key, record);
    final notifier = ref.read(mailNotifierProvider);
    final id = reminderIdFor(key);
    try {
      if (at == null) {
        await notifier.cancelReminder(id);
        return true;
      }
      return await notifier.scheduleReminder(
        id: id,
        at: at,
        title: record.subject.isEmpty ? 'Follow up' : record.subject,
        body: [
          if (record.sender.isNotEmpty) record.sender,
          if (record.due != null) dueLabel(record.due!, DateTime.now()),
        ].join(' · '),
        payload: message.id,
      );
    } catch (e) {
      debugPrint('[myemail] reminder not set: $e');
      return false;
    }
  }

  /// Done with, or the flag taken off: forgotten, its reminder with it.
  void forget(Iterable<MailMessage> messages) {
    final keys = {for (final m in messages) followUpKey(m)};
    if (!keys.any(state.containsKey)) return;
    final notifier = ref.read(mailNotifierProvider);
    for (final key in keys) {
      if (state[key]?.remindAt != null) {
        unawaited(notifier.cancelReminder(reminderIdFor(key)).catchError(
              (Object e) => debugPrint('[myemail] reminder not cancelled: $e'),
            ));
      }
    }
    state = {
      for (final MapEntry(:key, :value) in state.entries)
        if (!keys.contains(key)) key: value,
    };
  }

  void _put(String key, FollowUpRecord record) => state = {
        ...state,
        key: record,
      };

  static FollowUpRecord _recordFor(MailMessage m) => FollowUpRecord(
        accountId: m.accountId,
        messageId: m.id,
        subject: m.subject,
        sender: m.from.display,
      );
}

final followUpsProvider =
    NotifierProvider<FollowUps, Map<String, FollowUpRecord>>(FollowUps.new);
