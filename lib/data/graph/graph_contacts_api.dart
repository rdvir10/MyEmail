import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:http/http.dart' as http;

import '../answer_limit.dart';
import '../auth/microsoft_oauth.dart'
    show SignInNeedsConsent, SignInUnreachable;
import '../contacts/contact_mapping.dart'
    show graphContactSelect, graphDevicePropertyId, graphLinkPropertyId;
import '../contacts/contact_wire_errors.dart';
import '../mail_engine.dart' show AuthenticationFailed, ConnectionFailed;

/// A thin client over the Microsoft Graph contacts of the signed-in
/// account's own mailbox, for contact sync: the main Contacts folder read
/// whole or as changes (delta), contacts read by id, created (alone or
/// twenty to a `$batch`), changed and deleted, and the device claim kept on
/// the folder.
///
/// It takes and gives Graph's JSON as it is; what a contact holds, and how
/// it maps to Google's, is the mapping's. What it does know is the wire:
/// one `Prefer` header on every request and on every request inside a
/// `$batch`, so every contact id is the immutable kind, which stays the
/// same when Outlook moves the contact; the hidden tag and the device
/// claim, each a single-value extended property with a name fixed for
/// ever; a delta link expiring; a throttle waited out; and a token that
/// does not cover contacts. Its failures never carry Microsoft's own
/// sentence, which can quote the contact back.
///
/// Its own class, as the calendar's is, because contacts are a consent of
/// their own (`MicrosoftOAuth.contactSyncScopes`): a refusal of it must
/// never touch mail. Only the account's own mailbox: contact sync does not
/// take shared ones.
class GraphContactsApi {
  GraphContactsApi({
    required this.accessToken,
    this.mailAccessToken,
    http.Client? httpClient,
    this.sleep,
  }) : _given = httpClient;

  /// The account's token for its contacts. Asked for per request, because
  /// a refused one is asked for again with `force`.
  final Future<String> Function({bool force}) accessToken;

  /// The account's token for its mail, for the one call that reads a mail
  /// folder ([deletedItemsFolderId]): Deleted Items is a mail folder, and
  /// reading one is the mail consent's. Where none is given the contacts
  /// token is used, which Microsoft issues with every Graph permission the
  /// account has granted.
  final Future<String> Function({bool force})? mailAccessToken;

  /// A client handed in, which belongs to whoever handed it in.
  final http.Client? _given;

  /// One made here, and closed by [close].
  http.Client? _own;

  http.Client get _client => _given ?? (_own ??= http.Client());

  /// Overridden by tests, which must not really wait out a throttle.
  final Future<void> Function(Duration)? sleep;

  /// How many times a throttled request is tried again, and the longest
  /// wait worth sitting through: the same limits as the mail calls.
  static const maxThrottleRetries = 3;
  static const maxThrottleWait = Duration(seconds: 30);

  static const base = 'https://graph.microsoft.com/v1.0';

  /// Sent with every request, and with every request inside a `$batch`,
  /// which carries headers of its own: immutable ids, which a contact keeps
  /// when it is moved (an id that changed when Outlook moved a contact
  /// would read as a deletion and a new contact), and pages of 200.
  static const prefer = 'IdType="ImmutableId", odata.maxpagesize=200';

  /// The page a listing asks for with `$top`, as the calendar's listings
  /// do: Outlook's lists page by it, whatever the header says.
  static const pageSize = 200;

  /// How many requests one `$batch` may carry. Graph takes no more.
  static const batchLimit = 20;

  // The hidden tag ([graphLinkPropertyId]) and the device claim
  // ([graphDevicePropertyId]), each a named property in the app's own
  // property set, and the properties the sync reads ([graphContactSelect],
  // the delta's one `$select`, whose version goes with the delta link),
  // are the mapping's, defined there once. Graph builds the select into
  // its links, so a change to it starts a new delta.

  /// The id of the main Contacts folder, or null when it holds no contacts
  /// yet. Graph names no such folder in v1.0; every contact `/me/contacts`
  /// lists is in it, and says so in `parentFolderId`. With none there, the
  /// first contact [create] makes answers with it.
  Future<String?> mainFolderId() async {
    final json = await _get(
      Uri.parse('$base/me/contacts').replace(
        queryParameters: {r'$top': '1', r'$select': 'id,parentFolderId'},
      ),
      'folder',
    );
    final value = json['value'];
    if (value is List) {
      for (final c in value) {
        final id = c is Map ? c['parentFolderId'] : null;
        if (id is String && id.isNotEmpty) return id;
      }
    }
    return null;
  }

  /// Every contact in [folderId], or in the main Contacts folder when it
  /// is not known yet (`/me/contacts`), every page of them. With [whole],
  /// every property, as the backup files take them; otherwise the sync's
  /// ([graphContactSelect]).
  Future<List<Map<String, Object?>>> listAll({
    String? folderId,
    bool whole = false,
  }) async {
    final watch = Stopwatch()..start();
    final at = folderId == null
        ? '$base/me/contacts'
        : '$base/me/contactFolders/${_id(folderId)}/contacts';
    final (:items, :pages) = await _allPages(
      Uri.parse(at).replace(
        queryParameters: {
          r'$top': '$pageSize',
          if (!whole) r'$select': graphContactSelect,
        },
      ),
      'list',
    );
    debugPrint('[myemail] contacts: Microsoft listed ${items.length} '
        'contacts, $pages pages, ${watch.elapsedMilliseconds} ms');
    return items;
  }

  /// Every page of the list [first] asks for, following Graph's links to
  /// the end. Outlook pages a list by its `$top`, ten to a page without
  /// one, so a list read for what is in it is read to its last page.
  Future<({List<Map<String, Object?>> items, int pages})> _allPages(
    Uri first,
    String doing,
  ) async {
    Uri? next = first;
    final items = <Map<String, Object?>>[];
    final seen = <Uri>{};
    var pages = 0;
    while (next != null) {
      if (!seen.add(next)) throw _pagesLoop;
      final json = await _get(next, doing);
      pages++;
      items.addAll(_valueOf(json));
      final link = json['@odata.nextLink'];
      next = link is String ? _graphLink(link) : null;
    }
    return (items: items, pages: pages);
  }

  /// The changes in the Contacts folder [folderId] since [deltaLink], or,
  /// with none, every contact in it as the first round of a new delta.
  /// Every page is read before it returns; its [GraphContactsDelta.deltaLink]
  /// is where the next round starts.
  ///
  /// Throws [ContactFeedExpired] when the link is no good any more: then a
  /// new delta, without a link, is the answer. Graph says so with a 410, or
  /// a 40X "such as `syncStateNotFound`", a list it does not close; so on a
  /// round that started from a stored link any 400 or 410 is read as that,
  /// and so are the codes that name the sync state on any round. A fresh
  /// delta costs a full listing, which is reconciled against the rows. A
  /// folder that is not there is a [ContactGone], on a fresh round at the
  /// latest.
  Future<GraphContactsDelta> delta({
    required String folderId,
    String? deltaLink,
  }) async {
    final watch = Stopwatch()..start();
    Uri? next;
    if (deltaLink == null) {
      // The select goes in the first request only: Graph builds it into
      // the links it answers with.
      next = Uri.parse(
        '$base/me/contactFolders/${_id(folderId)}/contacts/delta',
      ).replace(queryParameters: {r'$select': graphContactSelect});
    } else {
      next = Uri.tryParse(deltaLink);
      // A link that is not Graph's is never sent the token: it is no link.
      if (next == null || !_isGraph(next)) throw const ContactFeedExpired(0);
    }
    final byId = <String, Map<String, Object?>>{};
    final seen = <Uri>{};
    var pages = 0;
    String? newLink;
    while (next != null) {
      if (!seen.add(next)) throw _pagesLoop;
      final response = await _exchange(() => http.Request('GET', next!));
      if (_deltaExpired(response, stored: deltaLink != null)) {
        debugPrint('[myemail] contacts: Microsoft delta expired '
            '(HTTP ${response.statusCode})');
        throw ContactFeedExpired(response.statusCode);
      }
      final json = _json(response, 'delta');
      pages++;
      for (final c in _valueOf(json)) {
        final id = c['id'];
        if (id is! String || id.isEmpty) continue;
        // The same contact can come more than once; its last entry is how
        // it stands.
        byId.remove(id);
        byId[id] = c;
      }
      final link = json['@odata.nextLink'];
      final done = json['@odata.deltaLink'];
      if (link is String) {
        next = _graphLink(link);
      } else {
        next = null;
        if (done is String && _isGraph(Uri.parse(done))) newLink = done;
      }
    }
    if (newLink == null) {
      throw const ConnectionFailed(
        'Microsoft did not finish listing the contacts. Try again shortly.',
      );
    }
    final removed = {
      for (final MapEntry(:key, :value) in byId.entries)
        if (value.containsKey('@removed')) key,
    };
    final result = GraphContactsDelta(
      contacts: [
        for (final c in byId.values)
          if (!c.containsKey('@removed')) c,
      ],
      removed: removed,
      deltaLink: newLink,
      complete: deltaLink == null,
      pages: pages,
    );
    final kind = deltaLink == null ? 'listed' : 'changes';
    debugPrint(
      '[myemail] contacts: Microsoft $kind'
      ' ${result.contacts.length} contacts, ${removed.length} removed, '
      '$pages pages, ${watch.elapsedMilliseconds} ms',
    );
    return result;
  }

  /// The contact [id] wherever it is in the mailbox, or null when it is not
  /// there. With [whole], every property (the read before a delete, which
  /// goes into Recently deleted); otherwise the sync's. With [withTag], its
  /// hidden tag too ([tagOf]).
  Future<Map<String, Object?>?> get(
    String id, {
    bool whole = false,
    bool withTag = false,
  }) async {
    final uri = Uri.parse('$base/me/contacts/${_id(id)}').replace(
      queryParameters: {
        if (!whole) r'$select': graphContactSelect,
        if (withTag) r'$expand': _expandOf(graphLinkPropertyId),
      },
    );
    final response = await _exchange(() => http.Request('GET', uri));
    if (response.statusCode == 404) return null;
    return _json(response, 'get');
  }

  /// The contacts in the main Contacts folder with [address] among their
  /// email addresses, each with its tag: how a create whose answer was lost
  /// is found again where the delta did not show it. Every page of them:
  /// an address many contacts share (a family's, an office's) can put the
  /// tagged one past the first.
  Future<List<Map<String, Object?>>> findByEmail(String address) async {
    final quoted = address.replaceAll("'", "''");
    final (:items, pages: _) = await _allPages(
      Uri.parse('$base/me/contacts').replace(
        queryParameters: {
          r'$filter': "emailAddresses/any(a:a/address eq '$quoted')",
          r'$top': '$pageSize',
          r'$select': graphContactSelect,
          r'$expand': _expandOf(graphLinkPropertyId),
        },
      ),
      'find',
    );
    return items;
  }

  /// The id of the mailbox's Deleted Items folder, where a contact Outlook
  /// deletes goes: a contact found there is a deletion, not a move.
  Future<String> deletedItemsFolderId() async {
    final json = await _get(
      Uri.parse('$base/me/mailFolders/deleteditems').replace(
        queryParameters: {r'$select': 'id'},
      ),
      'deleted items',
      token: mailAccessToken,
    );
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const ConnectionFailed(
        'Microsoft did not say which folder is Deleted Items. Try again '
        'shortly.',
      );
    }
    return id;
  }

  /// Create [contact] in the main Contacts folder, with [tag] as its hidden
  /// tag where given, and answer with it as Graph made it, its
  /// `parentFolderId` included.
  ///
  /// A refusal of this contact is a [ContactRefused]. A 503 is not sent
  /// again, as it is for a read: whatever answered it may have made the
  /// contact first, and a second would double it. Its tag settles it.
  Future<Map<String, Object?>> create(
    Map<String, Object?> contact, {
    String? tag,
  }) async {
    final body = jsonEncode(withTag(contact, tag));
    final response = await _exchange(
      () => http.Request('POST', Uri.parse('$base/me/contacts'))
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
      making: true,
    );
    return _json(response, 'create');
  }

  /// Create [contacts], [batchLimit] to a `$batch`, and answer with what
  /// became of each, in the order given: the contact made, or why not.
  /// Never throws for a failure: what was made before it is kept, and
  /// handed back.
  ///
  /// A batch answers 200 whatever happened inside it, so each create is
  /// read by its own status. One throttled (429: turned away unread) is
  /// sent again after the longest wait any asked for, as a request alone
  /// would be; one that failed otherwise, a 503 among them, is left as the
  /// failure it is, because a server in trouble may have made it all the
  /// same, and its tag finds it. For that reason a `$batch` answered 503
  /// as a whole is not sent again either: its parts may have been made. A
  /// batch refused as a whole is [ContactBatchRefused] for each in it, and
  /// the next batch goes on; any other failure of a whole batch is the
  /// answer for every contact not yet answered, its own and the ones after
  /// it, which are not sent.
  Future<List<ContactCreateAnswer>> createBatch(
    List<({Map<String, Object?> contact, String? tag})> contacts,
  ) async {
    final answers = List<ContactCreateAnswer?>.filled(contacts.length, null);
    for (var start = 0; start < contacts.length; start += batchLimit) {
      var asking = [
        for (var i = start; i < contacts.length && i < start + batchLimit; i++)
          i,
      ];
      try {
        await _batchOf(contacts, asking, answers);
      } on ContactBatchRefused catch (e) {
        for (var i = start; i < start + asking.length; i++) {
          answers[i] = (contact: null, failure: e);
        }
      } on _BatchFailed catch (failed) {
        for (final i in failed.asking) {
          answers[i] = (contact: null, failure: failed.cause);
        }
        for (var i = start; i < contacts.length; i++) {
          answers[i] ??= (contact: null, failure: failed.cause);
        }
        break;
      }
    }
    final made = answers.where((a) => a?.contact != null).length;
    debugPrint('[myemail] contacts: Microsoft batch made $made of '
        '${contacts.length}');
    return [for (final a in answers) a!];
  }

  /// One `$batch` of the creates [numbered], their answers put in
  /// [answers], and those throttled asked again. A whole batch that fails
  /// throws: [ContactBatchRefused] when refused on the first asking, and
  /// otherwise [_BatchFailed] with the ones it was asking.
  Future<void> _batchOf(
    List<({Map<String, Object?> contact, String? tag})> contacts,
    List<int> numbered,
    List<ContactCreateAnswer?> answers,
  ) async {
    var asking = numbered;
    for (var attempt = 0; asking.isNotEmpty; attempt++) {
      final body = jsonEncode({
        'requests': [
          for (final i in asking)
            {
              'id': '$i',
              'method': 'POST',
              'url': '/me/contacts',
              'headers': {
                'Content-Type': 'application/json',
                'Prefer': prefer,
              },
              'body': withTag(contacts[i].contact, contacts[i].tag),
            },
        ],
      });
      final Map<String, Object?> json;
      try {
        final response = await _exchange(
          () => http.Request('POST', Uri.parse('$base/\$batch'))
            ..headers['Content-Type'] = 'application/json'
            ..body = body,
          making: true,
        );
        json = _json(response, 'batch');
      } on ContactRefused catch (e) {
        if (attempt == 0) throw ContactBatchRefused.from('Microsoft', e);
        throw _BatchFailed(asking, ContactBatchRefused.from('Microsoft', e));
      } on Exception catch (e) {
        throw _BatchFailed(asking, e);
      }
      final responses = json['responses'];
      final byId = {
        for (final r in responses is List ? responses : const [])
          if (r is Map) '${r['id']}': r,
      };
      final again = <int>[];
      var wait = Duration.zero;
      for (final i in asking) {
        final r = byId['$i'];
        final status = r?['status'];
        final rBody = r?['body'] is Map
            ? (r!['body'] as Map).cast<String, Object?>()
            : const <String, Object?>{};
        if (status is! int) {
          answers[i] = (
            contact: null,
            failure: const ConnectionFailed(
              'Microsoft left part of the request unanswered. Try again.',
            ),
          );
        } else if (status >= 200 && status < 300) {
          answers[i] = (contact: rBody, failure: null);
          continue;
        } else {
          answers[i] = (contact: null, failure: _failureFor(status, rBody));
        }
        if (status == 429) {
          again.add(i);
          final asked = _innerRetryAfter(r?['headers']);
          if (asked > wait) wait = asked;
        }
      }
      if (again.isEmpty ||
          attempt >= maxThrottleRetries ||
          wait > maxThrottleWait) {
        return;
      }
      debugPrint('[myemail] contacts: Microsoft throttled ${again.length} '
          'of a batch, waiting ${wait.inSeconds} s');
      await (sleep ?? _realSleep)(wait);
      asking = again;
    }
  }

  /// Write [changes], the properties that changed (collections and
  /// addresses whole), to the contact [id], and answer with it as it now
  /// is. A contact no longer there is a [ContactGone].
  ///
  /// Graph has no conditional PATCH for contacts: the runner reads the
  /// contact just before, and plans again if its `changeKey` has moved.
  Future<Map<String, Object?>> update(
    String id,
    Map<String, Object?> changes,
  ) async {
    final body = jsonEncode(changes);
    final response = await _exchange(
      () => http.Request('PATCH', Uri.parse('$base/me/contacts/${_id(id)}'))
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    return _json(response, 'update');
  }

  /// Delete the contact [id]: an ordinary delete, which Exchange keeps
  /// among the mailbox's recoverable items, and never `permanentDelete`.
  /// True when it was deleted now, false when it was not there to delete:
  /// either way it is gone.
  Future<bool> delete(String id) async {
    final response = await _exchange(
      () => http.Request('DELETE', Uri.parse('$base/me/contacts/${_id(id)}')),
    );
    if (response.statusCode == 404) return false;
    _json(response, 'delete');
    return true;
  }

  /// The device claim on the Contacts folder [folderId], or null when no
  /// device has made one.
  Future<GraphDeviceClaim?> readClaim(String folderId) async {
    final json = await _get(
      Uri.parse('$base/me/contactFolders/${_id(folderId)}').replace(
        queryParameters: {
          r'$select': 'id',
          r'$expand': _expandOf(graphDevicePropertyId),
        },
      ),
      'claim',
    );
    final value = _propertyOf(json, graphDevicePropertyId);
    return value == null ? null : GraphDeviceClaim.parse(value);
  }

  /// Claim the Contacts folder [folderId] for [device], as of [at]: the
  /// mark a run that completes leaves, so a second device sees that this
  /// one syncs.
  Future<void> writeClaim(
    String folderId, {
    required String device,
    required DateTime at,
  }) async {
    final body = jsonEncode({
      'singleValueExtendedProperties': [
        {
          'id': graphDevicePropertyId,
          'value': GraphDeviceClaim(device: device, at: at).value,
        },
      ],
    });
    final response = await _exchange(
      () => http.Request(
        'PATCH',
        Uri.parse('$base/me/contactFolders/${_id(folderId)}'),
      )
        ..headers['Content-Type'] = 'application/json'
        ..body = body,
    );
    _json(response, 'claim');
  }

  /// [contact] with [tag] as its hidden tag, any other extended property it
  /// carries kept. [contact] itself unchanged, and returned as it is
  /// without a tag.
  static Map<String, Object?> withTag(
    Map<String, Object?> contact,
    String? tag,
  ) {
    if (tag == null) return contact;
    final others = contact['singleValueExtendedProperties'];
    return {
      ...contact,
      'singleValueExtendedProperties': [
        if (others is List)
          for (final p in others)
            if (p is! Map || !_sameProperty(p['id'], graphLinkPropertyId)) p,
        {'id': graphLinkPropertyId, 'value': tag},
      ],
    };
  }

  /// The hidden tag [contact] carries, where it was read with its tag
  /// ([get] with `withTag`, [findByEmail]).
  static String? tagOf(Map<String, Object?> contact) =>
      _propertyOf(contact, graphLinkPropertyId);

  /// Let go of the connection. Only one made here: a client handed in is
  /// closed by its owner.
  void close() {
    _own?.close();
    _own = null;
  }

  // --- plumbing --------------------------------------------------------------

  /// Graph ids are long, opaque and contain characters that mean something
  /// in a URL. They go through here every time.
  static String _id(String id) => Uri.encodeComponent(id);

  static String _expandOf(String property) =>
      "singleValueExtendedProperties(\$filter=id eq '$property')";

  /// Property ids come back as Exchange writes them, which need not be the
  /// case they were sent in: the GUID's letters among them.
  static bool _sameProperty(Object? id, String property) =>
      id is String && id.toLowerCase() == property.toLowerCase();

  static String? _propertyOf(Map<String, Object?> json, String property) {
    final props = json['singleValueExtendedProperties'];
    if (props is! List) return null;
    for (final p in props) {
      if (p is Map && _sameProperty(p['id'], property)) {
        final value = p['value'];
        if (value is String && value.isNotEmpty) return value;
      }
    }
    return null;
  }

  static List<Map<String, Object?>> _valueOf(Map<String, Object?> json) {
    final value = json['value'];
    return [
      if (value is List)
        for (final c in value)
          if (c is Map) c.cast<String, Object?>(),
    ];
  }

  static bool _isGraph(Uri uri) =>
      uri.scheme == 'https' && uri.host == 'graph.microsoft.com';

  /// A link Graph answered with, to follow. One elsewhere is not followed:
  /// the token would go with it.
  static Uri _graphLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || !_isGraph(uri)) {
      throw const ConnectionFailed(
        'Microsoft answered with a link that is not its own. Try again '
        'shortly.',
      );
    }
    return uri;
  }

  static const _pagesLoop = ConnectionFailed(
    'Microsoft sent the same page of contacts twice. Try again shortly.',
  );

  Future<Map<String, Object?>> _get(
    Uri uri,
    String doing, {
    Future<String> Function({bool force})? token,
  }) async {
    final response = await _exchange(
      () => http.Request('GET', uri),
      token: token,
    );
    return _json(response, doing);
  }

  /// Send what [build] makes, waiting out any throttling Graph asks for:
  /// a 429 or a 503 with how long in `Retry-After`. [build] is called per
  /// try because a request cannot be sent twice.
  ///
  /// With [making], a request that creates: only a 429 is sent again, which
  /// is Graph turning it away unread. A 503 may come from in front of a
  /// server that made the contact all the same.
  Future<http.Response> _exchange(
    http.Request Function() build, {
    Future<String> Function({bool force})? token,
    bool making = false,
  }) async {
    for (var attempt = 0;; attempt++) {
      final response = await _authorised(build, token ?? accessToken);
      final wait = making && response.statusCode != 429
          ? null
          : _retryAfter(response);
      if (wait == null || attempt >= maxThrottleRetries) return response;
      debugPrint('[myemail] contacts: Microsoft throttled '
          '(HTTP ${response.statusCode}), waiting ${wait.inSeconds} s');
      await (sleep ?? _realSleep)(wait);
    }
  }

  /// With the account's token and the immutable-id header, and once more
  /// with a freshly refreshed token if Microsoft turns the first away. A
  /// refresh that could not reach Microsoft reads as what it is, no
  /// connection, and so does an answer not had in time ([answeredInTime]).
  /// Neither keeps more than the kind of failure: its text can hold the
  /// request, and the request a contact's details.
  Future<http.Response> _authorised(
    http.Request Function() build,
    Future<String> Function({bool force}) tokenFor,
  ) async {
    for (var forced = false;; forced = true) {
      final String token;
      try {
        token = await tokenFor(force: forced);
      } on SignInUnreachable catch (e) {
        throw ConnectionFailed(e.message);
      }
      final request = build()
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Prefer'] = prefer;
      final http.Response response;
      try {
        response = await answeredInTime(
          _client.send(request),
          uploading: request.contentLength,
        );
      } on Exception catch (e) {
        debugPrint('[myemail] contacts: Microsoft not reached '
            '(${e.runtimeType})');
        throw ConnectionFailed(
          'Could not reach Microsoft (${e.runtimeType}).',
        );
      }
      if (response.statusCode != 401 || forced) return response;
    }
  }

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  /// How long to wait before trying again, or null if trying again is not
  /// the answer: Graph sends Retry-After in seconds on a 429 and often on a
  /// 503, and past the cap sitting there is worse than saying what happened.
  static Duration? _retryAfter(http.Response response) {
    if (response.statusCode != 429 && response.statusCode != 503) return null;
    final header = response.headers['retry-after'];
    final seconds = header == null ? null : int.tryParse(header.trim());
    final wait = Duration(seconds: seconds ?? 2);
    return wait > maxThrottleWait ? null : wait;
  }

  /// The wait a request inside a `$batch` asked for, in its own headers.
  static Duration _innerRetryAfter(Object? headers) {
    if (headers is Map) {
      for (final MapEntry(:key, :value) in headers.entries) {
        if ('$key'.toLowerCase() == 'retry-after') {
          final seconds = int.tryParse('$value'.trim());
          if (seconds != null && seconds >= 0) {
            return Duration(seconds: seconds);
          }
        }
      }
    }
    return const Duration(seconds: 2);
  }

  /// A delta link past its time: 410; a 40X whose code says the sync state
  /// is gone; and on a round that started from a [stored] link, any 400.
  static bool _deltaExpired(http.Response response, {required bool stored}) {
    final status = response.statusCode;
    if (status == 410 || (stored && status == 400)) return true;
    if (status < 400 || status >= 500) return false;
    final code = _codeOf(_errorOf(response))?.toLowerCase();
    return code == 'syncstatenotfound' ||
        code == 'syncstateinvalid' ||
        code == 'resyncrequired';
  }

  /// The response's JSON, or the failure it amounts to. An empty answer
  /// (204) is an empty map.
  static Map<String, Object?> _json(http.Response response, String doing) {
    final status = response.statusCode;
    if (status >= 400) {
      final error = _errorOf(response);
      final code = errorCode(_codeOf(error));
      debugPrint('[myemail] contacts: Microsoft $doing answered HTTP $status'
          '${code == null ? '' : ' ($code)'}');
      throw _failureFor(status, error);
    }
    if (status == 204 || response.body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // A page from something in between, a network's sign-in page or a
      // proxy, more often than Microsoft: one that passes.
    }
    throw ConnectionFailed(
      'Microsoft answered with something that was not JSON (HTTP $status).',
    );
  }

  static Map<String, Object?> _errorOf(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Not JSON. The status is all there is.
    }
    return const {};
  }

  /// The most detailed code Graph's error envelope gives: an inner error's
  /// where it has one that is a code, else the error's own.
  static String? _codeOf(Map<String, Object?> json) {
    final error = json['error'];
    if (error is! Map) return null;
    String? code = error['code'] is String ? error['code'] as String : null;
    var inner = error['innerError'] ?? error['innererror'];
    for (var depth = 0; inner is Map && depth < 5; depth++) {
      final c = inner['code'];
      if (c is String && c.isNotEmpty) code = c;
      inner = inner['innerError'] ?? inner['innererror'];
    }
    return code;
  }

  /// Graph's refusal as the failure the runner acts on: the status and the
  /// code, never Graph's own sentence.
  static Exception _failureFor(int status, Map<String, Object?> json) {
    final code = errorCode(_codeOf(json));
    if (status == 401 || code == 'InvalidAuthenticationToken') {
      return const AuthenticationFailed(
        'The sign-in for this account is no longer accepted. Open Settings, '
        'Accounts and sign in again.',
      );
    }
    if (status == 403) {
      // Not allowed contacts, which a sign-in that asks for them fixes, or
      // the organisation's approval does: as AccountPeople reads its 403.
      return const SignInNeedsConsent(
        'This Microsoft account has not allowed the app to change its '
        'contacts. Allow it, then sign in; where your organisation has to '
        'approve it, the sign-in sends them the request.',
      );
    }
    if (status == 404) return const ContactGone();
    if (status == 429) {
      return const ConnectionFailed(
        'Microsoft is rate limiting this account. Contact sync tries again '
        'later.',
      );
    }
    if (status >= 500) {
      return ConnectionFailed(
        'Microsoft is having trouble (HTTP $status). Try again shortly.',
      );
    }
    return ContactRefused.by('Microsoft', status, code);
  }
}

/// A whole `$batch` failed after some of it may have been answered: the
/// creates it was asking for, and why.
class _BatchFailed implements Exception {
  _BatchFailed(this.asking, this.cause);
  final List<int> asking;
  final Exception cause;
}

/// One round of a delta, every page of it.
@immutable
class GraphContactsDelta {
  const GraphContactsDelta({
    required this.contacts,
    required this.removed,
    required this.deltaLink,
    required this.complete,
    this.pages = 1,
  });

  /// Contacts added or changed (all of them, for the first round), once
  /// each. A property missing from one is not known, not cleared: such a
  /// contact is read whole by id before it is used.
  final List<Map<String, Object?>> contacts;

  /// The ids of contacts gone from the folder: deleted, or moved out.
  /// Which, is for a GET by id to say.
  final Set<String> removed;

  /// Where the next round starts.
  final String deltaLink;

  /// True for the first round of a new delta: every contact in the folder
  /// is in [contacts], so one missing from it is worth asking about.
  final bool complete;

  /// How many pages it took.
  final int pages;
}

/// The mark the syncing device leaves on the Contacts folder.
@immutable
class GraphDeviceClaim {
  const GraphDeviceClaim({required this.device, required this.at});

  /// The claim as [value] holds it, or null where it does not read as one.
  static GraphDeviceClaim? parse(String value) {
    final space = value.lastIndexOf(' ');
    if (space <= 0) return null;
    final at = DateTime.tryParse(value.substring(space + 1));
    if (at == null) return null;
    return GraphDeviceClaim(device: value.substring(0, space), at: at.toUtc());
  }

  /// The device's own random id.
  final String device;

  /// When it last completed a run.
  final DateTime at;

  /// As it is kept: the id, a space, and the time in UTC.
  String get value => '$device ${at.toUtc().toIso8601String()}';

  @override
  bool operator ==(Object other) =>
      other is GraphDeviceClaim &&
      other.device == device &&
      other.at.isAtSameMomentAs(at);

  @override
  int get hashCode => Object.hash(device, at.millisecondsSinceEpoch);
}
