import 'dart:async';

import '../credential_store.dart';
import 'microsoft_oauth.dart';
import 'oauth_refresher.dart';
import 'oauth_token.dart';

/// Keeps each OAuth account in usable access tokens.
///
/// The [CredentialStore] slot that holds an app password for a Gmail account
/// holds this account's token JSON instead, so the Keystore, the account
/// removal path and the "no secret stored" checks all keep working unchanged.
///
/// Two things here are not obvious and both are the point of the class:
///
/// One, refreshes are single-flighted per account. Opening a folder fires a
/// dozen Graph requests while a send may be under way, and all of them ask
/// for a token at once. Each refresh hands back a new refresh token, and the
/// newest one is the one to keep: Microsoft leaves the one just spent valid
/// until it expires, so a race is not a sign-out, but concurrent refreshes
/// still cost a round trip each and leave it to chance which token ends up
/// stored. The in-flight map makes the second caller await the first's
/// answer instead.
///
/// Two, a failed refresh does not sign the account out unless Microsoft
/// actually rejected the refresh token. A tunnel, a captive portal or a 503
/// must leave the stored token alone so the next attempt can use it.
class OAuthTokenRepository {
  OAuthTokenRepository({
    required this.credentialStore,
    required this.oauthClient,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final CredentialStore credentialStore;

  /// Built per refresh rather than held, so the HTTP client it owns is not
  /// kept open between the hours when nothing needs refreshing. By account,
  /// because a Google account and a Microsoft one refresh at different
  /// places; the engine answers from the account's provider.
  final OAuthRefresher Function(String accountId) oauthClient;
  final DateTime Function() _clock;

  final Map<String, Future<OAuthToken>> _inFlight = {};

  /// Access tokens for resources other than the default one, held in memory
  /// only.
  ///
  /// The Keystore record has room for one access token, and it holds the one
  /// for the default scopes, [MicrosoftOAuth.scopes]. Any other access token
  /// lives about an hour and is cheap to fetch again
  /// from the refresh token, so keeping it here costs nothing on a restart
  /// and keeps the stored format unchanged — and keeps a second long-lived
  /// credential out of storage, which is worth something on its own.
  final Map<String, OAuthToken> _byResource = {};

  /// The stored record, held in memory between reads.
  ///
  /// Every Graph request asks for a token, and opening a folder on a work
  /// account is a dozen requests: without this, each one decrypts the
  /// Keystore over a platform channel and parses the JSON again, and the
  /// sum of that is a visible part of the wait before mail appears.
  ///
  /// Replaced whenever a token is written, dropped when the account is
  /// forgotten, and bypassed by [force] — which is exactly the case where
  /// what is held turned out to be wrong.
  final Map<String, OAuthToken> _stored = {};

  static String _key(String accountId, List<String> scopes) =>
      '$accountId|${scopes.join(' ')}';

  /// A token good for at least [OAuthToken.refreshMargin] more.
  ///
  /// [force] refreshes even when the stored token still looks fresh, for the
  /// one case where "looks fresh" was wrong: the server rejected it anyway,
  /// which happens when the device clock is off or the token was revoked
  /// mid-life.
  Future<String> accessToken(
    String accountId, {
    bool force = false,
    List<String>? scopes,
  }) async {
    final stored = (force ? null : _stored[accountId]) ??
        OAuthToken.fromStoredJson(await credentialStore.readSecret(accountId));
    if (stored == null) {
      _stored.remove(accountId);
      throw const SignInExpired(
        'This account is not signed in. Remove it and add it again.',
      );
    }
    _stored[accountId] = stored;

    // A resource other than the default one. Its access token never goes to
    // storage, so the freshness check reads the in-memory copy instead.
    if (scopes != null) {
      final cached = _byResource[_key(accountId, scopes)];
      if (!force && cached != null && cached.isUsableAt(_clock())) {
        return cached.accessToken;
      }
      final refreshed = await _refreshOnce(accountId, stored, scopes);
      return refreshed.accessToken;
    }

    if (!force && stored.isUsableAt(_clock())) return stored.accessToken;

    try {
      return (await _refreshOnce(accountId, stored, null)).accessToken;
    } on SignInExpired {
      // The in-flight map only covers this isolate, and there are two. The
      // background worker runs in its own, with its own repository, reading
      // the same Keystore — so both can spend the same refresh token, and
      // whichever gets there second is told invalid_grant even though the
      // account is perfectly healthy.
      //
      // Nothing was overwritten on the way here, so the winner's token is
      // sitting in the store already. Re-read before concluding anything: if
      // it has moved on, this was the race and not a real sign-out.
      final newer = await _newerSignIn(accountId, stored);
      if (newer != null) return newer;
      _stored.remove(accountId);
      rethrow;
    } on SignInNeedsConsent {
      // What "Sign in again" is for. The new sign-in is written to the store,
      // but a repository in another isolate — the live worker, which runs for
      // an hour — still holds the old one, and refreshing that keeps getting
      // this answer. Only an expiry used to send it back to the store, so the
      // account went on failing there as if the sign-in had not happened.
      final newer = await _newerSignIn(accountId, stored);
      if (newer != null) return newer;
      rethrow;
    }
  }

  /// A token from a sign-in newer than [held], if the store has one: its
  /// access token if still good, otherwise a refresh of it. Null when the
  /// store holds the same sign-in as [held], or none.
  Future<String?> _newerSignIn(String accountId, OAuthToken held) async {
    final latest = OAuthToken.fromStoredJson(
      await credentialStore.readSecret(accountId),
    );
    if (latest == null || latest.refreshToken == held.refreshToken) {
      return null;
    }
    _stored[accountId] = latest;
    if (latest.isUsableAt(_clock())) return latest.accessToken;
    return (await _refreshOnce(accountId, latest, null)).accessToken;
  }

  /// Save the token a fresh sign-in produced.
  Future<void> store(String accountId, OAuthToken token) async {
    await credentialStore.writeSecret(accountId, token.toStoredJson());
    _stored[accountId] = token;
  }

  /// How many times each account has been forgotten. A refresh notes the
  /// count as it starts, and a refresh that finds it moved on by the time
  /// Microsoft answers writes nothing.
  final Map<String, int> _forgotten = {};

  /// Drop everything held for an account, on the way out.
  void forget(String accountId) {
    _forgotten[accountId] = (_forgotten[accountId] ?? 0) + 1;
    _stored.remove(accountId);
    _byResource.removeWhere((key, _) => key.startsWith('$accountId|'));
  }

  /// Whether this account's stored secret is an OAuth token rather than a
  /// password, without caring what the account record claims.
  Future<bool> hasToken(String accountId) async =>
      OAuthToken.fromStoredJson(await credentialStore.readSecret(accountId)) !=
      null;

  Future<OAuthToken> _refreshOnce(
    String accountId,
    OAuthToken stored,
    List<String>? scopes,
  ) {
    // Keyed by resource as well as account. Two resources are two different
    // exchanges and must not share one in-flight slot, or a caller waiting
    // for a token for one set of scopes would be handed one for another.
    final key = scopes == null ? accountId : _key(accountId, scopes);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final pending = _refresh(accountId, stored, scopes);
    _inFlight[key] = pending;
    // whenComplete rather than then: the slot must clear on failure too, or
    // one network blip would wedge the account until the app restarts.
    return pending.whenComplete(() => _inFlight.remove(key));
  }

  Future<OAuthToken> _refresh(
    String accountId,
    OAuthToken stored,
    List<String>? scopes,
  ) async {
    final generation = _forgotten[accountId] ?? 0;
    final client = oauthClient(accountId);
    try {
      final refreshed = await client.refresh(stored, scopes: scopes);

      // The account may have been removed while Microsoft was answering.
      // Writing now would put a working refresh token back on the device,
      // good for up to ninety days, for an account that looks gone and that
      // nothing will ever clean up. Removed here, forget has been called;
      // removed from the other isolate, the stored secret is gone. The
      // generation check comes after the read and straight before the
      // write, with no wait in between, so a removal that lands later has
      // its delete queued behind this write rather than ahead of it.
      if (await credentialStore.readSecret(accountId) == null ||
          (_forgotten[accountId] ?? 0) != generation) {
        return refreshed;
      }

      if (scopes == null) {
        await store(accountId, refreshed);
      } else {
        _byResource[_key(accountId, scopes)] = refreshed;
        // The access token belongs to another resource, but the refresh token
        // does not: every exchange hands back a new one, and the newest is
        // the one to keep. The spent one stays valid, but only until its own
        // expiry, so keeping it would sign the account out in the end
        // however often the account was used in between.
        await store(accountId, stored.withRefreshToken(refreshed.refreshToken));
      }
      return refreshed;
    } finally {
      client.close();
    }
  }
}
