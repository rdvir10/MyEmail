import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/file_types.dart';
import 'package:myemail/domain/mail_attachment.dart';

/// Deciding what an attachment is, so the right apps are offered to open it.
void main() {
  MailAttachment file(String name, String mimeType) => MailAttachment(
        id: 'a-1',
        name: name,
        mimeType: mimeType,
        sizeBytes: 1024,
      );

  group('what the name says', () {
    test('beats what the sender said, when the sender said nothing useful',
        () {
      // The whole complaint: a PDF labelled as a stream of bytes, and Android
      // offering every app that has ever claimed to open anything.
      expect(
        mimeTypeForFile('Invoice 8842.pdf', declared: 'application/octet-stream'),
        'application/pdf',
      );
      expect(file('Invoice 8842.pdf', 'application/octet-stream').openAs,
          'application/pdf');
    });

    test('and beats it when the sender was simply wrong', () {
      // Scanners and accounting systems label attachments by habit rather
      // than by looking. The name is what the person can see.
      expect(
        mimeTypeForFile('statement.pdf', declared: 'application/zip'),
        'application/pdf',
      );
    });

    test('covers what actually turns up on mail', () {
      const expected = {
        'Q3.xlsx':
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'notes.docx':
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'deck.pptx':
            'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'photo.JPG': 'image/jpeg',
        'scan.tiff': 'image/tiff',
        'meeting.ics': 'text/calendar',
        'forwarded.eml': 'message/rfc822',
        'card.vcf': 'text/vcard',
        'drawing.dwg': 'image/vnd.dwg',
        'archive.zip': 'application/zip',
        'notes.txt': 'text/plain',
      };
      for (final entry in expected.entries) {
        expect(mimeTypeForFile(entry.key, declared: 'application/octet-stream'),
            entry.value,
            reason: entry.key);
      }
    });
  });

  group('what the sender said', () {
    test('is used where the name gives nothing away', () {
      expect(mimeTypeForFile('scan0001', declared: 'image/png'), 'image/png');
      expect(mimeTypeForFile('attachment', declared: 'text/plain'),
          'text/plain');
    });

    test('has its parameters stripped, because Android matches the type', () {
      // `application/pdf; name=x.pdf` is a header. An intent carrying that
      // whole string matches no app at all.
      expect(
        mimeTypeForFile('scan0001', declared: 'application/pdf; name=x.pdf'),
        'application/pdf',
      );
    });

    test('is ignored where it says nothing', () {
      for (final vague in const [
        'application/octet-stream',
        'binary/octet-stream',
        'application/unknown',
        '*/*',
      ]) {
        expect(mimeTypeForFile('mystery', declared: vague),
            'application/octet-stream',
            reason: vague);
      }
    });

    test('and a file with neither is left as bytes, which is the truth', () {
      expect(mimeTypeForFile('mystery'), 'application/octet-stream');
      expect(mimeTypeForFile(''), 'application/octet-stream');
      expect(mimeTypeForFile('trailing.'), 'application/octet-stream');
    });
  });

  group('an app to install', () {
    // MyEmail may install apps, for its own updates, so the installer takes
    // a file it is handed as coming from a trusted source. A mailed APK
    // opened as one was a phishing mail one tap from "install this app?".
    const installer = 'application/vnd.android.package-archive';

    test('is opened as bytes, not handed to the installer', () {
      expect(mimeTypeForFile('Invoice.apk', declared: installer),
          'application/octet-stream');
      expect(file('update.APK', 'application/octet-stream').openAs,
          'application/octet-stream');
    });

    test('whatever the sender claims for a name that says nothing', () {
      expect(mimeTypeForFile('Invoice', declared: installer),
          'application/octet-stream');
      expect(
        mimeTypeForFile('scan0001', declared: '$installer; name=x.apk'),
        'application/octet-stream',
      );
    });

    test('and the Android side refuses the type too', () {
      // Handed octet-stream, FilesBridge looks the extension up again, and
      // Android's own table maps .apk back to the installer.
      final bridge = File(
        'android/app/src/main/kotlin/com/rdvir/mailtree/FilesBridge.kt',
      ).readAsStringSync();
      final typeFor = RegExp(r'private fun typeFor\([\s\S]*?\n    }')
          .firstMatch(bridge)
          ?.group(0);
      expect(typeFor, isNotNull);
      expect(typeFor,
          contains('if (type == ANDROID_PACKAGE) "application/octet-stream"'));
      expect(bridge, contains('ANDROID_PACKAGE = "$installer"'));
    });
  });

  test('a correctly labelled file is left exactly as it is', () {
    expect(file('report.pdf', 'application/pdf').openAs, 'application/pdf');
    expect(file('photo.png', 'image/png').openAs, 'image/png');
  });
}
