import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/mailbox_settings.dart';
import '../auth/microsoft_oauth.dart' show SignInUnreachable;
import '../compose/reply_draft.dart' show asParagraphs;
import '../imap/imap_mapping.dart' show htmlToText;
import '../mail_engine.dart';

/// The mailbox's own settings on Microsoft Graph: Automatic Replies, and the
/// Inbox rules. Its own client, as the calendar has: these are a consent of
/// their own (`MicrosoftOAuth.mailboxSettingsScopes`), and the token handed
/// in is the one for them, so a mailbox approved for mail alone still reads
/// its mail. The plumbing is GraphCalendarApi's, in the small.
class GraphSettingsApi {
  GraphSettingsApi({
    required this.accessToken,
    http.Client? httpClient,
    this.sleep,
  }) : _given = httpClient;

  final Future<String> Function({bool force}) accessToken;
  final http.Client? _given;
  http.Client? _own;
  http.Client get _client => _given ?? (_own ??= http.Client());
  final Future<void> Function(Duration)? sleep;

  static const base = 'https://graph.microsoft.com/v1.0';
  static const _inUtc = 'outlook.timezone="UTC"';
  static final _rules = Uri.parse('$base/me/mailFolders/inbox/messageRules');

  // --- automatic replies ------------------------------------------------------

  Future<AutoReply> automaticReplies() async {
    final json = await _getJson(Uri.parse(
        '$base/me/mailboxSettings/automaticRepliesSetting'));
    return autoReplyFrom(json);
  }

  Future<void> setAutomaticReplies(AutoReply reply) => _send('PATCH',
      Uri.parse('$base/me/mailboxSettings'),
      {'automaticRepliesSetting': automaticRepliesJson(reply)});

  /// Graph's setting as an [AutoReply], its messages as text.
  static AutoReply autoReplyFrom(Map<String, Object?> json) {
    final status = '${json['status'] ?? 'disabled'}';
    DateTime? at(Object? v) {
      if (v is! Map) return null;
      final text = v['dateTime'];
      if (text is! String) return null;
      final zone = '${v['timeZone'] ?? 'UTC'}';
      final t = DateTime.tryParse(
          zone.toUpperCase() == 'UTC' && !text.endsWith('Z') ? '${text}Z' : text);
      return t?.toLocal();
    }

    String text(Object? html) =>
        html is String ? htmlToText(html).trim() : '';
    final inside = text(json['internalReplyMessage']);
    final outside = text(json['externalReplyMessage']);
    return AutoReply(
      on: status != 'disabled',
      start: status == 'scheduled' ? at(json['scheduledStartDateTime']) : null,
      end: status == 'scheduled' ? at(json['scheduledEndDateTime']) : null,
      message: inside,
      outsideMessage: outside == inside ? '' : outside,
      audience: switch ('${json['externalAudience'] ?? 'all'}') {
        'none' => ReplyAudience.insideOnly,
        'contactsOnly' => ReplyAudience.contacts,
        _ => ReplyAudience.everyone,
      },
    );
  }

  /// [reply] as Graph's setting, its messages as HTML.
  static Map<String, Object?> automaticRepliesJson(AutoReply reply) {
    Map<String, String> at(DateTime t) => {
          'dateTime':
              t.toUtc().toIso8601String().replaceFirst(RegExp(r'Z$'), ''),
          'timeZone': 'UTC',
        };
    return {
      'status': !reply.on
          ? 'disabled'
          : reply.scheduled
              ? 'scheduled'
              : 'alwaysEnabled',
      if (reply.on && reply.scheduled) ...{
        'scheduledStartDateTime': at(reply.start!),
        'scheduledEndDateTime': at(reply.end!),
      },
      'internalReplyMessage': asParagraphs(reply.message),
      'externalReplyMessage': asParagraphs(reply.outsideMessage.trim().isEmpty
          ? reply.message
          : reply.outsideMessage),
      'externalAudience': switch (reply.audience) {
        ReplyAudience.insideOnly => 'none',
        ReplyAudience.contacts => 'contactsOnly',
        ReplyAudience.everyone => 'all',
      },
    };
  }

  // --- rules --------------------------------------------------------------------

  /// The Inbox rules, in the order Exchange runs them. [pathOf] names a
  /// folder by its Graph id, for a rule that moves mail.
  Future<List<MailRule>> rules(String? Function(String folderId) pathOf) async {
    final json = await _getJson(_rules);
    final value = json['value'];
    final rows = [
      for (final r in value is List ? value : const [])
        if (r is Map) r.cast<String, Object?>(),
    ]..sort((a, b) =>
        ((a['sequence'] as num?) ?? 0).compareTo((b['sequence'] as num?) ?? 0));
    return [for (final r in rows) ?ruleFrom(r, pathOf)];
  }

  /// [rule] made, run after the others, and answered with its id.
  Future<MailRule> createRule(MailRule rule, String? folderId) async {
    final sequence = (await _getJson(_rules))['value'];
    final next = 1 +
        [
          for (final r in sequence is List ? sequence : const [])
            if (r is Map && r['sequence'] is num) (r['sequence'] as num).toInt(),
        ].fold<int>(0, (a, b) => a > b ? a : b);
    final made = await _send('POST', _rules, ruleJson(rule, folderId, next));
    return rule.copyWith(id: '${made['id'] ?? ''}');
  }

  Future<void> setRuleEnabled(String id, bool enabled) => _send(
      'PATCH', Uri.parse('$_rules/${Uri.encodeComponent(id)}'),
      {'isEnabled': enabled});

  Future<void> deleteRule(String id) =>
      _send('DELETE', Uri.parse('$_rules/${Uri.encodeComponent(id)}'), null);

  /// One of Exchange's rules as a [MailRule], or null for one with no id.
  /// One that matches or does more than a [MailRule] can say is
  /// [MailRule.partly]: shown, and left to Outlook to change.
  static MailRule? ruleFrom(
    Map<String, Object?> json,
    String? Function(String folderId) pathOf,
  ) {
    final id = json['id'];
    if (id is! String) return null;
    Map<String, Object?> map(Object? v) =>
        v is Map ? v.cast<String, Object?>() : const <String, Object?>{};
    final conditions = map(json['conditions']);
    final actions = map(json['actions']);
    List<String> strings(Object? v) => [
          for (final s in v is List ? v : const [])
            if (s is String && s.isNotEmpty) s,
        ];
    final from = [
      ...strings(conditions['senderContains']),
      for (final a in conditions['fromAddresses'] is List
          ? conditions['fromAddresses'] as List
          : const [])
        if (a is Map && a['emailAddress'] is Map)
          '${(a['emailAddress'] as Map)['address'] ?? ''}',
    ]..removeWhere((s) => s.isEmpty);
    final folder = actions['moveToFolder'];
    // Set to something: Graph leaves out what is not, mostly, and sends
    // false or an empty list for some of what is not.
    bool isSet(Object? v) =>
        v != null &&
        v != false &&
        !(v is List && v.isEmpty) &&
        !(v is Map && v.isEmpty);
    const known = {'senderContains', 'fromAddresses', 'subjectContains'};
    const done = {
      'moveToFolder',
      'markAsRead',
      'delete',
      'permanentDelete',
      'stopProcessingRules',
    };
    final partly = json['isReadOnly'] == true ||
        isSet(json['exceptions']) ||
        conditions.entries.any((e) => !known.contains(e.key) && isSet(e.value)) ||
        actions.entries.any((e) => !done.contains(e.key) && isSet(e.value)) ||
        (folder is String && pathOf(folder) == null);
    return MailRule(
      id: id,
      name: '${json['displayName'] ?? ''}',
      enabled: json['isEnabled'] != false,
      from: from,
      subjectContains: strings(conditions['subjectContains']),
      moveTo: folder is String ? pathOf(folder) ?? folder : null,
      markRead: actions['markAsRead'] == true,
      delete: actions['delete'] == true || actions['permanentDelete'] == true,
      partly: partly,
    );
  }

  /// [rule] as Exchange's, run at [sequence], moving to [folderId].
  static Map<String, Object?> ruleJson(
    MailRule rule,
    String? folderId,
    int sequence,
  ) =>
      {
        'displayName': rule.title,
        'sequence': sequence,
        'isEnabled': rule.enabled,
        'conditions': {
          if (rule.from.isNotEmpty) 'senderContains': rule.from,
          if (rule.subjectContains.isNotEmpty)
            'subjectContains': rule.subjectContains,
        },
        'actions': {
          if (rule.delete) 'delete': true,
          if (!rule.delete && folderId != null) 'moveToFolder': folderId,
          if (rule.markRead) 'markAsRead': true,
          'stopProcessingRules': rule.delete || folderId != null,
        },
      };

  void close() {
    _own?.close();
    _own = null;
  }

  // --- plumbing -------------------------------------------------------------------

  Future<Map<String, Object?>> _getJson(Uri uri) async {
    final response =
        await _exchange(() => http.Request('GET', uri)..headers['Prefer'] = _inUtc);
    if (response.statusCode >= 400) throw _failureFor(response);
    return _jsonOf(response);
  }

  Future<Map<String, Object?>> _send(
    String method,
    Uri uri,
    Map<String, Object?>? body,
  ) async {
    final response = await _exchange(() {
      final request = http.Request(method, uri)..headers['Prefer'] = _inUtc;
      if (body != null) {
        request
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(body);
      }
      return request;
    });
    if (response.statusCode >= 400) throw _failureFor(response);
    return _jsonOf(response);
  }

  Future<http.Response> _exchange(http.Request Function() build) async {
    for (var attempt = 0;; attempt++) {
      final response = await _authorised(build);
      final status = response.statusCode;
      if ((status != 429 && status != 503) || attempt >= 3) return response;
      final seconds =
          int.tryParse(response.headers['retry-after']?.trim() ?? '') ?? 2;
      if (seconds > 30) return response;
      await (sleep ?? _realSleep)(Duration(seconds: seconds));
    }
  }

  Future<http.Response> _authorised(http.Request Function() build) async {
    for (var forced = false;; forced = true) {
      final String token;
      try {
        token = await accessToken(force: forced);
      } on SignInUnreachable catch (e) {
        throw ConnectionFailed(e.message);
      }
      final request = build()..headers['Authorization'] = 'Bearer $token';
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _client.send(request));
      } on Exception catch (e) {
        throw ConnectionFailed('Could not reach Microsoft. ($e)');
      }
      if (response.statusCode != 401 || forced) return response;
    }
  }

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  static Map<String, Object?> _jsonOf(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Not JSON.
    }
    return const {};
  }

  static Exception _failureFor(http.Response response) {
    final status = response.statusCode;
    final error = _jsonOf(response)['error'];
    final code = error is Map ? error['code'] as String? : null;
    final detail = error is Map ? error['message'] as String? : null;
    if (status == 401) {
      return const AuthenticationFailed(
        'The sign-in for this account is no longer accepted. Open Settings, '
        'Accounts and sign in again.',
      );
    }
    if (status == 403) {
      return const AuthenticationFailed(
        "Microsoft would not let the app change this mailbox's settings. If "
        'it is a work or school account, an administrator may need to '
        'approve the app for your organisation.',
      );
    }
    if (status == 429 || status >= 500) {
      return ConnectionFailed(
        'Microsoft is having trouble (HTTP $status). Try again shortly.',
      );
    }
    return ConnectionFailed(
      'Microsoft refused it (${code ?? 'HTTP $status'})'
      '${detail == null || detail.isEmpty ? '' : ': $detail'}',
    );
  }
}
