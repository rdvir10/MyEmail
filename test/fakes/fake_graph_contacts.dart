import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory Microsoft Graph for one mailbox's contacts, as an http
/// handler: hand [client] (or `MockClient(fake.handle)`) to
/// GraphContactsApi.
///
/// It keeps what the real one is known to do and the sync must cope with:
/// a main Contacts folder Graph gives no name to, beside subfolders and the
/// mailbox's Deleted Items, where a contact deleted in Outlook goes; a
/// delta of a folder in pages, whose `$select` is built into its links and
/// which expires ([expireDeltaLinks]); a contact's `changeKey` moved by
/// every write; `displayName` made again from the name parts by a PATCH
/// that does not send it; single-value extended properties on contacts and
/// on the folder; `$batch` of up to twenty, answered in any order; and
/// throttling, outside a batch and inside one.
///
/// It is stricter than Graph where a mistake would otherwise pass
/// silently: a request without `Prefer: IdType="ImmutableId"`, outside a
/// batch or inside one, is refused, because Graph would answer it with ids
/// that change when Outlook moves the contact; a delta link sent with the
/// `$select` again is refused; and so is a `$batch` request with a body
/// and no Content-Type of its own.
///
/// Tests seed and inspect contacts directly, and change them as Ron would
/// in Outlook ([addFromOutlook], [editFromOutlook], [deleteFromOutlook],
/// [moveFromOutlook]).
class FakeGraphContacts {
  FakeGraphContacts({DateTime? now})
    : now = now ?? DateTime.utc(2026, 11, 20, 9);

  /// The fake's clock: writes are stamped with it.
  DateTime now;

  /// The main Contacts folder, the one `/me/contacts` lists.
  static const mainFolderId = 'AAMkADcontactsMainFolder';

  /// The mailbox's Deleted Items, a mail folder.
  static const deletedItemsId = 'AAMkADdeletedItemsFolder';

  static const _base = 'https://graph.microsoft.com/v1.0';

  /// Every request, in the order it came, and every request inside each
  /// `$batch` as its own.
  final List<http.Request> requests = [];

  /// A client that sends everything here.
  http.Client get client => MockClient(handle);

  /// The largest page served, whatever was asked for.
  int maxPageSize = 200;

  /// In a delta after its first round, a changed contact comes with only
  /// the properties that changed (Graph promises at least those).
  bool sparseDelta = false;

  /// Every request answered 403, as Graph does for a token without
  /// Contacts.ReadWrite.
  bool consentMissing = false;

  /// Tokens answered 401.
  final Set<String> rejectTokens = {};

  /// A contact for which this answers true is refused on create and update
  /// with a 400 whose message quotes it, as Graph's do.
  bool Function(Map<String, Object?> contact)? refuse;

  /// The folder will not take the device claim.
  bool claimRefused = false;

  final Map<String, _Contact> _contacts = {};
  final Set<String> _folders = {mainFolderId};
  final Map<String, Map<String, String>> _folderProperties = {};

  /// Every change, by sequence number: where the contact was before it,
  /// where after (null when gone), and which properties changed (all, for
  /// null).
  final List<_Change> _log = [];

  /// Delta states: the folder, the sequence a round lists after, and the
  /// select it was made with.
  final Map<String, ({String folder, int seq, Set<String>? select})> _deltas =
      {};

  /// Delta and listing pages after the first.
  final Map<String, _Pages> _pages = {};

  final List<({int status, int retryAfter})> _throttles = [];
  final List<({int status, int retryAfter})> _batchThrottles = [];
  ({int status, String code})? _expiry;
  int _expiredBefore = 0;

  int _seq = 0;
  int _ids = 0;
  int _keys = 0;
  int _tokens = 0;

  // --- helpers for tests -----------------------------------------------------

  /// Add a contact with [fields] (Graph contact properties) to [folderId],
  /// the main Contacts folder unless given, carrying [tag] where given, as
  /// though made in Outlook, and answer with its immutable id.
  String addFromOutlook(
    Map<String, Object?> fields, {
    String? folderId,
    String? tag,
  }) {
    final c = _Contact(_newId(), folderId ?? mainFolderId, _newKey(), now)
      ..fields.addAll(_writable(fields));
    c.fields['displayName'] ??= _composed(c.fields);
    if (tag != null) c.properties[_tagProperty] = tag;
    _contacts[c.id] = c;
    _record(c.id, null, c.folder, null);
    return c.id;
  }

  /// The same as [addFromOutlook]: a contact that is there before the test
  /// starts.
  String seed(Map<String, Object?> fields, {String? folderId, String? tag}) =>
      addFromOutlook(fields, folderId: folderId, tag: tag);

  /// Change the properties in [changes] on [id], as an edit in Outlook
  /// does; a null value clears one. The display name is made again from
  /// the name parts unless it is among the changes.
  void editFromOutlook(String id, Map<String, Object?> changes) {
    final c = _there(id);
    _apply(c, changes);
  }

  /// Delete [id] in Outlook: it goes to Deleted Items, where a GET by its
  /// id still finds it.
  void deleteFromOutlook(String id) =>
      moveFromOutlook(id, deletedItemsId);

  /// Move [id] to [folderId], keeping its id.
  void moveFromOutlook(String id, String folderId) {
    final c = _there(id);
    final from = c.folder;
    c
      ..folder = folderId
      ..changeKey = _newKey()
      ..modified = now;
    _record(id, from, folderId, null);
  }

  /// Delete [id] for good, as emptying Deleted Items does.
  void purgeFromOutlook(String id) {
    final c = _there(id);
    _contacts.remove(id);
    _record(id, c.folder, null, null);
  }

  /// A new contact folder beside the main one, and its id.
  String addFolder() {
    final id = 'AAMkADfolder${_folders.length}';
    _folders.add(id);
    return id;
  }

  /// Make every delta link issued so far expire: answered [status] with
  /// [code].
  void expireDeltaLinks({
    int status = 410,
    String code = 'SyncStateNotFound',
  }) {
    _expiry = (status: status, code: code);
    _expiredBefore = _tokens;
  }

  /// Answer the next [count] requests (outside a batch) with [status] and
  /// a Retry-After of [retryAfter] seconds.
  void throttle(int count, {int status = 429, int retryAfter = 1}) {
    for (var i = 0; i < count; i++) {
      _throttles.add((status: status, retryAfter: retryAfter));
    }
  }

  /// Answer the next [count] requests inside batches with [status] and a
  /// Retry-After of [retryAfter] seconds in their own headers.
  void throttleInBatch(int count, {int status = 429, int retryAfter = 1}) {
    for (var i = 0; i < count; i++) {
      _batchThrottles.add((status: status, retryAfter: retryAfter));
    }
  }

  /// The contact [id] as it is now, every property, its folder and its
  /// extended properties included; null once deleted for good.
  Map<String, Object?>? contact(String id) {
    final c = _contacts[id];
    if (c == null) return null;
    return {
      ..._json(c, null),
      'singleValueExtendedProperties': [
        for (final MapEntry(:key, :value) in c.properties.entries)
          {'id': key, 'value': value},
      ],
    };
  }

  /// Every contact in [folderId], the main folder unless given.
  List<Map<String, Object?>> contactsIn([String folderId = mainFolderId]) => [
    for (final c in _contacts.values)
      if (c.folder == folderId) contact(c.id)!,
  ];

  /// How many contacts the main folder holds.
  int get count =>
      _contacts.values.where((c) => c.folder == mainFolderId).length;

  /// The id of the contact in the main folder with [email] among its
  /// addresses, if one has.
  String? idWithEmail(String email) {
    for (final c in _contacts.values) {
      if (c.folder == mainFolderId && _hasEmail(c, email)) return c.id;
    }
    return null;
  }

  /// The hidden tag [id] carries.
  String? tagOf(String id) => _contacts[id]?.properties[_tagProperty];

  /// The device claim on the main folder, as it is kept.
  String? get claim => _folderProperties[mainFolderId]?[_claimProperty];

  /// Requests (batch parts among them) to paths ending with [suffix].
  List<http.Request> requestsTo(String suffix) => [
    for (final r in requests)
      if (r.url.path.endsWith(suffix)) r,
  ];

  // --- the server ------------------------------------------------------------

  static const _guid = '958f81ac-dee9-4f9e-a713-9043484f5b0f';
  static const _tagProperty = 'String {$_guid} Name MyEmailLink';
  static const _claimProperty = 'String {$_guid} Name MyEmailSyncDevice';

  Future<http.Response> handle(http.Request request) async =>
      _handle(request, inBatch: false);

  http.Response _handle(http.Request request, {required bool inBatch}) {
    requests.add(request);
    final auth = request.headers['Authorization'] ?? '';
    if (!auth.startsWith('Bearer ') ||
        rejectTokens.contains(auth.substring(7))) {
      return _error(401, 'InvalidAuthenticationToken', 'Access token empty.');
    }
    final prefer = _header(request, 'Prefer') ?? '';
    if (!prefer.contains('IdType="ImmutableId"')) {
      return _error(
        400,
        'FakeImmutableIdMissing',
        'The fake wants Prefer: IdType="ImmutableId" on every request.',
      );
    }
    if (consentMissing) {
      return _error(403, 'ErrorAccessDenied', 'Access is denied.');
    }
    final throttles = inBatch ? _batchThrottles : _throttles;
    if (throttles.isNotEmpty) {
      final t = throttles.removeAt(0);
      return _error(
        t.status,
        switch (t.status) {
          429 => 'TooManyRequests',
          503 => 'ServiceUnavailable',
          _ => 'InternalServerError',
        },
        'Too many requests.',
        headers: {'retry-after': '${t.retryAfter}'},
      );
    }

    final s = request.url.pathSegments;
    final q = request.url.queryParameters;
    final asked = RegExp(r'odata\.maxpagesize=(\d+)').firstMatch(prefer);
    final page = (int.tryParse(asked?[1] ?? '') ?? maxPageSize).clamp(
      1,
      maxPageSize,
    );
    try {
      if (s.length < 2 || s[0] != 'v1.0') return _notFound();
      final m = request.method;
      if (m == 'POST' && s.length == 2 && s[1] == r'$batch') {
        if (inBatch) return _error(400, 'BadRequest', 'Nested batch.');
        return _batch(request);
      }
      if (s[1] != 'me') return _notFound();
      final rest = s.sublist(2);
      switch (rest) {
        case ['contacts'] when m == 'GET':
          return _list(mainFolderId, q, page);
        case ['contacts'] when m == 'POST':
          return _create(request.body);
        case ['contacts', final id] when m == 'GET':
          return _get(id, q);
        case ['contacts', final id] when m == 'PATCH':
          return _update(id, request.body);
        case ['contacts', final id] when m == 'DELETE':
          return _delete(id);
        case ['contactFolders', final f, 'contacts'] when m == 'GET':
          if (!_folders.contains(f)) return _notFound();
          return _list(f, q, page);
        case ['contactFolders', final f, 'contacts', 'delta'] when m == 'GET':
          return _delta(f, q, page);
        case ['contactFolders', final f] when m == 'GET':
          return _folder(f, q);
        case ['contactFolders', final f] when m == 'PATCH':
          return _claim(f, request.body);
        case ['mailFolders', 'deleteditems'] when m == 'GET':
          return _ok({'id': deletedItemsId, 'displayName': 'Deleted Items'});
      }
    } on _Refusal catch (r) {
      return r.response;
    }
    return _notFound();
  }

  http.Response _list(String folder, Map<String, String> q, int page) {
    final skip = q[r'$skiptoken'];
    final _Pages pages;
    if (skip != null) {
      pages = _pages[skip] ?? (throw _Refusal(_error(400, 'BadRequest', '')));
    } else {
      final select = _selectOf(q);
      final filter = q[r'$filter'];
      String? email;
      if (filter != null) {
        final f = RegExp(
          r"^emailAddresses/any\(a:a/address eq '((?:[^']|'')*)'\)$",
        ).firstMatch(filter);
        if (f == null) {
          throw _Refusal(_error(400, 'BadRequest', 'Unsupported filter.'));
        }
        email = f[1]!.replaceAll("''", "'");
      }
      final expand = _expandOf(q);
      final top = int.tryParse(q[r'$top'] ?? '');
      var items = [
        for (final c in _contacts.values)
          if (c.folder == folder && (email == null || _hasEmail(c, email)))
            {
              ..._json(c, select),
              if (expand != null) ..._expanded(c.properties, expand),
            },
      ];
      if (top != null && top < items.length) items = items.sublist(0, top);
      pages = _Pages(items, path: 'me/contacts');
    }
    return _ok(_pageOf(pages, page, 'value'));
  }

  http.Response _delta(String folder, Map<String, String> q, int page) {
    final skip = q[r'$skiptoken'];
    final token = q[r'$deltatoken'];
    if ((skip != null || token != null) && q.containsKey(r'$select')) {
      return _error(
        400,
        'BadRequest',
        'The select is in the link already; the fake refuses it again.',
      );
    }
    if (skip != null) {
      final pages = _pages[skip];
      if (pages == null) return _error(400, 'BadRequest', 'Bad skip token.');
      if (_expiry != null && pages.number <= _expiredBefore) {
        return _expired();
      }
      return _ok(_pageOf(pages, page, 'value'));
    }
    if (!_folders.contains(folder)) return _notFound();
    final Set<String>? select;
    final int since;
    if (token != null) {
      final state = _deltas[token];
      if (state == null || state.folder != folder) {
        return _error(400, 'BadRequest', 'Bad delta token.');
      }
      final number = int.tryParse(token.split('-').last) ?? 0;
      if (_expiry != null && number <= _expiredBefore) return _expired();
      select = state.select;
      since = state.seq;
    } else {
      select = _selectOf(q);
      since = -1;
    }

    final items = <Map<String, Object?>>[];
    if (since < 0) {
      for (final c in _contacts.values) {
        if (c.folder == folder) items.add(_json(c, select));
      }
    } else {
      final after = [
        for (final e in _log)
          if (e.seq > since) e,
      ];
      final ids = <String>{for (final e in after) e.id};
      for (final id in ids) {
        final mine = [
          for (final e in after)
            if (e.id == id) e,
        ];
        final wasHere = mine.first.from == folder;
        final c = _contacts[id];
        final isHere = c != null && c.folder == folder;
        if (isHere) {
          final only = sparseDelta && wasHere ? _changedIn(mine, folder) : null;
          items.add(
            only == null
                ? _json(c, select)
                : _json(c, {
                    'id',
                    ...select == null ? only : only.intersection(select),
                  }),
          );
        } else if (wasHere) {
          items.add({
            '@odata.type': '#microsoft.graph.contact',
            'id': id,
            '@removed': {'reason': 'deleted'},
          });
        }
      }
    }
    final number = ++_tokens;
    final next = 'delta-$number';
    _deltas[next] = (folder: folder, seq: _seq, select: select);
    final pages = _Pages(
      items,
      path: 'me/contactFolders/$folder/contacts/delta',
      deltaToken: next,
      number: number,
    );
    return _ok(_pageOf(pages, page, 'value'));
  }

  http.Response _get(String id, Map<String, String> q) {
    final c = _contacts[id];
    if (c == null) return _notFound();
    final expand = _expandOf(q);
    return _ok({
      ..._json(c, _selectOf(q)),
      if (expand != null) ..._expanded(c.properties, expand),
    });
  }

  http.Response _create(String body) {
    final json = _decode(body);
    _refused(json);
    final c = _Contact(_newId(), mainFolderId, _newKey(), now)
      ..fields.addAll(_writable(json));
    c.fields['displayName'] ??= _composed(c.fields);
    final props = json['singleValueExtendedProperties'];
    for (final p in props is List ? props : const []) {
      if (p is Map && p['id'] is String && p['value'] is String) {
        c.properties[p['id'] as String] = p['value'] as String;
      }
    }
    _contacts[c.id] = c;
    _record(c.id, null, c.folder, null);
    return _ok(_json(c, null), status: 201);
  }

  http.Response _update(String id, String body) {
    final c = _contacts[id];
    if (c == null) return _notFound();
    final json = _decode(body);
    _refused(json);
    _apply(c, json);
    return _ok(_json(c, null));
  }

  http.Response _delete(String id) {
    final c = _contacts.remove(id);
    if (c == null) return _notFound();
    _record(id, c.folder, null, null);
    return http.Response('', 204);
  }

  http.Response _folder(String id, Map<String, String> q) {
    if (!_folders.contains(id)) return _notFound();
    final expand = _expandOf(q);
    return _ok({
      'id': id,
      if (expand != null) ..._expanded(_folderProperties[id] ?? {}, expand),
    });
  }

  http.Response _claim(String id, String body) {
    if (!_folders.contains(id)) return _notFound();
    if (claimRefused) {
      return _error(400, 'ErrorInvalidProperty', 'The folder refused it.');
    }
    final props = _decode(body)['singleValueExtendedProperties'];
    for (final p in props is List ? props : const []) {
      if (p is Map && p['id'] is String && p['value'] is String) {
        (_folderProperties[id] ??= {})[p['id'] as String] =
            p['value'] as String;
      }
    }
    return _ok({'id': id});
  }

  http.Response _batch(http.Request outer) {
    final json = _decode(outer.body);
    final parts = json['requests'];
    if (parts is! List || parts.isEmpty || parts.length > 20) {
      return _error(400, 'BadRequest', 'Between 1 and 20 requests.');
    }
    final answers = <Map<String, Object?>>[];
    for (final part in parts) {
      if (part is! Map) continue;
      final id = '${part['id']}';
      final headers = <String, String>{
        if (part['headers'] case final Map h)
          for (final MapEntry(:key, :value) in h.entries) '$key': '$value',
      };
      final http.Response answer;
      if (part.containsKey('body') && _named(headers, 'Content-Type') == null) {
        answer = _error(
          400,
          'BadRequest',
          'Content-Type header must be specified when a body is given.',
        );
      } else {
        final url = '${part['url']}';
        final inner = http.Request(
          '${part['method']}',
          Uri.parse('$_base${url.startsWith('/') ? '' : '/'}$url'),
        )..headers.addAll({
            ...headers,
            'Authorization': ?outer.headers['Authorization'],
          });
        if (part['body'] != null) inner.body = jsonEncode(part['body']);
        answer = _handle(inner, inBatch: true);
      }
      answers.add({
        'id': id,
        'status': answer.statusCode,
        'headers': {
          'Content-Type': 'application/json',
          ...answer.headers,
        },
        if (answer.body.isNotEmpty) 'body': jsonDecode(answer.body),
      });
    }
    // Graph answers in any order: here, backwards.
    return _ok({'responses': answers.reversed.toList()});
  }

  // --- plumbing --------------------------------------------------------------

  String _newId() => 'AAkALgAAAAAAHYQDEapmEc2byACqAC-EWg0Aimm${++_ids}';
  String _newKey() => 'EQAAABYAAAD${++_keys}';

  _Contact _there(String id) {
    final c = _contacts[id];
    if (c == null) throw StateError('No contact $id');
    return c;
  }

  void _record(String id, String? from, String? to, Set<String>? props) =>
      _log.add((seq: ++_seq, id: id, from: from, to: to, props: props));

  /// The properties [changes] changed, where each was an edit in [folder]:
  /// null where one made, moved or deleted the contact instead.
  static Set<String>? _changedIn(List<_Change> changes, String folder) {
    final changed = <String>{};
    for (final e in changes) {
      final props = e.props;
      if (props == null || e.from != folder || e.to != folder) return null;
      changed.addAll(props);
    }
    return changed;
  }

  void _apply(_Contact c, Map<String, Object?> changes) {
    final writable = _writable(changes);
    for (final MapEntry(:key, :value) in writable.entries) {
      if (value == null) {
        c.fields.remove(key);
      } else {
        c.fields[key] = value;
      }
    }
    final changed = writable.keys.toSet();
    const parts = {
      'givenName',
      'middleName',
      'surname',
      'title',
      'generation',
    };
    if (!writable.containsKey('displayName') &&
        changed.intersection(parts).isNotEmpty) {
      // Graph makes the display name again from the parts, unless it is
      // sent: why every PATCH of the sync resends it.
      c.fields['displayName'] = _composed(c.fields);
      changed.add('displayName');
    }
    final props = changes['singleValueExtendedProperties'];
    for (final p in props is List ? props : const []) {
      if (p is Map && p['id'] is String && p['value'] is String) {
        c.properties[p['id'] as String] = p['value'] as String;
      }
    }
    c
      ..changeKey = _newKey()
      ..modified = now;
    _record(c.id, c.folder, c.folder, {
      ...changed,
      'changeKey',
      'lastModifiedDateTime',
    });
  }

  static String _composed(Map<String, Object?> fields) => [
    fields['givenName'],
    fields['middleName'],
    fields['surname'],
  ].whereType<String>().where((s) => s.isNotEmpty).join(' ');

  static const _readOnly = {
    'id',
    'changeKey',
    'parentFolderId',
    'createdDateTime',
    'lastModifiedDateTime',
    'singleValueExtendedProperties',
    'multiValueExtendedProperties',
  };

  /// The properties of [json] a write keeps, as JSON copies.
  static Map<String, Object?> _writable(Map<String, Object?> json) => {
    for (final MapEntry(:key, :value) in json.entries)
      if (!_readOnly.contains(key) && !key.startsWith('@'))
        key: jsonDecode(jsonEncode(value)),
  };

  void _refused(Map<String, Object?> json) {
    if (refuse?.call(json) ?? false) {
      throw _Refusal(
        _error(
          400,
          'ErrorInvalidProperty',
          'Invalid property in ${jsonEncode({
            'displayName': json['displayName'],
            'emailAddresses': json['emailAddresses'],
            'mobilePhone': json['mobilePhone'],
          })}',
        ),
      );
    }
  }

  static bool _hasEmail(_Contact c, String email) {
    final emails = c.fields['emailAddresses'];
    for (final e in emails is List ? emails : const []) {
      if (e is Map &&
          '${e['address']}'.toLowerCase() == email.toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  static const _collections = {
    'businessPhones',
    'homePhones',
    'emailAddresses',
    'imAddresses',
    'children',
    'categories',
  };

  static const _addresses = {'homeAddress', 'businessAddress', 'otherAddress'};

  static const _properties = [
    'id',
    'createdDateTime',
    'lastModifiedDateTime',
    'changeKey',
    'categories',
    'parentFolderId',
    'birthday',
    'fileAs',
    'displayName',
    'givenName',
    'initials',
    'middleName',
    'nickName',
    'surname',
    'title',
    'yomiGivenName',
    'yomiSurname',
    'yomiCompanyName',
    'generation',
    'imAddresses',
    'jobTitle',
    'companyName',
    'department',
    'officeLocation',
    'profession',
    'businessHomePage',
    'assistantName',
    'manager',
    'homePhones',
    'mobilePhone',
    'businessPhones',
    'spouseName',
    'personalNotes',
    'children',
    'emailAddresses',
    'homeAddress',
    'businessAddress',
    'otherAddress',
  ];

  /// [c] as Graph answers with it: [select]'s properties (every v1.0
  /// property for none), empty ones as Graph writes them.
  static Map<String, Object?> _json(_Contact c, Set<String>? select) {
    Object? valueOf(String p) => switch (p) {
      'id' => c.id,
      'changeKey' => c.changeKey,
      'parentFolderId' => c.folder,
      'createdDateTime' => c.created.toUtc().toIso8601String(),
      'lastModifiedDateTime' => c.modified.toUtc().toIso8601String(),
      _ when _collections.contains(p) => c.fields[p] ?? const [],
      _ when _addresses.contains(p) => c.fields[p] ?? const {},
      _ => c.fields[p],
    };
    return {
      '@odata.etag': 'W/"${c.changeKey}"',
      for (final p in _properties)
        if (select == null || select.contains(p) || p == 'id')
          p: jsonDecode(jsonEncode(valueOf(p))),
    };
  }

  static Set<String>? _selectOf(Map<String, String> q) {
    final select = q[r'$select'];
    if (select == null) return null;
    final names = select.split(',').map((s) => s.trim()).toSet();
    final unknown = names.difference(_properties.toSet());
    if (unknown.isNotEmpty) {
      throw _Refusal(
        _error(400, 'RequestBroker--ParseUri', 'Could not find a property.'),
      );
    }
    return names;
  }

  /// The extended property id an `$expand` asks for.
  static String? _expandOf(Map<String, String> q) {
    final expand = q[r'$expand'];
    if (expand == null) return null;
    final m = RegExp(
      r"^singleValueExtendedProperties\(\$filter=id eq '([^']*)'\)$",
    ).firstMatch(expand);
    if (m == null) {
      throw _Refusal(_error(400, 'BadRequest', 'Unsupported expand.'));
    }
    return m[1];
  }

  /// [properties] as an `$expand` of [id] puts them on the answer: Exchange
  /// matches the id whatever the case of its letters.
  static Map<String, Object?> _expanded(
    Map<String, String> properties,
    String id,
  ) {
    for (final MapEntry(:key, :value) in properties.entries) {
      if (key.toLowerCase() == id.toLowerCase()) {
        return {
          'singleValueExtendedProperties': [
            {'id': key, 'value': value},
          ],
        };
      }
    }
    return const {};
  }

  /// One page of [pages], with the link to the next, or the delta link.
  Map<String, Object?> _pageOf(_Pages pages, int size, String key) {
    final end = (pages.offset + size).clamp(0, pages.items.length);
    final body = <String, Object?>{
      key: pages.items.sublist(pages.offset, end),
    };
    if (end < pages.items.length) {
      final skip = 'skip-${++_tokens}';
      _pages[skip] = pages.from(end);
      body['@odata.nextLink'] =
          '$_base/${pages.path}?\$skiptoken=${Uri.encodeQueryComponent(skip)}';
    } else if (pages.deltaToken case final token?) {
      body['@odata.deltaLink'] = '$_base/${pages.path}?\$deltatoken=$token';
    }
    return body;
  }

  http.Response _expired() {
    final e = _expiry!;
    return _error(e.status, e.code, 'The sync state was not found.');
  }

  static String? _header(http.Request r, String name) =>
      _named(r.headers, name);

  static String? _named(Map<String, String> headers, String name) {
    for (final MapEntry(:key, :value) in headers.entries) {
      if (key.toLowerCase() == name.toLowerCase()) return value;
    }
    return null;
  }

  static Map<String, Object?> _decode(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map) return json.cast<String, Object?>();
    } on FormatException {
      // Answered below.
    }
    throw _Refusal(_error(400, 'BadRequest', 'Invalid JSON.'));
  }

  static http.Response _ok(Map<String, Object?> body, {int status = 200}) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: const {'content-type': 'application/json'},
      );

  static http.Response _notFound() =>
      _error(404, 'ErrorItemNotFound', 'The specified object was not found.');

  static http.Response _error(
    int status,
    String code,
    String message, {
    Map<String, String> headers = const {},
  }) => http.Response(
    jsonEncode({
      'error': {
        'code': code,
        'message': message,
        'innerError': {'request-id': 'fake', 'date': '2026-11-20T09:00:00'},
      },
    }),
    status,
    headers: {'content-type': 'application/json', ...headers},
  );
}

typedef _Change = ({
  int seq,
  String id,
  String? from,
  String? to,
  Set<String>? props,
});

class _Contact {
  _Contact(this.id, this.folder, this.changeKey, DateTime at)
    : created = at,
      modified = at;

  final String id;
  String folder;
  String changeKey;
  final DateTime created;
  DateTime modified;
  final Map<String, Object?> fields = {};
  final Map<String, String> properties = {};
}

class _Pages {
  _Pages(
    this.items, {
    required this.path,
    this.deltaToken,
    this.number = 0,
    this.offset = 0,
  });

  final List<Map<String, Object?>> items;
  final String path;
  final String? deltaToken;

  /// Which delta round these are pages of, for expiry.
  final int number;
  final int offset;

  _Pages from(int offset) => _Pages(
    items,
    path: path,
    deltaToken: deltaToken,
    number: number,
    offset: offset,
  );
}

class _Refusal implements Exception {
  _Refusal(this.response);
  final http.Response response;
}
