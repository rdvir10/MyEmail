import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/account.dart';
import '../../domain/draft.dart';
import '../../domain/mail_message.dart' as domain;
import '../mail_engine.dart';
import 'quote_builder.dart';

/// Turning a [Draft] into a MIME message, and putting it on the wire.
///
/// Kept apart from the engine so the message construction can be tested
/// without a socket: [buildMimeMessage] is pure, and only [SmtpSender] opens
/// a connection.

/// The MIME message a draft becomes: multipart/alternative with the editor's
/// HTML and a text rendering of it, plus any attachments.
em.MimeMessage buildMimeMessage({
  required Draft draft,
  required Account account,
}) {
  final from = em.MailAddress(account.displayName, account.emailAddress);
  final builder = em.MessageBuilder()
    ..from = [from]
    ..to = [for (final a in draft.to) _addr(a)]
    ..cc = [for (final a in draft.cc) _addr(a)]
    ..bcc = [for (final a in draft.bcc) _addr(a)]
    ..subject = draft.subject.trim().isEmpty
        ? '(No subject)'
        : draft.subject.trim();

  // Threading: a reply that omits these starts a new conversation in every
  // client that shows threads.
  final inReplyTo = draft.inReplyTo;
  if (inReplyTo != null) {
    builder.setHeader('In-Reply-To', inReplyTo);
    final references = [...draft.references, inReplyTo];
    builder.setHeader('References', references.join(' '));
  }

  builder.addMultipartAlternative(
    plainText: plainTextFromHtml(draft.htmlBody),
    htmlText: draft.htmlBody,
  );

  for (final attachment in draft.attachments) {
    builder.addBinary(
      attachment.bytes,
      em.MediaType.guessFromFileName(attachment.fileName),
      filename: attachment.fileName,
    );
  }

  return builder.buildMimeMessage();
}

em.MailAddress _addr(domain.MailAddress a) =>
    em.MailAddress(a.name, a.email);

/// SMTP over TLS for one account.
class SmtpSender {
  const SmtpSender({
    required this.host,
    required this.user,
    required this.secret,
    this.port = 465,
    this.isLogEnabled = false,
  });

  final String host;
  final String user;
  final String secret;

  /// 465 is implicit TLS, which is what Gmail wants and what avoids the
  /// STARTTLS upgrade dance.
  final int port;
  final bool isLogEnabled;

  static String smtpHostFor(MailProvider provider) => switch (provider) {
        MailProvider.gmail => 'smtp.gmail.com',
        MailProvider.outlook => 'smtp.office365.com',
      };

  Future<void> send(em.MimeMessage message) async {
    final client = em.SmtpClient('myemail', isLogEnabled: isLogEnabled);
    try {
      try {
        await client.connectToServer(host, port, isSecure: true);
        await client.ehlo();
      } on Exception catch (e) {
        throw ConnectionFailed('Could not reach $host. ($e)');
      }

      try {
        // PLAIN is what Gmail accepts with an app password; LOGIN is the
        // fallback for servers that do not advertise PLAIN.
        final mechanism = client.serverInfo.supportsAuth(em.AuthMechanism.plain)
            ? em.AuthMechanism.plain
            : em.AuthMechanism.login;
        await client.authenticate(user, secret, mechanism);
      } on em.SmtpException catch (e) {
        throw AuthenticationFailed(
          'The mail server refused the sign-in for sending. '
          'Check the app password. (${e.message ?? 'no reason given'})',
        );
      }

      final response = await client.sendMessage(message);
      if (!response.isOkStatus) {
        throw SendFailed(
          'The server would not accept the message: '
          '${response.message ?? response.code}',
        );
      }
    } on em.SmtpException catch (e) {
      throw SendFailed('Sending failed: ${e.message ?? e.toString()}');
    } finally {
      try {
        await client.quit();
      } catch (_) {
        // The message is already sent or already failed; a rude disconnect
        // changes nothing.
      }
    }
  }
}
