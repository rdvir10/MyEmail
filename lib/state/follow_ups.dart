import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/imap/imap_mapping.dart' show normaliseMessageId;
import '../data/mail_engine.dart' show FindsByMessageId;
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

  /// Where the message a tapped reminder's [payload] names is now: the
  /// payload itself, unless this device keeps a follow-up for it and the
  /// message is no longer there; then the message carrying its Message-ID.
  /// See [ReminderTarget] for what is said when there is none to open.
  ///
  /// A reminder opens its message by its id in the app, which has the
  /// folder in it, and a move gives the message a new one. Filed after its
  /// reminder was set, the usual flag-then-file, the tap opened the folder
  /// it had left with nothing in it, and on the phone nothing at all. The
  /// follow-up is kept by Message-ID for exactly that (see [followUpKey]).
  ///
  /// Its own account first, always: the device's copies in it, then its
  /// server. A copy in another account the device holds, Ron's own Sent
  /// copy of something he sent himself, opened in its place where the
  /// device held nothing of the folder it was filed in. That copy is taken
  /// only where its own account's server says it has none, as a message
  /// moved from one account to the other.
  Future<ReminderTarget> whereNow(String payload) async {
    final kept = state.entries
        .where((e) => e.value.messageId == payload)
        .firstOrNull;
    // Not a reminder's, or none this device still keeps: as it always was.
    if (kept == null) return ReminderTarget.at(payload);
    final engine = ref.read(mailEngineProvider);
    try {
      if (await engine.cachedMessage(payload) != null) {
        return ReminderTarget.at(payload);
      }
    } catch (_) {
      return ReminderTarget.at(payload);
    }
    // The key is the account and the Message-ID, or the old id where the
    // message had none, and then there is nothing to find it by.
    final record = kept.value;
    final messageId =
        normaliseMessageId(kept.key.substring(kept.key.indexOf('|') + 1));
    if (messageId == null ||
        messageId == payload ||
        engine is! FindsByMessageId) {
      return const ReminderTarget.gone();
    }
    final finder = engine as FindsByMessageId;
    String? held;
    try {
      held = await finder.messageWithId(messageId, accountId: record.accountId);
    } catch (e) {
      debugPrint('[myemail] the device was not asked for a message: $e');
    }
    if (held != null && held.startsWith('${record.accountId}:')) {
      return ReminderTarget.at(held);
    }
    // Asked for exactly, by its Message-ID: a search for its subject's
    // words looked at the newest hundred hits, and missed it under a
    // subject as common as "Re: Invoice".
    final String? there;
    try {
      there = await finder.messageWithIdOnServer(
        messageId,
        accountId: record.accountId,
      );
    } catch (e) {
      debugPrint('[myemail] a reminder\'s message was not looked for: $e');
      return ReminderTarget.notLooked(e);
    }
    if (there != null) return ReminderTarget.at(there);
    return held == null ? const ReminderTarget.gone() : ReminderTarget.at(held);
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

/// Where [FollowUps.whereNow] found a reminder's message: at [id]; or
/// nowhere, after looking; or not looked for, [failed] saying why. A
/// lookup that could not be made (no signal, a sign-in to renew) said the
/// message may have been deleted, as one that looked and found nothing
/// does.
class ReminderTarget {
  const ReminderTarget.at(String this.id) : failed = null;

  /// Looked for in its account, and not there, or only in Deleted Items.
  const ReminderTarget.gone()
      : id = null,
        failed = null;

  /// Its account could not be asked.
  const ReminderTarget.notLooked(Object this.failed) : id = null;

  final String? id;
  final Object? failed;
}

final followUpsProvider =
    NotifierProvider<FollowUps, Map<String, FollowUpRecord>>(FollowUps.new);
