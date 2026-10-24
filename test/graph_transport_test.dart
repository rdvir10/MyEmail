import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/folder_sync.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/graph/graph_id_map.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/graph/graph_transport.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/imap/imap_transport.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/error_report.dart' show Retryable;
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_credentials.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/message_move.dart';

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

    test('a folder whose own name has a slash keeps its place', () async {
      // Outlook allows "AP/AR", and a mailbox at work usually has one.
      // Joined into the path as-is it would fake a level: the folder would
      // show under a parent called AP, or at the top level called AR.
      server
        ..folder(id: 'f-fin', name: 'Finance', children: 1)
        ..folder(id: 'f-apar', name: 'AP/AR', parent: 'f-fin')
        ..folder(id: 'f-ap', name: 'AP');

      final folders = await transport.listFolders();
      final paths = folders.map((f) => f.path).toList();

      expect(paths, contains('Finance/AP∕AR'));
      expect(paths, isNot(contains('Finance/AP/AR')),
          reason: 'one folder, not two levels');
      expect(MailFolder.nameFor('Finance/AP∕AR'), 'AP∕AR',
          reason: 'the name reads as the person wrote it');
    });

    test('a name with a slash goes back to Graph with the slash', () async {
      // The path carries a look-alike in its place. Sending that as the name
      // saved "AP/AR" as something that matched nothing on the web.
      server
        ..folder(id: 'f-fin', name: 'Finance', children: 1)
        ..folder(id: 'f-apar', name: 'AP/AR', parent: 'f-fin');
      await transport.listFolders();

      await transport.renameFolder('Finance/AP∕AR', 'Finance/AP∕AP');

      expect(server.folders['f-apar']!['displayName'], 'AP/AP');
    });

    test('so does a new folder with one', () async {
      final sent = <Object?>[];
      final creating = GraphTransport(
        accountId: 'acct-1',
        idMap: ids,
        api: GraphMailApi(
          accessToken: ({bool force = false}) async => 'token',
          httpClient: http_testing.MockClient((request) async {
            sent.add(jsonDecode(request.body)['displayName']);
            return http.Response(
              jsonEncode({'id': 'f-new', 'displayName': 'AP/AR'}),
              201,
            );
          }),
        ),
      );

      await creating.createFolder('AP∕AR');

      expect(sent, ['AP/AR']);
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

    test('a throttled lookup inside the batch does not demote the Inbox',
        () async {
      // Graph throttles the requests in a batch one by one and answers the
      // batch itself with a 200. Read as "no such folder", the Inbox was
      // listed as an ordinary folder.
      server
        ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
        ..folder(id: 'f-trash', name: 'Deleted Items', wellKnown: 'deleteditems')
        ..throttledInBatch['inbox'] = 1;

      final folders = await patientTransport.listFolders();

      expect(folders.firstWhere((f) => f.path == 'Inbox').role,
          FolderRole.inbox);
      expect(folders.firstWhere((f) => f.path == 'Deleted Items').role,
          FolderRole.deleted);
      expect(server.batches, 2, reason: 'only the throttled name again');
    });

    test('and one that stays throttled fails the listing instead', () async {
      // A folder list with no Inbox in it is worse than no new list: it is
      // stored, and read as the truth until the next one.
      server
        ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
        ..throttledInBatch['inbox'] = 99;

      await expectLater(
        patientTransport.listFolders(),
        throwsA(isA<ConnectionFailed>()),
      );
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

    test('a search names the part of the message asked for, in the words '
        'Graph takes', () {
      expect(GraphMailApi.searchString('invoice', SearchField.all), 'invoice');
      expect(GraphMailApi.searchString('dana levi', SearchField.from),
          'from:dana from:levi');
      expect(GraphMailApi.searchString(' acme ', SearchField.subject),
          'subject:acme');
      expect(GraphMailApi.searchString('pay "now"', SearchField.body),
          r'body:pay body:\"now\"');
      expect(GraphMailApi.searchString('report.pdf', SearchField.attachment),
          'attachment:report.pdf');
    });

    test('every list of messages asks what was last done to each, at once',
        () async {
      // Exchange says a message was replied to or forwarded in a property
      // Graph hands over only when asked. Asked in the same request as the
      // rows, it costs nothing; asked message by message it would be a
      // request for every row of every folder.
      final asked = <Uri>[];
      final api = GraphMailApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          asked.add(request.url);
          return http.Response(jsonEncode({'id': 'm-1', 'value': []}), 200);
        }),
      );

      await api.messages('f-inbox');
      await api.message('m-1');
      await api.search('f-inbox', 'invoice');

      expect(asked, hasLength(3), reason: 'one request each, no more');
      for (final uri in asked) {
        expect(uri.queryParameters[r'$select'], GraphMailApi.headerFields);
        expect(
          uri.queryParameters[r'$expand'],
          r"singleValueExtendedProperties($filter=id eq 'Integer 0x1081' "
          r"or id eq 'Integer 0x1080' or id eq 'Integer 0x0E08')",
        );
      }
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
    /// One meeting request, in the two forms it travels in: the calendar
    /// part of a message Exchange typed as a meeting, and the same event
    /// as a file somebody attached.
    const ics = 'BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\n'
        'UID:u-1\r\nSUMMARY:Review\r\nDTSTART:20260923T184500Z\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n';
    const invitation = 'From: dana@example.com\r\n'
        'Subject: Review\r\n'
        'Content-Type: multipart/alternative; boundary="b"\r\n'
        '\r\n'
        '--b\r\n'
        'Content-Type: text/plain\r\n'
        '\r\n'
        'Please come.\r\n'
        '--b\r\n'
        'Content-Type: text/calendar; method=REQUEST\r\n'
        '\r\n'
        '$ics'
        '--b--\r\n';

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

    test('a list row carries its preview, which Graph gives for free',
        () async {
      // The one real difference between a Microsoft account and a Gmail one
      // here: Graph sends bodyPreview with every row, IMAP sends nothing of
      // the sort, and this was being thrown away. Without it a work inbox
      // shows a wall of subjects with no second line under any of them.
      server.message(
        'f-inbox',
        id: 'm1',
        subject: 'Our call',
        minutesAgo: 5,
        preview: 'Hi Ron, confirming Thursday at ten.',
      );

      final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;

      expect(header.preview, 'Hi Ron, confirming Thursday at ten.');
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

    test('headers carry Reply-To, and it is asked for', () async {
      // Without it a reply to a no-reply sender went to the no-reply.
      expect(GraphMailApi.headerFields.split(','), contains('replyTo'));
      server
        ..message('f-inbox', id: 'm1', subject: 'Ticket', minutesAgo: 5,
            from: 'noreply@vendor.example',
            replyTo: ['ticket-4411@vendor.example'])
        ..message('f-inbox', id: 'm2', subject: 'Lunch?', minutesAgo: 4,
            from: 'dana@example.com', replyTo: ['dana@example.com']);

      final headers = await transport.fetchHeadersFromUid('Inbox', 1);
      final byId = {for (final h in headers) h.subject: h};

      expect(byId['Ticket']!.replyTo.single.email,
          'ticket-4411@vendor.example');
      expect(byId['Lunch?']!.replyTo, isEmpty,
          reason: 'naming only the sender is the same as not saying');
    });

    test('a flag marked complete is done with, and no longer flagged',
        () async {
      // Follow Up's Mark complete, here or in Outlook: Outlook's Flagged
      // list leaves it out, and so does this app's.
      server.message('f-inbox', id: 'm1', subject: 'Done', minutesAgo: 5,
          flagStatus: 'complete');

      final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;

      expect(header.isFlagged, isFalse);
    });

    test('what was last done to a message reads as replied or forwarded',
        () async {
      // Exchange keeps one last verb rather than a flag for each: 102 a
      // reply, 103 a reply to all, 104 a forward. Anything else Outlook
      // records, a meeting accepted say, is neither, and so is nothing.
      server
        ..message('f-inbox', id: 'm1', subject: 'Replied', minutesAgo: 50,
            lastVerb: 102)
        ..message('f-inbox', id: 'm2', subject: 'Replied to all',
            minutesAgo: 40, lastVerb: 103)
        ..message('f-inbox', id: 'm3', subject: 'Forwarded', minutesAgo: 30,
            lastVerb: 104)
        ..message('f-inbox', id: 'm4', subject: 'Accepted', minutesAgo: 20,
            lastVerb: 512)
        ..message('f-inbox', id: 'm5', subject: 'Untouched', minutesAgo: 10);

      final headers = await transport.fetchHeadersFromUid('Inbox', 1);

      final marks = {
        for (final h in headers) h.subject: (h.isAnswered, h.isForwarded),
      };
      expect(marks, {
        'Replied': (true, false),
        'Replied to all': (true, false),
        'Forwarded': (false, true),
        'Accepted': (false, false),
        'Untouched': (false, false),
      });

      // The flags a sync reads again say the same.
      final uid = {for (final h in headers) h.subject: h.uid};
      final flags = {
        for (final f in await transport.fetchFlags('Inbox', 1, 5))
          f.uid: (f.isAnswered, f.isForwarded),
      };
      expect(flags[uid['Replied to all']], (true, false));
      expect(flags[uid['Forwarded']], (false, true));
      expect(flags[uid['Untouched']], (false, false));

      // And so does a search hit read on its own.
      final hit =
          await transport.fetchHeadersByUids('Inbox', [uid['Replied']!]);
      expect(hit.single.isAnswered, isTrue);
    });

    test('the conversation Exchange keeps comes with the header', () async {
      server
        ..message('f-inbox', id: 'm1', subject: 'SEO', minutesAgo: 30,
            conversationId: 'AAQk-1')
        ..message('f-inbox', id: 'm2', subject: 'SEO', minutesAgo: 20,
            conversationId: 'AAQk-2')
        ..message('f-inbox', id: 'm3', subject: 'Re: SEO', minutesAgo: 10,
            conversationId: 'AAQk-1');

      final headers = await transport.fetchHeadersFromUid('Inbox', 1);

      expect(
        {for (final h in headers) h.subject: h.conversationId},
        {'SEO': anyOf('AAQk-1', 'AAQk-2'), 'Re: SEO': 'AAQk-1'},
      );
      expect(headers.map((h) => h.conversationId).toSet(),
          {'AAQk-1', 'AAQk-2'});
    });

    test('a forward or reply Outlook marked by its icon alone reads too, '
        'and the verb wins where both are there', () async {
      // Outlook on a desktop sets the icon it draws its arrow from (261 a
      // reply, 262 a forward) and, for a forward made there, not the last
      // verb: Ron's two forwards had no verb on the server and no arrow
      // here. The verb says more when it is there, and a verb of a forward
      // beside an icon of a reply is a forward.
      server
        ..message('f-inbox', id: 'm1', subject: 'Icon forward', minutesAgo: 50,
            iconIndex: 262)
        ..message('f-inbox', id: 'm2', subject: 'Icon reply', minutesAgo: 40,
            iconIndex: 261)
        ..message('f-inbox', id: 'm3', subject: 'Both', minutesAgo: 30,
            lastVerb: 104, iconIndex: 261)
        ..message('f-inbox', id: 'm4', subject: 'Other icon', minutesAgo: 20,
            iconIndex: 256)
        ..message('f-inbox', id: 'm5', subject: 'Verb, other icon',
            minutesAgo: 10, lastVerb: 102, iconIndex: 256);

      final headers = await transport.fetchHeadersFromUid('Inbox', 1);

      final marks = {
        for (final h in headers) h.subject: (h.isAnswered, h.isForwarded),
      };
      expect(marks, {
        'Icon forward': (false, true),
        'Icon reply': (true, false),
        'Both': (false, true),
        'Other icon': (false, false),
        'Verb, other icon': (true, false),
      });

      final uid = {for (final h in headers) h.subject: h.uid};
      final flags = {
        for (final f in await transport.fetchFlags('Inbox', 1, 5))
          f.uid: (f.isAnswered, f.isForwarded),
      };
      expect(flags[uid['Icon forward']], (false, true));
      expect(flags[uid['Icon reply']], (true, false));
    });

    test('the body comes back as HTML when Graph sends HTML', () async {
      server.message('f-inbox', id: 'm1', subject: 'Hi', minutesAgo: 5);
      final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;
      server.bodies['m1'] = ('html', '<p>Hello</p>');

      final body = await transport.fetchBody('Inbox', header.uid);

      expect(body.html, '<p>Hello</p>');
    });

    test('a picture the body shows says which one it is', () async {
      // The listing cannot select contentId, so a pasted screenshot could
      // not be matched to the cid: link naming it and never showed.
      server
        ..message('f-inbox',
            id: 'm1', subject: 'Look', minutesAgo: 5, hasAttachments: true)
        ..attachments['m1'] = [
          ('a-1', 'image001.png', 'image/png', 'png bytes'),
          ('a-2', 'report.pdf', 'application/pdf', 'pdf bytes'),
        ]
        ..contentIds['a-1'] = '<image001.png@01DA>';
      final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;

      final files = await transport.listAttachments('Inbox', header.uid);

      expect(files.first.contentId, 'image001.png@01DA');
      expect(files.first.isInline, isTrue);
      expect(files.last.contentId, isNull);
      expect(server.contentIdLookups, ['a-1'],
          reason: 'a file nobody draws needs no second request');
      expect(server.fetchedAttachments, isEmpty);
      expect(server.wholeAttachmentLookups, isEmpty,
          reason: 'the cast answered, so nothing is asked twice');
    });

    test('where the cast is refused, the picture is still named', () async {
      // Signature pictures on a work mailbox showed as dashed boxes: the
      // name that matches them to the body came from the cast alone, and a
      // refusal was swallowed.
      server
        ..fileCastRefused = true
        ..message('f-inbox',
            id: 'm1', subject: 'Look', minutesAgo: 5, hasAttachments: true)
        ..attachments['m1'] = [
          ('a-1', 'image.png', 'image/png', 'png bytes'),
        ]
        ..contentIds['a-1'] = '<ii_m1abc0>';
      final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;

      final files = await transport.listAttachments('Inbox', header.uid);

      expect(files.single.contentId, 'ii_m1abc0');
      expect(server.wholeAttachmentLookups, ['a-1']);
    });

    test('but a large picture is not fetched whole just for its name',
        () async {
      server
        ..fileCastRefused = true
        ..message('f-inbox',
            id: 'm1', subject: 'Look', minutesAgo: 5, hasAttachments: true)
        ..attachments['m1'] = [
          ('a-1', 'photo.jpg', 'image/jpeg', 'x' * (1024 * 1024 + 1)),
        ]
        ..contentIds['a-1'] = '<photo@x>';
      final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;

      final files = await transport.listAttachments('Inbox', header.uid);

      expect(files.single.contentId, isNull);
      expect(server.wholeAttachmentLookups, isEmpty);
    });

    test('an email dragged into the message is listed as one', () async {
      // Outlook items come with their subject for a name and no type, and
      // were offered to Android as unknown data: Google Pay, the launcher.
      server
        ..message('f-inbox',
            id: 'm1', subject: 'Memo', minutesAgo: 5, hasAttachments: true)
        ..attachments['m1'] = [
          ('a-1', 'Extrusion shape pictures', '', 'the item as MIME'),
          ('a-2', 'Memo.docx', 'application/octet-stream', 'docx bytes'),
        ]
        ..itemAttachments.add('a-1');
      final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;

      final files = await transport.listAttachments('Inbox', header.uid);

      expect(files.first.name, 'Extrusion shape pictures.eml');
      expect(files.first.mimeType, 'message/rfc822');
      expect(files.first.openAs, 'message/rfc822');
      expect(files.last.name, 'Memo.docx', reason: 'a file stays as it was');
    });

    group('a meeting request', () {
      Future<MailBody> fetch() async {
        final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;
        return transport.fetchBody('Inbox', header.uid);
      }

      test('a title in Hebrew comes through as Hebrew', () async {
        // The message now comes over as bytes. Its calendar part is 8-bit
        // UTF-8, and has to be read as that and not one byte per letter.
        server
          ..message('f-inbox', id: 'm1', subject: 'Review', minutesAgo: 5)
          ..bodies['m1'] = ('html', '<p>Please come.</p>')
          ..mimes['m1'] = invitation
              .replaceFirst('SUMMARY:Review', 'SUMMARY:סקירה רבעונית')
              .replaceFirst(
                'Content-Type: text/calendar; method=REQUEST\r\n',
                'Content-Type: text/calendar; method=REQUEST; charset=utf-8\r\n'
                    'Content-Transfer-Encoding: 8bit\r\n',
              )
          ..eventMessages.add('m1');

        final body = await fetch();

        expect(CalendarInvite.parse(body.calendar!)!.summary, 'סקירה רבעונית');
      });

      test('brings its invitation with it', () async {
        server
          ..message('f-inbox', id: 'm1', subject: 'Review', minutesAgo: 5)
          ..bodies['m1'] = ('html', '<p>Please come.</p>')
          ..mimes['m1'] = invitation
          ..eventMessages.add('m1');

        final body = await fetch();

        expect(body.calendar, contains('BEGIN:VEVENT'));
        expect(CalendarInvite.parse(body.calendar!)!.summary, 'Review');
      });

      test('still does when the type is left out of the answer', () async {
        // What a mailbox was doing when invitations stopped showing a card:
        // the selected response carried no @odata.type, so the message read
        // as an ordinary one and its calendar part was never fetched.
        server
          ..message('f-inbox', id: 'm1', subject: 'Review', minutesAgo: 5)
          ..bodies['m1'] = ('html', '<p>Please come.</p>')
          ..mimes['m1'] = invitation
          ..eventMessages.add('m1')
          ..odataTypeOmitted = true;

        final body = await fetch();

        expect(body.calendar, contains('BEGIN:VEVENT'),
            reason: 'the cast names it a meeting request instead');
      });

      test('a mailbox that refuses the cast still shows the message',
          () async {
        server
          ..message('f-inbox', id: 'm1', subject: 'Review', minutesAgo: 5)
          ..bodies['m1'] = ('html', '<p>Please come.</p>')
          ..mimes['m1'] = invitation
          ..eventMessages.add('m1')
          ..castSelectRefused = true;

        final body = await fetch();

        expect(body.html, '<p>Please come.</p>', reason: 'asked again plainly');
        expect(body.calendar, contains('BEGIN:VEVENT'),
            reason: '@odata.type still says what it is');
      });

      // Graph types an invitation eventMessageRequest and an answer, or a
      // new time proposed, eventMessageResponse. Read as ending in
      // ".eventMessage", only a cancellation was known by its type, and
      // with the cast refused the others showed no card.
      for (final (kind, type) in const [
        ('an invitation', '#microsoft.graph.eventMessageRequest'),
        ('an answer', '#microsoft.graph.eventMessageResponse'),
      ]) {
        test('$kind is meeting mail by its own type too', () async {
          server
            ..message('f-inbox', id: 'm1', subject: 'Review', minutesAgo: 5)
            ..bodies['m1'] = ('html', '<p>Please come.</p>')
            ..mimes['m1'] = invitation
            ..eventMessages.add('m1')
            ..eventMessageType = type
            ..castSelectRefused = true;

          final body = await fetch();

          expect(body.calendar, contains('BEGIN:VEVENT'));
        });
      }

      test('an ordinary message fetches no MIME at all', () async {
        server
          ..message('f-inbox', id: 'm1', subject: 'Hello', minutesAgo: 5)
          ..bodies['m1'] = ('html', '<p>Hello</p>');

        final body = await fetch();

        expect(body.calendar, isNull);
      });

      test('one attached to an ordinary message is found too', () async {
        // Not every meeting is booked in Outlook. A Zoom or Webex booking
        // passed on by whoever made it arrives as a file on a message
        // Exchange never typed as a meeting request, and often with the
        // media type of anything at all.
        server
          ..message('f-inbox',
              id: 'm1',
              subject: 'Our call',
              minutesAgo: 5,
              hasAttachments: true)
          ..bodies['m1'] = ('html', '<p>See you then.</p>')
          ..attachments['m1'] = [
            ('a-1', 'meeting.ics', 'application/octet-stream', ics),
          ];

        final body = await fetch();

        expect(body.calendar, contains('BEGIN:VEVENT'));
        expect(CalendarInvite.parse(body.calendar!)!.summary, 'Review');
      });

      /// Opened twice through the cache, as the reading pane opens it: what
      /// the first open was given, or what it threw, and then the second,
      /// which must not be handed what the first would have kept.
      Future<(Object, MailBody)> openTwice() async {
        final cache = MemoryCacheStore();
        final sync =
            FolderSync(transport: transport, store: cache, accountId: 'acct-1');
        await sync.sync('Inbox');
        final uid = (await cache.readMessages('acct-1', 'Inbox',
                offset: 0, limit: 10))
            .single
            .uid;
        Object first;
        try {
          first = await sync.body('Inbox', uid);
        } on ConnectionFailed catch (e) {
          first = e;
        }
        return (first, await sync.body('Inbox', uid));
      }

      /// The message to read, without its card for now.
      Matcher readableAlone(String html) => isA<MailBody>()
          .having((b) => b.html, 'html', html)
          .having((b) => b.calendar, 'calendar', isNull)
          .having((b) => b.calendarPending, 'calendarPending', isTrue);

      test('an invitation that would not download is asked for again',
          () async {
        // A weak signal or a throttle on the MIME was taken for a message
        // with no invitation, and cached so: the Accept and Decline card
        // never came back for it. Failing the whole body instead left a
        // meeting request with a large deck attached unreadable on a weak
        // signal.
        server
          ..message('f-inbox', id: 'm1', subject: 'Review', minutesAgo: 5)
          ..bodies['m1'] = ('html', '<p>Please come.</p>')
          ..mimes['m1'] = invitation
          ..eventMessages.add('m1')
          ..mimeAnswers.add(500);

        final (first, second) = await openTwice();

        expect(first, readableAlone('<p>Please come.</p>'));
        expect(second.calendar, contains('BEGIN:VEVENT'));
      });

      test('so is one on a message whose files would not list', () async {
        server
          ..message('f-inbox',
              id: 'm1',
              subject: 'Our call',
              minutesAgo: 5,
              hasAttachments: true)
          ..bodies['m1'] = ('html', '<p>See you then.</p>')
          ..attachments['m1'] = [
            ('a-1', 'meeting.ics', 'application/octet-stream', ics),
          ]
          // Twice: the sync asks the files' names for the row first, and
          // the body asks for the files themselves after.
          ..attachmentListingAnswers.addAll([500, 500]);

        final (first, second) = await openTwice();

        expect(first, readableAlone('<p>See you then.</p>'));
        expect(second.calendar, contains('BEGIN:VEVENT'));
      });

      test('and so is one whose first question failed for a moment',
          () async {
        // Asked again without the cast, the answer may not say what type
        // the message is, and the MIME with the invitation was never asked
        // for at all.
        server
          ..message('f-inbox', id: 'm1', subject: 'Review', minutesAgo: 5)
          ..bodies['m1'] = ('html', '<p>Please come.</p>')
          ..mimes['m1'] = invitation
          ..eventMessages.add('m1')
          ..odataTypeOmitted = true
          ..castSelectAnswers.add(500);

        final (first, second) = await openTwice();

        expect(first, isA<ConnectionFailed>(),
            reason: 'there was no body to show');
        expect(second.calendar, contains('BEGIN:VEVENT'));
      });

      test('but MIME Microsoft refuses still leaves the message to read',
          () async {
        server
          ..message('f-inbox', id: 'm1', subject: 'Review', minutesAgo: 5)
          ..bodies['m1'] = ('html', '<p>Please come.</p>')
          ..mimes['m1'] = invitation
          ..eventMessages.add('m1')
          ..mimeAnswers.add(400);

        final body = await fetch();

        expect(body.html, '<p>Please come.</p>');
        expect(body.calendar, isNull);
      });

      test('a message with ordinary files downloads none of them', () async {
        server
          ..message('f-inbox',
              id: 'm1',
              subject: 'Report',
              minutesAgo: 5,
              hasAttachments: true)
          ..bodies['m1'] = ('html', '<p>Attached.</p>')
          ..attachments['m1'] = [
            ('a-1', 'report.pdf', 'application/pdf', 'not really a pdf'),
          ];

        final body = await fetch();

        expect(body.calendar, isNull);
        expect(server.fetchedAttachments, isEmpty,
            reason: 'looking for an invitation must not pull down a deck');
      });
    });

    group('answering a meeting request', () {
      setUp(() {
        server
          ..message('f-inbox', id: 'm1', subject: 'Review', minutesAgo: 5)
          ..bodies['m1'] = ('html', '<p>Please come.</p>')
          ..mimes['m1'] = invitation
          ..eventMessages.add('m1');
      });

      Future<bool> answer() async {
        final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;
        return transport.respondToInvite(
          'Inbox',
          header.uid,
          InviteResponse.accepted,
          iCalUid: 'u-1',
        );
      }

      test('goes through the cast when the plain link is refused', () async {
        // The mailbox in the report: "Resource not found for the segment
        // 'event'". The link belongs to eventMessage, not to message, and
        // naming that type in the path is what makes it parse.
        server
          ..messageEvents['m1'] = 'e-1'
          ..events['e-1'] = 'u-1'
          ..eventNeedsCast = true;

        expect(await answer(), isTrue);
        expect(server.responded, ['e-1:accept']);
      });

      test('goes through the plain link where the cast is refused', () async {
        server
          ..messageEvents['m1'] = 'e-1'
          ..events['e-1'] = 'u-1'
          ..eventCastRefused = true;

        expect(await answer(), isTrue);
        expect(server.responded, ['e-1:accept']);
      });

      test('finds the event by the invitation UID when neither link works',
          () async {
        // Automatic processing put the meeting on the calendar without
        // leaving anything on the message pointing at it. The UID in the
        // invitation is the same one the event carries.
        server
          ..events['e-9'] = 'u-1'
          ..eventNeedsCast = true;

        expect(await answer(), isTrue);
        expect(server.responded, ['e-9:accept']);
      });

      test('says no rather than failing when there is no event at all',
          () async {
        // Nothing here to answer on, which is the caller's cue to send the
        // reply as mail. Before this the refusal reached the screen instead.
        server.eventNeedsCast = true;

        expect(await answer(), isFalse);
        expect(server.responded, isEmpty);
      });

      test('the event a message links to is followed, the series\' or its '
          'own', () async {
        // What a cancellation or a new time proposed is checked against:
        // the meeting the message is about, found the way Exchange links
        // it, through the cast where the plain link is refused.
        server
          ..messageEvents['m1'] = 'e-1'
          ..events['e-1'] = 'u-1'
          ..eventNeedsCast = true;
        final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;

        expect(await transport.linkedEventId('Inbox', header.uid), 'e-1');
      });

      test('and a message that links to none has none, not a failure',
          () async {
        server.eventNeedsCast = true;
        final header = (await transport.fetchHeadersFromUid('Inbox', 1)).single;

        expect(await transport.linkedEventId('Inbox', header.uid), isNull);
        expect(server.responded, isEmpty);
      });
    });

    test('every pass sees the folder as it is now', () async {
      // Holding one pass over the folder and sharing it between the three
      // the sync makes was tried, to save two thirds of the requests. It
      // hides anything that changed in between, which is a bug waiting for
      // the moment it matters. The saving has to come from asking once and
      // passing the answer down.
      server
        ..message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 30)
        ..message('f-inbox', id: 'm2', subject: 'B', minutesAgo: 20);
      await transport.fetchHeadersFromUid('Inbox', 1);
      await transport.fetchFlags('Inbox', 1, 2);

      server.remove('m2');

      expect(await transport.existingUids('Inbox', 1, 2), hasLength(1));
    });

    test('the previews of a range come back with the headers', () async {
      // What fills in the second lines of a mailbox cached by a version
      // that dropped them. It is the same page of messages the flags pass
      // reads, and Graph puts bodyPreview in every row of it.
      server
        ..message('f-inbox',
            id: 'm1', subject: 'A', minutesAgo: 30, preview: 'First line.')
        ..message('f-inbox',
            id: 'm2', subject: 'B', minutesAgo: 20, preview: 'Second line.');
      await transport.fetchHeadersFromUid('Inbox', 1);

      expect(transport.canRefreshHeaders, isTrue);
      final again = await transport.refreshHeaders('Inbox', 1, 2);

      expect(again.map((h) => h.preview),
          containsAll(<String>['First line.', 'Second line.']));
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

    test('a reply is written on the original as Outlook writes one',
        () async {
      // Exchange has no answered flag. Outlook records what it did and
      // when, and says "You replied on ..." from the two; the same two are
      // written here.
      server.message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5);
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;
      final before = DateTime.now().toUtc();

      await transport.markAnswered('Inbox', uid);

      final written = server.extendedProperties('m1');
      expect(written['Integer 0x1081'], '102');
      final at = DateTime.parse(written['SystemTime 0x1082']!);
      expect(at.isUtc, isTrue);
      expect(at.difference(before).inSeconds.abs(), lessThan(5));
      expect(written['Integer 0x1080'], '261',
          reason: 'the icon Outlook on a desktop draws its arrow from');
    });

    test('a reply to all and a forward are verbs of their own', () async {
      server.message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5);
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;

      await transport.markAnswered('Inbox', uid, toAll: true);
      expect(server.extendedProperties('m1')['Integer 0x1081'], '103');

      await transport.markForwarded('Inbox', uid);
      expect(server.extendedProperties('m1')['Integer 0x1081'], '104');
      expect(server.extendedProperties('m1')['Integer 0x1080'], '262');

      // One verb, the last, so the forward is all the message shows now.
      expect(transport.keepsBothMarks, isFalse);
      final flags = (await transport.fetchFlags('Inbox', uid, uid)).single;
      expect(flags.isForwarded, isTrue);
      expect(flags.isAnswered, isFalse);
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

    test('emptying a folder of 250 deletes all 250', () async {
      // Deleting page by page with an offset stepped over every other page:
      // 100 were left on the server while the app showed the folder empty.
      server.folder(id: 'f-junk', name: 'Junk Email', wellKnown: 'junkemail');
      for (var i = 0; i < 250; i++) {
        server.message('f-junk', id: 'j$i', subject: 'J$i', minutesAgo: i + 1);
      }

      await transport.storeFlagOnAll('Junk Email',
          flag: MessageFlag.deleted, set: true);

      expect(server.messages.values.where((m) => m['_folder'] == 'f-junk'),
          isEmpty);
    });

    test('a message leaving mid-scan does not take the next one with it',
        () async {
      // Pages are asked for by offset, one request each. One message gone
      // between two of them moved the rest up a place, the first of the
      // next page was never seen, and the sync dropped it as deleted.
      for (var i = 0; i < 150; i++) {
        server.message('f-inbox', id: 'm$i', subject: 'M$i', minutesAgo: i + 1);
      }
      // The whole folder is the cached window, so the scan reads it all.
      final window = DateTime.utc(2000);
      final uidOf = {
        for (final h in await transport.fetchHeadersFromUid('Inbox', 1,
            windowStart: window))
          h.subject: h.uid,
      };
      expect(uidOf, hasLength(150));
      final top = uidOf.values.reduce((a, b) => a > b ? a : b);
      final start = server.listings;
      server.afterListing = (n) {
        if (n == start + 1) server.remove('m0');
      };

      final existing =
          await transport.existingUids('Inbox', 1, top, windowStart: window);

      // M0 was on the first page before it went, so it was seen; M100 was
      // the first of the second page, which is the one that went missing.
      expect(existing, contains(uidOf['M100']));
      expect(existing, containsAll([for (var i = 1; i < 150; i++) uidOf['M$i']]));
    });

    test('and when more go than the pages overlap, the scan starts again',
        () async {
      for (var i = 0; i < 150; i++) {
        server.message('f-inbox', id: 'm$i', subject: 'M$i', minutesAgo: i + 1);
      }
      final window = DateTime.utc(2000);
      final uidOf = {
        for (final h in await transport.fetchHeadersFromUid('Inbox', 1,
            windowStart: window))
          h.subject: h.uid,
      };
      final top = uidOf.values.reduce((a, b) => a > b ? a : b);
      final start = server.listings;
      server.afterListing = (n) {
        if (n != start + 1) return;
        for (var i = 0; i < 20; i++) {
          server.remove('m$i');
        }
      };

      final existing =
          await transport.existingUids('Inbox', 1, top, windowStart: window);

      expect(existing, containsAll([for (var i = 20; i < 150; i++) uidOf['M$i']]));
    });

    test('a scan that runs out of pages does not say what is gone', () async {
      // Forty pages reach 3,610 messages. Listing only those, it had the
      // sync drop every cached row older than the last page as deleted.
      for (var i = 0; i < 3700; i++) {
        server.message('f-inbox', id: 'm$i', subject: 'M$i', minutesAgo: i + 1);
      }

      final existing = await transport.existingUids('Inbox', 1, 3700,
          windowStart: DateTime.utc(2000));

      expect(existing, isNull);
    });

    test('a message already gone from Microsoft counts as moved', () async {
      // Deleted in Outlook while its notification was up: Delete in the
      // shade failed five times over, then said it was where it was.
      server.message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5);
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;
      server.remove('m1');

      final moved = await transport.moveMessages('Inbox', [uid], 'Archive');

      expect(moved, isNull, reason: 'nothing landed');
    });

    test('and deleting one already gone has nothing left to do', () async {
      server.message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5);
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;
      server.remove('m1');

      await expectLater(
        transport.storeFlag('Inbox',
            uids: [uid], flag: MessageFlag.deleted, set: true),
        completes,
      );
    });

    test('but a delete refused for a message still there is a failure',
        () async {
      server.message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5);
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;
      server.refuseDeleteOf.add('m1');

      await expectLater(
        transport.storeFlag('Inbox',
            uids: [uid], flag: MessageFlag.deleted, set: true),
        throwsA(isA<GraphNotFound>()),
      );
    });

    test('and anything else on a message gone is still a failure', () async {
      server.message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5);
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;
      server.remove('m1');

      await expectLater(
        transport.storeFlag('Inbox',
            uids: [uid], flag: MessageFlag.seen, set: true),
        throwsA(isA<GraphNotFound>()),
      );
    });

    test('a move to a folder deleted since is not taken for done', () async {
      // Without the check that the message itself is gone, a move into a
      // folder deleted elsewhere would drop the message from the list while
      // it stayed in the Inbox.
      server
        ..folder(id: 'f-old', name: 'Old')
        ..message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5);
      await transport.listFolders();
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;
      server.folders.remove('f-old');

      await expectLater(
        transport.moveMessages('Inbox', [uid], 'Old'),
        throwsA(isA<GraphNotFound>()),
      );
      expect(server.messages.containsKey('m1'), isTrue);
    });

    group('a message from another account', () {
      const raw = 'From: Dana Levi <dana@example.com>\r\n'
          'To: ron@example.com\r\n'
          'Cc: Avi Cohen <avi@example.com>\r\n'
          'Subject: Invoice 12\r\n'
          'Date: Wed, 04 Mar 2026 05:06:00 +0000\r\n'
          'Message-ID: <inv12@example.com>\r\n'
          'Importance: high\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: multipart/mixed; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: text/html; charset=utf-8\r\n'
          '\r\n'
          '<p>Attached.</p>\r\n'
          '--b\r\n'
          'Content-Type: application/pdf; name="invoice.pdf"\r\n'
          'Content-Disposition: attachment; filename="invoice.pdf"\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          'JVBERi0xLjQK\r\n'
          '--b--\r\n';

      Map<String, Object?> properties(Map<String, Object?> message) => {
            for (final p
                in message['singleValueExtendedProperties'] as List)
              (p as Map)['id'] as String: p['value'],
          };

      setUp(() => server.folder(id: 'f-receipts', name: 'Receipts'));

      test('is filed as received mail, not a draft, with its file', () async {
        await transport.listFolders();

        final uid = await transport.fileMessage(
          'Receipts',
          raw,
          seen: true,
          flagged: true,
          arrived: DateTime.utc(2026, 3, 4, 5, 7),
        );

        expect(uid, isNotNull);
        expect(server.createdAs.single, 'application/json',
            reason: 'Graph makes a draft of anything created from MIME');
        final (id, filed) = server.messages.entries
            .map((e) => (e.key, e.value))
            .single;
        expect(filed['isDraft'], isFalse);
        expect(filed['isRead'], isTrue);
        expect(filed['_folder'], 'f-receipts');
        expect(filed['subject'], 'Invoice 12');
        expect((filed['body'] as Map)['contentType'], 'html');
        expect((filed['body'] as Map)['content'], contains('Attached.'));
        expect((filed['from'] as Map)['emailAddress'],
            {'address': 'dana@example.com', 'name': 'Dana Levi'});
        expect((filed['ccRecipients'] as List).single,
            {'emailAddress': {'address': 'avi@example.com', 'name': 'Avi Cohen'}});
        expect(filed['internetMessageId'], '<inv12@example.com>');
        expect(filed['importance'], 'high');
        expect(filed['flag'], {'flagStatus': 'flagged'});
        expect(properties(filed), {
          'Integer 0x0E07': '1',
          'SystemTime 0x0E06': '2026-03-04T05:07:00.000Z',
          'SystemTime 0x0039': '2026-03-04T05:06:00.000Z',
        });
        expect(server.attached[id]?.single['name'], 'invoice.pdf');
        expect(server.attached[id]?.single['contentType'], 'application/pdf');
      });

      test('unread stays unread', () async {
        await transport.listFolders();

        await transport.fileMessage('Receipts', raw, seen: false);

        expect(server.messages.values.single['isRead'], isFalse);
      });

      test('a Message-ID Graph will not take is left off, not the message',
          () async {
        server.refuseInternetMessageId = true;
        await transport.listFolders();

        final uid = await transport.fileMessage('Receipts', raw, seen: true);

        expect(uid, isNotNull);
        final filed = server.messages.values.single;
        expect(filed.containsKey('internetMessageId'), isFalse);
        expect(filed['subject'], 'Invoice 12');
      });

      test('a file that will not go takes the message back out', () async {
        server.refuseAttachments = true;
        await transport.listFolders();

        await expectLater(
          transport.fileMessage('Receipts', raw, seen: true),
          throwsA(isA<ConnectionFailed>()),
        );
        expect(server.messages, isEmpty,
            reason: 'a copy without its files is not the message');
      });

      group('its body', () {
        /// [mime] filed, as Graph was given it: the body, and the names
        /// of the files put on it after.
        Future<({Map body, List<Object?> files})> filed(String mime) async {
          await transport.listFolders();
          await transport.fileMessage('Receipts', mime, seen: true);
          final (id, message) =
              server.messages.entries.map((e) => (e.key, e.value)).single;
          return (
            body: message['body'] as Map,
            files: [for (final f in server.attached[id] ?? []) f['name']],
          );
        }

        String message(String contentType, String parts) =>
            'From: Dana Levi <dana@example.com>\r\n'
            'To: ron@example.com\r\n'
            'Subject: Numbers\r\n'
            'MIME-Version: 1.0\r\n'
            'Content-Type: $contentType; boundary="b"\r\n'
            '\r\n'
            '$parts'
            '--b--\r\n';

        test('is the sender\'s words, not an HTML page attached', () async {
          // enough_mail hands over the first HTML part it finds, a file
          // among them: the copy's body became the attached page, and what
          // Dana wrote was gone.
          final result = await filed(message(
            'multipart/mixed',
            '--b\r\n'
                'Content-Type: text/plain; charset=utf-8\r\n'
                '\r\n'
                'The report is attached.\r\n'
                '--b\r\n'
                'Content-Type: text/html; name="report.html"\r\n'
                'Content-Disposition: attachment; filename="report.html"\r\n'
                '\r\n'
                '<h1>Quarterly report</h1>\r\n',
          ));

          expect(result.body['contentType'], 'text');
          expect(result.body['content'], contains('The report is attached.'));
          expect(result.body['content'], isNot(contains('Quarterly')));
          expect(result.files, ['report.html']);
        });

        test('keeps the words after a picture, as Apple Mail splits them',
            () async {
          // iPhone Mail writes the text either side of a picture as parts
          // of their own. Everything after the first picture was dropped,
          // and the later parts went neither into the body nor as files.
          final result = await filed(message(
            'multipart/mixed',
            '--b\r\n'
                'Content-Type: text/plain; charset=utf-8\r\n'
                '\r\n'
                'Before the photo.\r\n'
                '--b\r\n'
                'Content-Type: image/jpeg; name="IMG_0001.jpg"\r\n'
                'Content-Disposition: inline; filename="IMG_0001.jpg"\r\n'
                'Content-Transfer-Encoding: base64\r\n'
                '\r\n'
                '/9j/4AAQ\r\n'
                '--b\r\n'
                'Content-Type: text/plain; charset=utf-8\r\n'
                '\r\n'
                'After the photo.\r\n',
          ));

          expect(result.body['content'], contains('Before the photo.'));
          expect(result.body['content'], contains('After the photo.'));
          expect(result.files, ['IMG_0001.jpg']);
        });

        test('joins HTML either side of a picture, and text as HTML',
            () async {
          final result = await filed(message(
            'multipart/mixed',
            '--b\r\n'
                'Content-Type: multipart/alternative; boundary="a"\r\n'
                '\r\n'
                '--a\r\n'
                'Content-Type: text/plain\r\n'
                '\r\n'
                'Before.\r\n'
                '--a\r\n'
                'Content-Type: text/html\r\n'
                '\r\n'
                '<html><body><p>Before.</p></body></html>\r\n'
                '--a--\r\n'
                '--b\r\n'
                'Content-Type: image/png; name="chart.png"\r\n'
                'Content-Disposition: inline; filename="chart.png"\r\n'
                'Content-Transfer-Encoding: base64\r\n'
                '\r\n'
                'iVBORw0KGgo=\r\n'
                '--b\r\n'
                'Content-Type: text/plain\r\n'
                '\r\n'
                'After <the> chart.\r\n',
          ));

          expect(result.body['contentType'], 'html');
          final content = result.body['content'] as String;
          expect(content, contains('<p>Before.</p>'));
          expect(content, contains('After &lt;the&gt; chart.'));
          expect(content.indexOf('Before'), lessThan(content.indexOf('After')));
          expect('Before.'.allMatches(content), hasLength(1),
              reason: 'one form of an alternative, not both');
        });

        test('takes a text file with a name for a file', () async {
          final result = await filed(message(
            'multipart/mixed',
            '--b\r\n'
                'Content-Type: text/plain\r\n'
                '\r\n'
                'Notes attached.\r\n'
                '--b\r\n'
                'Content-Type: text/plain; name="notes.txt"\r\n'
                'Content-Disposition: inline; filename="notes.txt"\r\n'
                '\r\n'
                'Bring the drawings.\r\n',
          ));

          expect(result.body['content'], isNot(contains('Bring')));
          expect(result.files, ['notes.txt']);
        });
      });
    });

    group('a draft too large to post whole', () {
      // Graph takes 4 MB a request and base64 adds a third. A forward with
      // a 4 MB file on it could never be saved as a draft, and the Try
      // again offered could never work.
      final pdf = base64Encode(List<int>.generate(3000, (i) => i % 256));
      final raw = 'From: ron@contoso.example\r\n'
          'Subject: Drawings\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: multipart/mixed; boundary="m"\r\n'
          '\r\n'
          '--m\r\n'
          'Content-Type: multipart/related; boundary="r"\r\n'
          '\r\n'
          '--r\r\n'
          'Content-Type: text/html; charset=utf-8\r\n'
          '\r\n'
          '<p>Here they are.</p><img src="cid:logo@x">\r\n'
          '--r\r\n'
          'Content-Type: image/png\r\n'
          'Content-ID: <logo@x>\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          'iVBORw0KGgo=\r\n'
          '--r--\r\n'
          '--m\r\n'
          'Content-Type: application/pdf; name="drawings.pdf"\r\n'
          'Content-Disposition: attachment; filename="drawings.pdf"\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          '$pdf\r\n'
          '--m--\r\n';

      GraphTransport postingUpTo(int bytes) => GraphTransport(
            accountId: 'acct-1',
            idMap: ids,
            api: GraphMailApi(
              accessToken: ({bool force = false}) async => 'token',
              httpClient: http_testing.MockClient(server.handle),
            ),
            maxMimeBytes: bytes,
          );

      setUp(() {
        server.folder(id: 'f-drafts', name: 'Drafts', wellKnown: 'drafts');
      });

      test('goes up as its words, and then each file', () async {
        await postingUpTo(2048).appendMessage('Drafts', raw, draft: true);

        final (id, made) =
            server.messages.entries.map((e) => (e.key, e.value)).single;
        final words = made['_mime'] as String;
        expect(words.length, lessThan(2048));
        expect(words, isNot(contains(pdf.substring(0, 64))));
        expect(em.MimeMessage.parseFromText(words).decodeTextHtmlPart(),
            contains('cid:logo@x'));
        final files = server.attached[id]!;
        expect([for (final f in files) f['name']],
            unorderedEquals(['drawings.pdf', 'attachment.png']));
        final picture = files.firstWhere((f) => f['name'] != 'drawings.pdf');
        expect(picture['contentId'], 'logo@x',
            reason: 'the body still finds its picture');
        expect(made['isRead'], isTrue);
      });

      test('a file that will not go takes the draft back out', () async {
        // As a move does: a failed save then leaves nothing half made, and
        // the copy it was to replace stays where it was.
        server.refuseAttachments = true;

        await expectLater(
          postingUpTo(2048).appendMessage('Drafts', raw, draft: true),
          throwsA(isA<ConnectionFailed>()),
        );
        expect(server.messages, isEmpty);
      });

      test('words that are too large alone are said to be, once', () async {
        await expectLater(
          postingUpTo(200).appendMessage('Drafts', raw, draft: true),
          throwsA(isA<SendFailed>()
              .having((e) => e, 'error', isNot(isA<Retryable>()))),
        );
        expect(server.messages, isEmpty);
      });
    });

    test('a request too large for Microsoft is not offered again', () async {
      final api = GraphMailApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((_) async => http.Response(
              jsonEncode({
                'error': {'code': 'ErrorRequestEntityTooLarge'},
              }),
              413,
            )),
      );

      await expectLater(
        api.createMessage('f-drafts', 'Subject: Hi\r\n\r\nHello'),
        throwsA(isNot(isA<Retryable>())),
      );
    });

    test('a draft that was created is saved, marked read or not', () async {
      // Failing to mark it read threw, and a reply from the shade took that
      // for "not saved" and saved another copy each time round.
      server.folder(id: 'f-drafts', name: 'Drafts', wellKnown: 'drafts');
      server.refuseAllPatches = true;

      await expectLater(
        transport.appendMessage('Drafts', 'Subject: Hi\r\n\r\nHello',
            draft: true),
        completes,
      );
    });

    test('a draft refused with nothing said is not taken for saved',
        () async {
      // A gateway's 502 has no body. Read as success, Save draft deleted
      // the copy it was opened from and closed on "Saved to Drafts" with
      // the words saved nowhere.
      server
        ..folder(id: 'f-drafts', name: 'Drafts', wellKnown: 'drafts')
        ..emptyRefusalOfCreate = 502;

      await expectLater(
        transport.appendMessage('Drafts', 'Subject: Hi\r\n\r\nHello',
            draft: true),
        throwsA(isA<ConnectionFailed>()),
      );
    });

    test('nor is a draft Microsoft took without saying where', () async {
      final api = GraphMailApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient(
          (_) async => http.Response('{}', 201),
        ),
      );

      await expectLater(
        api.createMessage('f-drafts', 'Subject: Hi\r\n\r\nHello'),
        throwsA(isA<ConnectionFailed>()),
      );
    });

    test('a move refused with nothing said is not taken for done', () async {
      // Counted as moved, the row went from the list and came back at the
      // next sync.
      server
        ..message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 5)
        ..emptyRefusalOfMove = 502;
      final uid = (await transport.fetchHeadersFromUid('Inbox', 1)).single.uid;

      await expectLater(
        transport.moveMessages('Inbox', [uid], 'Archive'),
        throwsA(isA<ConnectionFailed>()),
      );
      expect(await ids.remoteIdsFor('acct-1', 'Inbox', [uid]), {uid: 'm1'},
          reason: 'its number still names it');
    });

    test('a property is found however Graph writes its id', () {
      // Asked for as 'Integer 0x0E08', it comes back as 'Integer 0xe08'.
      expect(GraphMailApi.propertyKey('Integer 0x0E08'),
          GraphMailApi.propertyKey('Integer 0xe08'));
      expect(GraphMailApi.propertyKey('Integer 0x1081'),
          GraphMailApi.propertyKey('integer 0x1081'));
      expect(GraphMailApi.propertyKey('Integer 0x0E08'),
          isNot(GraphMailApi.propertyKey('Long 0x0E08')));
    });

    test('every row says what the message weighs', () async {
      // Microsoft sends no size with a row, so the paperclip on a Microsoft
      // row stood alone where Gmail's said what it weighed. Exchange's own
      // size of the message comes with the marks it already asks for.
      server
        ..message('f-inbox',
            id: 'm1',
            subject: 'Drawings',
            minutesAgo: 5,
            hasAttachments: true,
            sizeBytes: 1843200)
        ..message('f-inbox',
            id: 'm2', subject: 'Plain', minutesAgo: 4, sizeBytes: 9000);

      final rows = {
        for (final h in await transport.fetchHeadersFromUid('Inbox', 1))
          h.subject: h,
      };

      expect(rows['Drawings']!.sizeBytes, 1843200);
      expect(rows['Plain']!.sizeBytes, 9000,
          reason: 'with files or without, as Outlook shows it');
    });

    test('and mail already on the phone gets its size at the next sync',
        () async {
      server
        ..message('f-inbox',
            id: 'm1',
            subject: 'Drawings',
            minutesAgo: 5,
            hasAttachments: true,
            sizeBytes: 1843200)
        ..message('f-inbox',
            id: 'm2', subject: 'Plain', minutesAgo: 4, sizeBytes: 9000)
        ..message('f-inbox', id: 'm3', subject: 'Unsaid', minutesAgo: 3);
      final uid = {
        for (final h in await transport.fetchHeadersFromUid('Inbox', 1))
          h.subject: h.uid,
      };

      final sizes = {
        for (final f in await transport.fetchFlags('Inbox', 1, 10))
          f.uid: f.sizeBytes,
      };

      expect(sizes[uid['Drawings']], 1843200);
      expect(sizes[uid['Plain']], 9000,
          reason: 'rows without files get their size too');
      expect(sizes[uid['Unsaid']], isNull,
          reason: 'unknown, not 0, so a size already had is kept');
    });

    test('a move that fails part way says which went', () async {
      // One request per message: the second failing left the first moved,
      // and nothing said so.
      server
        ..folder(id: 'f-archive', name: 'Archive', wellKnown: 'archive')
        ..message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 30)
        ..message('f-inbox', id: 'm2', subject: 'B', minutesAgo: 20)
        ..refuseMoveOf.add('m1');
      final byId = {
        for (final h in await transport.fetchHeadersFromUid('Inbox', 1))
          h.subject: h.uid,
      };

      // Patient: a server fault inside a batch is asked again, after a wait.
      await expectLater(
        patientTransport.moveMessages(
            'Inbox', [byId['B']!, byId['A']!], 'Archive'),
        throwsA(isA<MovedInPart>()
            .having((p) => p.moved, 'moved', [byId['B']])
            .having((p) => p.landed, 'landed', hasLength(1))),
      );
    });

    group('a selection', () {
      /// [count] messages in the Inbox, by subject, numbered.
      Future<Map<String, int>> inbox(int count) async {
        for (var i = 0; i < count; i++) {
          server.message('f-inbox',
              id: 'm$i', subject: 'M$i', minutesAgo: count - i);
        }
        return {
          for (final h in await transport.fetchHeadersFromUid('Inbox', 1,
              windowStart: DateTime.utc(2000)))
            h.subject: h.uid,
        };
      }

      test('moved goes twenty to a request, and lands numbered', () async {
        // Sixty selected and moved were sixty requests one after another,
        // fifteen seconds and more on a phone before the list settled.
        final uids = await inbox(45);

        final landed =
            await transport.moveMessages('Inbox', [...uids.values], 'Archive');

        expect(server.batchSizes, [20, 20, 5]);
        expect(landed, hasLength(45));
        final archived = {
          for (final h in await transport.fetchHeadersFromUid('Archive', 1,
              windowStart: DateTime.utc(2000)))
            h.uid: h.subject,
        };
        expect([for (final uid in landed!) archived[uid]],
            [for (var i = 0; i < 45; i++) 'M$i'],
            reason: 'each number names the message that went');
      });

      test('deleted goes twenty to a request', () async {
        final uids = await inbox(60);

        await transport.storeFlag('Inbox',
            uids: [...uids.values], flag: MessageFlag.deleted, set: true);

        expect(server.batchSizes, [20, 20, 20]);
        expect(server.messages, isEmpty);
      });

      test('flagged goes in one request', () async {
        final uids = await inbox(5);

        await transport.storeFlag('Inbox',
            uids: [...uids.values], flag: MessageFlag.flagged, set: true);

        expect(server.batchSizes, [5]);
        expect(
          [for (final m in server.messages.values) (m['flag'] as Map)['flagStatus']],
          everyElement('flagged'),
        );
      });

      test('one throttled inside the batch is asked again', () async {
        final uids = await inbox(3);
        server.throttledInBatch['1'] = 1;

        final landed = await patientTransport
            .moveMessages('Inbox', [...uids.values], 'Archive');

        expect(landed, hasLength(3));
        expect(server.batchSizes, [3, 1]);
      });

      test('deleted, with one gone already, has nothing left to do',
          () async {
        final uids = await inbox(3);
        server.remove('m1');

        await transport.storeFlag('Inbox',
            uids: [...uids.values], flag: MessageFlag.deleted, set: true);

        expect(server.messages, isEmpty);
      });

      test('marked, with one refused, is a failure that says which went',
          () async {
        final uids = await inbox(3);
        server.refusePatchOf.add('m1');

        await expectLater(
          patientTransport.storeFlag('Inbox',
              uids: [...uids.values], flag: MessageFlag.seen, set: true),
          throwsA(isA<FlaggedInPart>()
              .having((p) => p.stored, 'stored', [uids['M0'], uids['M2']])
              .having((p) => p.cause, 'cause', isA<ConnectionFailed>())),
        );
        expect(server.messages['m0']!['isRead'], isTrue,
            reason: 'the rest are marked all the same');
      });

      test('marked, with every one refused, is the failure itself', () async {
        final uids = await inbox(2);
        server.refuseAllPatches = true;

        await expectLater(
          patientTransport.storeFlag('Inbox',
              uids: [...uids.values], flag: MessageFlag.flagged, set: true),
          throwsA(isA<ConnectionFailed>()),
        );
      });

      test('emptying a folder deletes twenty to a request', () async {
        // Emptying a Deleted Items of thousands took minutes.
        await inbox(50);

        await transport.storeFlagOnAll('Inbox',
            flag: MessageFlag.deleted, set: true);

        expect(server.messages, isEmpty);
        expect(server.batchSizes, [20, 20, 10]);
      });
    });

    test('marking all read reaches unread mail past the four thousandth',
        () async {
      // Paged by offset, it looked at the newest 4,000 and stopped without
      // a word: older unread mail in a folder a rule fills stayed unread,
      // and the badge stayed up. Every message was listed to find the few
      // unread, and each was marked with a request of its own.
      server.folder(id: 'f-rule', name: 'Alerts');
      for (var i = 0; i < 4300; i++) {
        server.message('f-rule',
            id: 'a$i', subject: 'A$i', minutesAgo: i + 1, isRead: i < 4000);
      }

      await transport.storeFlagOnAll('Alerts',
          flag: MessageFlag.seen, set: true);

      expect(
        server.messages.values.where((m) => m['isRead'] != true),
        isEmpty,
      );
      expect(server.patched, hasLength(300),
          reason: 'what was read already is left alone');
      expect(server.batchSizes, List.filled(15, 20));
    });

    test('a message that will not be marked read ends it, not loops',
        () async {
      server
        ..message('f-inbox', id: 'm1', subject: 'A', minutesAgo: 30)
        ..message('f-inbox', id: 'm2', subject: 'B', minutesAgo: 20)
        ..stayUnread.add('m1');

      await expectLater(
        transport.storeFlagOnAll('Inbox', flag: MessageFlag.seen, set: true),
        throwsA(isA<ConnectionFailed>()),
      );
      expect(server.messages['m2']!['isRead'], isTrue);
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

  group('files and invitation answers', () {
    /// A Graph that throttles the first request of each kind once, and
    /// records every wait it is asked to sit out.
    ({GraphMailApi api, List<Duration> waits}) throttledOnce(
      http.Response Function(http.Request request) answer,
    ) {
      final waits = <Duration>[];
      final throttled = <String>{};
      final api = GraphMailApi(
        accessToken: ({bool force = false}) async => 'token',
        sleep: (d) async => waits.add(d),
        httpClient: http_testing.MockClient((request) async {
          if (throttled.add('${request.method} ${request.url.path}')) {
            return http.Response(
              jsonEncode({
                'error': {'code': 'TooManyRequests', 'message': 'Slow down.'},
              }),
              429,
              headers: const {'retry-after': '1'},
            );
          }
          return answer(request);
        }),
      );
      return (api: api, waits: waits);
    }

    test('a throttled attachment download is waited out', () async {
      // It failed at once with "rate limiting", while every other request
      // to Graph waited as asked and went through.
      final graph = throttledOnce(
        (_) => http.Response.bytes([1, 2, 3], 200),
      );

      final bytes = await graph.api.attachmentBytes('m-1', 'a-1');

      expect(bytes, [1, 2, 3]);
      expect(graph.waits, [const Duration(seconds: 1)]);
    });

    test('a throttled invitation answer is waited out', () async {
      final graph = throttledOnce((request) => request.method == 'GET'
          ? http.Response(jsonEncode({'id': 'e-1'}), 200)
          : http.Response('', 202));

      final answered = await graph.api
          .respondToInvite('m-1', InviteResponse.accepted);

      expect(answered, isTrue);
      expect(graph.waits, hasLength(2), reason: 'the lookup and the answer');
    });

    test('a refused download says what Graph said about it', () async {
      final api = GraphMailApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((_) async => http.Response(
              jsonEncode({
                'error': {
                  'code': 'ErrorItemNotFound',
                  'message': 'The attachment was removed.',
                },
              }),
              400,
            )),
      );

      await expectLater(
        api.attachmentBytes('m-1', 'a-1'),
        throwsA(isA<ConnectionFailed>().having(
          (e) => e.message,
          'message',
          contains('The attachment was removed.'),
        )),
      );
    });
  });

  // The folder sync over this transport, end to end. Graph numbers a message
  // when it first sees it, not in date order, and each of these was a place
  // the sync took the numbers for dates.
  group('the sync over Graph', () {
    late MemoryCacheStore cache;
    late FolderSync sync;

    setUp(() {
      cache = MemoryCacheStore();
      sync = FolderSync(transport: transport, store: cache, accountId: 'acct-1');
    });

    Future<List<CachedMessage>> cached(String path) =>
        cache.readMessages('acct-1', path, offset: 0, limit: 1 << 30);

    Future<Set<String>> subjects(String path) async =>
        {for (final m in await cached(path)) m.subject};

    test('older mail pages in past the first two hundred, and stays', () async {
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');
      for (var i = 0; i < 350; i++) {
        server.message('f-inbox', id: 'm$i', subject: 'M$i', minutesAgo: i);
      }

      await sync.sync('Inbox');
      expect(await cache.countMessages('acct-1', 'Inbox'), 200);
      // A sync with nothing new must not creep past the window either.
      await sync.sync('Inbox');
      expect(await cache.countMessages('acct-1', 'Inbox'), 200);

      // It used to add nothing here: the older mail was numbered above the
      // window and dropped as "not older".
      expect(await sync.ensureCached('Inbox', 250), 250);
      expect(await subjects('Inbox'), containsAll(['M200', 'M249']));
      expect(await subjects('Inbox'), isNot(contains('M250')));

      // And the next sync must not take it for deleted.
      await sync.sync('Inbox');
      expect(await cache.countMessages('acct-1', 'Inbox'), 250);
      expect(await subjects('Inbox'), contains('M249'));
    });

    test('opening an HTML message keeps the second line under it', () async {
      // Graph's body has no text form beside the HTML, and the empty text
      // went into the cache as the preview: every work message opened lost
      // its second line for good, and a meeting made from one had only the
      // From line for notes.
      server
        ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
        ..message('f-inbox',
            id: 'm1',
            subject: 'Our call',
            minutesAgo: 5,
            preview: 'Hi Ron, confirming Thursday at ten.')
        ..bodies['m1'] =
            ('html', '<p>Hi Ron, confirming <b>Thursday</b> at ten.</p>');
      await sync.sync('Inbox');
      final uid = (await cached('Inbox')).single.uid;

      final body = await sync.body('Inbox', uid);

      expect(body.text, contains('confirming Thursday at ten.'));
      expect((await cached('Inbox')).single.preview,
          contains('confirming Thursday at ten.'));
    });

    test('and one opened before that gets its second line back', () async {
      // Cached with no text, it was served as it was for good: nothing asks
      // the server for a body the cache has.
      server
        ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
        ..message('f-inbox', id: 'm1', subject: 'Our call', minutesAgo: 5);
      await sync.sync('Inbox');
      final uid = (await cached('Inbox')).single.uid;
      const html = '<p>Hi Ron, confirming <b>Thursday</b> at ten.</p>';
      await cache.writeBody('acct-1', 'Inbox', uid,
          text: '', html: html, preview: '');

      final body = await sync.body('Inbox', uid);

      expect(body.html, html);
      expect(body.text, contains('confirming Thursday at ten.'));
      final row = (await cached('Inbox')).single;
      expect(row.preview, contains('confirming Thursday at ten.'));
      expect((await cache.readBody('acct-1', 'Inbox', row.uid))!.text, body.text,
          reason: 'kept, not made at every open');
    });

    test('the first page is the newest mail after older mail is paged in',
        () async {
      // Older mail is numbered when it is first seen, after the newest. A
      // list read by number then opened on last week's mail, with the last
      // few days' missing until it had been scrolled four pages.
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');
      for (var i = 0; i < 300; i++) {
        server.message('f-inbox', id: 'm$i', subject: 'M$i', minutesAgo: i);
      }
      await sync.sync('Inbox');
      await sync.ensureCached('Inbox', 250);

      final page = await cache.readMessages('acct-1', 'Inbox', limit: 50);

      expect(page.map((m) => m.subject),
          [for (var i = 0; i < 50; i++) 'M$i']);
    });

    test('a window deeper than a scan reaches is not taken for deleted',
        () async {
      // Past 3,610 cached messages every sync dropped the oldest, bodies
      // and all, and scrolling down fetched them again for the next sync
      // to drop.
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');
      for (var i = 0; i < 3700; i++) {
        server.message('f-inbox', id: 'm$i', subject: 'M$i', minutesAgo: i);
      }
      await sync.sync('Inbox');
      expect(await sync.ensureCached('Inbox', 3700), 3700);

      // A list scrolled all the way down.
      final result = await sync.sync('Inbox', reach: 3700);

      expect(result.removed, 0);
      expect(await cache.countMessages('acct-1', 'Inbox'), 3700);
      expect(await subjects('Inbox'), contains('M3699'));
    });

    group('a folder scrolled far back', () {
      setUp(() async {
        server
          ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
          ..folder(
              id: 'f-del', name: 'Deleted Items', wellKnown: 'deleteditems');
        for (var i = 0; i < 1000; i++) {
          server.message('f-inbox', id: 'm$i', subject: 'M$i', minutesAgo: i);
        }
        await sync.sync('Inbox');
        await sync.ensureCached('Inbox', 1000);
        // And synced again since, as it is every minute.
        await sync.sync('Inbox');
      });

      Future<CachedMessage?> row(String subject) async {
        for (final m in await cached('Inbox')) {
          if (m.subject == subject) return m;
        }
        return null;
      }

      test('syncs no further back than the newest rows', () async {
        // Every scan paged back to the oldest row cached, which nothing
        // ever trims: twelve requests each here, three or four scans a
        // sync, every minute in push mode. Three each reach the newest two
        // hundred.
        final before = server.listings;

        await sync.sync('Inbox');

        expect(server.listings - before, lessThanOrEqualTo(9));
      });

      test('and brings older rows up to date when a list reaches them',
          () async {
        server.messages['m900']!['isRead'] = true;
        server.remove('m950');

        await sync.sync('Inbox', reach: 1000);

        expect((await row('M900'))!.isRead, isTrue);
        expect(await row('M950'), isNull);
        expect(await cache.countMessages('acct-1', 'Inbox'), 999);
      });

      test('an old message put back by an undo turns up', () async {
        // A move here numbers the message at once. Where the sync looked
        // only as far back as the newest rows, it missed one dated before
        // them, and newer mail was then numbered above it, so nothing ever
        // asked for it again.
        final uid = (await row('M800'))!.uid;
        final binned =
            await transport.moveMessages('Inbox', [uid], 'Deleted Items');
        await cache.deleteUids('acct-1', 'Inbox', {uid});
        await transport.moveMessages('Deleted Items', binned!, 'Inbox');

        await sync.sync('Inbox');
        server.message('f-inbox', id: 'new', subject: 'New', minutesAgo: -5);
        await sync.sync('Inbox');

        expect(await row('M800'), isNotNull);
        expect(await row('New'), isNotNull);
        expect(await cache.countMessages('acct-1', 'Inbox'), 1001);
      });

      test('mail moved in from elsewhere turns up when a list reaches its date',
          () async {
        // Moved in by Outlook, it keeps its old date and has no number yet.
        // A sync of the newest rows does not page back as far as it, which
        // is what keeps that sync cheap; the sync made for a list scrolled
        // down to it does. Nothing else would bring it in: paging goes by
        // how many are cached, and it lies among them by date.
        server.message('f-inbox', id: 'x', subject: 'X', minutesAgo: 500);

        await sync.sync('Inbox');
        expect(await row('X'), isNull);

        await sync.sync('Inbox', reach: 600);
        expect(await row('X'), isNotNull);
        expect(await cache.countMessages('acct-1', 'Inbox'), 1001);
      });

      test('and at the next sync when it lands just below the newest rows',
          () async {
        // The first sync's last page reaches past the newest rows and
        // numbers it on the way, and a number with no row has the next sync
        // look back across the whole cache.
        server.message('f-inbox', id: 'x', subject: 'X', minutesAgo: 230);

        await sync.sync('Inbox');
        await sync.sync('Inbox');

        expect(await row('X'), isNotNull);
        expect(await cache.countMessages('acct-1', 'Inbox'), 1001);
      });
    });

    test('an older message moved in turns up in its new folder', () async {
      server
        ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
        ..folder(id: 'f-del', name: 'Deleted Items', wellKnown: 'deleteditems');
      for (var i = 0; i < 150; i++) {
        server.message('f-del', id: 'd$i', subject: 'D$i', minutesAgo: i * 2);
      }
      // Older than the hundred newest in Deleted Items, inside its window.
      server.message('f-inbox', id: 'old', subject: 'Old one', minutesAgo: 251);
      await sync.sync('Inbox');
      await sync.sync('Deleted Items');

      final uid = (await cached('Inbox')).single.uid;
      await transport.moveMessages('Inbox', [uid], 'Deleted Items');
      await sync.sync('Deleted Items');

      // The scan used to stop at the first page, below which it lies.
      expect(await subjects('Deleted Items'), contains('Old one'));
    });

    test('a renamed folder keeps every cached row on its own message',
        () async {
      // Against the database the app uses, where the numbering was dropped
      // and the folder numbered from 1 again under its new name.
      final db = MailDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final drift = DriftGraphIdMap(db);
      final onDisk = GraphTransport(
        accountId: 'acct-1',
        idMap: drift,
        api: GraphMailApi(
          accessToken: ({bool force = false}) async => 'token',
          httpClient: http_testing.MockClient(server.handle),
        ),
      );
      final work = FolderSync(transport: onDisk, store: cache, accountId: 'acct-1');

      server.folder(id: 'f-work', name: 'Work');
      for (var i = 0; i < 150; i++) {
        server.message('f-work', id: 'w$i', subject: 'W$i', minutesAgo: i);
      }
      await work.sync('Work');

      await onDisk.renameFolder('Work', 'Clients');
      await cache.renameFolder('acct-1', 'Work', 'Clients');
      await work.sync('Clients');

      final rows = await cached('Clients');
      expect(rows, hasLength(150), reason: 'nothing taken for deleted');
      final remote = await drift.remoteIdsFor(
        'acct-1',
        'Clients',
        [for (final r in rows) r.uid],
      );
      for (final r in rows) {
        expect(remote[r.uid], 'w${r.subject.substring(1)}', reason: r.subject);
      }
    });

    test('the numbering of folders under a renamed one moves with them',
        () async {
      final db = MailDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final drift = DriftGraphIdMap(db);
      await drift.uidsFor('acct-1', 'Work', ['a', 'b']);
      await drift.uidsFor('acct-1', 'Work/2026', ['c']);
      await drift.uidsFor('acct-1', 'Workshop', ['d']);

      await drift.renameFolder('acct-1', 'Work', 'Clients');

      expect(await drift.remoteIdsFor('acct-1', 'Clients', [1, 2]),
          {1: 'a', 2: 'b'});
      expect(await drift.remoteIdsFor('acct-1', 'Clients/2026', [1]),
          {1: 'c'});
      expect(await drift.remoteIdsFor('acct-1', 'Workshop', [1]), {1: 'd'},
          reason: 'a folder that only starts with the same letters stays');
      expect(await drift.highestUid('acct-1', 'Clients'), 2,
          reason: 'the count carries on, not from 1');
    });
  });

  // Sending through the engine, which is where the message answered is
  // marked, on Exchange and in the cache.
  group('a reply sent from a Microsoft account', () {
    late MemoryCacheStore cache;
    late CachedImapEngine engine;

    setUp(() {
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');
      cache = MemoryCacheStore();
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: cache,
        transportFactory: (_, _) => transport,
        // Sends nothing: the Graph send has tests of its own.
        senderFactory: (_, _) => _SendsNothing(),
      );
    });

    test('marks the original at once, and a forward after it replaces it',
        () async {
      server.message('f-inbox', id: 'm1', subject: 'Numbers', minutesAgo: 5,
          from: 'dana@example.com');
      final account = await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'ron@contoso.example',
        provider: MailProvider.outlook,
        secret: 'unused',
      );
      final inbox = '${account.id}:Inbox';
      final original = (await engine.loadMessages(inbox)).single;
      Draft answer(ComposeKind kind) => Draft(
            accountId: account.id,
            kind: kind,
            to: const [MailAddress(email: 'dana@example.com')],
            subject: 'Re: Numbers',
            htmlBody: '<p>Yes.</p>',
            originalMessageId: original.id,
          );

      await engine.sendDraft(answer(ComposeKind.reply));

      expect(server.extendedProperties('m1')['Integer 0x1081'], '102');
      final replied = await engine.cachedMessage(original.id);
      expect(replied!.isAnswered, isTrue, reason: 'in the list before a sync');

      await engine.sendDraft(answer(ComposeKind.forward));

      expect(server.extendedProperties('m1')['Integer 0x1081'], '104');
      final forwarded = await engine.cachedMessage(original.id);
      expect(forwarded!.isForwarded, isTrue);
      expect(forwarded.isAnswered, isFalse,
          reason: 'Exchange keeps only the last, and the list says the same');

      final synced = (await engine.loadMessages(inbox)).single;
      expect((synced.isAnswered, synced.isForwarded), (false, true),
          reason: 'and the next sync agrees');
    });

    test('a list scrolled down is kept up to date as far as it shows',
        () async {
      // The sync keeps only the newest rows up to date unless it is told
      // how far down the list reaches.
      for (var i = 0; i < 300; i++) {
        server.message('f-inbox', id: 'm$i', subject: 'M$i', minutesAgo: i);
      }
      final account = await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'ron@contoso.example',
        provider: MailProvider.outlook,
        secret: 'unused',
      );
      final inbox = '${account.id}:Inbox';
      await engine.loadMessages(inbox, limit: 300);

      server.messages['m280']!['isRead'] = true;
      final shown = await engine.loadMessages(inbox, limit: 300);

      expect(shown.firstWhere((m) => m.subject == 'M280').isRead, isTrue);
    });

    test('mark all read reaches every cached row', () async {
      for (var i = 0; i < 300; i++) {
        server.message('f-inbox', id: 'm$i', subject: 'M$i', minutesAgo: i);
      }
      final account = await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'ron@contoso.example',
        provider: MailProvider.outlook,
        secret: 'unused',
      );
      final inbox = '${account.id}:Inbox';
      await engine.loadMessages(inbox, limit: 300);

      await engine.markAllRead(inbox);

      final cached = await engine.cachedMessages(inbox, limit: 300);
      expect(cached, hasLength(300));
      expect(cached.where((m) => !m.isRead), isEmpty);
    });
  });

  group('searching a Microsoft account', () {
    test('makes its rows from the search, not a request per hit', () async {
      // Graph's search answers with every header field. Kept to the
      // numbers, each hit not cached was asked for again on its own, one
      // after another: a folder of a hundred old hits, a hundred round
      // trips, and the whole search waiting on it.
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');
      final asked = <Uri>[];
      final searching = GraphTransport(
        accountId: 'acct-1',
        idMap: ids,
        api: GraphMailApi(
          accessToken: ({bool force = false}) async => 'token',
          httpClient: http_testing.MockClient((request) {
            asked.add(request.url);
            return server.handle(request);
          }),
        ),
      );
      final engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => searching,
      );
      final account = await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'ron@contoso.example',
        provider: MailProvider.outlook,
        secret: 'unused',
      );
      // Come since the account was added, so none of it is cached, as most
      // of what a search turns up is not.
      server
        ..message('f-inbox', id: 'm1', subject: 'Acme quote', minutesAgo: 30,
            from: 'dana@acme.example')
        ..message('f-inbox', id: 'm2', subject: 'Acme order', minutesAgo: 20);
      asked.clear();

      final hits = await engine.searchMessages(
        'acme',
        SearchScope.folder('${account.id}:Inbox'),
      );

      expect(hits.map((m) => m.subject), ['Acme order', 'Acme quote']);
      expect(hits.last.from.email, 'dana@acme.example');
      expect(
        asked.where((u) => u.path.contains('/me/messages/')),
        isEmpty,
        reason: 'no hit asked for again',
      );
      // The same numbers a search by number gives, so a row opened from
      // the results is the message a sync would number so.
      expect(
        [for (final m in hits) m.uid],
        await searching.searchUids('Inbox', 'acme'),
      );
    });

    test('shows a cached hit as the search found it, and keeps that',
        () async {
      // A sync keeps only the newest rows' flags current, so a message read
      // in Outlook a month back stayed bold in the cache, and the search,
      // preferring the cached row, showed it bold too.
      server.folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox');
      final store = MemoryCacheStore();
      final engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: store,
        transportFactory: (_, _) => transport,
      );
      final account = await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'ron@contoso.example',
        provider: MailProvider.outlook,
        secret: 'unused',
      );
      server.message('f-inbox',
          id: 'm1', subject: 'Acme quote', minutesAgo: 30);
      final inbox = '${account.id}:Inbox';
      final listed = (await engine.loadMessages(inbox)).single;
      expect(listed.isRead, isFalse);
      server.messages['m1']!['isRead'] = true;

      final hit =
          (await engine.searchMessages('acme', SearchScope.folder(inbox)))
              .single;

      expect(hit.isRead, isTrue);
      expect(
        (await store.readMessage(account.id, 'Inbox', hit.uid))!.isRead,
        isTrue,
        reason: 'the cached row brought up to date with it',
      );
    });
  });

  // Saving through the engine, which is where a save that did not happen
  // has to stop before the earlier copy is deleted.
  group('a draft saved on a Microsoft account', () {
    late CachedImapEngine engine;

    setUp(() {
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => transport,
        senderFactory: (_, _) => _SendsNothing(),
      );
    });

    test('a save Microsoft refuses keeps the copy it was opened from',
        () async {
      // The create answered with an empty 502 read as saved: the earlier
      // copy was deleted, and what was written existed nowhere.
      server
        ..folder(id: 'f-drafts', name: 'Drafts', wellKnown: 'drafts')
        ..message('f-drafts', id: 'd1', subject: 'Plan', minutesAgo: 5);
      final account = await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'ron@contoso.example',
        provider: MailProvider.outlook,
        secret: 'unused',
      );
      final earlier =
          (await engine.loadMessages('${account.id}:Drafts')).single;
      server.emptyRefusalOfCreate = 502;

      await expectLater(
        engine.saveDraft(Draft(
          accountId: account.id,
          kind: ComposeKind.newMessage,
          subject: 'Plan',
          htmlBody: '<p>The second version.</p>',
          savedAs: earlier.id,
        )),
        throwsA(isA<ConnectionFailed>()),
      );
      expect(server.messages.keys, ['d1']);
    });

    test('a forward too large to post whole is saved with its file',
        () async {
      // The message as the app builds it, taken apart: the words go up
      // first and the file after them.
      final small = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => GraphTransport(
          accountId: 'acct-1',
          idMap: ids,
          api: GraphMailApi(
            accessToken: ({bool force = false}) async => 'token',
            httpClient: http_testing.MockClient(server.handle),
          ),
          maxMimeBytes: 8 * 1024,
        ),
        senderFactory: (_, _) => _SendsNothing(),
      );
      server.folder(id: 'f-drafts', name: 'Drafts', wellKnown: 'drafts');
      final account = await small.addAccount(
        displayName: 'Work',
        emailAddress: 'ron@contoso.example',
        provider: MailProvider.outlook,
        secret: 'unused',
      );
      final file = Uint8List.fromList(List.generate(20000, (i) => i % 251));

      await small.saveDraft(Draft(
        accountId: account.id,
        kind: ComposeKind.forward,
        subject: 'Fw: Drawings',
        htmlBody: '<p>See the drawings.</p>',
        attachments: [
          DraftAttachment(
            fileName: 'drawings.pdf',
            mimeType: 'application/pdf',
            bytes: file,
          ),
        ],
      ));

      final (id, made) =
          server.messages.entries.map((e) => (e.key, e.value)).single;
      final words = em.MimeMessage.parseFromText(made['_mime'] as String);
      expect(words.decodeSubject(), 'Fw: Drawings');
      expect(words.decodeTextHtmlPart(), contains('See the drawings.'));
      expect((made['_mime'] as String).length, lessThan(8 * 1024));
      final attached = server.attached[id]!.single;
      expect(attached['name'], 'drawings.pdf');
      expect(base64Decode(attached['contentBytes'] as String), file);
    });
  });

  // Marking a selection through the engine, which is where it went one
  // message at a time: sixty flagged were sixty requests end to end.
  group('a selection on a Microsoft account', () {
    late CachedImapEngine engine;

    setUp(() {
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => patientTransport,
        senderFactory: (_, _) => _SendsNothing(),
      );
    });

    /// [count] unread messages in a folder, as the list shows them.
    Future<List<MailMessage>> listed(
      int count, {
      String id = 'f-inbox',
      String name = 'Inbox',
      String wellKnown = 'inbox',
    }) async {
      server.folder(id: id, name: name, wellKnown: wellKnown);
      for (var i = 0; i < count; i++) {
        server.message(id, id: 'm$i', subject: 'M$i', minutesAgo: count - i);
      }
      final account = await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'ron@contoso.example',
        provider: MailProvider.outlook,
        secret: 'unused',
      );
      final shown = await engine.loadMessages('${account.id}:$name', limit: 100);
      server.batchSizes.clear();
      return shown;
    }

    test('marked read goes twenty to a request', () async {
      final shown = await listed(45);

      await engine.setMessagesRead([for (final m in shown) m.id], true);

      expect(server.batchSizes, [20, 20, 5]);
      expect(server.messages.values.where((m) => m['isRead'] != true), isEmpty);
      final cached =
          await engine.cachedMessages(shown.first.folderId, limit: 100);
      expect(cached.where((m) => !m.isRead), isEmpty,
          reason: 'and the list says so before the next sync');
    });

    test('flagged, with one refused, says which and keeps the rest',
        () async {
      final shown = await listed(3);
      server.refusePatchOf.add('m1');
      final refused = shown.firstWhere((m) => m.subject == 'M1');

      await expectLater(
        engine.setMessagesFlagged([for (final m in shown) m.id], true),
        throwsA(isA<PartialFlagChange>()
            .having((p) => p.failed, 'failed', [refused.id])),
      );
      expect(server.batchSizes.first, 3, reason: 'the three together');
      final cached = await engine.cachedMessages(refused.folderId);
      expect({for (final m in cached) m.subject: m.isFlagged},
          {'M0': true, 'M1': false, 'M2': true});
    });

    test('deleted for good, with one refused, says which went', () async {
      // Microsoft deletes one message at a time. All of them came back on
      // screen, though only one was still there.
      final shown = await listed(3,
          id: 'f-deleted', name: 'Deleted Items', wellKnown: 'deleteditems');
      server.refuseDeleteOf.add('m1');
      final refused = shown.firstWhere((m) => m.subject == 'M1');

      await expectLater(
        engine.deleteMessages([for (final m in shown) m.id]),
        throwsA(isA<PartialMove>().having((p) => p.moved, 'moved',
            [for (final m in shown) if (m.id != refused.id) m.id])),
      );
      expect(server.messages.keys, ['m1']);
      expect(
        [for (final m in await engine.cachedMessages(refused.folderId)) m.id],
        [refused.id],
      );
    });
  });

  // Outlook's Follow Up and Flagged email (#29, #30).
  group('follow-ups', () {
    setUp(() {
      server
        ..folder(id: 'f-inbox', name: 'Inbox', wellKnown: 'inbox')
        ..folder(id: 'f-work', name: 'Work');
    });

    Future<int> numbered(String id) async =>
        (await ids.uidsFor('acct-1', 'Inbox', [id]))[id]!;

    test('a day goes as noon UTC, start and due both', () async {
      server.message('f-inbox', id: 'm1', subject: 'Quote', minutesAgo: 5);
      await transport.listFolders();

      await transport.storeFollowUp('Inbox',
          uids: [await numbered('m1')], due: DateTime(2026, 10, 30));

      final flag = server.messages['m1']!['flag'] as Map;
      expect(flag['flagStatus'], 'flagged');
      expect(flag['dueDateTime'],
          {'dateTime': '2026-10-30T12:00:00', 'timeZone': 'UTC'});
      expect(flag['startDateTime'], flag['dueDateTime']);
    });

    test('no date is the flag taken off and put back, which clears a day',
        () async {
      server.message('f-inbox', id: 'm1', subject: 'Quote', minutesAgo: 5,
          isFlagged: true, flagDue: '2026-10-30T12:00:00.0000000');
      await transport.listFolders();

      await transport.storeFollowUp('Inbox', uids: [await numbered('m1')]);

      expect(server.patched, ['m1', 'm1']);
      expect(server.messages['m1']!['flag'], {'flagStatus': 'flagged'});
    });

    test('complete is Outlook\'s check, with when', () async {
      server.message('f-inbox', id: 'm1', subject: 'Quote', minutesAgo: 5,
          isFlagged: true);
      await transport.listFolders();

      await transport.storeFollowUp('Inbox',
          uids: [await numbered('m1')], complete: true);

      final flag = server.messages['m1']!['flag'] as Map;
      expect(flag['flagStatus'], 'complete');
      expect((flag['completedDateTime'] as Map)['timeZone'], 'UTC');
    });

    test('everything flagged in the mailbox, by folder, with its day',
        () async {
      server
        ..message('f-inbox', id: 'm1', subject: 'Quote', minutesAgo: 30,
            isFlagged: true, flagDue: '2026-10-30T12:00:00.0000000')
        ..message('f-work', id: 'm2', subject: 'Specs', minutesAgo: 20,
            isFlagged: true)
        ..message('f-inbox', id: 'm3', subject: 'Lunch', minutesAgo: 10)
        ..message('f-work', id: 'm4', subject: 'Done', minutesAgo: 5,
            flagStatus: 'complete');

      final hits = await transport.flaggedHits();

      expect({for (final h in hits) h.hit.header!.subject: h.path},
          {'Quote': 'Inbox', 'Specs': 'Work'});
      final quote =
          hits.firstWhere((h) => h.hit.header!.subject == 'Quote');
      expect(quote.due, DateTime(2026, 10, 30));
      expect(hits.firstWhere((h) => h.path == 'Work').due, isNull);
      expect(quote.hit.uid, await numbered('m1'),
          reason: 'numbered in its own folder, as any row there is');
    });
  });
}

/// A sender that sends nothing.
class _SendsNothing extends SmtpSender {
  _SendsNothing()
      : super(
          host: 'smtp.example',
          user: '',
          credentials: const PasswordCredentials(''),
        );

  @override
  Future<void> send(em.MimeMessage message) async {}

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

  /// How many requests each batch of anything but the well-known names
  /// carried, in order: moves, marks and deletes sent together.
  final List<int> batchSizes = [];

  /// Called once each listing of a folder's messages has been read, with
  /// how many there have been: the moment to change the folder under a
  /// scan that is part way through.
  void Function(int listings)? afterListing;

  /// Messages the server will not move.
  final Set<String> refuseMoveOf = {};

  /// Messages whose delete is answered 404 although they are there.
  final Set<String> refuseDeleteOf = {};

  /// Messages whose PATCH is answered 500.
  final Set<String> refusePatchOf = {};

  /// Every message PATCH answered 500.
  bool refuseAllPatches = false;

  /// Messages a PATCH of isRead is answered for and leaves unread.
  final Set<String> stayUnread = {};

  /// The Content-Type each message was created with: MIME (text/plain) or
  /// Graph's own JSON.
  final List<String> createdAs = [];

  /// Refuse a message created with a Message-ID, as Graph may.
  bool refuseInternetMessageId = false;

  /// Answer every message created with this status and nothing in the
  /// body, as a gateway in front of Graph does.
  int? emptyRefusalOfCreate;

  /// Answer every move with this status and nothing in the body.
  int? emptyRefusalOfMove;

  /// Files put on each message, by its id, as they were sent.
  final Map<String, List<Map<String, Object?>>> attached = {};

  /// Answer every file put on a message with a 500.
  bool refuseAttachments = false;

  /// Names whose lookup inside a batch is throttled, and how many times.
  final Map<String, int> throttledInBatch = {};

  /// How many times a folder's messages were paged through. A sync asks the
  /// same question three or four times over and they should share an answer.
  int listings = 0;

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

  /// The message as MIME, by id, for the `$value` form.
  final Map<String, String> mimes = {};

  /// Messages this server treats as meeting requests.
  final Set<String> eventMessages = {};

  /// What it types them as: Graph's own types are `eventMessage` for a
  /// cancellation, `eventMessageRequest` for an invitation and
  /// `eventMessageResponse` for an answer.
  String eventMessageType = '#microsoft.graph.eventMessage';

  /// Some mailboxes leave `@odata.type` out of a selected answer.
  bool odataTypeOmitted = false;

  /// And one may refuse the cast in a select outright.
  bool castSelectRefused = false;

  /// Statuses to answer the next requests of each kind with, in turn, in
  /// place of the answer: a message's MIME, what is attached to one, and
  /// a body asked for through the cast.
  final List<int> mimeAnswers = [];
  final List<int> attachmentListingAnswers = [];
  final List<int> castSelectAnswers = [];

  static http.Response _failure(int status) => http.Response(
        jsonEncode({
          'error': {'code': status >= 500 ? 'ServiceUnavailable' : 'BadRequest'},
        }),
        status,
        headers: const {'content-type': 'application/json'},
      );

  /// Files on a message: id to (name, contentType, bytes).
  final Map<String, List<(String, String, String, String)>> attachments = {};

  /// Attachment ids that are Outlook items (an email dragged into the
  /// message) rather than files: no media type, a subject for a name.
  final Set<String> itemAttachments = {};

  /// Which attachment bodies were actually downloaded.
  final List<String> fetchedAttachments = [];

  /// Inline files: attachment id to its Content-ID header.
  final Map<String, String> contentIds = {};

  /// Which attachments were asked for their Content-ID.
  final List<String> contentIdLookups = [];

  /// A mailbox that will not take `/microsoft.graph.fileAttachment` after
  /// an attachment, the way some would not take the event cast.
  bool fileCastRefused = false;

  /// Which attachments were asked for whole, bytes and all.
  final List<String> wholeAttachmentLookups = [];

  /// Events on the calendar: id to the invitation UID it came from.
  final Map<String, String> events = {};

  /// Which message links to which event, if this mailbox links them at all.
  final Map<String, String> messageEvents = {};

  /// The mailbox that started all this: it answers `/event` on a plain
  /// message with "Resource not found for the segment 'event'", and only
  /// gives up the event when the path names the derived type.
  bool eventNeedsCast = false;

  /// And one that has never heard of the cast.
  bool eventCastRefused = false;

  /// Answers given, as 'eventId:action'.
  final List<String> responded = [];

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
    String preview = '',
    List<String> replyTo = const [],
    int? lastVerb,
    int? iconIndex,
    String? conversationId,
    int? sizeBytes,
    String? flagDue,
  }) {
    messages[id] = {
      'id': id,
      '_folder': folderId,
      'subject': subject,
      'from': {
        'emailAddress': {'address': from, 'name': ?fromName},
      },
      'toRecipients': const [],
      'replyTo': [
        for (final a in replyTo)
          {
            'emailAddress': {'address': a},
          },
      ],
      'receivedDateTime': DateTime.utc(2026, 9, 18, 12)
          .subtract(Duration(minutes: minutesAgo))
          .toIso8601String(),
      'isRead': isRead,
      'flag': {
        'flagStatus': flagStatus ?? (isFlagged ? 'flagged' : 'notFlagged'),
        if (flagDue != null)
          'dueDateTime': {'dateTime': flagDue, 'timeZone': 'UTC'},
      },
      'hasAttachments': hasAttachments,
      'bodyPreview': preview,
      'conversationId': ?conversationId,
      // What Outlook, or anything else, last did to it, and the icon it
      // draws for it.
      // and, as every message has one, its size.
      if (lastVerb != null || iconIndex != null || sizeBytes != null)
        'singleValueExtendedProperties': [
          if (lastVerb != null) {'id': 'Integer 0x1081', 'value': '$lastVerb'},
          if (iconIndex != null) {'id': 'Integer 0x1080', 'value': '$iconIndex'},
          // Written back as Graph writes it, without the leading zero.
          if (sizeBytes != null) {'id': 'Integer 0xe08', 'value': '$sizeBytes'},
        ],
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

  /// A message's extended properties, id to value, as they stand.
  Map<String, String> extendedProperties(String id) => {
        for (final p in (messages[id]?['singleValueExtendedProperties']
                as List?) ??
            const [])
          '${(p as Map)['id']}': '${p['value']}',
      };

  /// [message] as Graph answers with it: extended properties only where
  /// `$expand` asked for them, and only the ones its filter names. Asked
  /// for any other way, a row has none.
  static Map<String, Object?> _row(
    Map<String, Object?> message,
    Map<String, String> query,
  ) {
    final row = {...message}..remove('singleValueExtendedProperties');
    final expand = query[r'$expand'] ?? '';
    final asked = <String>{
      if (RegExp(r"^singleValueExtendedProperties\(\$filter=(id eq '[^']+'"
              r"( or id eq '[^']+')*)\)$")
          .hasMatch(expand))
        for (final m in RegExp(r"id eq '([^']+)'").allMatches(expand))
          m.group(1)!,
    };
    final kept = [
      for (final p in (message['singleValueExtendedProperties'] as List?) ??
          const [])
        if (asked
            .map(GraphMailApi.propertyKey)
            .contains(GraphMailApi.propertyKey('${(p as Map)['id']}')))
          p,
    ];
    if (kept.isNotEmpty) row['singleValueExtendedProperties'] = kept;
    return row;
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

    // The batch that resolves every well-known name in one request, and
    // any other batch, each request in it answered as it would be alone.
    if (request.method == 'POST' && path.endsWith(r'/$batch')) {
      batches++;
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final requests = body['requests'] as List;
      if (!requests.any((r) => knownNames.contains((r as Map)['id']))) {
        batchSizes.add(requests.length);
      }
      return json({
        'responses': [
          for (final r in requests)
            if ((throttledInBatch[(r as Map)['id']] ?? 0) > 0 &&
                (throttledInBatch[r['id']] = throttledInBatch[r['id']]! - 1) >=
                    0)
              {
                'id': r['id'],
                'status': 429,
                'headers': {'Retry-After': '1'},
                'body': {
                  'error': {'code': 'ApplicationThrottled'},
                },
              }
            else if (wellKnown.containsKey(r['id']))
              {
                'id': r['id'],
                'status': 200,
                'body': {'id': wellKnown[r['id']]},
              }
            else if (knownNames.contains(r['id']))
              {'id': (r)['id'], 'status': 404, 'body': {}}
            else
              await _inBatch(r.cast<String, Object?>()),
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

    // Flagged mail anywhere in the mailbox, each with its folder.
    if (request.method == 'GET' && path.endsWith('/me/messages')) {
      final flaggedOnly =
          (query[r'$filter'] ?? '').contains("flag/flagStatus eq 'flagged'");
      final found = messages.values
          .where((m) =>
              !flaggedOnly || (m['flag'] as Map?)?['flagStatus'] == 'flagged')
          .toList()
        ..sort((a, b) => '${b['receivedDateTime']}'
            .compareTo('${a['receivedDateTime']}'));
      return json({
        'value': [
          for (final m in found)
            {..._row(m, query), 'parentFolderId': m['_folder']},
        ],
      });
    }

    // A folder's messages.
    if (request.method == 'GET' && path.endsWith('/messages')) {
      listings++;
      final folderId = _folderIdIn(path);
      // Only unread mail where that is asked for. Ordered as well by a
      // property the filter does not name, Graph refuses the request.
      final filter = query[r'$filter'] ?? '';
      final unreadOnly = filter == 'isRead eq false';
      if (unreadOnly && query.containsKey(r'$orderby')) {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'InefficientFilter',
              'message': 'The restriction or sort order is too complex for '
                  'this operation.',
            },
          }),
          400,
          headers: const {'content-type': 'application/json'},
        );
      }
      final inFolder = messages.values
          .where((m) => m['_folder'] == folderId)
          .where((m) => !unreadOnly || m['isRead'] != true)
          .toList()
        ..sort((a, b) => '${b['receivedDateTime']}'
            .compareTo('${a['receivedDateTime']}'));
      final skip = int.tryParse(query['\$skip'] ?? '0') ?? 0;
      final top = int.tryParse(query['\$top'] ?? '50') ?? 50;
      final page = inFolder.skip(skip).take(top).toList();
      afterListing?.call(listings);
      return json({
        'value': [for (final m in page) _row(m, query)],
      });
    }

    // One folder.
    if (request.method == 'GET' && path.contains('/me/mailFolders/')) {
      final folder = folders[_folderIdIn(path)];
      if (folder == null) return http.Response('{}', 404);
      return json(folder);
    }

    // The event a meeting request is about. A link on eventMessage, not on
    // message: asking for it without the cast is what a real mailbox
    // refused, and the app now asks both ways.
    if (request.method == 'GET' && path.endsWith('/event')) {
      final rest = path.split('/me/messages/').last;
      final cast = rest.contains('/microsoft.graph.eventMessage/');
      final id = rest.split('/').first;
      if (cast && eventCastRefused) return _parseUri('microsoft.graph');
      if (!cast && eventNeedsCast) return _parseUri('event');
      final eventId = messageEvents[id];
      if (eventId == null) return _parseUri('event');
      return json({'id': eventId});
    }

    // The calendar, searched by the UID the invitation carries.
    if (request.method == 'GET' && path.endsWith('/me/events')) {
      final filter = query[r'$filter'] ?? '';
      final wanted = RegExp("iCalUId eq '(.*)'").firstMatch(filter)?.group(1);
      return json({
        'value': [
          for (final e in events.entries)
            if (e.value == wanted) {'id': e.key},
        ],
      });
    }

    // Accepting, tentatively accepting or declining one.
    if (request.method == 'POST' && path.contains('/me/events/')) {
      final rest = path.split('/me/events/').last;
      final parts = rest.split('/');
      if (parts.length == 2 && events.containsKey(parts.first)) {
        responded.add('${parts.first}:${parts.last}');
        return http.Response('', 202);
      }
      return http.Response('{}', 404);
    }

    // One file's Content-ID, asked of it cast to a file.
    if (request.method == 'GET' &&
        path.endsWith('/microsoft.graph.fileAttachment')) {
      if (fileCastRefused) return _parseUri('microsoft.graph');
      final attachmentId =
          path.split('/attachments/').last.split('/').first;
      contentIdLookups.add(attachmentId);
      return json({
        'id': attachmentId,
        if (contentIds[attachmentId] != null)
          'contentId': contentIds[attachmentId],
      });
    }

    // One attachment's bytes.
    if (request.method == 'GET' &&
        path.contains('/attachments/') &&
        path.endsWith(r'/$value')) {
      final rest = path.split('/me/messages/').last;
      final messageId = rest.split('/').first;
      final attachmentId = rest.split('/attachments/').last.split('/').first;
      for (final a in attachments[messageId] ?? const []) {
        if (a.$1 != attachmentId) continue;
        fetchedAttachments.add('$messageId/$attachmentId');
        return http.Response(a.$4, 200);
      }
      return http.Response('{}', 404);
    }

    // One attachment whole: what it is, its Content-ID, and its bytes.
    if (request.method == 'GET' &&
        path.contains('/attachments/') &&
        !path.endsWith(r'/$value')) {
      final rest = path.split('/me/messages/').last;
      final messageId = rest.split('/').first;
      final attachmentId = rest.split('/attachments/').last;
      for (final a in attachments[messageId] ?? const []) {
        if (a.$1 != attachmentId) continue;
        wholeAttachmentLookups.add(attachmentId);
        return json({
          '@odata.type': '#microsoft.graph.fileAttachment',
          'id': a.$1,
          'name': a.$2,
          'contentType': a.$3,
          'size': a.$4.length,
          'isInline': contentIds.containsKey(a.$1),
          if (contentIds[a.$1] != null) 'contentId': contentIds[a.$1],
          'contentBytes': base64Encode(utf8.encode(a.$4)),
        });
      }
      return http.Response('{}', 404);
    }

    // What is attached, without the bytes.
    if (request.method == 'GET' && path.endsWith('/attachments')) {
      final id = path.split('/me/messages/').last.replaceAll('/attachments', '');
      if (attachmentListingAnswers.isNotEmpty) {
        return _failure(attachmentListingAnswers.removeAt(0));
      }
      return json({
        'value': [
          for (final a in attachments[id] ?? const [])
            {
              // Always there, as Graph sends it: the listing is of the
              // base type, and each item says which kind it is.
              '@odata.type': itemAttachments.contains(a.$1)
                  ? '#microsoft.graph.itemAttachment'
                  : '#microsoft.graph.fileAttachment',
              'id': a.$1,
              'name': a.$2,
              'contentType': itemAttachments.contains(a.$1) ? null : a.$3,
              'size': a.$4.length,
              'isInline': contentIds.containsKey(a.$1),
            },
        ],
      });
    }

    // The whole message as MIME.
    if (request.method == 'GET' && path.endsWith(r'/$value')) {
      final id = path.split('/me/messages/').last.replaceAll(r'/$value', '');
      if (mimeAnswers.isNotEmpty) return _failure(mimeAnswers.removeAt(0));
      final mime = mimes[id];
      if (mime == null) return http.Response('{}', 404);
      // The bytes as sent, which for 8-bit mail are UTF-8.
      return http.Response.bytes(utf8.encode(mime), 200,
          headers: {'content-type': 'text/plain'});
    }

    // One message, headers or body.
    if (request.method == 'GET' && path.contains('/me/messages/')) {
      final id = path.split('/me/messages/').last;
      final message = messages[id];
      if (message == null) return http.Response('{}', 404);
      // The body itself, not a header's bodyPreview.
      if ((query['\$select'] ?? '').split(',').contains('body')) {
        final body = bodies[id] ?? ('text', '');
        final select = query['\$select'] ?? '';
        if (castSelectRefused && select.contains('microsoft.graph.')) {
          return http.Response('{"error":{"code":"BadRequest"}}', 400);
        }
        if (castSelectAnswers.isNotEmpty &&
            select.contains('microsoft.graph.')) {
          return _failure(castSelectAnswers.removeAt(0));
        }
        return json({
          'body': {'contentType': body.$1, 'content': body.$2},
          'hasAttachments': message['hasAttachments'],
          // Graph names a derived type, and the cast asks for the property
          // only a meeting request has. A mailbox may answer with either,
          // or with just one of them.
          if (eventMessages.contains(id) && !odataTypeOmitted)
            '@odata.type': eventMessageType,
          if (eventMessages.contains(id) &&
              select.contains('meetingMessageType'))
            'meetingMessageType': 'meetingRequest',
        });
      }
      return json(_row(message, query));
    }

    // Renaming a folder: a new display name, the same id.
    if (request.method == 'PATCH' && path.contains('/me/mailFolders/')) {
      final folder = folders[_folderIdIn(path)];
      if (folder == null) return http.Response('{}', 404);
      folder.addAll(
        (jsonDecode(request.body) as Map).cast<String, Object?>(),
      );
      return json(folder);
    }

    if (request.method == 'PATCH') {
      final id = path.split('/me/messages/').last;
      final message = messages[id];
      if (message == null) return http.Response('{}', 404);
      if (refusePatchOf.contains(id) || refuseAllPatches) {
        return http.Response('{"error":{"code":"ErrorInternalServerError"}}',
            500);
      }
      patched.add(id);
      final body = jsonDecode(request.body) as Map<String, Object?>;
      if (stayUnread.contains(id)) body.remove('isRead');
      // Extended properties are set one by one, by id, and the rest kept.
      final properties = body.remove('singleValueExtendedProperties');
      if (properties is List) {
        message['singleValueExtendedProperties'] = {
          for (final p in (message['singleValueExtendedProperties'] as List?) ??
              const [])
            (p as Map)['id']: p,
          for (final p in properties) (p as Map)['id']: p,
        }.values.toList();
      }
      message.addAll(body);
      _recount('${message['_folder']}');
      return json(message);
    }

    if (request.method == 'DELETE') {
      final id = path.split('/me/messages/').last;
      // As Graph does: nothing there, or refused as if it were not.
      if (!messages.containsKey(id) || refuseDeleteOf.contains(id)) {
        return http.Response('{}', 404);
      }
      remove(id);
      return http.Response('', 204);
    }

    // A message made from MIME, as a draft is, or from Graph's JSON, which
    // is a draft only without PidTagMessageFlags.
    final creating =
        RegExp(r'/me/mailFolders/([^/]+)/messages$').firstMatch(path);
    if (request.method == 'POST' && creating != null) {
      final folderId = wellKnown[creating.group(1)] ?? creating.group(1)!;
      if (!folders.containsKey(folderId)) return http.Response('{}', 404);
      if (emptyRefusalOfCreate case final status?) {
        return http.Response('', status);
      }
      final type = (request.headers['content-type'] ?? '').split(';').first;
      createdAs.add(type);
      final id = 'created-${messages.length}';
      final message = <String, Object?>{
        'id': id,
        '_folder': folderId,
        'isRead': false,
        'isDraft': true,
      };
      // The MIME it was made from, as it went up.
      if (type == 'text/plain') {
        message['_mime'] = utf8.decode(base64Decode(request.body));
      }
      if (type == 'application/json') {
        final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
        if (refuseInternetMessageId && body.containsKey('internetMessageId')) {
          return http.Response(
            '{"error":{"code":"ErrorInvalidPropertySet"}}',
            400,
          );
        }
        message.addAll(body);
        final flags = [
          for (final p in (body['singleValueExtendedProperties'] as List?) ??
              const [])
            if ((p as Map)['id'] == 'Integer 0x0E07') int.parse('${p['value']}'),
        ].firstOrNull;
        message['isRead'] = flags != null && flags & 1 == 1;
        message['isDraft'] = flags == null || flags & 8 == 8;
      }
      messages[id] = message;
      _recount(folderId);
      return json({'id': id});
    }

    final attaching =
        RegExp(r'/me/messages/([^/]+)/attachments$').firstMatch(path);
    if (request.method == 'POST' && attaching != null) {
      if (refuseAttachments) {
        return http.Response(
            '{"error":{"code":"ErrorInternalServerError"}}', 500);
      }
      final id = Uri.decodeComponent(attaching.group(1)!);
      if (!messages.containsKey(id)) return http.Response('{}', 404);
      (attached[id] ??= [])
          .add((jsonDecode(request.body) as Map).cast<String, Object?>());
      return http.Response(
        jsonEncode({'id': 'a-${attached[id]!.length}'}),
        201,
        headers: const {'content-type': 'application/json'},
      );
    }

    if (request.method == 'POST' && path.endsWith('/move')) {
      final id = path.split('/me/messages/').last.replaceAll('/move', '');
      if (emptyRefusalOfMove case final status?) {
        return http.Response('', status);
      }
      if (refuseMoveOf.contains(id)) {
        return http.Response('{"error":{"code":"ErrorInternalServerError"}}',
            500);
      }
      final destination =
          (jsonDecode(request.body) as Map)['destinationId'] as String;
      // A destination deleted since it was listed: not found, and the
      // message stays where it was.
      if (!folders.containsKey(destination) &&
          !wellKnown.containsKey(destination)) {
        return http.Response('{}', 404);
      }
      final message = messages.remove(id);
      if (message == null) return http.Response('{}', 404);
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

  /// One request of a batch, answered as it would be sent alone, in the
  /// form a batch carries its answers in.
  Future<Map<String, Object?>> _inBatch(Map<String, Object?> asked) async {
    final inner = http.Request(
      '${asked['method']}',
      Uri.parse('${GraphMailApi.base}${asked['url']}'),
    );
    if (asked['body'] != null) {
      inner
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode(asked['body']);
    }
    final answer = await handle(inner);
    return {
      'id': asked['id'],
      'status': answer.statusCode,
      'headers': answer.headers,
      'body': answer.body.isEmpty ? null : jsonDecode(answer.body),
    };
  }

  /// What Microsoft says when a path does not parse: the message in Ron's
  /// screenshot, word for word.
  static http.Response _parseUri(String segment) => http.Response(
        jsonEncode({
          'error': {
            'code': 'RequestBroker--ParseUri',
            'message': "Resource not found for the segment '$segment'.",
          },
        }),
        400,
        headers: const {'content-type': 'application/json'},
      );

  static String _folderIdIn(String path) {
    final after = path.split('/me/mailFolders/').last;
    return after.split('/').first;
  }
}
