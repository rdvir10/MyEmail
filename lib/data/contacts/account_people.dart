import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:http/http.dart' as http;

import '../../domain/account.dart';
import '../../domain/address_suggestions.dart';
import '../auth/google_oauth.dart' show GoogleOAuth;
import '../auth/microsoft_oauth.dart'
    show MicrosoftOAuth, SignInExpired, SignInNeedsConsent;

/// Whether an account's own address book can be searched from here.
enum PeopleSearchState {
  /// Searched as recipients are typed.
  on,

  /// The account has not allowed it yet. A sign-in that asks for it does.
  needsSignIn,

  /// The account's organisation lets only its administrator allow it.
  /// The same sign-in sends them the request.
  needsAdministrator,

  /// Signed in with an app password, which reaches mail and nothing else.
  notPossible,

  /// Allowed, but the search is switched off where the app is registered:
  /// the People API in the app's Google Cloud project.
  switchedOff,

  /// Could not be asked just now: no connection, or the sign-in itself
  /// needs repairing in Settings, Accounts.
  unknown,
}

@immutable
class PeopleSearchAccess {
  const PeopleSearchAccess(this.state, [this.message]);

  final PeopleSearchState state;

  /// What went wrong, in a sentence, where something did.
  final String? message;
}

/// Each account's own address book, searched online as a recipient is
/// typed: Microsoft's people for an Outlook or Microsoft 365 account (its
/// contacts, the people it writes to, and its organisation's directory),
/// and Google's contacts for a Gmail account signed in with Google (its
/// contacts, and the "other contacts" Gmail keeps of everyone answered).
///
/// Each is a permission of its own, asked for by name, so an account that
/// was allowed mail and not this goes on reading its mail. An account that
/// has not allowed it is passed over, quietly, and not asked again for a
/// while: a question per letter typed whose answer is known is a question
/// to the token server per letter typed.
///
/// Never throws from [search]. Suggestions are a convenience, and a slow
/// or refused address book leaves the ones from the phone and from mail.
class AccountPeople {
  AccountPeople({
    required this.accessToken,
    required this.accounts,
    http.Client? httpClient,
    DateTime Function()? clock,
  }) : _given = httpClient,
       _clock = clock ?? DateTime.now;

  /// The account's token for [scopes].
  final Future<String> Function(
    String accountId, {
    bool force,
    List<String>? scopes,
  })
  accessToken;

  /// Every account in the app, as it stands.
  final Iterable<Account> Function() accounts;

  final http.Client? _given;
  http.Client? _own;
  http.Client get _client => _given ?? (_own ??= http.Client());
  final DateTime Function() _clock;

  /// How long an account that could not be searched is left alone, and
  /// how long an answer is kept for the same letters typed again.
  static const recheckAfter = Duration(minutes: 10);
  static const keepAnswers = Duration(minutes: 10);

  /// The longest one account's search is waited for. The others' answers
  /// are not held up by it.
  static const patience = Duration(seconds: 4);

  /// At most this many from each account.
  static const perAccount = 10;

  /// Accounts passed over, and since when.
  final Map<String, DateTime> _passedOver = {};

  /// Answers by query, lower-cased.
  final Map<String, ({DateTime at, List<AddressSuggestion> people})> _answers =
      {};

  /// Google accounts whose search has been warmed; see [warm].
  final Set<String> _warmed = {};

  /// Microsoft accounts that refused the header asking for the directory
  /// too: a personal account has no directory, and may say so.
  final Set<String> _noDirectory = {};

  static final _graphPeople = Uri.parse(
    'https://graph.microsoft.com/v1.0/me/people',
  );
  static final _googleContacts = Uri.parse(
    'https://people.googleapis.com/v1/people:searchContacts',
  );
  static final _googleOther = Uri.parse(
    'https://people.googleapis.com/v1/otherContacts:search',
  );

  /// Whether [account] could ever be searched: one signed in with Google or
  /// Microsoft. An app password covers IMAP and SMTP and nothing else.
  static bool canSearch(Account account) => switch (account.provider) {
    MailProvider.outlook => true,
    MailProvider.gmail => account.authMethod == AuthMethod.oauth,
  };

  static List<String> scopesFor(Account account) =>
      account.provider == MailProvider.outlook
      ? MicrosoftOAuth.peopleScopes
      : GoogleOAuth.contactsScopes;

  /// Everyone the accounts' address books find for [query], each account's
  /// best first, one entry per address.
  Future<List<AddressSuggestion>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final key = q.toLowerCase();
    final now = _clock();
    final kept = _answers[key];
    if (kept != null && now.difference(kept.at) < keepAnswers) {
      return kept.people;
    }

    final searched = [
      for (final a in accounts())
        if (canSearch(a) && !_isPassedOver(a.id, now)) a,
    ];
    if (searched.isEmpty) return const [];
    final answers = await Future.wait([
      for (final a in searched)
        _searchOne(a, q).timeout(
          patience,
          onTimeout: () {
            debugPrint(
              '[myemail] ${a.emailAddress} took too long to search '
              'its address book',
            );
            return const <AddressSuggestion>[];
          },
        ),
    ]);

    final seen = <String>{};
    final people = [
      for (final answer in answers)
        for (final p in answer)
          if (seen.add(p.email.toLowerCase())) p,
    ];
    if (_answers.length > 100) _answers.clear();
    _answers[key] = (at: now, people: people);
    return people;
  }

  /// Ready the accounts' address books for searching. Google asks for an
  /// empty search first, which brings its index up to date; without it the
  /// first searches can miss people. Done when a recipient field is first
  /// used, not on every letter.
  Future<void> warm() async {
    final now = _clock();
    await Future.wait([
      for (final a in accounts())
        if (a.provider == MailProvider.gmail &&
            canSearch(a) &&
            !_warmed.contains(a.id) &&
            !_isPassedOver(a.id, now))
          _warmGoogle(a).then(
            (_) {},
            onError: (Object e) {
              // Not allowed, or switched off: as a search would find, and
              // left alone as a search would leave it.
              if (e is SignInNeedsConsent ||
                  e is SignInExpired ||
                  e is _SwitchedOff) {
                _passedOver[a.id] = _clock();
                return;
              }
              debugPrint(
                '[myemail] could not ready ${a.emailAddress}\'s '
                'contacts: $e',
              );
            },
          ),
    ]);
  }

  /// Whether [account] can be searched, asked now rather than remembered:
  /// what Settings shows, and how it learns a sign-in has allowed it.
  Future<PeopleSearchAccess> access(Account account) async {
    if (!canSearch(account)) {
      return const PeopleSearchAccess(PeopleSearchState.notPossible);
    }
    try {
      await accessToken(account.id, scopes: scopesFor(account));
      if (account.provider == MailProvider.gmail) {
        // The permission is in hand; whether the API answers is the other
        // half, and the one that is set in the app's Google Cloud project.
        _warmed.remove(account.id);
        await _warmGoogle(account);
      }
      _passedOver.remove(account.id);
      return const PeopleSearchAccess(PeopleSearchState.on);
    } on SignInNeedsConsent catch (e) {
      _passedOver[account.id] = _clock();
      return PeopleSearchAccess(
        e.needsAdministrator
            ? PeopleSearchState.needsAdministrator
            : PeopleSearchState.needsSignIn,
        e.message,
      );
    } on _SwitchedOff catch (e) {
      _passedOver[account.id] = _clock();
      return PeopleSearchAccess(PeopleSearchState.switchedOff, e.message);
    } on SignInExpired catch (e) {
      return PeopleSearchAccess(PeopleSearchState.unknown, e.message);
    } catch (e) {
      return PeopleSearchAccess(PeopleSearchState.unknown, '$e');
    }
  }

  /// Start again for [accountId], which has just signed in again: what it
  /// refused before it may allow now.
  void forget(String accountId) {
    _passedOver.remove(accountId);
    _warmed.remove(accountId);
    _noDirectory.remove(accountId);
    _answers.clear();
  }

  void close() {
    _own?.close();
    _own = null;
  }

  bool _isPassedOver(String accountId, DateTime now) {
    final since = _passedOver[accountId];
    if (since == null) return false;
    if (now.difference(since) < recheckAfter) return true;
    _passedOver.remove(accountId);
    return false;
  }

  Future<List<AddressSuggestion>> _searchOne(Account account, String q) async {
    try {
      return switch (account.provider) {
        MailProvider.outlook => await _searchMicrosoft(account, q),
        MailProvider.gmail => await _searchGoogle(account, q),
      };
    } on SignInNeedsConsent {
      // Not allowed yet, which is the usual case until Settings is used;
      // not worth a line in the log per letter.
      _passedOver[account.id] = _clock();
    } on SignInExpired {
      _passedOver[account.id] = _clock();
    } catch (e) {
      debugPrint(
        '[myemail] could not search ${account.emailAddress}\'s '
        'address book: $e',
      );
      if (e is _SwitchedOff) _passedOver[account.id] = _clock();
    }
    return const [];
  }

  // --- Microsoft -------------------------------------------------------------

  /// Microsoft's people for [q]: ranked by how much the account has to do
  /// with each, matched loosely ("tiler" finds Tyler), and with the
  /// organisation's directory where there is one.
  Future<List<AddressSuggestion>> _searchMicrosoft(
    Account account,
    String q,
  ) async {
    // Quoted, as Graph asks for a search holding an @ or a space; a quote
    // inside would end it early.
    final uri = _graphPeople.replace(
      queryParameters: {
        r'$search': '"${q.replaceAll('"', '')}"',
        r'$top': '$perAccount',
        r'$select': 'displayName,scoredEmailAddresses',
      },
    );
    var directory = !_noDirectory.contains(account.id);
    for (;;) {
      final response = await _authorised(
        account,
        () => http.Request('GET', uri)
          ..headers['Accept'] = 'application/json'
          ..headers.addAll({
            if (directory) 'X-PeopleQuery-QuerySources': 'Mailbox,Directory',
          }),
      );
      if (response.statusCode == 400 && directory) {
        _noDirectory.add(account.id);
        directory = false;
        continue;
      }
      if (response.statusCode == 403) {
        throw const SignInNeedsConsent(
          'This account has not allowed the app to search its people.',
        );
      }
      if (response.statusCode >= 400) {
        throw StateError('Microsoft answered HTTP ${response.statusCode}');
      }
      final value = _json(response)['value'];
      return [
        if (value is List)
          for (final p in value.whereType<Map>())
            if (_firstAddress(p['scoredEmailAddresses'], 'address')
                case final email?)
              AddressSuggestion(
                email: email,
                name: _nonEmpty(p['displayName']),
                fromContacts: true,
              ),
      ];
    }
  }

  // --- Google ----------------------------------------------------------------

  /// Google's contacts for [q], then its other contacts: the people saved
  /// by hand first, then everyone Gmail kept from mail answered.
  Future<List<AddressSuggestion>> _searchGoogle(
    Account account,
    String q,
  ) async {
    if (!_warmed.contains(account.id)) await _warmGoogle(account);
    final answers = await Future.wait([
      _googleSearch(account, _googleContacts, q),
      _googleSearch(account, _googleOther, q),
    ]);
    return [...answers[0], ...answers[1]];
  }

  Future<void> _warmGoogle(Account account) async {
    await Future.wait([
      _googleSearch(account, _googleContacts, ''),
      _googleSearch(account, _googleOther, ''),
    ]);
    _warmed.add(account.id);
  }

  Future<List<AddressSuggestion>> _googleSearch(
    Account account,
    Uri endpoint,
    String q,
  ) async {
    final uri = endpoint.replace(
      queryParameters: {
        'query': q,
        'readMask': 'names,emailAddresses',
        'pageSize': '$perAccount',
      },
    );
    final response = await _authorised(
      account,
      () => http.Request('GET', uri)..headers['Accept'] = 'application/json',
    );
    if (response.statusCode == 403) {
      final error = _json(response)['error'];
      final detail = error is Map ? '${error['message'] ?? ''}' : '';
      final disabled =
          response.body.contains('SERVICE_DISABLED') ||
          detail.contains('has not been used') ||
          detail.contains('is disabled');
      if (disabled) {
        throw const _SwitchedOff(
          "The People API is switched off in the app's Google Cloud "
          'project. Open APIs & Services, Library, People API and enable '
          'it.',
        );
      }
      throw const SignInNeedsConsent(
        'This Google account has not allowed the app to search its '
        'contacts. Sign in with Google again to allow it; nothing cached is '
        'lost.',
      );
    }
    if (response.statusCode >= 400) {
      throw StateError('Google answered HTTP ${response.statusCode}');
    }
    final results = _json(response)['results'];
    return [
      if (results is List)
        for (final r in results.whereType<Map>())
          if (r['person'] case final Map person)
            if (_firstAddress(person['emailAddresses'], 'value')
                case final email?)
              AddressSuggestion(
                email: email,
                name: _googleName(person['names']),
                fromContacts: true,
              ),
    ];
  }

  static String? _googleName(Object? names) {
    if (names is! List) return null;
    for (final n in names.whereType<Map>()) {
      if (_nonEmpty(n['displayName']) case final name?) return name;
    }
    return null;
  }

  // --- plumbing --------------------------------------------------------------

  /// With the account's token for its address book, and once more with a
  /// freshly refreshed one if the server turns the first away.
  Future<http.Response> _authorised(
    Account account,
    http.Request Function() build,
  ) async {
    for (var forced = false; ; forced = true) {
      final token = await accessToken(
        account.id,
        force: forced,
        scopes: scopesFor(account),
      );
      final request = build()..headers['Authorization'] = 'Bearer $token';
      final response = await http.Response.fromStream(
        await _client.send(request),
      );
      if (response.statusCode != 401 || forced) return response;
    }
  }

  static Map<String, Object?> _json(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Not JSON. The status is all there is.
    }
    return const {};
  }

  /// The first entry of [list] whose [field] looks like an address.
  static String? _firstAddress(Object? list, String field) {
    if (list is! List) return null;
    for (final e in list.whereType<Map>()) {
      final email = _nonEmpty(e[field]);
      if (email != null && email.contains('@')) return email;
    }
    return null;
  }

  static String? _nonEmpty(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// The search is switched off where the app is registered.
class _SwitchedOff implements Exception {
  const _SwitchedOff(this.message);
  final String message;
  @override
  String toString() => message;
}
