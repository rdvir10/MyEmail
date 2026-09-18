import 'dart:convert';

import 'package:flutter/foundation.dart';

/// What a successful OAuth sign-in leaves behind.
///
/// The access token is the one that goes on the wire, and it dies in about an
/// hour. The refresh token is the one worth keeping: it is what lets the app
/// get another access token at 3am without waking anybody, and it is the only
/// part that belongs in the Keystore.
@immutable
class OAuthToken {
  const OAuthToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;

  /// UTC. Always compare against a UTC now.
  final DateTime expiresAt;

  /// How much life a token needs left before we will hand it to a transport.
  ///
  /// Not zero, because a token with twenty seconds left passes the check,
  /// gets used to open an IMAP connection, and then expires in the middle of
  /// a sync that has already started. Five minutes is longer than any single
  /// operation the app performs.
  static const refreshMargin = Duration(minutes: 5);

  bool isUsableAt(DateTime now) =>
      expiresAt.isAfter(now.toUtc().add(refreshMargin));

  /// Build from the JSON of a token endpoint response.
  ///
  /// [now] is the moment the response arrived: the server sends a lifetime in
  /// seconds, not a deadline, so the deadline is only as good as the clock
  /// reading we pair it with.
  ///
  /// [previousRefreshToken] covers the refresh case. Microsoft usually
  /// returns a new refresh token when you spend one, but it is not obliged
  /// to, and treating a missing one as "signed out" would sign the account
  /// out for no reason.
  factory OAuthToken.fromResponseJson(
    Map<String, Object?> json, {
    required DateTime now,
    String? previousRefreshToken,
  }) {
    final access = json['access_token'];
    if (access is! String || access.isEmpty) {
      throw const FormatException('Token response had no access_token.');
    }
    final refresh = json['refresh_token'];
    final keptRefresh =
        (refresh is String && refresh.isNotEmpty) ? refresh : previousRefreshToken;
    if (keptRefresh == null || keptRefresh.isEmpty) {
      throw const FormatException(
        'Token response had no refresh_token, and there was no earlier one to '
        'keep. Was offline_access in the requested scopes?',
      );
    }

    // Seconds, per the spec. Anything unparseable is treated as an hour,
    // which is what Microsoft issues anyway; the refresh margin absorbs the
    // difference and a wrong guess costs one extra refresh, not a failure.
    final lifetime = switch (json['expires_in']) {
      final int s => Duration(seconds: s),
      final String s when int.tryParse(s) != null =>
        Duration(seconds: int.parse(s)),
      _ => const Duration(hours: 1),
    };

    return OAuthToken(
      accessToken: access,
      refreshToken: keptRefresh,
      expiresAt: now.toUtc().add(lifetime),
    );
  }

  /// The Keystore holds one string per account, so the whole token travels as
  /// JSON in that one slot.
  String toStoredJson() => jsonEncode({
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt.toUtc().toIso8601String(),
      });

  /// Null rather than throwing for anything unreadable. A corrupt entry means
  /// the account signs in again, which is recoverable; an exception on the
  /// read path means the app cannot open.
  static OAuthToken? fromStoredJson(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    try {
      final json = jsonDecode(stored);
      if (json is! Map) return null;
      final access = json['access_token'];
      final refresh = json['refresh_token'];
      final expires = DateTime.tryParse('${json['expires_at']}');
      if (access is! String || refresh is! String || expires == null) {
        return null;
      }
      return OAuthToken(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: expires.toUtc(),
      );
    } on FormatException {
      return null;
    }
  }

  OAuthToken copyWith({String? accessToken, DateTime? expiresAt}) => OAuthToken(
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken,
        expiresAt: expiresAt ?? this.expiresAt,
      );

  /// Keep everything but take the newer refresh token.
  ///
  /// For a refresh made for some other resource: Microsoft rotates the refresh
  /// token on every exchange, whatever was asked for, so the one that comes
  /// back has to replace the stored one even though its access token is for
  /// something else. Dropping it would leave the stored refresh token retired,
  /// and the account would sign itself out at its next ordinary refresh.
  OAuthToken withRefreshToken(String refreshToken) => OAuthToken(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
      );

  /// Deliberately no token values. This ends up in logs.
  @override
  String toString() => 'OAuthToken(expiresAt: $expiresAt)';
}
