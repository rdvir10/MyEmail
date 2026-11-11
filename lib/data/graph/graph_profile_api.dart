import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../../domain/password_expiry.dart';
import '../auth/microsoft_oauth.dart' show SignInUnreachable;
import '../mail_engine.dart' show AuthenticationFailed, ConnectionFailed;

/// The account's own profile on Microsoft Graph, for when its password was
/// last changed. A consent of its own (`MicrosoftOAuth.profileScopes`,
/// User.Read), and the token handed in is the one for it, so an account
/// that has not allowed it goes on reading its mail.
class GraphProfileApi {
  GraphProfileApi({required this.accessToken, http.Client? httpClient})
      : _given = httpClient;

  final Future<String> Function({bool force}) accessToken;
  final http.Client? _given;
  http.Client? _own;
  http.Client get _client => _given ?? (_own ??= http.Client());

  /// Both are left out of `/me` unless asked for by name.
  static final me = Uri.parse(
    'https://graph.microsoft.com/v1.0/me'
    r'?$select=lastPasswordChangeDateTime,passwordPolicies',
  );

  Future<PasswordAge> passwordAge() async {
    for (var forced = false;; forced = true) {
      final String token;
      try {
        token = await accessToken(force: forced);
      } on SignInUnreachable catch (e) {
        throw ConnectionFailed(e.message);
      }
      final http.Response response;
      try {
        response = await _client.get(me, headers: {
          'Authorization': 'Bearer $token',
        });
      } on Exception catch (e) {
        throw ConnectionFailed('Could not reach Microsoft. ($e)');
      }
      if (response.statusCode == 401 && !forced) continue;
      final said = response.statusCode < 400
          ? response.body
          : _errorCode(response.body);
      debugPrint('[myemail] password date: ${response.statusCode} $said');
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const AuthenticationFailed(
          'Microsoft would not say when the password was changed.',
        );
      }
      if (response.statusCode >= 400) {
        throw ConnectionFailed(
          'Microsoft could not be asked just now (${response.statusCode}).',
        );
      }
      return passwordAgeFrom(response.body);
    }
  }

  /// The error's code alone, for the log: a refusal's message can name
  /// the tenant.
  static String _errorCode(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['error'] is Map) {
        return '${(json['error'] as Map)['code']}';
      }
    } on FormatException {
      // Not JSON.
    }
    return '';
  }

  /// Graph's answer as a [PasswordAge]. `passwordPolicies` is a list in a
  /// string, "DisablePasswordExpiration, DisableStrongPassword", or null.
  ///
  /// A user brought over from an organisation's own servers can have
  /// 1601-01-01, Windows' day nought, meaning no date at all: read as one,
  /// the password expired 154,000 days ago. Anything before 2000 is none.
  static PasswordAge passwordAgeFrom(String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return PasswordAge.unknown;
    }
    if (json is! Map) return PasswordAge.unknown;
    final changed = json['lastPasswordChangeDateTime'];
    final policies = json['passwordPolicies'];
    return PasswordAge(
      lastChanged:
          switch (changed is String ? DateTime.tryParse(changed) : null) {
        final t? when t.year >= 2000 => t,
        _ => null,
      },
      neverExpires: policies is String &&
          policies
              .split(',')
              .any((p) => p.trim() == 'DisablePasswordExpiration'),
    );
  }

  void close() {
    _own?.close();
    _own = null;
  }
}
