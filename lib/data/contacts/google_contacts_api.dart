import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:http/http.dart' as http;

import '../answer_limit.dart';
import '../auth/microsoft_oauth.dart'
    show SignInNeedsConsent, SignInUnreachable;
import '../mail_engine.dart' show AuthenticationFailed, ConnectionFailed;
import 'contact_wire_errors.dart';

/// A thin client over Google's People API for contact sync: the account's
/// saved contacts read whole or as changes since a sync token, read again
/// one by one or 200 at a time, and created, changed and deleted.
///
/// It takes and gives Google's JSON as it is (`Person` objects as maps);
/// what a contact holds, and how it maps to Outlook's, is the mapping's.
/// What it does know is the wire: the field mask and the source on every
/// call that answers with a Person, how a sync token expires, an etag that
/// is stale, a throttle waited out, a daily quota spent, the API switched
/// off, and a token that does not cover contacts. Its failures never carry
/// Google's own sentence, which can quote the contact back.
///
/// Calls go one at a time, as Google asks of changes to one account's
/// contacts: the runner awaits each before the next.
class GoogleContactsApi {
  GoogleContactsApi({
    required this.accessToken,
    http.Client? httpClient,
    this.sleep,
    DateTime Function()? clock,
  }) : _given = httpClient,
       _clock = clock ?? DateTime.now;

  /// The Google account's token for its contacts. Asked for per request,
  /// because a refused one is asked for again with `force`.
  final Future<String> Function({bool force}) accessToken;

  /// A client handed in, which belongs to whoever handed it in.
  final http.Client? _given;

  /// One made here, and closed by [close].
  http.Client? _own;

  http.Client get _client => _given ?? (_own ??= http.Client());

  /// Overridden by tests, which must not really wait out a throttle.
  final Future<void> Function(Duration)? sleep;

  final DateTime Function() _clock;

  static const base = 'https://people.googleapis.com/v1';

  /// The fields the sync reads, on every call that answers with a Person
  /// (as `personFields`, or `readMask` for a batch create). Asking for
  /// these alone keeps the answers small, and a sync token is tied to the
  /// mask it was made with: a change to this list must come with a new
  /// [syncFieldsVersion], which makes the next run a full listing.
  static const syncFields =
      'names,nicknames,emailAddresses,phoneNumbers,addresses,organizations,'
      'birthdays,biographies,relations,urls,imClients,memberships,'
      'clientData,metadata';

  /// Kept with the sync token: a token made under another version is not
  /// used.
  static const syncFieldsVersion = 1;

  /// Every field a contact can be read with: for the read just before a
  /// delete, which goes into Recently deleted whole, and for the backup
  /// files. The deprecated ones are left out; Google refuses some of them.
  static const everyField =
      'addresses,ageRanges,biographies,birthdays,calendarUrls,clientData,'
      'coverPhotos,emailAddresses,events,externalIds,genders,imClients,'
      'interests,locales,locations,memberships,metadata,miscKeywords,names,'
      'nicknames,occupations,organizations,phoneNumbers,photos,relations,'
      'sipAddresses,skills,urls,userDefined';

  /// Sent with every call that answers with a Person. Without it Google
  /// merges in the person's own Google profile, which cannot be written
  /// back and would read as changes.
  static const contactSource = 'READ_SOURCE_TYPE_CONTACT';

  /// The most a listing page may hold: the fewer pages, the fewer of the
  /// fixed-quota first pages a full listing spends.
  static const pageSize = 1000;

  /// The most names one `getBatchGet`, and contacts one
  /// `batchCreateContacts`, may carry.
  static const batchLimit = 200;

  /// The `clientData` key of the hidden tag a contact the sync creates
  /// carries: the id of its partner on the other side.
  static const tagKey = 'myemail.link';

  /// The longest a throttle is waited out, all waits together, before the
  /// run stops to be tried again later.
  static const longestBackoff = Duration(minutes: 1);

  /// The account's saved contacts, all of them, with a sync token for the
  /// changes after this. Every page is read before it returns.
  ///
  /// With [everyField], every readable field and no token: for the backup
  /// files, which are not a feed.
  Future<GoogleContactsRead> listAll({bool everyField = false}) =>
      _list(everyField: everyField);

  /// The changes since [syncToken]: contacts added or changed, deletions,
  /// and contacts Google has given new names. Every page is read before it
  /// returns, so a re-key on a later page is applied before a deletion on
  /// an earlier one is believed.
  ///
  /// Throws [ContactFeedExpired] when the token is no good any more: then a
  /// full listing ([listAll]) is the answer.
  Future<GoogleContactsRead> listChanges(String syncToken) =>
      _list(syncToken: syncToken, everyField: false);

  /// One contact as it is now, or null when it is not there. Under another
  /// name where Google has re-keyed it: the answer's `resourceName` says.
  Future<Map<String, Object?>?> get(
    String resourceName, {
    bool everyField = false,
  }) async {
    final uri = Uri.parse('$base/${_name(resourceName)}').replace(
      queryParameters: {
        'personFields': everyField ? GoogleContactsApi.everyField : syncFields,
        'sources': contactSource,
      },
    );
    final response = await _exchange(() => http.Request('GET', uri));
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) throw _failureFor(response, 'get');
    return _personOf(response);
  }

  /// [resourceNames] read again, [batchLimit] to a request: which are
  /// there (some perhaps under new names), which Google says are not, and
  /// which it said nothing clear about.
  ///
  /// Only a NOT_FOUND is a deletion. Google's listings lag behind its
  /// writes by minutes, so a contact missing from a full listing is asked
  /// about here before it is believed gone.
  Future<GoogleBatchRead> getBatch(
    Iterable<String> resourceNames, {
    bool everyField = false,
  }) async {
    final names = resourceNames.toSet().toList();
    final found = <String, Map<String, Object?>>{};
    final notFound = <String>{};
    for (var start = 0; start < names.length; start += batchLimit) {
      final chunk = names.sublist(
        start,
        start + batchLimit < names.length ? start + batchLimit : names.length,
      );
      final uri = Uri.parse('$base/people:batchGet').replace(
        queryParameters: {
          'resourceNames': [for (final n in chunk) _name(n)],
          'personFields':
              everyField ? GoogleContactsApi.everyField : syncFields,
          'sources': contactSource,
        },
      );
      final response = await _exchange(() => http.Request('GET', uri));
      if (response.statusCode >= 400) throw _failureFor(response, 'batchGet');
      final responses = _jsonOf(response)['responses'];
      for (final r in responses is List ? responses : const []) {
        if (r is! Map) continue;
        final person = r['person'];
        var asked = r['requestedResourceName'];
        if (asked is! String && person is Map) asked = person['resourceName'];
        if (asked is! String || !chunk.contains(asked)) continue;
        final status = r['status'];
        final code = status is Map ? status['code'] : null;
        final httpCode = r['httpStatusCode'];
        if (person is Map && (code == null || code == 0)) {
          found[asked] = person.cast<String, Object?>();
        } else if (code == 5 || (code == null && httpCode == 404)) {
          notFound.add(asked);
        }
      }
    }
    return GoogleBatchRead(
      found: found,
      notFound: notFound,
      unknown: {
        for (final n in names)
          if (!found.containsKey(n) && !notFound.contains(n)) n,
      },
    );
  }

  /// Create [person] and answer with it as Google made it. [tag], where
  /// given, goes in as the hidden tag ([tagKey]), beside any other
  /// `clientData` the person carries.
  ///
  /// A refusal of this contact is a [ContactRefused].
  Future<Map<String, Object?>> create(
    Map<String, Object?> person, {
    String? tag,
  }) async {
    final uri = Uri.parse('$base/people:createContact').replace(
      queryParameters: {'personFields': syncFields, 'sources': contactSource},
    );
    final body = jsonEncode(withTag(person, tag));
    final response = await _exchange(
      () => http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode >= 400) throw _failureFor(response, 'create');
    return _personOf(response);
  }

  /// Create [people], [batchLimit] to a request, each with its tag, and
  /// answer with what became of each, in the order given. Never throws for
  /// a failure: what was made before it is kept, and handed back.
  ///
  /// The order of Google's answer is not documented, so each contact made
  /// is matched to what was asked by its tag, which must be there and be
  /// different for each. When Google refuses a batch it names the contacts
  /// it would not take (`contactErrors`, by their place in the request) and
  /// makes none: those are refused ([ContactRefused]) and the rest sent
  /// again. A refusal that names none is the batch's ([ContactBatchRefused])
  /// and the next batch goes on. Any other failure (no connection, a
  /// server in trouble, a throttle past its waits, a quota or a sign-in)
  /// is the answer for every contact not yet answered, this batch's and
  /// the ones after it, which are not sent.
  Future<List<ContactCreateAnswer>> createBatch(
    List<({Map<String, Object?> person, String tag})> people,
  ) async {
    final places = <String, int>{};
    for (var i = 0; i < people.length; i++) {
      final tag = people[i].tag;
      if (tag.isEmpty || places.putIfAbsent(tag, () => i) != i) {
        throw ArgumentError.value(tag, 'people', 'each needs a tag of its own');
      }
    }
    final answers = List<ContactCreateAnswer?>.filled(people.length, null);
    final uri = Uri.parse('$base/people:batchCreateContacts');
    for (var start = 0; start < people.length; start += batchLimit) {
      var pending = [
        for (var i = start;
            i < people.length && i < start + batchLimit;
            i++)
          i,
      ];
      try {
        while (pending.isNotEmpty) {
          final body = jsonEncode({
            'contacts': [
              for (final i in pending)
                {'contactPerson': withTag(people[i].person, people[i].tag)},
            ],
            'readMask': syncFields,
            'sources': [contactSource],
          });
          final response = await _exchange(
            () => http.Request('POST', uri)
              ..headers['Content-Type'] = 'application/json'
              ..body = body,
          );
          if (response.statusCode < 400) {
            final made = _jsonOf(response)['createdPeople'];
            for (final r in made is List ? made : const []) {
              if (r is! Map || r['person'] is! Map) continue;
              final person = (r['person'] as Map).cast<String, Object?>();
              final i = places[tagOf(person)];
              if (i != null && pending.contains(i)) {
                answers[i] = (contact: person, failure: null);
              }
            }
            for (final i in pending) {
              answers[i] ??= (
                contact: null,
                failure: const ConnectionFailed(
                  'Google made the new contacts but did not hand this one '
                  'back. It is looked for by its tag.',
                ),
              );
            }
            break;
          }
          final named = response.statusCode == 400
              ? _contactErrors(response)
              : const <int, String?>{};
          final refused = {
            for (final k in named.keys)
              if (k >= 0 && k < pending.length) k,
          };
          if (refused.isEmpty) {
            final failure = _failureFor(response, 'batchCreate');
            throw failure is ContactRefused
                ? ContactBatchRefused.from('Google', failure)
                : failure;
          }
          for (final k in refused) {
            answers[pending[k]] = (
              contact: null,
              failure: ContactRefused.by('Google', 400, named[k]),
            );
          }
          debugPrint(
            '[myemail] contacts: Google refused ${refused.length} of a '
            'batch of ${pending.length} new contacts',
          );
          pending = [
            for (var k = 0; k < pending.length; k++)
              if (!refused.contains(k)) pending[k],
          ];
        }
      } on ContactBatchRefused catch (e) {
        for (final i in pending) {
          answers[i] = (contact: null, failure: e);
        }
      } on Exception catch (e) {
        for (var i = start; i < people.length; i++) {
          answers[i] ??= (contact: null, failure: e);
        }
        break;
      }
    }
    final made = answers.where((a) => a?.contact != null).length;
    debugPrint('[myemail] contacts: Google batch made $made of '
        '${people.length}');
    return [for (final a in answers) a!];
  }

  /// Write [fields] (Google's `updatePersonFields`) of [person], which
  /// carries the etag it was read with, to the contact [resourceName], and
  /// answer with the contact as it now is.
  ///
  /// A stale etag is a [ContactChangedMeanwhile]: read it again, merge
  /// again, try once more. A contact no longer there is a [ContactGone].
  Future<Map<String, Object?>> update(
    String resourceName,
    Map<String, Object?> person, {
    required Iterable<String> fields,
  }) async {
    final uri = Uri.parse('$base/${_name(resourceName)}:updateContact').replace(
      queryParameters: {
        'updatePersonFields': fields.join(','),
        'personFields': syncFields,
        'sources': contactSource,
      },
    );
    final body = jsonEncode(person);
    final response = await _exchange(
      () => http.Request('PATCH', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    if (response.statusCode == 404) throw const ContactGone();
    if (_etagClash(response)) {
      debugPrint('[myemail] contacts: Google update met a newer etag '
          '(HTTP ${response.statusCode})');
      throw const ContactChangedMeanwhile();
    }
    if (response.statusCode >= 400) throw _failureFor(response, 'update');
    return _personOf(response);
  }

  /// Delete the contact [resourceName]. True when it was deleted now, false
  /// when it was not there to delete: either way it is gone.
  Future<bool> delete(String resourceName) async {
    final uri = Uri.parse('$base/${_name(resourceName)}:deleteContact');
    final response = await _exchange(() => http.Request('DELETE', uri));
    if (response.statusCode == 404) return false;
    if (response.statusCode >= 400) throw _failureFor(response, 'delete');
    return true;
  }

  /// [person] with [tag] as its hidden tag, every other app's `clientData`
  /// kept. [person] itself unchanged, and returned as it is without a tag.
  static Map<String, Object?> withTag(
    Map<String, Object?> person,
    String? tag,
  ) {
    if (tag == null) return person;
    final others = person['clientData'];
    return {
      ...person,
      'clientData': [
        if (others is List)
          for (final e in others)
            if (e is! Map || e['key'] != tagKey) e,
        {'key': tagKey, 'value': tag},
      ],
    };
  }

  /// The hidden tag [person] carries, if any.
  static String? tagOf(Map<String, Object?> person) {
    final data = person['clientData'];
    if (data is! List) return null;
    for (final e in data) {
      if (e is Map && e['key'] == tagKey && e['value'] is String) {
        final value = e['value'] as String;
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  /// Let go of the connection. Only one made here: a client handed in is
  /// closed by its owner.
  void close() {
    _own?.close();
    _own = null;
  }

  // --- listing ---------------------------------------------------------------

  Future<GoogleContactsRead> _list({
    String? syncToken,
    required bool everyField,
  }) async {
    final watch = Stopwatch()..start();
    // The same parameters on every page and, for a later run, with the
    // token: Google refuses a token sent with any that differ.
    final fixed = <String, String>{
      'personFields': everyField ? GoogleContactsApi.everyField : syncFields,
      'sources': contactSource,
      'pageSize': '$pageSize',
      if (!everyField) 'requestSyncToken': 'true',
      'syncToken': ?syncToken,
    };
    final entries = <Map<String, Object?>>[];
    final pageTokens = <String>{};
    String? pageToken;
    String? nextSyncToken;
    var pages = 0;
    do {
      final uri = Uri.parse('$base/people/me/connections').replace(
        queryParameters: {...fixed, 'pageToken': ?pageToken},
      );
      final response = await _exchange(() => http.Request('GET', uri));
      if (syncToken != null && _tokenExpired(response)) {
        debugPrint('[myemail] contacts: Google sync token expired '
            '(HTTP ${response.statusCode})');
        throw ContactFeedExpired(response.statusCode);
      }
      if (response.statusCode >= 400) throw _failureFor(response, 'list');
      final json = _jsonOf(response);
      pages++;
      final connections = json['connections'];
      for (final c in connections is List ? connections : const []) {
        if (c is Map) entries.add(c.cast<String, Object?>());
      }
      pageToken = _text(json['nextPageToken']);
      if (pageToken != null && !pageTokens.add(pageToken)) {
        // Asked for again, it would come again: a listing that never ends.
        throw const ConnectionFailed(
          'Google sent the same page of contacts twice. Try again shortly.',
        );
      }
      if (pageToken == null) nextSyncToken = _text(json['nextSyncToken']);
    } while (pageToken != null);

    final read = foldListing(
      entries,
      syncToken: everyField ? null : nextSyncToken,
      complete: syncToken == null,
      pages: pages,
    );
    debugPrint(
      '[myemail] contacts: Google ${syncToken == null ? 'listed' : 'changes'}'
      ' ${read.people.length} people, ${read.deleted.length} deleted, '
      '${read.rekeyed.length} re-keyed, $pages pages, '
      '${watch.elapsedMilliseconds} ms',
    );
    return read;
  }

  /// A listing's entries, every page of them, as what they say: who is
  /// there, who has gone, and who has a new name.
  ///
  /// The same contact can come more than once; its last entry is how it
  /// stands. A name some contact lists in its `previousResourceNames` is a
  /// re-key, not a deletion, even where the old name comes as deleted, and
  /// an entry still under the old name is the contact from before.
  static GoogleContactsRead foldListing(
    List<Map<String, Object?>> entries, {
    required String? syncToken,
    required bool complete,
    int pages = 1,
  }) {
    final byName = <String, Map<String, Object?>>{};
    for (final e in entries) {
      final name = e['resourceName'];
      if (name is! String || name.isEmpty) continue;
      byName.remove(name);
      byName[name] = e;
    }
    final rekeyed = <String, String>{};
    for (final MapEntry(key: name, value: e) in byName.entries) {
      if (_isDeleted(e)) continue;
      final metadata = e['metadata'];
      final previous =
          metadata is Map ? metadata['previousResourceNames'] : null;
      for (final old in previous is List ? previous : const []) {
        if (old is String && old.isNotEmpty && old != name) rekeyed[old] = name;
      }
    }
    // A re-key of a re-key ends at the name the contact has now.
    for (final old in rekeyed.keys.toList()) {
      var now = rekeyed[old]!;
      for (var hops = 0; rekeyed.containsKey(now) && hops < 10; hops++) {
        now = rekeyed[now]!;
      }
      rekeyed[old] = now;
    }
    return GoogleContactsRead(
      people: [
        for (final MapEntry(key: name, value: e) in byName.entries)
          if (!_isDeleted(e) && !rekeyed.containsKey(name)) e,
      ],
      deleted: {
        for (final MapEntry(key: name, value: e) in byName.entries)
          if (_isDeleted(e) && !rekeyed.containsKey(name)) name,
      },
      rekeyed: rekeyed,
      syncToken: syncToken,
      complete: complete,
      pages: pages,
    );
  }

  static bool _isDeleted(Map<String, Object?> person) {
    final metadata = person['metadata'];
    return metadata is Map && metadata['deleted'] == true;
  }

  // --- plumbing --------------------------------------------------------------

  /// [resourceName] as it goes into a path: `people/` and the id, which is
  /// encoded, so a name that is not one cannot reach another endpoint.
  static String _name(String resourceName) {
    const prefix = 'people/';
    if (!resourceName.startsWith(prefix) ||
        resourceName.length == prefix.length) {
      throw ArgumentError.value(resourceName, 'resourceName', 'not a person');
    }
    final id = resourceName.substring(prefix.length);
    return '$prefix${Uri.encodeComponent(id)}';
  }

  /// Send what [build] makes, waiting out Google's throttling: for as long
  /// as it asks where it says (`Retry-After`), otherwise twice as long
  /// each time from a second, the last wait cut to what is left of
  /// [longestBackoff], which is the most waited in all. After that, or
  /// when Google asks for longer than is left, the run stops and is tried
  /// again later. A daily quota is not waited for: nothing changes until
  /// the next day.
  Future<http.Response> _exchange(http.Request Function() build) async {
    var waited = Duration.zero;
    var next = const Duration(seconds: 1);
    for (;;) {
      final response = await _authorised(build);
      if (!_throttled(response)) return response;
      if (_dailyQuota(response)) {
        final until = nextQuotaDay(_clock());
        debugPrint('[myemail] contacts: Google daily quota spent '
            '(HTTP ${response.statusCode})');
        throw ContactQuotaSpent(until);
      }
      // A Retry-After of nothing is no answer: asked again at once, it
      // would be asked for ever.
      final asked = switch (_retryAfter(response)) {
        final d? when d > Duration.zero => d,
        _ => null,
      };
      final left = longestBackoff - waited;
      final wait = asked ?? (next < left ? next : left);
      if (left <= Duration.zero || wait > left) {
        debugPrint('[myemail] contacts: Google still throttling after '
            '${waited.inSeconds} s (HTTP ${response.statusCode})');
        throw const ConnectionFailed(
          'Google is rate limiting the contacts of this account. Contact '
          'sync tries again later.',
        );
      }
      debugPrint('[myemail] contacts: Google throttled '
          '(HTTP ${response.statusCode}), waiting ${wait.inSeconds} s');
      await (sleep ?? _realSleep)(wait);
      waited += wait;
      if (asked == null) next *= 2;
    }
  }

  /// When Google's daily quotas start again after [now]: they are renewed
  /// at midnight Pacific time, which is 08:00 UTC while California keeps
  /// standard time and 07:00 UTC in its summer time.
  static DateTime nextQuotaDay(DateTime now) {
    final utc = now.toUtc();
    final local = utc.subtract(Duration(hours: _pacificSummer(utc) ? 7 : 8));
    // The next Pacific midnight, as a date, and how far behind UTC
    // California is then: summer time starts and ends at 2 a.m., so a
    // midnight is on the clock of the day before it changes.
    final day = DateTime.utc(local.year, local.month, local.day + 1);
    final summer =
        day.isAfter(_sunday(day.year, 3, 2)) &&
        !day.isAfter(_sunday(day.year, 11, 1));
    return day.add(Duration(hours: summer ? 7 : 8));
  }

  /// Whether California keeps summer time at the instant [utc]: from 2 a.m.
  /// standard time (10:00 UTC) on the second Sunday of March to 2 a.m.
  /// summer time (09:00 UTC) on the first Sunday of November.
  static bool _pacificSummer(DateTime utc) {
    final starts = _sunday(utc.year, 3, 2).add(const Duration(hours: 10));
    final ends = _sunday(utc.year, 11, 1).add(const Duration(hours: 9));
    return !utc.isBefore(starts) && utc.isBefore(ends);
  }

  /// The [nth] Sunday of [month] in [year], as a UTC date.
  static DateTime _sunday(int year, int month, int nth) {
    final first = DateTime.utc(year, month);
    final toSunday = (DateTime.sunday - first.weekday) % 7;
    return DateTime.utc(year, month, 1 + toSunday + 7 * (nth - 1));
  }

  /// With the account's token, and once more with a freshly refreshed one
  /// if Google turns the first away. A refresh that could not reach Google
  /// reads as what it is, no connection, and so does an answer not had in
  /// time ([answeredInTime]). Neither keeps more than the kind of failure:
  /// its text can hold the request, and the request a contact's name.
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
        response = await answeredInTime(
          _client.send(request),
          uploading: request.contentLength,
        );
      } on Exception catch (e) {
        debugPrint('[myemail] contacts: Google not reached '
            '(${e.runtimeType})');
        throw ConnectionFailed('Could not reach Google (${e.runtimeType}).');
      }
      if (response.statusCode != 401 || forced) return response;
    }
  }

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  /// The response's JSON, or nothing if it has none.
  static Map<String, Object?> _jsonOf(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Not JSON. The status is all there is.
    }
    return const {};
  }

  /// The Person a write or read answered with. One without a name is not
  /// taken for a contact: what was made could not be found again.
  static Map<String, Object?> _personOf(http.Response response) {
    final json = _jsonOf(response);
    if (json['resourceName'] is! String) {
      throw ConnectionFailed(
        'Google answered without the contact '
        '(HTTP ${response.statusCode}). Try again shortly.',
      );
    }
    return json;
  }

  static String? _text(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  /// What Google's error envelope says, as codes: its status word, and the
  /// reasons in its details (the newer envelope) or errors (the older).
  /// Its message is read only by the few checks that must, and kept by
  /// nothing.
  static ({int status, String word, Set<String> reasons, String message})
      _errorOf(http.Response response) {
    var word = '';
    var message = '';
    final reasons = <String>{};
    final error = _jsonOf(response)['error'];
    if (error is Map) {
      word = '${error['status'] ?? ''}'.toUpperCase();
      message = error['message'] is String ? error['message'] as String : '';
      for (final list in [error['details'], error['errors']]) {
        if (list is! List) continue;
        for (final d in list) {
          if (d is Map && d['reason'] is String) {
            reasons.add((d['reason'] as String).toUpperCase());
          }
        }
      }
    }
    return (
      status: response.statusCode,
      word: word,
      reasons: reasons,
      message: message,
    );
  }

  /// A sync token past its time: 410, or a 400 with the reason
  /// EXPIRED_SYNC_TOKEN, or a 400 whose message says so where no reason
  /// came. The message is read to tell, and only that.
  static bool _tokenExpired(http.Response response) {
    if (response.statusCode == 410) return true;
    if (response.statusCode != 400) return false;
    final error = _errorOf(response);
    return error.reasons.contains('EXPIRED_SYNC_TOKEN') ||
        error.message.startsWith('Sync token is expired');
  }

  /// A stale etag on an update: Google's FAILED_PRECONDITION, or a 412.
  static bool _etagClash(http.Response response) {
    if (response.statusCode == 412) return true;
    if (response.statusCode != 400) return false;
    final error = _errorOf(response);
    return error.word == 'FAILED_PRECONDITION' ||
        error.reasons.contains('FAILEDPRECONDITION') ||
        error.reasons.contains('FAILED_PRECONDITION');
  }

  static const _throttleReasons = {
    'RATE_LIMIT_EXCEEDED',
    'RATELIMITEXCEEDED',
    'USERRATELIMITEXCEEDED',
    'QUOTAEXCEEDED',
    'QUOTA_EXCEEDED',
  };

  /// Turned away for asking too much: a 429, or a 403 that names a rate
  /// limit (Google's older envelope throttles with 403).
  static bool _throttled(http.Response response) {
    final status = response.statusCode;
    if (status == 429) return true;
    if (status != 403) return false;
    final error = _errorOf(response);
    return error.word == 'RESOURCE_EXHAUSTED' ||
        error.reasons.any(_throttleReasons.contains);
  }

  /// Whether a throttle is a daily quota rather than a per-minute one. The
  /// quota's name is the only place that says so: in the details' metadata
  /// (`quota_limit`, `quota_metric`), a QuotaFailure's violations, or the
  /// message. Read to tell, and kept by nothing.
  static bool _dailyQuota(http.Response response) {
    bool daily(Object? text) {
      if (text is! String) return false;
      final t = text.toLowerCase();
      return t.contains('per day') ||
          t.contains('perday') ||
          t.contains('daily');
    }

    final error = _jsonOf(response)['error'];
    if (error is! Map) return false;
    if (daily(error['message'])) return true;
    final details = error['details'];
    for (final d in details is List ? details : const []) {
      if (d is! Map) continue;
      final metadata = d['metadata'];
      if (metadata is Map &&
          (daily(metadata['quota_limit']) || daily(metadata['quota_metric']))) {
        return true;
      }
      final violations = d['violations'];
      for (final v in violations is List ? violations : const []) {
        if (v is Map && (daily(v['subject']) || daily(v['description']))) {
          return true;
        }
      }
    }
    return false;
  }

  /// How long Google asked to be left alone, where it said, in seconds.
  static Duration? _retryAfter(http.Response response) {
    final header = response.headers['retry-after'];
    final seconds = header == null ? null : int.tryParse(header.trim());
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  /// The contacts a refused batch create names, by their place in the
  /// request, each with the code of why. Google puts them in the details,
  /// as `contactErrors`, a map from the place to a status.
  static Map<int, String?> _contactErrors(http.Response response) {
    final named = <int, String?>{};
    final error = _jsonOf(response)['error'];
    final details = error is Map ? error['details'] : null;
    for (final d in details is List ? details : const []) {
      final errors = d is Map ? d['contactErrors'] : null;
      if (errors is! Map) continue;
      for (final MapEntry(:key, :value) in errors.entries) {
        final place = int.tryParse('$key');
        if (place == null) continue;
        String? reason;
        if (value is Map) {
          reason = _codeName(value['code']);
          final inner = value['details'];
          for (final i in inner is List ? inner : const []) {
            if (i is Map && errorCode(i['reason']) != null) {
              reason = errorCode(i['reason']);
              break;
            }
          }
        }
        named[place] = reason;
      }
    }
    return named;
  }

  /// The name of a google.rpc status code.
  static String? _codeName(Object? code) => switch (code) {
    3 => 'INVALID_ARGUMENT',
    5 => 'NOT_FOUND',
    6 => 'ALREADY_EXISTS',
    7 => 'PERMISSION_DENIED',
    8 => 'RESOURCE_EXHAUSTED',
    9 => 'FAILED_PRECONDITION',
    _ => null,
  };

  /// Google's refusal as the failure the runner acts on, logged by its
  /// status and code alone.
  ///
  /// Three refusals come as 403 and mean different things: the People API
  /// switched off in the app's Google Cloud project, which is a setting to
  /// change there; a token that does not cover contacts, which a sign-in
  /// with Contacts ticked fixes; and a quota, handled before this.
  static Exception _failureFor(http.Response response, String doing) {
    final error = _errorOf(response);
    final status = error.status;
    final reason = errorCode(
      error.reasons.isNotEmpty ? error.reasons.first : error.word,
    );
    debugPrint('[myemail] contacts: Google $doing answered HTTP $status'
        '${reason == null ? '' : ' ($reason)'}');

    if (status == 401) {
      return const AuthenticationFailed(
        'The Google sign-in is no longer accepted. Open Settings, Accounts '
        'and sign in to the Gmail account again.',
      );
    }
    if (status == 403) {
      if (error.reasons.contains('SERVICE_DISABLED') ||
          error.reasons.contains('ACCESSNOTCONFIGURED') ||
          error.message.contains('has not been used') ||
          error.message.contains('is disabled')) {
        return const ContactsSwitchedOff();
      }
      return const SignInNeedsConsent(
        'This Google account has not allowed the app to change its '
        'contacts. Sign in with Google again and tick Contacts; nothing '
        'cached is lost.',
      );
    }
    if (status == 404) return const ContactGone();
    if (status == 429) {
      return const ConnectionFailed(
        'Google is rate limiting the contacts of this account. Contact '
        'sync tries again later.',
      );
    }
    if (status >= 500) {
      return ConnectionFailed(
        'Google is having trouble (HTTP $status). Try again shortly.',
      );
    }
    return ContactRefused.by('Google', status, reason);
  }
}

/// One read of Google's listing, every page of it.
@immutable
class GoogleContactsRead {
  const GoogleContactsRead({
    required this.people,
    required this.deleted,
    required this.rekeyed,
    required this.syncToken,
    required this.complete,
    this.pages = 1,
  });

  /// Every contact the read returned that is there, as Google sent it,
  /// once each (its last entry), and none under a name it no longer has.
  final List<Map<String, Object?>> people;

  /// The names of contacts deleted since the token, apart from names a
  /// contact in this read has had before. Always empty for a full listing.
  final Set<String> deleted;

  /// Old names to the names the contacts have now, from
  /// `metadata.previousResourceNames`.
  final Map<String, String> rekeyed;

  /// The token for the changes after this read: from the last page. Null
  /// for a listing of every field, and where Google sent none.
  final String? syncToken;

  /// True for a full listing: every contact is in [people], so a contact
  /// missing from it is worth asking about ([GoogleContactsApi.getBatch]).
  final bool complete;

  /// How many pages it took.
  final int pages;
}

/// Contacts read again by name.
@immutable
class GoogleBatchRead {
  const GoogleBatchRead({
    required this.found,
    required this.notFound,
    required this.unknown,
  });

  /// The name asked for to the contact as it is, whose `resourceName` is
  /// a new one where Google has re-keyed it.
  final Map<String, Map<String, Object?>> found;

  /// Names Google said NOT_FOUND to: deleted.
  final Set<String> notFound;

  /// Names it said anything else to, or nothing: neither there nor gone.
  final Set<String> unknown;

  /// The names asked for that came back under another name, to that name.
  Map<String, String> get rekeyed => {
    for (final MapEntry(:key, :value) in found.entries)
      if (value['resourceName'] case final String now when now != key)
        key: now,
  };
}

