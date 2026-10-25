import 'dart:convert';

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

/// MyEmail's half of the connector for Claude (C:/dev/myemail-duet): the
/// newest Inbox messages of the accounts ticked in Settings, Claude (Duet),
/// sent as text after a mail check, with no attachments. With each keep
/// account's goes the list of what its Inbox holds now, so what leaves it
/// leaves the connector too. A read-once account (Hadco) sends only the last
/// day's mail, which the connector deletes once Duet has read it.
///
/// Each message is sent once: the ids sent are kept on the phone.
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

  /// Bring the connector up to date, if switched on and [every] has passed
  /// since the last time (or [force]). Never throws: what went wrong is the
  /// answer's line, and kept for the settings screen.
  Future<DuetResult> run({
    bool force = false,
    Duration every = const Duration(minutes: 5),
  }) async {
    final settings = DuetSettings.fromJson(ui.readString(UiStateKeys.duet));
    final key = (await secrets.readSecret(keyName))?.trim() ?? '';
    if (!settings.enabled || key.isEmpty) {
      return (ran: false, sent: 0, line: '');
    }
    final now = _clock();
    final last = DateTime.tryParse(ui.readString(UiStateKeys.duetLastRun) ?? '');
    if (!force && last != null && now.difference(last) < every && !now.isBefore(last)) {
      return (ran: false, sent: 0, line: '');
    }
    await ui.writeString(UiStateKeys.duetLastRun, now.toIso8601String());

    final client = _given ?? http.Client();
    final sentIds = _readSent();
    var sent = 0;
    final problems = <String>[];
    try {
      final accounts = await engine.loadAccounts();
      // An account no longer ticked comes off the connector.
      for (final id in sentIds.keys.toList()) {
        if (settings.accounts.contains(id)) continue;
        final cleared = await _post(client, settings, key, {
          'account': {'key': id},
          'clear': true,
        });
        if (cleared == null) sentIds.remove(id);
      }
      for (final account in accounts) {
        if (!settings.accounts.contains(account.id)) continue;
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
        final problem = await _post(client, settings, key, {
          'account': {
            'key': account.id,
            'name': account.displayName,
            'policy': readOnce ? 'readOnce' : 'keep',
          },
          'messages': messages,
          if (!readOnce) 'keep': [for (final m in list) m.id],
        });
        if (problem != null) {
          problems.add(problem);
          continue;
        }
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
    final line = problems.isNotEmpty
        ? problems.first
        : switch (sent) {
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
  /// connector that lost its store, or a fresh start.
  Future<void> forgetSent() => ui.writeString(UiStateKeys.duetSent, null);

  Map<String, List<String>> _readSent() {
    try {
      final j = jsonDecode(ui.readString(UiStateKeys.duetSent) ?? '{}');
      if (j is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in j.entries)
          if (key is String && value is List) key: [for (final v in value) '$v'],
      };
    } on FormatException {
      return {};
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
