import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/graph/graph_id_map.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/graph/graph_transport.dart';
import 'package:myemail/data/imap/imap_transport.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/folder_role.dart';

/// The mail transport over Microsoft Graph.
///
/// It implements the same port as the IMAP one, so the sync, the cache and the
/// whole UI run against it unchanged. What the tests below mostly guard is the
/// join between the two worlds: Graph has opaque string ids and the sync is
/// built on integers that only ever rise.
void main() {
  late _FakeGraph server;
  late MemoryGraphIdMap ids;
  late GraphTransport transport;

  /// The same transport with the waiting taken out, so a throttling test does
  /// not really sit there for seconds.
  late GraphTransport patientTransport;

  setUp(() {
    server = _FakeGraph();
    ids = MemoryGraphIdMap();
    patientTransport = GraphTransport(
      accountId: 'acct-1',
      idMap: ids,
      api: GraphMailApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient(server.handle),
        sleep: (_) async {},
      ),
    );
    transport = GraphTransport(
      accountId: 'acct-1',
      idMap: ids,
      api: GraphMailApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient(server.handle),
      ),
    );
  });

  group('folders', () {
    test('well-known names become the app roles', () async {
      server
        ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
        ..folder(id: 'f-sent', name: 'Sent Items', wellKnown: 'sentitems')
        ..folder(id: 'f-junk', name: 'Junk Email', wellKnown: 'junkemail')
        ..folder(id: 'f-arch', name: 'Archive', wellKnown: 'archive')
        ..folder(id: 'f-work', name: 'Work');

      final folders = await transport.listFolders();

      Map<String, FolderRole> roles = {
        for (final f in folders) f.path: f.role,
      };
      expect(roles['Inbox'], FolderRole.inbox);
      expect(roles['Sent Items'], FolderRole.sent);
      expect(roles['Junk Email'], FolderRole.junk);
      expect(roles['Archive'], FolderRole.archive);
      expect(roles['Work'], FolderRole.user);
    });

    test('a nested folder gets a slash path', () async {
      // Graph reports a parent id and a name; the tree wants the path.
      server
        ..folder(id: 'f-work', name: 'Work', children: 1)
        ..folder(id: 'f-inv', name: 'Invoices', parent: 'f-work');

      final folders = await transport.listFolders();

      expect(
        folders.map((f) => f.path),
        containsAll(<String>['Work', 'Work/Invoices']),
      );
    });

    test('counts come through for the tree badges', () async {
      server.folder(
        id: 'f-inbox',
        name: 'Inbox',
        wellKnown: 'inbox',
        total: 42,
        unread: 7,
      );

      final inbox = (await transport.listFolders()).single;

      expect(inbox.total, 42);
      expect(inbox.unread, 7);
    });

    test('a folder id change invalidates the cache, as UIDVALIDITY would',
        () async {
      // Deleting a folder and making another of the same name gives a new
      // Graph id. Without this the old folder's cached messages would be
      // matched against the new folder's.
      server.folder(id: 'f-a', name: 'Work');
      await transport.listFolders();
      final before = await transport.selectFolder('Work');

      server
        ..reset()
        ..folder(id: 'f-b', name: 'Work');
      await transport.listFolders();
      final after = await transport.selectFolder('Work');

      expect(after.uidValidity, isNot(before.uidValidity));
    });
  });

  group('what Graph is asked for', () {
    test('every folder field exists in v1.0', () {
      // wellKnownName was in this list and exists only in the beta API.
      // Graph refuses a $select naming a property it does not have, with a
      // bare BadRequest for the whole request — so every folder listing
      // failed and nothing in the app loaded at all.
      const v1Properties = {
        'id',
        'displayName',
        'parentFolderId',
        'childFolderCount',
        'totalItemCount',
        'unreadItemCount',
        'isHidden',
      };

      for (final field in GraphMailApi.folderFields.split(',')) {
        expect(v1Properties, contains(field));
      }
    });

    test('the special folders are found by name instead', () async {
      // The supported way to learn which folder is the Inbox without the
      // beta property: Graph resolves these names in any mailbox, in any
      // language.
      server
        ..folder(id: 'f-inbox', name: 'Posteingang', wellKnown: 'inbox')
        ..folder(id: 'f-other', name: 'Inbox', wellKnown: null);

      final folders = await transport.listFolders();

      expect(
        folders.firstWhere((f) => f.path == 'Posteingang').role,
        FolderRole.inbox,
        reason: 'the name in the mailbox language must not decide the role',
      );
      expect(
        folders.firstWhere((f) => f.path == 'Inbox').role,
        FolderRole.user,
      );
    });

    test('a mailbox with no Archive is not an error', () async {
      // Plenty of mailboxes have never had one, and the lookup 404s.
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');

      final folders = await transport.listFolders();

      expect(folders, hasLength(1));
    });

    test('the well-known names are resolved in one request, not six',
        () async {
      // Six at once is a burst, and a burst is what Graph throttles hardest.
      // Adding an account failed outright with a 429 before anything loaded.
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');

      await transport.listFolders();

      expect(server.batches, 1);
    });

    test('being throttled is waited out rather than handed over', () async {
      // Graph says how long to wait in a Retry-After header. Reporting "rate
      // limited" instead leaves someone with nothing to do but tap the same
      // button again themselves.
      server
        ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
        ..throttle = 2;

      final folders = await patientTransport.listFolders();

      expect(folders, hasLength(1));
      expect(server.throttle, 0, reason: 'both refusals were retried');
    });

    test('a throttle that never lets up is eventually reported', () async {
      // Retrying forever would be an app that appears frozen. Past a few
      // attempts it says what happened.
      server
        ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
        ..throttle = 99;

      await expectLater(
        patientTransport.listFolders(),
        throwsA(isA<ConnectionFailed>()),
      );
    });

    test('a refusal repeats what Graph said about it', () async {
      // "Microsoft refused the request (BadRequest)" says only that something
      // was wrong with a request the person never made. Graph's own sentence
      // names the property, which is the whole diagnosis.
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');
      server.rejectFolderSelect = true;

      await expectLater(
        transport.listFolders(),
        throwsA(isA<ConnectionFailed>().having(
          (e) => e.message,
          'message',
          contains('Could not find a property named'),
        )),
      );
    });
  });

  group('numbering messages', () {
    setUp(() {
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');
    });

    test('a later message gets a higher number', () async {
      // The one property the whole sync rests on: "a higher number arrived
      // later". Break it and every incremental sync silently misses mail.
      server
        ..message('f-inbox', id: 'm1', subject: 'First', minutesAgo: 30)
        ..message('f-inbox', id: 'm2', subject: 'Second', minutesAgo: 20)
        ..message('f-inbox', id: 'm3', subject: 'Third', minutesAgo: 10);

      final headers = await transport.fetchHeadersFromUid('Inbox', 1);
      final bySubject = {for (final h in headers) h.subject: h.uid};

      expect(bySubject['First']!, lessThan(bySubject['Second']!));
      expect(bySubject['Second']!, lessThan(bySubject['Third']!));
    });

    test('the same message keeps its number across syncs', () async {
      // A number that moved would point every cached row at the wrong
      // message.
      server.message('f-inbox', id: 'm1', subject: 'First', minutesAgo: 10);

      final first = await transport.fetchHeadersFromUid('Inbox', 1);
      final second = await transport.fetchHeadersFromUid('Inbox', 1);

      expect(second.single.uid, first.single.uid);
    });

    test('new mail numbers above what is already there', () async {
      server.message('f-inbox', id: 'm1', subject: 'First', minutesAgo: 30);
      final first = await transport.fetchHeadersFromUid('Inbox', 1);

      server.message('f-inbox', id: 'm2', subject: 'Second', minutesAgo: 5);
      final next = await transport.fetchHeadersFromUid(
        'Inbox',
        first.single.uid + 1,
      );

      expect(next.single.subject, 'Second');
      expect(next.single.uid, greaterThan(first.single.uid));
    });

    test('a number is never handed out twice, even after a delete', () async {
      // Reusing one would make a stale cache row resolve to a different
      // message, which is exactly what UIDVALIDITY exists to prevent.
      server.message('f-inbox', id: 'm1', subject: 'First', minutesAgo: 30);
      final first = await transport.fetchHeadersFromUid('Inbox', 1);

      await ids.forgetMoved('acct-1', 'Inbox', [first.single.uid]);
      server
        ..remove('m1')
        ..message('f-inbox', id: 'm2', subject: 'Second', minutesAgo: 5);

      final next = await transport.fetchHeadersFromUid('Inbox', 1);

      expect(next.single.uid, isNot(first.single.uid));
    });

    test('uidNext is above every number handed out', () async {
      server
        ..message('f-inbox', id: 'm1', subject: 'First', minutesAgo: 30)
        ..message('f-inbox', id: 'm2', subject: 'Second', minutesAgo: 20);
      final headers = await transport.fetchHeadersFromUid('Inbox', 1);

      final status = await transport.selectFolder('Inbox');

      expect(
        status.uidNext,
        greaterThan(headers.map((h) => h.uid).reduce((a, b) => a > b ? a : b)),
      );
    });
  });

  group('reading', () {
    setUp(() {
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');
    });

    test('a sequence range reads oldest first, as IMAP numbers them',
        () async {
      // Graph pages newest first. Getting this backwards would fill the cache
      // with the newest messages labelled as the oldest.
      for (var i = 1; i <= 5; i++) {
        server.message('f-inbox', id: 'm$i', subject: 'M$i', minutesAgo: 60 - i * 5);
      }

      final headers = await transport.fetchHeadersBySequence('Inbox', 1, 3);

      expect(headers.map((h) => h.subject), ['M1', 'M2', 'M3']);
    });

    test('headers carry what the list row shows', () async {
      server.message(
        'f-inbox',
        id: 'm1',
        subject: 'Lunch?',
        from: 'dana@example.com',
        fromName: 'Dana Levi',
        minutesAgo: 5,
        isRead: false,
        isFlagged: true,
        hasAttachments: true,
      );

      final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;

      expect(header.subject, 'Lunch?');
      expect(header.from.email, 'dana@example.com');
      expect(header.from.name, 'Dana Levi');
      expect(header.isRead, isFalse);
      expect(header.isFlagged, isTrue);
      expect(header.hasAttachments, isTrue);
    });

    test('a flag marked complete still reads as flagged', () async {
      // Outlook shows a completed follow-up with the flag still on, so
      // treating only "flagged" as flagged would lose it on sync.
      server.message('f-inbox', id: 'm1', subject: 'Done', minutesAgo: 5,
          flagStatus: 'complete');

      final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;

      expect(header.isFlagged, isTrue);
    });

    test('the body comes back as HTML when Graph sends HTML', () async {
      server.message('f-inbox', id: 'm1', subject: 'Hi', minutesAgo: 5);
      final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;
      server.bodies['m1'] = ('html', '<p>Hello</p>');

      final body = await transport.fetchBody('Inbox', header.uid);

      expect(body.html, '<p>Hello</p>');
    });

    test('flags for a range come back for the whole range', () async {
      // No CONDSTORE equivalent, so the caller compares everything.
      server
        ..message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 30)
        ..message('f-inbox', id: 'm2', subject: 'B', minutesAgo: 20,
            isRead: true);
      final headers = await transport.fetchHeadersFromUid('Inbox', 1);
      final lowest = headers.map((h) => h.uid).reduce((a, b) => a < b ? a : b);
      final highest = headers.map((h) => h.uid).reduce((a, b) => a > b ? a : b);

      final flags = await transport.fetchFlags('Inbox', lowest, highest);

      expect(flags, hasLength(2));
      expect(flags.firstWhere((f) => f.uid == highest).isRead, isTrue);
    });

    test('a message deleted elsewhere drops out of existingUids', () async {
      server
        ..message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 30)
        ..message('f-inbox', id: 'm2', subject: 'B', minutesAgo: 20);
      final headers = await transport.fetchHeadersFromUid('Inbox', 1);
      final gone = headers.firstWhere((h) => h.subject == 'A').uid;
      final kept = headers.firstWhere((h) => h.subject == 'B').uid;

      server.remove('m1');
      final existing = await transport.existingUids('Inbox', gone, kept);

      expect(existing, {kept});
    });
  });

  group('writing', () {
    setUp(() {
      server
        ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
        ..folder(id: 'f-arch', name: 'Archive', wellKnown: 'archive');
    });

    test('marking read patches the message', () async {
      server.message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5);
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;

      await transport.storeFlag('Inbox', uids: [uid],
          flag: MessageFlag.seen, set: true);

      expect(server.messages['m1']!['isRead'], isTrue);
    });

    test('deleting removes it, because Graph has no two-step expunge',
        () async {
      server.message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5);
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;

      await transport.storeFlag('Inbox', uids: [uid],
          flag: MessageFlag.deleted, set: true);
      await transport.expunge('Inbox');

      expect(server.messages.containsKey('m1'), isFalse);
    });

    test('a move takes the new id Graph issues', () async {
      // Graph reissues the id on a move and the old one stops resolving at
      // once. Keeping the old one would leave the destination unreadable
      // until a full resync.
      server.message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5);
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;

      final moved = await transport.moveMessages('Inbox', [uid], 'Archive');

      expect(moved, hasLength(1));
      final inArchive = await transport.fetchHeadersFromUid('Archive', 1);
      expect(inArchive.single.subject, 'A');
      expect(inArchive.single.uid, moved!.single);
    });

    test('marking all read skips what is already read', () async {
      // A second "mark all read" over a large folder would otherwise be
      // thousands of pointless writes.
      server
        ..message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 30,
            isRead: true)
        ..message('f-inbox', id: 'm2', subject: 'B', minutesAgo: 20);

      await transport.storeFlagOnAll('Inbox',
          flag: MessageFlag.seen, set: true);

      expect(server.patched, ['m2']);
    });
  });

  test('there is no push, so waiting reports nothing happened', () async {
    // Graph's push needs a public HTTPS endpoint a tablet cannot have. The
    // caller treats false as "time to sync", which degrades to a poll rather
    // than an error.
    server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');

    final changed = await transport.awaitChanges(
      'Inbox',
      timeout: const Duration(milliseconds: 1),
    );

    expect(changed, isFalse);
  });
}

/// A Graph mailbox in memory, answering the endpoints the transport uses.
class _FakeGraph {
  final Map<String, Map<String, Object?>> folders = {};
  final Map<String, Map<String, Object?>> messages = {};
  final Map<String, (String, String)> bodies = {};
  final List<String> patched = [];

  /// Refuse any folder $select, to exercise the error path.
  bool rejectFolderSelect = false;

  /// How many batch requests were made. One per folder listing, not one per
  /// well-known name, is the whole point of batching them.
  int batches = 0;

  /// Answer the next [throttle] requests with a 429 and a Retry-After.
  int throttle = 0;

  /// Which folder id answers to which well-known name, as Graph's
  /// /me/mailFolders/inbox shortcut does.
  final Map<String, String> wellKnown = {};

  static const knownNames = [
    'inbox',
    'drafts',
    'sentitems',
    'deleteditems',
    'junkemail',
    'archive',
  ];

  /// Exactly the v1.0 mailFolder properties. Anything else is a 400, as Graph
  /// itself does.
  static const _folderProperties = {
    'id',
    'displayName',
    'parentFolderId',
    'childFolderCount',
    'totalItemCount',
    'unreadItemCount',
    'isHidden',
  };

  void reset() {
    folders.clear();
    messages.clear();
    wellKnown.clear();
  }

  void folder({
    required String id,
    required String name,
    String? wellKnown,
    String? parent,
    int children = 0,
    int total = 0,
    int unread = 0,
  }) {
    folders[id] = {
      'id': id,
      'displayName': name,
      'parentFolderId': ?parent,
      'childFolderCount': children,
      'totalItemCount': total,
      'unreadItemCount': unread,
    };
    if (wellKnown != null) this.wellKnown[wellKnown] = id;
  }

  void message(
    String folderId, {
    required String id,
    required String subject,
    required int minutesAgo,
    String from = 'someone@example.com',
    String? fromName,
    bool isRead = false,
    bool isFlagged = false,
    bool hasAttachments = false,
    String? flagStatus,
  }) {
    messages[id] = {
      'id': id,
      '_folder': folderId,
      'subject': subject,
      'from': {
        'emailAddress': {'address': from, 'name': ?fromName},
      },
      'toRecipients': const [],
      'receivedDateTime': DateTime.utc(2026, 9, 18, 12)
          .subtract(Duration(minutes: minutesAgo))
          .toIso8601String(),
      'isRead': isRead,
      'flag': {
        'flagStatus': flagStatus ?? (isFlagged ? 'flagged' : 'notFlagged'),
      },
      'hasAttachments': hasAttachments,
      'bodyPreview': '',
    };
    _recount(folderId);
  }

  void remove(String id) {
    final folderId = messages.remove(id)?['_folder'];
    if (folderId is String) _recount(folderId);
  }

  void _recount(String folderId) {
    final folder = folders[folderId];
    if (folder == null) return;
    final inFolder =
        messages.values.where((m) => m['_folder'] == folderId).toList();
    folder['totalItemCount'] = inFolder.length;
    folder['unreadItemCount'] =
        inFolder.where((m) => m['isRead'] != true).length;
  }

  Future<http.Response> handle(http.Request request) async {
    if (throttle > 0) {
      throttle--;
      return http.Response(
        jsonEncode({
          'error': {'code': 'TooManyRequests', 'message': 'Slow down.'},
        }),
        429,
        headers: const {
          'content-type': 'application/json',
          'retry-after': '1',
        },
      );
    }

    final path = Uri.decodeComponent(request.url.path);
    final query = request.url.queryParameters;

    http.Response json(Object? body) => http.Response(
          jsonEncode(body),
          200,
          headers: const {'content-type': 'application/json'},
        );

    // A property v1.0 does not have. Graph answers a bad $select with a bare
    // BadRequest and nothing loads at all, which is exactly what happened
    // with wellKnownName: it exists only in the beta API.
    final select = query[r'$select'] ?? '';
    if (path.contains('/mailFolders') && !path.endsWith('/messages')) {
      for (final asked in select.split(',')) {
        if (asked.isEmpty) continue;
        if (_folderProperties.contains(asked) && !rejectFolderSelect) continue;
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'BadRequest',
              'message': "Could not find a property named '$asked' on type "
                  "'microsoft.graph.mailFolder'.",
            },
          }),
          400,
          headers: const {'content-type': 'application/json'},
        );
      }
    }

    // The batch that resolves every well-known name in one request.
    if (request.method == 'POST' && path.endsWith(r'/$batch')) {
      batches++;
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final requests = body['requests'] as List;
      return json({
        'responses': [
          for (final r in requests)
            if (wellKnown.containsKey((r as Map)['id']))
              {
                'id': r['id'],
                'status': 200,
                'body': {'id': wellKnown[r['id']]},
              }
            else
              {'id': (r)['id'], 'status': 404, 'body': {}},
        ],
      });
    }

    // Addressing a folder by its well-known name rather than its id, which is
    // how the special folders are identified without the beta property.
    if (request.method == 'GET' && path.contains('/me/mailFolders/')) {
      final name = path.split('/me/mailFolders/').last;
      if (wellKnown.containsKey(name)) return json({'id': wellKnown[name]});
      if (knownNames.contains(name)) return http.Response('{}', 404);
    }

    // Folder listings, top level and children.
    if (request.method == 'GET' && path.endsWith('/me/mailFolders')) {
      return json({
        'value': [
          for (final f in folders.values)
            if (f['parentFolderId'] == null) f,
        ],
      });
    }
    if (request.method == 'GET' && path.endsWith('/childFolders')) {
      final parent = _folderIdIn(path);
      return json({
        'value': [
          for (final f in folders.values)
            if (f['parentFolderId'] == parent) f,
        ],
      });
    }

    // A folder's messages.
    if (request.method == 'GET' && path.endsWith('/messages')) {
      final folderId = _folderIdIn(path);
      final inFolder = messages.values
          .where((m) => m['_folder'] == folderId)
          .toList()
        ..sort((a, b) => '${b['receivedDateTime']}'
            .compareTo('${a['receivedDateTime']}'));
      final skip = int.tryParse(query['\$skip'] ?? '0') ?? 0;
      final top = int.tryParse(query['\$top'] ?? '50') ?? 50;
      final page = inFolder.skip(skip).take(top).toList();
      return json({'value': page});
    }

    // One folder.
    if (request.method == 'GET' && path.contains('/me/mailFolders/')) {
      final folder = folders[_folderIdIn(path)];
      if (folder == null) return http.Response('{}', 404);
      return json(folder);
    }

    // One message, headers or body.
    if (request.method == 'GET' && path.contains('/me/messages/')) {
      final id = path.split('/me/messages/').last;
      final message = messages[id];
      if (message == null) return http.Response('{}', 404);
      if ((query['\$select'] ?? '').contains('body')) {
        final body = bodies[id] ?? ('text', '');
        return json({
          'body': {'contentType': body.$1, 'content': body.$2},
          'hasAttachments': message['hasAttachments'],
        });
      }
      return json(message);
    }

    if (request.method == 'PATCH') {
      final id = path.split('/me/messages/').last;
      final message = messages[id];
      if (message == null) return http.Response('{}', 404);
      patched.add(id);
      final body = jsonDecode(request.body) as Map<String, Object?>;
      message.addAll(body);
      _recount('${message['_folder']}');
      return json(message);
    }

    if (request.method == 'DELETE') {
      remove(path.split('/me/messages/').last);
      return http.Response('', 204);
    }

    if (request.method == 'POST' && path.endsWith('/move')) {
      final id = path.split('/me/messages/').last.replaceAll('/move', '');
      final message = messages.remove(id);
      if (message == null) return http.Response('{}', 404);
      final destination =
          (jsonDecode(request.body) as Map)['destinationId'] as String;
      // Graph reissues the id on a move. Doing the same here is the point of
      // the test that follows it.
      final newId = '$id-moved';
      message['id'] = newId;
      message['_folder'] = destination;
      messages[newId] = message;
      _recount(destination);
      return json(message);
    }

    return http.Response('{"error":{"code":"NotHandled"}}', 400);
  }

  static String _folderIdIn(String path) {
    final after = path.split('/me/mailFolders/').last;
    return after.split('/').first;
  }
}
