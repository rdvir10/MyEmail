import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/folder_sync.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/row_attachments.dart';

import 'fakes/fake_imap_transport.dart';

/// Attachments on the row: the files' names under a message in the list,
/// as new Outlook shows them, each opened with a tap.
void main() {
  CachedMessage cached(int uid, {List<String>? names, bool files = true}) =>
      CachedMessage(
        uid: uid,
        subject: 'S $uid',
        from: const MailAddress(email: 'x@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: DateTime(2026, 10, 1).add(Duration(hours: uid)),
        isRead: false,
        isFlagged: false,
        hasAttachments: files,
        attachmentNames: names,
      );

  MailMessage message({
    String id = 'a:INBOX#7',
    List<String> names = const ['Quote 7.pdf', 'Photo 7.jpg'],
    bool meeting = false,
    DateTime? date,
  }) =>
      MailMessage(
        id: id,
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: int.parse(id.split('#').last),
        subject: 'Quote',
        from: const MailAddress(email: 'x@example.com', name: 'X'),
        to: const [MailAddress(email: 'me@example.com')],
        date: date ?? DateTime(2026, 10, 1),
        preview: 'See attached.',
        hasAttachments: names.isNotEmpty,
        attachmentNames: names,
        isMeeting: meeting,
      );

  test('the setting: on until put away, and kept', () {
    expect(const DisplaySettings().attachmentsOnRow, isTrue);
    expect(DisplaySettings.fromJson(const {}).attachmentsOnRow, isTrue,
        reason: 'a record from before the setting shows them');
    final off = const DisplaySettings(attachmentsOnRow: false);
    expect(DisplaySettings.fromJson(off.toJson()), off);
    expect(off, isNot(const DisplaySettings()));
  });

  group('which files a row names', () {
    test("an invitation's own calendar file is left to its card", () {
      final invite = message(names: ['invite.ics', 'Agenda.pdf'], meeting: true);
      expect(rowFilesOf(invite).map((f) => f.name), ['Agenda.pdf']);
      final mailed = message(names: ['invite.ics']);
      expect(rowFilesOf(mailed).map((f) => f.name), ['invite.ics'],
          reason: 'a calendar file sent on its own is a file');
    });

    test("a thread's row names its files newest first, each once", () {
      final older = message(
        id: 'a:INBOX#1',
        names: ['Plan.pdf', 'Site.jpg'],
        date: DateTime(2026, 10, 1),
      );
      final newer = message(
        id: 'a:INBOX#2',
        names: ['Plan v2.pdf', 'site.JPG'],
        date: DateTime(2026, 10, 2),
      );
      final files = rowFilesOfAll([older, newer]);
      expect(files.map((f) => f.name), ['Plan v2.pdf', 'site.JPG', 'Plan.pdf']);
      expect(files.first.messageId, 'a:INBOX#2');
    });

    test('a chip opens the file of its name, the second of two by that name',
        () {
      const listed = [
        MailAttachment(id: 'logo', name: 'a.png', mimeType: 'image/png',
            sizeBytes: 1, isInline: true),
        MailAttachment(id: '1', name: 'a.png', mimeType: 'image/png',
            sizeBytes: 1),
        MailAttachment(id: '2', name: 'a.png', mimeType: 'image/png',
            sizeBytes: 1),
      ];
      expect(fileForRow(listed, 'a.png', 0)!.id, '1',
          reason: 'what the body shows is not among the row\'s files');
      expect(fileForRow(listed, 'a.png', 1)!.id, '2');
      expect(fileForRow(listed, 'b.png', 0), isNull);
    });
  });

  group('the cache', () {
    Future<void> namesKept(CacheStore store) async {
      await store.upsertMessages('a', 'INBOX', [cached(1, names: ['x.pdf'])]);
      // A Microsoft header read again says only that there are files.
      await store.upsertMessages('a', 'INBOX', [cached(1)]);
      expect((await store.readMessage('a', 'INBOX', 1))!.attachmentNames,
          ['x.pdf']);

      await store.upsertMessages('a', 'INBOX', [cached(2)]);
      var rows = await store.readSyncRows('a', 'INBOX');
      expect(
        {for (final r in rows) r.uid: r.needsAttachmentNames},
        {1: false, 2: true},
      );

      await store.updateAttachmentNames('a', 'INBOX', {2: ['y.docx', 'z.xlsx']});
      rows = await store.readSyncRows('a', 'INBOX');
      expect(rows.any((r) => r.needsAttachmentNames), isFalse);
      final read = await store.readMessages('a', 'INBOX');
      expect(
        read.map((m) => m.toMailMessage(accountId: 'a', folderId: 'a:INBOX'))
            .firstWhere((m) => m.uid == 2)
            .attachmentNames,
        ['y.docx', 'z.xlsx'],
      );

      // A row with no files needs no names.
      await store.upsertMessages('a', 'INBOX', [cached(3, files: false)]);
      rows = await store.readSyncRows('a', 'INBOX');
      expect(rows.firstWhere((r) => r.uid == 3).needsAttachmentNames, isFalse);
    }

    test('in memory', () => namesKept(MemoryCacheStore()));

    test('in the database', () async {
      final db = MailDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await namesKept(DriftCacheStore(db));
    });
  });

  group('the sync', () {
    late FakeImapTransport server;
    late MemoryCacheStore store;
    late FolderSync sync;

    setUp(() {
      server = FakeImapTransport();
      store = MemoryCacheStore();
      sync = FolderSync(transport: server, store: store, accountId: 'a');
    });

    test('names the files a header did not, once', () async {
      final inbox = server.folder('INBOX');
      inbox.deliver();
      final withFiles = inbox.deliver()
        ..hasAttachments = true
        ..attachmentNames = null;
      server.attachmentNameAnswers[withFiles.uid] = ['Invoice.pdf'];

      await sync.sync('INBOX');
      expect((await store.readMessage('a', 'INBOX', withFiles.uid))!
          .attachmentNames, ['Invoice.pdf']);
      expect(server.calls.where((c) => c.endsWith('NAMES')), hasLength(1));

      server.calls.clear();
      await sync.sync('INBOX');
      expect(server.calls.where((c) => c.endsWith('NAMES')), isEmpty,
          reason: 'known names are not asked for again');
    });

    test('a header that names its files costs nothing more', () async {
      final inbox = server.folder('INBOX');
      inbox.deliver()
        ..hasAttachments = true
        ..attachmentNames = ['a.pdf'];
      await sync.sync('INBOX');
      expect(server.calls.where((c) => c.endsWith('NAMES')), isEmpty);
      expect((await store.readMessage('a', 'INBOX', 1))!.attachmentNames,
          ['a.pdf']);
    });

    test('rows cached before names were kept get them, a pass at a time',
        () async {
      final inbox = server.folder('INBOX');
      for (var i = 0; i < FolderSync.attachmentNamesPerPass + 5; i++) {
        inbox.deliver()
          ..hasAttachments = true
          ..attachmentNames = null;
      }
      // Cached with no names, as by a version before them: the server
      // unable to give names for a moment.
      server.refuseAttachmentNames = true;
      await sync.sync('INBOX');
      server.refuseAttachmentNames = false;
      expect(
        (await store.readSyncRows('a', 'INBOX'))
            .where((r) => r.needsAttachmentNames),
        hasLength(FolderSync.attachmentNamesPerPass + 5),
        reason: 'a failure leaves the names to the next pass',
      );

      await sync.sync('INBOX');
      expect(
        (await store.readSyncRows('a', 'INBOX'))
            .where((r) => r.needsAttachmentNames),
        hasLength(5),
      );
      await sync.sync('INBOX');
      expect(
        (await store.readSyncRows('a', 'INBOX'))
            .where((r) => r.needsAttachmentNames),
        isEmpty,
      );
    });
  });

  group('the row', () {
    Future<FakeFileBridge> pump(
      WidgetTester tester,
      MailMessage m, {
      ListDensity density = ListDensity.cozy,
      bool show = true,
    }) async {
      final bridge = FakeFileBridge();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
            mailEngineProvider.overrideWithValue(_Listing()),
            fileBridgeProvider.overrideWithValue(bridge),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 380,
                child: MessageTile(
                  message: m,
                  isSelected: false,
                  onTap: () {},
                  density: density,
                  showAttachments: show,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return bridge;
    }

    testWidgets('names three files, then how many more', (tester) async {
      await pump(
        tester,
        message(names: ['a.pdf', 'b.docx', 'c.xlsx', 'd.jpg', 'e.zip']),
      );
      for (final name in ['a.pdf', 'b.docx', 'c.xlsx']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('d.jpg'), findsNothing);
      expect(find.text('+2'), findsOneWidget);
    });

    testWidgets('not in Compact, and not when put away in Settings',
        (tester) async {
      await pump(tester, message(), density: ListDensity.compact);
      expect(find.text('Quote 7.pdf'), findsNothing);
      await pump(tester, message(), show: false);
      expect(find.text('Quote 7.pdf'), findsNothing);
    });

    testWidgets('a tap opens the file without opening the message',
        (tester) async {
      final bridge = await pump(tester, message());
      await tester.tap(find.text('Quote 7.pdf'));
      await tester.pumpAndSettle();
      expect(bridge.opened, hasLength(1));
      expect(bridge.opened.single, endsWith('Quote 7.pdf'));
    });

    testWidgets('a file gone from the message says so', (tester) async {
      await pump(tester, message(names: ['Gone.pdf']));
      await tester.tap(find.text('Gone.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('Gone.pdf is no longer on the message.'), findsOneWidget);
    });
  });
}

/// The sample engine, with every message carrying the same two files.
class _Listing extends SampleMailEngine {
  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async => [
        const MailAttachment(
          id: '2',
          name: 'Quote 7.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 1000,
        ),
        const MailAttachment(
          id: '3',
          name: 'Photo 7.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 1000,
        ),
      ];
}
