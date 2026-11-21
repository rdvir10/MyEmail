import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// How an expired sync token is answered: Google has used all three.
enum FakeTokenExpiry {
  /// 410 Gone.
  gone,

  /// 400 with the ErrorInfo reason EXPIRED_SYNC_TOKEN.
  reason,

  /// 400 with no reason, whose message begins "Sync token is expired".
  message,
}

/// An in-memory Google People API for one account's contacts, as an http
/// handler: hand [client] (or `MockClient(fake.handle)`) to
/// GoogleContactsApi.
///
/// It keeps what the real one is known to do and the sync must cope with:
/// listings in pages, with a sync token on the last page that expires a
/// week after the full listing that started it, and that is refused when
/// sent with other parameters; deleted contacts in a listing with a
/// token; contacts that Google re-keys, named in `previousResourceNames`;
/// an etag on every contact, moved by every write and checked by
/// updateContact; and writes through the API that show in the listings
/// only later ([lagWrites], until [publish]), while reads by name show
/// them at once.
///
/// It is stricter than Google where a mistake would otherwise pass
/// silently: a call that answers with a Person and does not send
/// `sources=READ_SOURCE_TYPE_CONTACT`, or sends no field mask, is refused.
///
/// Tests seed and inspect contacts directly, and change them as Ron would
/// in Gmail ([addFromGmail], [editFromGmail], [deleteFromGmail],
/// [rekeyFromGmail], [mergeInGmail]).
class FakeGooglePeople {
  FakeGooglePeople({DateTime? now})
    : now = now ?? DateTime.utc(2026, 11, 20, 9);

  /// The fake's clock: tokens expire by it, and writes are stamped with it.
  DateTime now;

  /// Every request, in the order it came.
  final List<http.Request> requests = [];

  /// A client that sends everything here.
  http.Client get client => MockClient(handle);

  /// Writes made through the API show in listings only after [publish]:
  /// Google's listings lag behind its writes by minutes. Reads by name
  /// ([people.get], getBatchGet) see them at once either way.
  bool lagWrites = true;

  /// The largest page served, whatever was asked for.
  int maxPageSize = 1000;

  /// How long a sync token lasts after the full listing that started its
  /// chain. Using it does not extend that.
  Duration tokenLifetime = const Duration(days: 7);

  /// How an expired token is answered.
  FakeTokenExpiry expiry = FakeTokenExpiry.gone;

  /// Every request answered 403 for want of the contacts permission.
  bool consentMissing = false;

  /// Every request answered 403 because the People API is switched off in
  /// the app's Cloud project.
  bool switchedOff = false;

  /// Tokens answered 401.
  final Set<String> rejectTokens = {};

  /// A contact for which this answers true is refused on create and update
  /// with a 400 whose message quotes it, as Google's do.
  bool Function(Map<String, Object?> person)? refuse;

  /// How many batch creates to come are refused as a whole with a 400 that
  /// names no contact, making none of them.
  int refuseBatchesWhole = 0;

  /// The contacts as they are, by resource name, deleted ones kept marked.
  final Map<String, _Person> _current = {};

  /// The contacts as the listings show them.
  final Map<String, _Person> _listed = {};

  /// Names written through the API and not yet in the listings.
  final Set<String> _unpublished = {};

  /// Every name change, by sequence number: what a token lists after it.
  final List<({int seq, String name})> _log = [];

  /// Old names to the names their contacts have now.
  final Map<String, String> _renamed = {};

  /// Sync tokens issued, with the sequence they list after, when the full
  /// listing that started their chain was, and the parameters they were
  /// issued under.
  final Map<String, ({int seq, DateTime fullAt, String params})> _tokens = {};

  /// Page snapshots, for the pages after the first of a listing.
  final Map<String, _Listing> _listings = {};

  final List<_Throttle> _throttles = [];

  int _seq = 0;
  int _ids = 0;
  int _etags = 0;
  int _snapshots = 0;

  /// The people asked for so far in full listings (first pages only):
  /// those draw on a quota of their own.
  int fullListings = 0;

  // --- helpers for tests -----------------------------------------------------

  /// Add a contact with [fields] (Person fields: names, emailAddresses...),
  /// as though made in Gmail, and answer with its resource name. It shows
  /// in the next listing.
  String addFromGmail(Map<String, Object?> fields, {bool lag = false}) {
    final p = _Person(_newName(), _stored(fields), ++_etags, now);
    _current[p.name] = p;
    _changed(p.name, lag: lag);
    return p.name;
  }

  /// The same as [addFromGmail]: a contact that is there before the test
  /// starts.
  String seed(Map<String, Object?> fields) => addFromGmail(fields);

  /// Replace each field group named in [fields] on [name], as an edit in
  /// Gmail does; a null value removes the group.
  void editFromGmail(
    String name,
    Map<String, Object?> fields, {
    bool lag = false,
  }) {
    final p = _live(name);
    for (final MapEntry(:key, :value) in fields.entries) {
      if (!_personFields.contains(key) || key == 'metadata') {
        throw ArgumentError.value(key, 'fields', 'not a Person field');
      }
      if (value == null) {
        p.fields.remove(key);
      } else {
        p.fields[key] = _stored({key: value})[key];
      }
    }
    _bump(p);
    _changed(p.name, lag: lag);
  }

  /// Delete [name] in Gmail.
  void deleteFromGmail(String name, {bool lag = false}) {
    final p = _live(name);
    p.deleted = true;
    _bump(p);
    _changed(p.name, lag: lag);
  }

  /// Give [name] a new resource name, as Google does when a contact is
  /// linked to or unlinked from a profile, and answer with it. A listing
  /// with a token shows the old name deleted and the contact under the new
  /// one, with the old in its `previousResourceNames`.
  String rekeyFromGmail(String name) {
    final old = _live(name);
    final p = _Person(_newName(), Map.of(old.fields), ++_etags, now)
      ..previous = [...old.previous, old.name];
    old.deleted = true;
    _current[p.name] = p;
    _renamed[old.name] = p.name;
    for (final e in _renamed.entries.toList()) {
      if (e.value == old.name) _renamed[e.key] = p.name;
    }
    _changed(old.name);
    _changed(p.name);
    return p.name;
  }

  /// Merge [other] into [keep], as Gmail's Merge & fix does: [keep] takes
  /// [other]'s lists beside its own and its name in
  /// `previousResourceNames`, and [other] is gone.
  void mergeInGmail(String keep, String other) {
    final k = _live(keep);
    final o = _live(other);
    for (final MapEntry(:key, :value) in o.fields.entries) {
      final mine = k.fields[key];
      if (mine is List && value is List) {
        k.fields[key] = [...mine, ...value];
      } else {
        k.fields.putIfAbsent(key, () => value);
      }
    }
    k.previous = [...k.previous, o.name, ...o.previous];
    o.deleted = true;
    _renamed[o.name] = k.name;
    _bump(k);
    _changed(o.name);
    _changed(k.name);
  }

  /// Show every write made through the API in the listings, as Google does
  /// some minutes after it.
  void publish() {
    for (final name in _unpublished.toList()) {
      _publishOne(name);
    }
    _unpublished.clear();
  }

  /// Make every sync token issued so far expire.
  void expireSyncTokens() {
    for (final t in _tokens.keys.toList()) {
      final was = _tokens[t]!;
      _tokens[t] = (
        seq: was.seq,
        fullAt: DateTime.utc(2000),
        params: was.params,
      );
    }
  }

  /// Answer the next [count] requests 429, with [retryAfter] seconds where
  /// given, and naming a daily quota with [daily]. With [asForbidden], in
  /// Google's older way: a 403 whose reason is rateLimitExceeded.
  void throttle(
    int count, {
    int? retryAfter,
    bool daily = false,
    bool asForbidden = false,
  }) {
    for (var i = 0; i < count; i++) {
      _throttles.add(_Throttle(retryAfter, daily, asForbidden));
    }
  }

  /// Answer the next [count] requests with [status], a server in trouble.
  void fail(int count, {int status = 503}) {
    for (var i = 0; i < count; i++) {
      _failures.add(status);
    }
  }

  final List<int> _failures = [];

  /// The contact [name] as it is now, every field, as Google would answer;
  /// null once deleted. Under its new name where it was re-keyed.
  Map<String, Object?>? person(String name) {
    final p = _current[_renamed[name] ?? name];
    if (p == null || p.deleted) return null;
    return _json(p, null);
  }

  /// Every contact there now.
  List<Map<String, Object?>> get people => [
    for (final p in _current.values)
      if (!p.deleted) _json(p, null),
  ];

  int get count => _current.values.where((p) => !p.deleted).length;

  /// The name of the contact with [email] among its addresses, if one has.
  String? nameWithEmail(String email) {
    for (final p in _current.values) {
      if (p.deleted) continue;
      final emails = p.fields['emailAddresses'];
      for (final e in emails is List ? emails : const []) {
        if (e is Map &&
            '${e['value']}'.toLowerCase() == email.toLowerCase()) {
          return p.name;
        }
      }
    }
    return null;
  }

  /// The hidden tag the contact [name] carries.
  String? tagOf(String name) {
    final p = _current[_renamed[name] ?? name];
    final data = p?.fields['clientData'];
    for (final e in data is List ? data : const []) {
      if (e is Map && e['key'] == 'myemail.link') return e['value'] as String?;
    }
    return null;
  }

  /// Requests whose path ends with [suffix] (`:updateContact`,
  /// `/connections`).
  List<http.Request> requestsTo(String suffix) => [
    for (final r in requests)
      if (r.url.path.endsWith(suffix)) r,
  ];

  // --- the server ------------------------------------------------------------

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final auth = request.headers['Authorization'] ?? '';
    if (!auth.startsWith('Bearer ') ||
        rejectTokens.contains(auth.substring(7))) {
      return _error(401, 'UNAUTHENTICATED', 'Request had invalid credentials.');
    }
    if (switchedOff) {
      return _error(
        403,
        'PERMISSION_DENIED',
        'People API has not been used in project 1 before or it is '
            'disabled.',
        reason: 'SERVICE_DISABLED',
      );
    }
    if (consentMissing) {
      return _error(
        403,
        'PERMISSION_DENIED',
        'Request had insufficient authentication scopes.',
        reason: 'ACCESS_TOKEN_SCOPE_INSUFFICIENT',
      );
    }
    if (_throttles.isNotEmpty) {
      final t = _throttles.removeAt(0);
      return _throttled(t);
    }
    if (_failures.isNotEmpty) {
      final status = _failures.removeAt(0);
      return _error(status, 'UNAVAILABLE', 'The service is unavailable.');
    }

    final path = request.url.path;
    final q = request.url.queryParametersAll;
    try {
      if (request.method == 'GET' && path == '/v1/people/me/connections') {
        return _connections(q);
      }
      if (request.method == 'GET' && path == '/v1/people:batchGet') {
        return _batchGet(q);
      }
      if (request.method == 'POST' && path == '/v1/people:createContact') {
        return _create(q, request.body);
      }
      if (request.method == 'POST' &&
          path == '/v1/people:batchCreateContacts') {
        return _batchCreate(request.body);
      }
      final m = RegExp(r'^/v1/(people/[^/:]+)(?::(\w+))?$').firstMatch(path);
      if (m != null) {
        final name = Uri.decodeComponent(m[1]!);
        return switch ((request.method, m[2])) {
          ('GET', null) => _get(name, q),
          ('PATCH', 'updateContact') => _update(name, q, request.body),
          ('DELETE', 'deleteContact') => _delete(name),
          _ => _error(404, 'NOT_FOUND', 'No such method.'),
        };
      }
    } on _Refusal catch (r) {
      return r.response;
    }
    return _error(404, 'NOT_FOUND', 'No such endpoint.');
  }

  http.Response _connections(Map<String, List<String>> q) {
    final fields = _mask(q['personFields']);
    _contactSourceOnly(q);
    final size = (int.tryParse(_one(q['pageSize']) ?? '') ?? 100).clamp(
      1,
      maxPageSize,
    );
    final wantToken = _one(q['requestSyncToken']) == 'true';
    final syncToken = _one(q['syncToken']);
    final pageToken = _one(q['pageToken']);
    // What must match from page to page, and from a token to its use.
    final params = jsonEncode({
      'personFields': _one(q['personFields']),
      'sources': q['sources'],
      'pageSize': _one(q['pageSize']),
      'requestSyncToken': wantToken,
    });
    final pageKey = '$params|${syncToken ?? ''}';

    final _Listing listing;
    if (pageToken != null) {
      final kept = _listings[pageToken];
      if (kept == null || kept.params != pageKey) {
        throw _Refusal(_error(400, 'INVALID_ARGUMENT', 'Bad page token.'));
      }
      listing = kept;
    } else if (syncToken != null) {
      final token = _tokens[syncToken];
      if (token == null) {
        throw _Refusal(_error(400, 'INVALID_ARGUMENT', 'Bad sync token.'));
      }
      if (now.difference(token.fullAt) > tokenLifetime) {
        throw _Refusal(_expired());
      }
      if (token.params != params) {
        throw _Refusal(
          _error(
            400,
            'INVALID_ARGUMENT',
            'Parameters differ from the request that made the sync token.',
          ),
        );
      }
      final names = <String>{};
      for (final e in _log) {
        if (e.seq > token.seq) {
          names.remove(e.name);
          names.add(e.name);
        }
      }
      listing = _Listing(
        [
          for (final n in names)
            if (_listed[n] case final p?) p.copy(),
        ],
        seq: _seq,
        fullAt: token.fullAt,
        params: pageKey,
      );
    } else {
      fullListings++;
      final names = _listed.keys.toList()..sort();
      listing = _Listing(
        [
          for (final n in names)
            if (!_listed[n]!.deleted) _listed[n]!.copy(),
        ],
        seq: _seq,
        fullAt: now,
        params: pageKey,
      );
    }

    final start = pageToken == null ? 0 : listing.offset;
    final end = (start + size).clamp(0, listing.people.length);
    final last = end >= listing.people.length;
    final body = <String, Object?>{
      'connections': [
        for (final p in listing.people.sublist(start, end))
          _json(p, fields, withDeleted: true),
      ],
      'totalItems': listing.people.length,
    };
    if (!last) {
      final token = 'page-${++_snapshots}';
      _listings[token] = listing.from(end);
      body['nextPageToken'] = token;
    } else if (wantToken) {
      final token = 'sync-${++_snapshots}';
      _tokens[token] = (
        seq: listing.seq,
        fullAt: listing.fullAt,
        params: params,
      );
      body['nextSyncToken'] = token;
    }
    return _ok(body);
  }

  http.Response _get(String name, Map<String, List<String>> q) {
    final fields = _mask(q['personFields']);
    _contactSourceOnly(q);
    final p = _current[_renamed[name] ?? name];
    if (p == null || p.deleted) {
      return _error(404, 'NOT_FOUND', 'Requested entity was not found.');
    }
    return _ok(_json(p, fields));
  }

  http.Response _batchGet(Map<String, List<String>> q) {
    final fields = _mask(q['personFields']);
    _contactSourceOnly(q);
    final names = q['resourceNames'] ?? const [];
    if (names.isEmpty || names.length > 200) {
      return _error(400, 'INVALID_ARGUMENT', 'Between 1 and 200 names.');
    }
    return _ok({
      'responses': [
        for (final name in names)
          if (_current[_renamed[name] ?? name] case final p?
              when !p.deleted)
            {
              'httpStatusCode': 200,
              'person': _json(p, fields),
              'requestedResourceName': name,
              'status': <String, Object?>{},
            }
          else
            {
              'httpStatusCode': 404,
              'requestedResourceName': name,
              'status': {
                'code': 5,
                'message': 'Requested entity was not found.',
              },
            },
      ],
    });
  }

  http.Response _create(Map<String, List<String>> q, String body) {
    final fields = _mask(q['personFields']);
    _contactSourceOnly(q);
    final person = _decode(body);
    _refused(person);
    final p = _made(person);
    return _ok(_json(p, fields));
  }

  http.Response _batchCreate(String body) {
    final json = _decode(body);
    final fields = _mask([if (json['readMask'] case final String m) m]);
    final sources = json['sources'];
    if (sources is! List || !sources.contains('READ_SOURCE_TYPE_CONTACT')) {
      throw _Refusal(_noSources());
    }
    final contacts = json['contacts'];
    if (contacts is! List || contacts.isEmpty || contacts.length > 200) {
      return _error(400, 'INVALID_ARGUMENT', 'Between 1 and 200 contacts.');
    }
    final people = [
      for (final c in contacts)
        (c is Map && c['contactPerson'] is Map)
            ? (c['contactPerson'] as Map).cast<String, Object?>()
            : <String, Object?>{},
    ];
    if (refuseBatchesWhole > 0) {
      refuseBatchesWhole--;
      return _error(
        400,
        'INVALID_ARGUMENT',
        'Request contains an invalid argument: ${_quote(people.first)}',
      );
    }
    // Google makes none of a batch it refuses, and names the ones why.
    final errors = <String, Object?>{};
    for (var i = 0; i < people.length; i++) {
      final problem = _problem(people[i]);
      if (problem != null) {
        errors['$i'] = {'code': 3, 'message': problem};
      }
    }
    if (errors.isNotEmpty) {
      return _envelope(400, {
        'code': 400,
        'message': 'Invalid contacts: ${errors.values.first}',
        'status': 'INVALID_ARGUMENT',
        'details': [
          {
            '@type': 'type.googleapis.com/'
                'google.people.v1.BatchCreateContactsErrorDetails',
            'contactErrors': errors,
          },
        ],
      });
    }
    final made = [for (final p in people) _made(p)];
    // The answer's order is not documented: here it is backwards.
    return _ok({
      'createdPeople': [
        for (final p in made.reversed)
          {
            'httpStatusCode': 200,
            'person': _json(p, fields),
            'status': <String, Object?>{},
          },
      ],
    });
  }

  http.Response _update(
    String name,
    Map<String, List<String>> q,
    String body,
  ) {
    final fields = _mask(q['personFields']);
    _contactSourceOnly(q);
    final updating = (_one(q['updatePersonFields']) ?? '')
        .split(',')
        .where((f) => f.isNotEmpty)
        .toList();
    if (updating.isEmpty) {
      return _error(400, 'INVALID_ARGUMENT', 'updatePersonFields is empty.');
    }
    if (!_writableFields.containsAll(updating)) {
      return _error(
        400,
        'INVALID_ARGUMENT',
        'Invalid updatePersonFields mask path.',
      );
    }
    final p = _current[name];
    if (p == null || p.deleted) {
      return _error(404, 'NOT_FOUND', 'Requested entity was not found.');
    }
    final person = _decode(body);
    final etag = person['etag'];
    final metadata = person['metadata'];
    String? sourceEtag;
    final sources = metadata is Map ? metadata['sources'] : null;
    for (final s in sources is List ? sources : const []) {
      if (s is Map && s['type'] == 'CONTACT' && s['etag'] is String) {
        sourceEtag = s['etag'] as String;
      }
    }
    // Google checks the contact source's etag, and wants it there.
    if (sourceEtag == null) {
      return _error(
        400,
        'INVALID_ARGUMENT',
        'Request person.metadata.sources must be set with the contact '
            'source.',
      );
    }
    if (sourceEtag != p.sourceEtag || (etag != null && etag != p.etag)) {
      return _error(
        400,
        'FAILED_PRECONDITION',
        'Request person.etag is different than the current person.etag. '
            'Clear local cache and get the latest person.',
        reason: 'failedPrecondition',
      );
    }
    if (updating.contains('memberships')) {
      final groups = person['memberships'];
      final inOne = groups is List &&
          groups.any((m) => m is Map && m['contactGroupMembership'] is Map);
      if (!inOne) {
        return _error(
          400,
          'INVALID_ARGUMENT',
          'Person must have at least one contact group membership.',
        );
      }
    }
    _refused(person);
    final given = _stored(person);
    for (final f in updating) {
      if (given.containsKey(f)) {
        p.fields[f] = given[f];
      } else {
        p.fields.remove(f);
      }
    }
    _bump(p);
    _written(p.name);
    return _ok(_json(p, fields));
  }

  http.Response _delete(String name) {
    final p = _current[name];
    if (p == null || p.deleted) {
      return _error(404, 'NOT_FOUND', 'Requested entity was not found.');
    }
    p.deleted = true;
    _bump(p);
    _written(p.name);
    return _ok(<String, Object?>{});
  }

  // --- plumbing --------------------------------------------------------------

  String _newName() => 'people/c${1000 + ++_ids}';

  _Person _live(String name) {
    final p = _current[_renamed[name] ?? name];
    if (p == null || p.deleted) throw StateError('No contact $name');
    return p;
  }

  _Person _made(Map<String, Object?> person) {
    final fields = _stored(person);
    fields.putIfAbsent(
      'memberships',
      () => [
        {
          'contactGroupMembership': {
            'contactGroupId': 'myContacts',
            'contactGroupResourceName': 'contactGroups/myContacts',
          },
        },
      ],
    );
    final p = _Person(_newName(), fields, ++_etags, now);
    _current[p.name] = p;
    _written(p.name);
    return p;
  }

  void _bump(_Person p) {
    p.etagNumber = ++_etags;
    p.updated = now;
  }

  /// A change made in Gmail: in the listings at once unless [lag].
  void _changed(String name, {bool lag = false}) {
    if (lag) {
      _unpublished.add(name);
    } else {
      _unpublished.remove(name);
      _publishOne(name);
    }
  }

  /// A write through the API: in the listings after [publish].
  void _written(String name) => _changed(name, lag: lagWrites);

  void _publishOne(String name) {
    final p = _current[name];
    if (p == null) return;
    _listed[name] = p.copy();
    _log.add((seq: ++_seq, name: name));
  }

  void _refused(Map<String, Object?> person) {
    final problem = _problem(person);
    if (problem != null) {
      throw _Refusal(_error(400, 'INVALID_ARGUMENT', problem));
    }
  }

  /// Why Google would not take [person], in its words, or null: a test's
  /// [refuse], or more than one value on a field that holds one.
  String? _problem(Map<String, Object?> person) {
    if (refuse?.call(person) ?? false) {
      return 'Invalid value in person: ${_quote(person)}';
    }
    for (final f in _singletons) {
      final value = person[f];
      if (value is List && value.length > 1) {
        return 'Only one value is allowed for $f: ${_quote(person)}';
      }
    }
    return null;
  }

  /// Fields a contact holds one of.
  static const _singletons = {'names', 'birthdays', 'biographies', 'genders'};

  /// What `updatePersonFields` may name.
  static const _writableFields = {
    'addresses', 'biographies', 'birthdays', 'calendarUrls', 'clientData',
    'emailAddresses', 'events', 'externalIds', 'genders', 'imClients',
    'interests', 'locales', 'locations', 'memberships', 'miscKeywords',
    'names', 'nicknames', 'occupations', 'organizations', 'phoneNumbers',
    'relations', 'sipAddresses', 'urls', 'userDefined',
  };

  /// What a refusal quotes, as Google's do: the contact's own details.
  static String _quote(Map<String, Object?> person) => jsonEncode({
    'names': person['names'],
    'emailAddresses': person['emailAddresses'],
    'phoneNumbers': person['phoneNumbers'],
  });

  static const _personFields = {
    'addresses', 'ageRanges', 'biographies', 'birthdays', 'calendarUrls',
    'clientData', 'coverPhotos', 'emailAddresses', 'events', 'externalIds',
    'genders', 'imClients', 'interests', 'locales', 'locations',
    'memberships', 'metadata', 'miscKeywords', 'names', 'nicknames',
    'occupations', 'organizations', 'phoneNumbers', 'photos', 'relations',
    'sipAddresses', 'skills', 'urls', 'userDefined',
  };

  /// [person]'s fields as kept: its contact groups and nothing Google makes
  /// itself (names, etags, metadata), each entry without the metadata
  /// Google puts on it.
  static Map<String, Object?> _stored(Map<String, Object?> person) {
    final kept = <String, Object?>{};
    for (final MapEntry(:key, :value) in person.entries) {
      if (key == 'metadata' || !_personFields.contains(key)) continue;
      kept[key] = jsonDecode(jsonEncode(value));
      if (kept[key] case final List list) {
        for (final e in list) {
          if (e is Map) e.remove('metadata');
        }
      }
    }
    return kept;
  }

  /// The mask asked for, which must be there.
  Set<String> _mask(List<String>? values) {
    final mask = _one(values);
    if (mask == null || mask.isEmpty) {
      throw _Refusal(
        _error(400, 'INVALID_ARGUMENT', 'personFields mask is required.'),
      );
    }
    final fields = mask.split(',').map((f) => f.trim()).toSet();
    final unknown = fields.difference(_personFields);
    if (unknown.isNotEmpty) {
      throw _Refusal(
        _error(400, 'INVALID_ARGUMENT', 'Invalid personFields mask path.'),
      );
    }
    return fields;
  }

  /// Stricter than Google, which would answer with the profile merged in:
  /// a call that answers with a Person sends the contact source alone.
  void _contactSourceOnly(Map<String, List<String>> q) {
    final sources = q['sources'];
    if (sources == null ||
        sources.length != 1 ||
        sources.single != 'READ_SOURCE_TYPE_CONTACT') {
      throw _Refusal(_noSources());
    }
  }

  http.Response _noSources() => _error(
    400,
    'INVALID_ARGUMENT',
    'The fake wants sources=READ_SOURCE_TYPE_CONTACT on this call.',
    reason: 'FAKE_SOURCES_MISSING',
  );

  static String? _one(List<String>? values) =>
      values == null || values.isEmpty ? null : values.first;

  /// [p] as Google answers with it, its fields cut to [mask] (all with
  /// none), each entry with the metadata that says it is the contact's.
  Map<String, Object?> _json(
    _Person p,
    Set<String>? mask, {
    bool withDeleted = false,
  }) {
    final id = p.name.substring('people/'.length);
    final source = {'type': 'CONTACT', 'id': id};
    final metadata = <String, Object?>{
      'sources': [
        {
          ...source,
          'etag': p.sourceEtag,
          'updateTime': p.updated.toUtc().toIso8601String(),
        },
      ],
      if (p.previous.isNotEmpty) 'previousResourceNames': p.previous,
      if (p.deleted) 'deleted': true,
      'objectType': 'PERSON',
    };
    if (p.deleted && withDeleted) {
      return {'resourceName': p.name, 'etag': p.etag, 'metadata': metadata};
    }
    final json = <String, Object?>{'resourceName': p.name, 'etag': p.etag};
    for (final MapEntry(:key, :value) in p.fields.entries) {
      if (mask != null && !mask.contains(key)) continue;
      final copy = jsonDecode(jsonEncode(value));
      if (copy is List) {
        for (var i = 0; i < copy.length; i++) {
          final e = copy[i];
          if (e is! Map) continue;
          e['metadata'] = {'primary': i == 0, 'source': source};
          if (e['type'] is String && e['formattedType'] == null) {
            final type = e['type'] as String;
            e['formattedType'] = type.isEmpty
                ? type
                : '${type[0].toUpperCase()}${type.substring(1)}';
          }
          if (key == 'names') {
            final parts = [
              e['givenName'],
              e['middleName'],
              e['familyName'],
            ].whereType<String>().where((s) => s.isNotEmpty);
            final shown = parts.isNotEmpty
                ? parts.join(' ')
                : '${e['unstructuredName'] ?? ''}';
            e['displayName'] = shown;
            e['unstructuredName'] ??= shown;
          }
        }
      }
      json[key] = copy;
    }
    if (mask == null || mask.contains('metadata')) json['metadata'] = metadata;
    return json;
  }

  http.Response _expired() => switch (expiry) {
    FakeTokenExpiry.gone => _error(
      410,
      'GONE',
      'Sync token is expired. Clear local cache and retry call without '
          'the sync token.',
    ),
    FakeTokenExpiry.reason => _error(
      400,
      'FAILED_PRECONDITION',
      'Sync token is no good.',
      reason: 'EXPIRED_SYNC_TOKEN',
    ),
    FakeTokenExpiry.message => _error(
      400,
      'FAILED_PRECONDITION',
      'Sync token is expired. Clear local cache and retry call without '
          'the sync token.',
    ),
  };

  http.Response _throttled(_Throttle t) {
    if (t.asForbidden) {
      return _envelope(403, {
        'code': 403,
        'message': 'Rate Limit Exceeded',
        'errors': [
          {
            'message': 'Rate Limit Exceeded',
            'domain': 'usageLimits',
            'reason': 'rateLimitExceeded',
          },
        ],
        'status': 'PERMISSION_DENIED',
      });
    }
    final limit = t.daily
        ? 'Daily Contact Writes per day per user'
        : 'Critical read requests (Contact and Profile Reads) per minute '
              'per user';
    final response = _envelope(429, {
      'code': 429,
      'message': "Quota exceeded for quota metric and limit '$limit'.",
      'status': 'RESOURCE_EXHAUSTED',
      'details': [
        {
          '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
          'reason': 'RATE_LIMIT_EXCEEDED',
          'domain': 'googleapis.com',
          'metadata': {
            'quota_limit': t.daily
                ? 'DailyContactWritesPerDayPerUser'
                : 'CriticalReadRequestsPerMinutePerUser',
            'service': 'people.googleapis.com',
          },
        },
      ],
    });
    if (t.retryAfter == null) return response;
    return http.Response(
      response.body,
      429,
      headers: {...response.headers, 'retry-after': '${t.retryAfter}'},
    );
  }

  static Map<String, Object?> _decode(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map) return json.cast<String, Object?>();
    } on FormatException {
      // Answered below.
    }
    throw _Refusal(_error(400, 'INVALID_ARGUMENT', 'Invalid JSON payload.'));
  }

  static http.Response _ok(Map<String, Object?> body) => http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  static http.Response _error(
    int status,
    String word,
    String message, {
    String? reason,
  }) => _envelope(status, {
    'code': status,
    'message': message,
    'status': word,
    if (reason != null)
      'details': [
        {
          '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
          'reason': reason,
          'domain': 'googleapis.com',
        },
      ],
  });

  static http.Response _envelope(int status, Map<String, Object?> error) =>
      http.Response(
        jsonEncode({'error': error}),
        status,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
}

class _Person {
  _Person(this.name, this.fields, this.etagNumber, this.updated);

  final String name;
  Map<String, Object?> fields;
  int etagNumber;
  DateTime updated;
  List<String> previous = const [];
  bool deleted = false;

  String get etag => '%EgUBAi43PRoEAQIFByIM$etagNumber';
  String get sourceEtag => '#S$etagNumber';

  _Person copy() {
    final fields = jsonDecode(jsonEncode(this.fields)) as Map<String, Object?>;
    return _Person(name, fields, etagNumber, updated)
      ..previous = [...previous]
      ..deleted = deleted;
  }
}

class _Listing {
  _Listing(
    this.people, {
    required this.seq,
    required this.fullAt,
    required this.params,
    this.offset = 0,
  });

  final List<_Person> people;
  final int seq;
  final DateTime fullAt;
  final String params;
  final int offset;

  _Listing from(int offset) => _Listing(
    people,
    seq: seq,
    fullAt: fullAt,
    params: params,
    offset: offset,
  );
}

class _Throttle {
  _Throttle(this.retryAfter, this.daily, this.asForbidden);
  final int? retryAfter;
  final bool daily;
  final bool asForbidden;
}

class _Refusal implements Exception {
  _Refusal(this.response);
  final http.Response response;
}
