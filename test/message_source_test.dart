import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/ui/messages/message_source.dart';

/// Writing a message out exactly as it arrived.
void main() {
  MailMessage message({String subject = "Kohl's Rewards: 40% off"}) =>
      MailMessage(
        id: 'a:INBOX#1',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 1,
        subject: subject,
        preview: 'Find fall styles',
        from: const MailAddress(email: 'kohls@s.example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: DateTime.utc(2026, 9, 19, 7, 5),
      );

  group('what lands in the file', () {
    test('the body is untouched', () {
      // The whole point is to see what the sender sent, so nothing here
      // strips images, wraps the body, or tidies the markup.
      const html = '<table width="640"><tr><td>Hello</td></tr></table>';

      final file = messageSourceFile(
        message(),
        const MailBody(text: 'Hello', html: html),
      );

      expect(file, contains(html));
    });

    test('a header says which message it was', () {
      final file = messageSourceFile(
        message(),
        const MailBody(text: 'Hello', html: '<p>Hi</p>'),
      );

      expect(file, contains('kohls@s.example.com'));
      expect(file, contains("Kohl's Rewards: 40% off"));
      expect(file, contains('2026-09-19'));
      expect(file, startsWith('<!--'));
    });

    test('a plain-text message still opens as a file', () {
      final file = messageSourceFile(
        message(),
        const MailBody(text: 'Can you send the <invoice>?'),
      );

      expect(file, contains('<pre>'));
      expect(file, contains('&lt;invoice&gt;'),
          reason: 'text is escaped, not rendered');
    });
  });

  group('the file name', () {
    test('is the subject and the day it arrived', () {
      expect(
        messageSourceFileName(message()),
        startsWith('kohl-s-rewards-40-off-2026-09-19'),
      );
      expect(messageSourceFileName(message()), endsWith('.html'));
    });

    test('survives a subject made of punctuation', () {
      expect(messageSourceFileName(message(subject: '!!! ***')),
          'message-2026-09-19.html');
    });

    test('does not run away with a long subject', () {
      final name = messageSourceFileName(
        message(subject: 'A' * 200),
      );

      expect(name.length, lessThan(60));
      expect(name, isNot(contains('--')));
    });
  });

  group('loading pictures without being asked', () {
    test('is off to begin with', () {
      // A remote picture tells the sender the message was opened, so this
      // stays a choice rather than a default.
      expect(const DisplaySettings().alwaysShowImages, isFalse);
    });

    test('survives a restart', () {
      final saved = const DisplaySettings(alwaysShowImages: true).toJson();

      expect(DisplaySettings.fromJson(saved).alwaysShowImages, isTrue);
    });

    test('an install from before the setting existed has it off', () {
      expect(
        DisplaySettings.fromJson(const {'density': 'cozy'}).alwaysShowImages,
        isFalse,
      );
    });
  });
}
