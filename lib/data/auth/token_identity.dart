import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Who a Microsoft access token was issued to, where the token says.
///
/// A work or school account's token is a JWT whose claims name the user:
/// `tid` and `oid` exactly, `upn` or `preferred_username` as an address. A
/// personal Microsoft account's token is opaque and says nothing, and then
/// there is no identity: [of] answers null.
///
/// Read without asking Microsoft for anything more. The app's consent covers
/// mail only, and asking for the profile as well would mean a new consent,
/// which an organisation that approved the app for mail may not allow.
@immutable
class TokenIdentity {
  const TokenIdentity({required this.user, this.address});

  /// Tenant and object id together: the same person, whatever address they
  /// are known by.
  final String user;

  /// The sign-in name, which on almost every work account is the address.
  final String? address;

  static TokenIdentity? of(String accessToken) {
    final parts = accessToken.split('.');
    if (parts.length != 3) return null;
    try {
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (claims is! Map) return null;
      final tid = claims['tid'];
      final oid = claims['oid'];
      if (tid is! String || oid is! String) return null;
      String? address;
      for (final name in ['upn', 'preferred_username', 'unique_name']) {
        final value = claims[name];
        if (value is! String || !value.contains('@')) continue;
        // A guest's unique_name carries where they come from in front:
        // "live.com#someone@outlook.com".
        address = value.substring(value.lastIndexOf('#') + 1);
        break;
      }
      return TokenIdentity(user: '$tid/$oid', address: address);
    } catch (_) {
      return null;
    }
  }

  /// Whether two tokens belong to the same person, as far as can be told.
  ///
  /// Two opaque tokens cannot be told apart, so they pass. One readable and
  /// one not are a work account and a personal one: different people.
  static bool sameUser(TokenIdentity? a, TokenIdentity? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.user == b.user;
  }
}
