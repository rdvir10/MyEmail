import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// The pair that ties an authorization request to the app that made it.
///
/// PKCE (RFC 7636) exists because a public client cannot keep a secret, so
/// anything that intercepts the authorization code — another app claiming the
/// same redirect, a proxy, a log — could otherwise spend it. The app sends a
/// hash of a random value up front and the value itself when redeeming the
/// code, so a stolen code is worth nothing without the value, which never left
/// the device.
@immutable
class PkcePair {
  const PkcePair({required this.verifier, required this.challenge});

  /// Sent only when the code is redeemed, never in the browser.
  final String verifier;

  /// Sent in the authorization request. SHA-256 of the verifier.
  final String challenge;

  /// The transformation, named in the request so the server knows not to
  /// expect the plain verifier. `plain` is also legal in the spec and is worth
  /// nothing, so it is never used here.
  static const method = 'S256';

  /// RFC 7636 allows 43 to 128 characters. 64 random bytes, base64url encoded,
  /// lands near the top of that range.
  static Future<PkcePair> generate({Random? random}) async {
    final rng = random ?? Random.secure();
    final verifier = _base64Url([
      for (var i = 0; i < 64; i++) rng.nextInt(256),
    ]);
    final digest = await Sha256().hash(ascii.encode(verifier));
    return PkcePair(
      verifier: verifier,
      challenge: _base64Url(digest.bytes),
    );
  }

  /// base64url without padding, which is what the spec asks for: the '=' would
  /// need escaping in a query string and servers differ on whether they strip
  /// it before comparing.
  static String _base64Url(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  /// No verifier in it. This can reach a log.
  @override
  String toString() => 'PkcePair(challenge: $challenge)';
}

/// A random value echoed back by the authorization server, so a redirect that
/// did not come from the request this app made is recognised and refused.
String newOAuthState({Random? random}) {
  final rng = random ?? Random.secure();
  return PkcePair._base64Url([for (var i = 0; i < 16; i++) rng.nextInt(256)]);
}
