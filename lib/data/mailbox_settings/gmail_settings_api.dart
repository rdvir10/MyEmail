import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/mailbox_settings.dart';
import '../auth/microsoft_oauth.dart'
    show SignInNeedsConsent, SignInUnreachable;
import '../compose/reply_draft.dart' show asParagraphs;
import '../imap/imap_mapping.dart' show htmlToText;
import '../mail_engine.dart';

/// Gmail's settings, over the Gmail API: the vacation responder, and the
/// filters Gmail runs on mail as it arrives. The mail itself goes over IMAP;
/// these are not there. Changing them needs `gmail.settings.basic`, which
/// the token handed in is asked for (`GoogleOAuth.gmailSettingsScopes`);
/// Google's answer carries every scope granted, so the same token reads the
/// labels too.
class GmailSettingsApi {
  GmailSettingsApi({required this.accessToken, http.Client? httpClient})
      : _given = httpClient;

  final Future<String> Function({bool force}) accessToken;
  final http.Client? _given;
  http.Client? _own;
  http.Client get _client => _given ?? (_own ??= http.Client());

  static const base = 'https://gmail.googleapis.com/gmail/v1/users/me';
  static final _vacation = Uri.parse('$base/settings/vacation');
  static final _filters = Uri.parse('$base/settings/filters');
  static final _labels = Uri.parse('$base/labels');

  // --- vacation responder -----------------------------------------------------

  Future<AutoReply> vacation() async => autoReplyFrom(await _send('GET', _vacation));

  Future<void> setVacation(AutoReply reply) =>
      _send('PUT', _vacation, vacationJson(reply));

  /// Gmail's vacation settings as an [AutoReply].
  static AutoReply autoReplyFrom(Map<String, Object?> json) {
    DateTime? at(Object? v) {
      final ms = v is num ? v.toInt() : int.tryParse('${v ?? ''}');
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    }

    final text = '${json['responseBodyPlainText'] ?? ''}'.trim();
    final html = json['responseBodyHtml'];
    final start = at(json['startTime']), end = at(json['endTime']);
    return AutoReply(
      on: json['enableAutoReply'] == true,
      start: start != null && end != null ? start : null,
      end: start != null && end != null ? end : null,
      message: text.isNotEmpty
          ? text
          : html is String
              ? htmlToText(html).trim()
              : '',
      audience: json['restrictToDomain'] == true
          ? ReplyAudience.insideOnly
          : json['restrictToContacts'] == true
              ? ReplyAudience.contacts
              : ReplyAudience.everyone,
      subject: '${json['responseSubject'] ?? ''}',
    );
  }

  /// [reply] as Gmail's vacation settings: the message as text and as
  /// HTML, a Hebrew paragraph reading from the right.
  static Map<String, Object?> vacationJson(AutoReply reply) => {
        'enableAutoReply': reply.on,
        'responseSubject': reply.subject.trim(),
        'responseBodyPlainText': reply.message.trim(),
        'responseBodyHtml': asParagraphs(reply.message),
        'restrictToContacts': reply.audience == ReplyAudience.contacts,
        'restrictToDomain': reply.audience == ReplyAudience.insideOnly,
        if (reply.scheduled) ...{
          'startTime': '${reply.start!.millisecondsSinceEpoch}',
          'endTime': '${reply.end!.millisecondsSinceEpoch}',
        },
      };

  // --- filters ------------------------------------------------------------------

  /// The labels by id, as IMAP names the folders they are: user labels
  /// only, the system ones being Gmail's own words (INBOX, TRASH).
  Future<Map<String, String>> labelNames() async {
    final json = await _send('GET', _labels);
    final labels = json['labels'];
    return {
      for (final l in labels is List ? labels : const [])
        if (l is Map && l['type'] == 'user' && l['id'] is String)
          l['id'] as String: '${l['name'] ?? ''}',
    };
  }

  /// The filters, as Gmail lists them, with [labels] from [labelNames].
  Future<List<MailRule>> filters(Map<String, String> labels) async {
    final json = await _send('GET', _filters);
    final rows = json['filter'];
    return [
      for (final f in rows is List ? rows : const [])
        if (f is Map) ?ruleFrom(f.cast<String, Object?>(), labels),
    ];
  }

  /// [rule] made as a filter, moving to [labelId] or, with [archive],
  /// skipping the Inbox, and answered with its id.
  Future<MailRule> createFilter(
    MailRule rule, {
    String? labelId,
    bool archive = false,
  }) async {
    final made = await _send(
        'POST', _filters, filterJson(rule, labelId: labelId, archive: archive));
    return rule.copyWith(id: '${made['id'] ?? ''}');
  }

  Future<void> deleteFilter(String id) =>
      _send('DELETE', Uri.parse('$_filters/${Uri.encodeComponent(id)}'));

  /// One of Gmail's filters as a [MailRule], or null for one with no id.
  /// One that matches or does more than a [MailRule] can say is
  /// [MailRule.partly]: shown, and left to Gmail on the web to change.
  static MailRule? ruleFrom(
    Map<String, Object?> json,
    Map<String, String> labels,
  ) {
    final id = json['id'];
    if (id is! String) return null;
    Map<String, Object?> map(Object? v) =>
        v is Map ? v.cast<String, Object?>() : const <String, Object?>{};
    final criteria = map(json['criteria']);
    final action = map(json['action']);
    List<String> ids(Object? v) => [
          for (final s in v is List ? v : const [])
            if (s is String) s,
        ];
    final added = ids(action['addLabelIds']);
    final removed = ids(action['removeLabelIds']);
    final from = splitOr('${criteria['from'] ?? ''}');
    final subject = splitOr('${criteria['subject'] ?? ''}');

    final delete = added.contains('TRASH');
    final userLabels = [
      for (final l in added)
        if (labels.containsKey(l)) labels[l]!,
    ];
    final skipsInbox = removed.contains('INBOX');
    final markRead = removed.contains('UNREAD');
    bool isSet(Object? v) =>
        v != null && v != false && v != '' && !(v is List && v.isEmpty);
    final partly = criteria.entries.any((e) =>
            e.key != 'from' && e.key != 'subject' && isSet(e.value)) ||
        isSet(action['forward']) ||
        added.any((l) => l != 'TRASH' && !labels.containsKey(l)) ||
        removed.any((l) => l != 'INBOX' && l != 'UNREAD') ||
        userLabels.length > 1 ||
        (userLabels.isNotEmpty && !skipsInbox) ||
        [...from, ...subject].any((w) => w.contains(RegExp(r'[(){}]')));
    return MailRule(
      id: id,
      from: from,
      subjectContains: subject,
      moveTo: delete
          ? null
          : userLabels.isNotEmpty
              ? userLabels.first
              : skipsInbox
                  ? archiveName
                  : null,
      markRead: markRead,
      delete: delete,
      partly: partly,
    );
  }

  /// What a filter that only skips the Inbox moves mail to, as a rule says.
  static const archiveName = 'Archive';

  /// [rule] as a Gmail filter.
  static Map<String, Object?> filterJson(
    MailRule rule, {
    String? labelId,
    bool archive = false,
  }) {
    final remove = [
      if (!rule.delete && (labelId != null || archive)) 'INBOX',
      if (rule.markRead) 'UNREAD',
    ];
    return {
      'criteria': {
        if (rule.from.isNotEmpty) 'from': joinOr(rule.from),
        if (rule.subjectContains.isNotEmpty)
          'subject': joinOr(rule.subjectContains),
      },
      'action': {
        if (rule.delete)
          'addLabelIds': ['TRASH']
        else if (labelId != null)
          'addLabelIds': [labelId],
        if (remove.isNotEmpty) 'removeLabelIds': remove,
      },
    };
  }

  /// "dana@example.com OR levi" as its parts, quotes off.
  static List<String> splitOr(String text) => [
        for (final part in text.split(RegExp(r'\s+OR\s+|\s*\|\s*')))
          if (part.trim().isNotEmpty) _unquoted(part.trim()),
      ];

  /// The other way: a phrase with a space in quotes, as Gmail's search
  /// wants it.
  static String joinOr(List<String> parts) => [
        for (final p in parts)
          p.trim().contains(' ') ? '"${p.trim()}"' : p.trim(),
      ].join(' OR ');

  static String _unquoted(String s) =>
      s.length > 1 && s.startsWith('"') && s.endsWith('"')
          ? s.substring(1, s.length - 1)
          : s;

  void close() {
    _own?.close();
    _own = null;
  }

  // --- plumbing -------------------------------------------------------------------

  Future<Map<String, Object?>> _send(
    String method,
    Uri uri, [
    Map<String, Object?>? body,
  ]) async {
    for (var forced = false;; forced = true) {
      final String token;
      try {
        token = await accessToken(force: forced);
      } on SignInUnreachable catch (e) {
        throw ConnectionFailed(e.message);
      }
      final request = http.Request(method, uri)
        ..headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        request
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(body);
      }
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _client.send(request));
      } on Exception catch (e) {
        throw ConnectionFailed('Could not reach Google. ($e)');
      }
      if (response.statusCode == 401 && !forced) continue;
      if (response.statusCode >= 400) throw _failureFor(response);
      return _jsonOf(response);
    }
  }

  static Map<String, Object?> _jsonOf(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Not JSON: a DELETE answers with nothing.
    }
    return const {};
  }

  /// Google's refusal as the failure the app shows: the Gmail API switched
  /// off in the app's Google Cloud project is a setting to change there, a
  /// token without the settings scope a sign-in again.
  static Exception _failureFor(http.Response response) {
    final status = response.statusCode;
    final error = _jsonOf(response)['error'];
    final detail = error is Map ? '${error['message'] ?? ''}' : '';
    final reasons = <String>{
      if (error is Map && error['details'] is List)
        for (final d in error['details'] as List)
          if (d is Map && d['reason'] is String)
            (d['reason'] as String).toUpperCase(),
      if (error is Map && error['errors'] is List)
        for (final d in error['errors'] as List)
          if (d is Map && d['reason'] is String)
            (d['reason'] as String).toUpperCase(),
    };
    if (status == 401) {
      return const AuthenticationFailed(
        'The Google sign-in is no longer accepted. Open Settings, Accounts '
        'and sign in to the Gmail account again.',
      );
    }
    if (status == 429) {
      return const ConnectionFailed(
        'Google is rate limiting this account. Try again shortly.',
      );
    }
    if (status == 403) {
      if (reasons.contains('SERVICE_DISABLED') ||
          reasons.contains('ACCESSNOTCONFIGURED') ||
          detail.contains('has not been used') ||
          detail.contains('is disabled')) {
        return const ConnectionFailed(
          "The Gmail API is switched off in the app's Google Cloud project. "
          'Open APIs & Services, Library, Gmail API and enable it, then try '
          'again.',
        );
      }
      if (reasons.contains('ACCESS_TOKEN_SCOPE_INSUFFICIENT') ||
          reasons.contains('INSUFFICIENTPERMISSIONS') ||
          detail.toLowerCase().contains('insufficient')) {
        return const SignInNeedsConsent(
          "This Google account has not allowed the app to change Gmail's "
          'settings. Sign in with Google again to allow it; nothing cached '
          'is lost.',
        );
      }
    }
    if (status >= 500) {
      return ConnectionFailed(
        'Google is having trouble (HTTP $status). Try again shortly.',
      );
    }
    return ConnectionFailed(
      'Google refused it (HTTP $status)${detail.isEmpty ? '' : ': $detail'}',
    );
  }
}
