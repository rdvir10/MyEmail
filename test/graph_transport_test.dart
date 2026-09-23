import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/folder_sync.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/graph/graph_id_map.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/graph/graph_transport.dart';
import 'package:myemail/data/imap/imap_transport.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/mail_folder.dart';

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

  /// Called once each listing of a folder's messages has been read, with
  /// how many there have been: the moment to change the folder under a
  /// scan that is part way through.
  void Function(int listings)? afterListing;

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

  /// Some mailboxes leave `@odata.type` out of a selected answer.
  bool odataTypeOmitted = false;

  /// And one may refuse the cast in a select outright.
  bool castSelectRefused = false;

  /// Files on a message: id to (name, contentType, bytes).
  final Map<String, List<(String, String, String, String)>> attachments = {};

  /// Which attachment bodies were actually downloaded.
  final List<String> fetchedAttachments = [];

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
      },
      'hasAttachments': hasAttachments,
      'bodyPreview': preview,
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
      listings++;
      final folderId = _folderIdIn(path);
      final inFolder = messages.values
          .where((m) => m['_folder'] == folderId)
          .toList()
        ..sort((a, b) => '${b['receivedDateTime']}'
            .compareTo('${a['receivedDateTime']}'));
      final skip = int.tryParse(query['\$skip'] ?? '0') ?? 0;
      final top = int.tryParse(query['\$top'] ?? '50') ?? 50;
      final page = inFolder.skip(skip).take(top).toList();
      afterListing?.call(listings);
      return json({'value': page});
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

    // What is attached, without the bytes.
    if (request.method == 'GET' && path.endsWith('/attachments')) {
      final id = path.split('/me/messages/').last.replaceAll('/attachments', '');
      return json({
        'value': [
          for (final a in attachments[id] ?? const [])
            {
              'id': a.$1,
              'name': a.$2,
              'contentType': a.$3,
              'size': a.$4.length,
              'isInline': false,
            },
        ],
      });
    }

    // The whole message as MIME.
    if (request.method == 'GET' && path.endsWith(r'/$value')) {
      final id = path.split('/me/messages/').last.replaceAll(r'/$value', '');
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
      if ((query['\$select'] ?? '').contains('body')) {
        final body = bodies[id] ?? ('text', '');
        final select = query['\$select'] ?? '';
        if (castSelectRefused && select.contains('microsoft.graph.')) {
          return http.Response('{"error":{"code":"BadRequest"}}', 400);
        }
        return json({
          'body': {'contentType': body.$1, 'content': body.$2},
          'hasAttachments': message['hasAttachments'],
          // Graph names a derived type, and the cast asks for the property
          // only a meeting request has. A mailbox may answer with either,
          // or with just one of them.
          if (eventMessages.contains(id) && !odataTypeOmitted)
            '@odata.type': '#microsoft.graph.eventMessage',
          if (eventMessages.contains(id) &&
              select.contains('meetingMessageType'))
            'meetingMessageType': 'meetingRequest',
        });
      }
      return json(message);
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
