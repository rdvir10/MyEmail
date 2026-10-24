import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/compose/mime_parts.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/send_checks.dart';

/// What batch 3 puts on a message before it goes: the checks at Send,
/// importance, and a read receipt asked for.
void main() {
  const account = Account(
    id: 'a',
    displayName: 'Ron',
    emailAddress: 'me@example.com',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.appPassword,
    colorValue: 0xFF0F6CBD,
  );

  group('the attachment reminder', () {
    test('English, by whole word', () {
      for (final said in [
        'The contract is attached.',
        'See the attachment',
        'I am attaching the plans',
        'Please find enclosed the invoice',
      ]) {
        expect(mentionsAttachment(said), isTrue, reason: said);
      }
      for (final said in ['An unattached garage', 'Attachable racks', 'Hi']) {
        expect(mentionsAttachment(said), isFalse, reason: said);
      }
    });

    test('Hebrew, by stem, and the letters for "attached herewith"', () {
      for (final said in [
        'מצורפת ההצעה',
        'הקובץ מצורף',
        'צירפתי את התוכניות',
        'מצ"ב החשבונית',
        'רצ״ב המסמך',
      ]) {
        expect(mentionsAttachment(said), isTrue, reason: said);
      }
      expect(mentionsAttachment('שלום, נדבר מחר'), isFalse);
    });

    test("only what was written: not the quote, not the signature", () {
      const html = '<p>Thanks, that works.</p>'
          '<div class="mailtree-signature">Ron · see attached terms</div>'
          '<blockquote>The contract is attached.</blockquote>';
      expect(mentionsAttachment(ownTextOf(html)), isFalse);
      expect(ownTextOf(html), contains('Thanks, that works.'));
    });
  });

  group('importance', () {
    test('read from whichever header the sender wrote', () {
      expect(Importance.fromHeaders(importance: 'High'), Importance.high);
      expect(Importance.fromHeaders(importance: 'low'), Importance.low);
      expect(Importance.fromHeaders(xPriority: '1 (Highest)'), Importance.high);
      expect(Importance.fromHeaders(xPriority: '2'), Importance.high);
      expect(Importance.fromHeaders(xPriority: '5 (Lowest)'), Importance.low);
      expect(Importance.fromHeaders(priority: 'urgent'), Importance.high);
      expect(Importance.fromHeaders(msMailPriority: 'Low'), Importance.low);
      expect(Importance.fromHeaders(), Importance.normal);
      expect(Importance.fromGraph('high'), Importance.high);
      expect(Importance.fromGraph(null), Importance.normal);
    });

    test('sent as Outlook writes it, with a receipt asked of the reader', () {
      final message = buildMimeMessage(
        draft: const Draft(
          accountId: 'a',
          kind: ComposeKind.newMessage,
          to: [MailAddress(email: 'dana@example.com')],
          subject: 'Today',
          htmlBody: '<p>Now.</p>',
          importance: Importance.high,
          requestReadReceipt: true,
        ),
        account: account,
      );
      expect(message.getHeaderValue('importance'), 'High');
      expect(message.getHeaderValue('x-priority'), '1 (Highest)');
      expect(
        message.getHeaderValue('disposition-notification-to'),
        'me@example.com',
      );

      final plain = buildMimeMessage(
        draft: const Draft(
          accountId: 'a',
          kind: ComposeKind.newMessage,
          to: [MailAddress(email: 'dana@example.com')],
          subject: 'Today',
        ),
        account: account,
      );
      expect(plain.getHeaderValue('importance'), isNull);
      expect(plain.getHeaderValue('disposition-notification-to'), isNull);
    });

    test('a saved draft keeps both when it is opened again', () {
      final saved = buildMimeMessage(
        draft: const Draft(
          accountId: 'a',
          kind: ComposeKind.newMessage,
          subject: 'Later',
          importance: Importance.low,
          requestReadReceipt: true,
        ),
        account: account,
      ).renderMessage();
      final headers = savedDraftHeaders(saved);
      expect(headers.importance, Importance.low);
      expect(headers.requestReadReceipt, isTrue);
    });
  });

  test('the settings: Undo Send for 5 seconds, both checks, and asked', () {
    const fresh = DisplaySettings();
    expect(fresh.undoSend, UndoSend.five);
    expect(fresh.undoSend.hold, const Duration(seconds: 5));
    expect(fresh.askNoSubject, isTrue);
    expect(fresh.attachmentReminder, isTrue);
    expect(fresh.receipts, ReceiptAnswer.ask);
    expect(DisplaySettings.fromJson(const {}), fresh,
        reason: 'a record from before them has the defaults');

    final changed = fresh.copyWith(
      undoSend: UndoSend.off,
      askNoSubject: false,
      attachmentReminder: false,
      receipts: ReceiptAnswer.never,
    );
    expect(DisplaySettings.fromJson(changed.toJson()), changed);
    expect(changed, isNot(fresh));
  });

  test("a read receipt's words name the message it answers", () {
    final original = em.MimeMessage()
      ..addHeader('Disposition-Notification-To', 'dana@example.com')
      ..addHeader('Message-ID', '<m1@example.com>')
      ..addHeader('Subject', 'Plans')
      ..addHeader('From', 'Dana <dana@example.com>');
    final receipt = em.MessageBuilder.buildReadReceipt(
      original,
      em.MailAddress('Ron', 'me@example.com'),
      reportingUa: 'MyEmail',
      subject: 'Read: Plans',
      textTemplate: readReceiptText,
    );
    final text = receipt.renderMessage();
    expect(receipt.decodeSubject(), 'Read: Plans');
    expect(receipt.to!.single.email, 'dana@example.com');
    expect(text, contains('multipart/report'));
    expect(text, contains('Original-Message-ID: <m1@example.com>'));
    expect(text, contains('Subject: Plans'));
    expect(text, contains('was read.'));
  });
}
