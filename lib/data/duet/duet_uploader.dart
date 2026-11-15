import 'dart:convert';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../../domain/duet_settings.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_message.dart';
import '../credential_store.dart';
import '../mail_engine.dart';
import '../ui_state_store.dart';

/// What one pass did, for Settings, Claude (Duet) to say.
typedef DuetResult = ({bool ran, int sent, String line});

/// What the connector last took of an account from this device: a digest
/// of the upload, and when. See `DuetUploader._digestOf`.
typedef _Posted = ({String digest, DateTime at});

/// MyEmail's half of the connector for Claude (C:/dev/myemail-duet): the
/// newest Inbox messages of the accounts ticked in Settings, Claude (Duet),
/// sent as text after a mail check, with no attachments. With each keep
/// account's goes the list of what its Inbox holds now, so what leaves it
/// leaves the connector too. A read-once account (Hadco) sends only the last
/// day's mail, which the connector deletes once Duet has read it.
///
/// Each message is sent once: the ids sent are kept on the phone, by
/// account, which is also the record of the accounts on the connector. One
/// unticked, removed, or every one with the switch off, is cleared from it.
///
/// A keep account with nothing new, its name, its Inbox and the connector's
/// address as they were when the connector last took it, is not sent again
/// until [resendAfter]: each upload rewrites the account's file in the
/// connector's Blob store, whose operations are counted by the month.
class DuetUploader {
  DuetUploader({
    required this.engine,
    required this.ui,
    required this.secrets,
    http.Client? client,
    DateTime Function()? clock,
  })  : _given = client,
        _clock = clock ?? DateTime.now;

  final MailEngine engine;
  final UiStateStore ui;
  final CredentialStore secrets;
  final http.Client? _given;
  final DateTime Function() _clock;

  /// Where the upload key is kept, beside the account secrets.
  static const keyName = 'duet-upload-key';

  /// The newest messages of an Inbox looked at for new ones.
  static const newest = 30;

  /// At most this many messages' text fetched per account in one pass.
  static const perPass = 20;

  /// The Inbox's newest ids sent as what it holds.
  static const keepIds = 200;

  /// The ids sent remembered per account.
  static const remembered = 500;

  static const readOnceWindow = Duration(days: 1);
  static const textChars = 20000;

  /// How long a keep account with nothing new goes unsent at most: then it
  /// is sent all the same, so what another device or an upload gone astray
  /// left on the connector is put right within that time. The mail itself
  /// goes once: a store emptied by hand still needs Send everything again.
  static const resendAfter = Duration(hours: 3);

  /// Bring the connector up to date, if switched on and [every] has passed
  /// since the last time (or [force]). Never throws: what went wrong is the
  /// answer's line, and kept for the settings screen.
  Future<DuetResult> run({
    bool force = false,
    Duration every = const Duration(minutes: 5),
  }) async {
    final settings = DuetSettings.fromJson(ui.readString(UiStateKeys.duet));
    final key = (await secrets.readSecret(keyName))?.trim() ?? '';
    // With no key nothing is sent, nor cleared: the Duet screen says to
    // empty it only once what was sent is cleared.
    if (key.isEmpty) return (ran: false, sent: 0, line: '');
    // What was sent and when, as the device has it. The worker sends too,
    // through its own copy of the settings, and the app's copy, kept for
    // hours by push, did not have it: the app sent the same mail again.
    final sentIds = await _readSent();
    // Switched off, a pass only clears what was sent. It used to do nothing
    // at all, and the mail stayed on the connector for Duet to read.
    if (!settings.enabled && sentIds.isEmpty) {
      return (ran: false, sent: 0, line: '');
    }
    final now = _clock();
    final last =
        DateTime.tryParse(await _readNow(UiStateKeys.duetLastRun) ?? '');
    if (!force && last != null && now.difference(last) < every && !now.isBefore(last)) {
      return (ran: false, sent: 0, line: '');
    }
    await ui.writeString(UiStateKeys.duetLastRun, now.toIso8601String());
    // Read as what was sent is, and for the same reason: the worker's
    // posts are the connector's as much as the app's.
    final posted = await _readPosted();
    // This pass's word on each account it sends: what the connector took,
    // or not known. Put with what the device has at the end: see
    // [_keepPosted].
    final changed = <String, _Posted>{};

    final client = _given ?? http.Client();
    var sent = 0;
    final problems = <String>[];
    try {
      final accounts = await engine.loadAccounts();
      // On the connector, while switched on: the accounts ticked that are
      // still here. Any other sent comes off it, whether unticked, removed
      // (its id stayed ticked, out of sight), or switched off. No accounts
      // at all is the list not read yet, not every one removed.
      final here = {for (final a in accounts) a.id};
      final onIt = {
        if (settings.enabled)
          for (final id in settings.accounts)
            if (here.isEmpty || here.contains(id)) id,
      };
      for (final id in sentIds.keys.toList()) {
        if (onIt.contains(id)) continue;
        final cleared = await _post(client, settings, key, {
          'account': {'key': id},
          'clear': true,
        });
        if (cleared == null) {
          sentIds.remove(id);
        } else {
          problems.add(cleared);
        }
      }
      for (final account in accounts) {
        if (!onIt.contains(account.id)) continue;
        final readOnce = settings.readOnce.contains(account.id);
        final folders = await engine.cachedFolders(account.id);
        final inbox =
            folders.where((f) => f.role == FolderRole.inbox).firstOrNull;
        if (inbox == null) continue;
        final list = [
          ...await engine.cachedMessages(inbox.id, limit: keepIds),
        ]..sort((a, b) => b.date.compareTo(a.date));
        final already = {...?sentIds[account.id]};
        final fresh = [
          for (final m in list.take(newest))
            if (!already.contains(m.id) &&
                (!readOnce || now.difference(m.date) < readOnceWindow))
              m,
        ].take(perPass);
        final messages = <Map<String, Object?>>[];
        for (final m in fresh) {
          String text;
          try {
            text = (await engine.loadMessageBody(m.id)).text;
          } catch (e) {
            // Its text another time; the others go now.
            debugPrint('[myemail] duet: no text for ${m.id}: $e');
            continue;
          }
          messages.add(_messageJson(m, text));
        }
        final about = {
          'key': account.id,
          'name': account.displayName,
          'policy': readOnce ? 'readOnce' : 'keep',
        };
        final keep = readOnce ? null : [for (final m in list) m.id];
        final digest = await _digestOf(settings, about, keep);
        // Nothing it would change: the connector writes the same file
        // again. Never a read-once account's: its upload is also when the
        // connector takes out what is past its day, so it goes every pass,
        // as it always has.
        if (!force &&
            !readOnce &&
            messages.isEmpty &&
            _unchanged(posted[account.id], digest, now)) {
          continue;
        }
        final problem = await _post(client, settings, key, {
          'account': about,
          'messages': messages,
          'keep': ?keep,
        });
        if (problem != null) {
          problems.add(problem);
          // Kept before the answer was lost, or not at all: not known, so
          // not assumed. A digest no upload has, so it never stands for
          // one, and another pass sees that this one sent it.
          changed[account.id] = (digest: '', at: now);
          continue;
        }
        changed[account.id] = (digest: digest, at: now);
        sent += messages.length;
        sentIds[account.id] = [
          for (final m in messages) '${m['id']}',
          ...?sentIds[account.id],
        ].take(remembered).toList();
      }
    } catch (e) {
      problems.add('$e');
    } finally {
      if (_given == null) client.close();
    }
    await ui.writeString(UiStateKeys.duetSent, jsonEncode(sentIds));
    await _keepPosted(posted, changed, sentIds);
    // A pass that left every account alone says Up to date, which it is.
    final line = switch (sent) {
      _ when problems.isNotEmpty => problems.first,
      _ when !settings.enabled => 'Cleared from your connector',
      0 => 'Up to date',
      1 => 'Sent 1 message',
      _ => 'Sent $sent messages',
    };
    await ui.writeString(
      UiStateKeys.duetStatus,
      jsonEncode({'at': now.toIso8601String(), 'line': line, 'ok': problems.isEmpty}),
    );
    return (ran: true, sent: sent, line: line);
  }

  /// Forget what was sent, so the next pass sends the newest again: for a
  /// connector that lost its store, or a fresh start. Which accounts were
  /// sent is kept: it is the only record of what is on the connector, and
  /// one unticked just before would otherwise never be cleared from it.
  Future<void> forgetSent() async {
    final sent = await _readSent();
    await ui.writeString(
      UiStateKeys.duetSent,
      jsonEncode({for (final id in sent.keys) id: const <String>[]}),
    );
    // Nor is what the connector last took known any more.
    await forgetPosted();
  }

  /// Forget what the connector last took, so the next pass sends every
  /// account: for a new upload key, which would otherwise wait up to
  /// [resendAfter] to be used for an account with nothing new.
  Future<void> forgetPosted() => ui.writeString(UiStateKeys.duetPosted, null);

  /// What the connector last took from this device, by account: a digest of
  /// what the upload would leave there besides new mail (see [_digestOf]),
  /// and when. Read fresh, as [_readSent] is.
  Future<Map<String, _Posted>> _readPosted() async {
    try {
      final j = jsonDecode(await _readNow(UiStateKeys.duetPosted) ?? '{}');
      if (j is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in j.entries)
          if (key is String && value is Map && value['digest'] is String)
            if (DateTime.tryParse('${value['at']}') case final at?)
              key: (digest: value['digest'] as String, at: at),
      };
    } on FormatException {
      return {};
    }
  }

  /// What an upload leaves on the connector besides new mail: where it
  /// goes, the account's name and policy, and for a keep account the ids
  /// its Inbox holds, sorted, since the connector takes them as a set.
  static Future<String> _digestOf(
    DuetSettings settings,
    Map<String, Object?> about,
    List<String>? keep,
  ) async {
    final hash = await Sha256().hash(utf8.encode(jsonEncode({
      'server': settings.server,
      'account': about,
      'keep': keep == null ? null : ([...keep]..sort()),
    })));
    return base64Encode(hash.bytes);
  }

  /// Whether [last], what the connector last took of an account, is
  /// [digest] and recent enough to stand for it [now]. One from a time
  /// ahead of now (the clock put back) does not.
  static bool _unchanged(_Posted? last, String digest, DateTime now) =>
      last != null &&
      last.digest == digest &&
      !now.isBefore(last.at) &&
      now.difference(last.at) < resendAfter;

  /// [changed], this pass's word on the accounts it sent, put with what the
  /// device has now. The app and the worker pass each with its own copy,
  /// and can pass at once (Send now over a worker's pass): written back
  /// whole, the last to finish won, and a record could describe an upload
  /// the connector had not taken last. So only the accounts this pass sent
  /// are written; the rest stay as the device has them. One whose record
  /// another pass changed since [read] was read is left with none: which
  /// upload the connector took last is not known, so the next pass sends
  /// it, as every pass used to.
  Future<void> _keepPosted(
    Map<String, _Posted> read,
    Map<String, _Posted> changed,
    Map<String, List<String>> sentIds,
  ) async {
    final kept = await _readPosted();
    for (final MapEntry(:key, :value) in changed.entries) {
      if (kept[key] != read[key]) {
        kept.remove(key);
      } else {
        kept[key] = value;
      }
    }
    // An account cleared from the connector is not on it to be left alone.
    kept.removeWhere((id, _) => !sentIds.containsKey(id));
    await ui.writeString(UiStateKeys.duetPosted, jsonEncode({
      for (final MapEntry(:key, :value) in kept.entries)
        key: {'digest': value.digest, 'at': value.at.toIso8601String()},
    }));
  }

  Future<Map<String, List<String>>> _readSent() async {
    try {
      final j = jsonDecode(await _readNow(UiStateKeys.duetSent) ?? '{}');
      if (j is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in j.entries)
          if (key is String && value is List) key: [for (final v in value) '$v'],
      };
    } on FormatException {
      return {};
    }
  }

  /// [key] as the device has it now, or as this copy has it where the
  /// device will not say: [run] never throws.
  Future<String?> _readNow(String key) async {
    try {
      return await ui.readFresh(key);
    } catch (e) {
      debugPrint('[myemail] duet: $key read from the copy: $e');
      return ui.readString(key);
    }
  }

  static String _address(MailAddress a) =>
      a.name == null || a.name!.trim().isEmpty ? a.email : '${a.name} <${a.email}>';

  static Map<String, Object?> _messageJson(MailMessage m, String text) => {
        'id': m.id,
        'from': _address(m.from),
        'to': [for (final a in m.to) _address(a)].join(', '),
        'date': m.date.toUtc().toIso8601String(),
        'subject': m.subject,
        'text': text.length > textChars ? text.substring(0, textChars) : text,
      };

  /// Null where the connector took it, else what went wrong, in a sentence.
  Future<String?> _post(
    http.Client client,
    DuetSettings settings,
    String key,
    Map<String, Object?> body,
  ) async {
    final base = settings.server.replaceAll(RegExp(r'/+$'), '');
    try {
      final response = await client
          .post(
            Uri.parse('$base/api/upload'),
            headers: {
              'Content-Type': 'application/json',
              'X-MyEmail-Upload-Key': key,
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 60));
      return switch (response.statusCode) {
        200 => null,
        401 => 'The connector does not take this upload key.',
        _ => 'The connector refused it (HTTP ${response.statusCode}).',
      };
    } catch (e) {
      return 'Could not reach the connector.';
    }
  }
}

/// [DuetUploader.run] where something should not wait on it or fail with
/// it: the background passes and the app's coming to the front.
Future<void> sendToDuetIfDue(
  MailEngine engine,
  UiStateStore ui,
  CredentialStore secrets,
) async {
  try {
    final result =
        await DuetUploader(engine: engine, ui: ui, secrets: secrets).run();
    if (result.ran) debugPrint('[myemail] duet: ${result.line}');
  } catch (e) {
    debugPrint('[myemail] duet: $e');
  }
}
