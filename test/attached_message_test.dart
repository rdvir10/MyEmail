import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/files/attached_message.dart';
import 'package:myemail/data/files/attachment_files.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/graph/graph_transport.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/attached_message_screen.dart';
import 'package:myemail/ui/messages/attachment_bar.dart';

import 'fakes/fake_webview.dart';

/// An email attached to another, as Outlook attaches one: shown as an
/// email, and opened in the app with its own pictures and files.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  // An email with a picture in its body, a file, and an older email
  // attached to it in turn, which has a file of its own.
  final eml = Uint8List.fromList(utf8.encode([
    'From: Michael Reznik <michaelr@example.com>',
    'To: Rolland Kloes <rollandk@example.com>',
    'Cc: Ron Dvir <ron@example.com>',
    'Subject: Extrusion shape pictures',
    'Date: Sat, 03 Oct 2026 14:30:00 -0400',
    'MIME-Version: 1.0',
    'Content-Type: multipart/mixed; boundary="outer"',
    '',
    '--outer',
    'Content-Type: multipart/related; boundary="rel"',
    '',
    '--rel',
    'Content-Type: text/html; charset=utf-8',
    '',
    '<p>Shapes below</p><img src="cid:image001.png@01DD">',
    '--rel',
    'Content-Type: image/png',
    'Content-ID: <image001.png@01DD>',
    'Content-Transfer-Encoding: base64',
    '',
    'iVBORw0KGgo=',
    '--rel--',
    '--outer',
    'Content-Type: application/pdf; name="shapes.pdf"',
    'Content-Disposition: attachment; filename="shapes.pdf"',
    'Content-Transfer-Encoding: base64',
    '',
    'JVBERi0xLjQ=',
    '--outer',
    'Content-Type: message/rfc822',
    'Content-Disposition: attachment; filename="Older thread.eml"',
    '',
    'From: a@example.com',
    'Subject: Older thread',
    'MIME-Version: 1.0',
    'Content-Type: multipart/mixed; boundary="inner"',
    '',
    '--inner',
    'Content-Type: text/plain',
    '',
    'Inside',
    '--inner',
    'Content-Type: image/jpeg; name="inside.jpg"',
    'Content-Disposition: attachment; filename="inside.jpg"',
    'Content-Transfer-Encoding: base64',
    '',
    '/9j/4AAQ',
    '--inner--',
    '--outer--',
    '',
  ].join('\r\n')));

  group('read from its own bytes', () {
    late AttachedMessage m;
    setUp(() => m = AttachedMessage.parse(eml)!);

    test('who it is from and to, and when', () {
      expect(m.subject, 'Extrusion shape pictures');
      expect(m.from.display, 'Michael Reznik');
      expect(m.to.single.display, 'Rolland Kloes');
      expect(m.cc.single.email, 'ron@example.com');
      expect(m.date, isNotNull);
    });

    test('its body, with the picture it shows put in place', () {
      expect(m.body.html, contains('Shapes below'));
      expect(m.inlinePictures['image001.png@01dd'],
          startsWith('data:image/png;base64,'));
    });

    test('its own files, not the picture the body shows', () {
      expect(m.listed.map((f) => f.name),
          ['shapes.pdf', 'Older thread.eml']);
      final pdf = m.listed.first;
      expect(utf8.decode(m.bytesOf(pdf)!), '%PDF-1.4');
      expect(pdf.sizeBytes, 8);
    });

    test("an email in it is its own, with its own files", () {
      expect(m.listed.map((f) => f.name), isNot(contains('inside.jpg')),
          reason: 'the older email keeps its files to itself');
      final inner = AttachedMessage.parse(m.bytesOf(m.listed.last)!)!;
      expect(inner.subject, 'Older thread');
      expect(inner.body.text.trim(), 'Inside');
      expect(inner.listed.single.name, 'inside.jpg');
    });

    test('something that is not an email is not taken for one', () {
      expect(
        AttachedMessage.parse(Uint8List.fromList(utf8.encode('%PDF-1.4'))),
        isNull,
      );
    });
  });

  group('an Outlook item, as Microsoft lists it', () {
    MailAttachment item(String name, [String type = 'application/octet-stream']) =>
        attachedItem(GraphAttachment(
          id: 'a',
          name: name,
          mimeType: type,
          sizeBytes: 7000000,
          isInline: false,
          isItem: true,
        ));

    test('is an email, named as one', () {
      final m = item('Extrusion shape pictures');
      expect(m.name, 'Extrusion shape pictures.eml');
      expect(m.openAs, 'message/rfc822');
      expect(attachmentIcon(m.openAs), Icons.mail_outline);
      expect(item('Already.eml').name, 'Already.eml');
      expect(item('  ').name, 'Attached item.eml');
    });

    test('a calendar item or a contact where Microsoft says so', () {
      expect(item('Review', 'text/calendar').name, 'Review.ics');
      expect(item('Dana', 'text/x-vcard').name, 'Dana.vcf');
    });
  });

  group('opened', () {
    Future<void> pumpOpen(WidgetTester tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  openAttachedMessage(context, eml, key: 'm1/a1'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('as an email, with its files under who it is from',
        (tester) async {
      await pumpOpen(tester);

      expect(find.byType(AttachedMessageScreen), findsOneWidget);
      expect(find.text('Extrusion shape pictures'), findsOneWidget);
      expect(find.text('Michael Reznik'), findsOneWidget);
      expect(find.text('To: Rolland Kloes'), findsOneWidget);
      expect(find.text('shapes.pdf'), findsOneWidget);
      expect(find.text('Older thread.eml'), findsOneWidget);
    });

    testWidgets('and an email in it opens on top, the same way',
        (tester) async {
      await pumpOpen(tester);

      await tester.tap(find.text('Older thread.eml'));
      await tester.pumpAndSettle();

      expect(find.byType(AttachedMessageScreen, skipOffstage: false),
          findsNWidgets(2));
      expect(find.text('Older thread'), findsOneWidget);
      expect(find.text('inside.jpg'), findsOneWidget);
      expect(find.textContaining('Inside'), findsOneWidget);
    });

    testWidgets('from the message it is attached to, by a tap',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('attached');
      addTearDown(() => dir.deleteSync(recursive: true));
      final engine = _OneEmailAttached(eml);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          mailEngineProvider.overrideWithValue(engine),
          attachmentFilesProvider.overrideWithValue(_TempFiles(dir)),
        ],
        child: const MaterialApp(
          home: Scaffold(body: AttachmentBar(messageId: 'acct:INBOX#1')),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.mail_outline), findsOneWidget);

      // Real files: the copy is written to disk and read back.
      await tester.runAsync(() async {
        await tester.tap(find.text('Extrusion shape pictures.eml'));
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();

      expect(find.byType(AttachedMessageScreen), findsOneWidget);
      expect(find.text('shapes.pdf'), findsOneWidget);
    });
  });
}

/// One message with one Outlook item attached to it.
class _OneEmailAttached extends SampleMailEngine {
  _OneEmailAttached(this.bytes);

  final Uint8List bytes;

  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async => [
        attachedItem(GraphAttachment(
          id: 'a1',
          name: 'Extrusion shape pictures',
          mimeType: 'application/octet-stream',
          sizeBytes: bytes.length,
          isInline: false,
          isItem: true,
        )),
      ];

  @override
  Future<Uint8List> fetchAttachment(String messageId, String id) async =>
      bytes;
}

/// Files on disk, in a directory of the test's own.
class _TempFiles implements AttachmentFiles {
  _TempFiles(this.dir);

  final Directory dir;

  @override
  Future<File?> cached(String messageId, MailAttachment attachment) async =>
      null;

  @override
  Future<File> write(
    String messageId,
    MailAttachment attachment,
    Uint8List bytes,
  ) async =>
      File('${dir.path}/${attachment.name}').writeAsBytes(bytes);
}
