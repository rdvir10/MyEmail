import 'dart:async';

import 'package:enough_mail/enough_mail.dart' as em;
// SmtpCommand is how SmtpClient lets a caller drive a conversation of its
// own; the package uses it for every command but does not export it.
// ignore: implementation_imports
import 'package:enough_mail/src/private/smtp/smtp_command.dart';

import '../../domain/account.dart';
import '../../domain/draft.dart';
import '../../domain/mail_credentials.dart';
import '../../domain/mail_message.dart' as domain;
import '../imap/imap_mapping.dart' show normaliseMessageId;
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
  final from = em.MailAddress(account.senderName, account.emailAddress);
  final builder = em.MessageBuilder()
    ..from = [from]
    ..to = [for (final a in draft.to) _addr(a)]
    ..cc = [for (final a in draft.cc) _addr(a)]
    ..bcc = [for (final a in draft.bcc) _addr(a)]
    ..subject = draft.subject.trim().isEmpty
        ? '(No subject)'
        : draft.subject.trim();

  // Threading: a reply that omits these starts a new conversation in every
  // client that shows threads. The cache keeps ids without their angle
  // brackets and a saved draft's header has them, so each is put in its
  // written form here.
  final inReplyTo = _angled(draft.inReplyTo);
  if (inReplyTo != null) {
    builder.setHeader('In-Reply-To', inReplyTo);
    final references = [
      for (final id in draft.references) ?_angled(id),
      inReplyTo,
    ];
    builder.setHeader('References', references.join(' '));
  }

  final html = restoreBlockedImages(draft.htmlBody);
  builder.addMultipartAlternative(
    plainText: plainTextFromHtml(html),
    htmlText: html,
  );

  // An answer to an invitation: the calendar part goes beside the text,
  // typed so a calendar server knows it for a reply.
  final reply = draft.calendarReply;
  if (reply != null) {
    final part = builder.addText(
      reply,
      mediaType: em.MediaType.fromText('text/calendar'),
    );
    part.contentType?.setParameter('method', 'REPLY');
  }

  for (final attachment in draft.attachments) {
    final cid = attachment.contentId;
    final part = builder.addBinary(
      attachment.bytes,
      em.MediaType.guessFromFileName(attachment.fileName),
      filename: attachment.fileName,
      // A picture the HTML shows in place goes inline under its Content-ID,
      // or the cid: link in a forwarded quote finds nothing.
      disposition: cid == null
          ? null
          : em.ContentDispositionHeader.from(
              em.ContentDisposition.inline,
              filename: attachment.fileName,
              size: attachment.size,
            ),
    );
    if (cid != null) part.setHeader('Content-ID', '<$cid>');
  }

  return builder.buildMimeMessage();
}

em.MailAddress _addr(domain.MailAddress a) =>
    em.MailAddress(a.name, a.email);

String? _angled(String? id) {
  final bare = normaliseMessageId(id);
  return bare == null ? null : '<$bare>';
}

/// Everyone the message is delivered to: To, Cc and Bcc, each address once.
///
/// Passed to the server as the envelope, which is the only place Bcc
/// recipients belong.
List<em.MailAddress> envelopeRecipients(em.MimeMessage message) {
  final seen = <String>{};
  return [
    for (final a in [...?message.to, ...?message.cc, ...?message.bcc])
      if (seen.add(a.email.toLowerCase())) a,
  ];
}

/// The bytes that go between DATA and the final dot.
///
/// Done here rather than left to enough_mail, which gets two things wrong.
///
/// Bcc: it removes the header with a pattern that takes only its first
/// physical line. A Bcc list longer than about 76 characters is folded onto
/// continuation lines, those survive, and because they start with
/// whitespace they join the header above them — Cc, or To — so every
/// recipient sees the blind copies. Here the header goes with all its
/// continuation lines.
///
/// Dot-stuffing: RFC 5321 4.5.2 says every line that starts with a dot gets
/// another one. enough_mail pads only lines that are exactly a dot, and of
/// two such lines in a row only the first. A second bare dot ended the
/// message early and whatever followed reached the server as commands, so
/// a message quoting hidden `.` lines could make a reply send mail of the
/// sender's choosing; and "...and then" arrived as "..and then". Here every
/// leading dot is doubled, so no line of the message can be the terminator.
String wireText(em.MimeMessage message) {
  final rendered =
      message.renderMessage().replaceAll(RegExp(r'\r?\n'), '\r\n');
  final end = rendered.indexOf('\r\n\r\n');
  final head = end < 0 ? rendered : rendered.substring(0, end + 2);
  final body = end < 0 ? '' : rendered.substring(end + 2);
  final visible = head.replaceAll(
    RegExp(r'^Bcc:.*\r\n(?:[ \t].*\r\n)*', multiLine: true, caseSensitive: false),
    '',
  );
  final stuffed = (visible + body)
      .replaceAllMapped(RegExp(r'(^|\r\n)\.'), (m) => '${m[1]}..');
  // EnvelopeCommand adds CRLF before the final dot itself.
  return stuffed.endsWith('\r\n')
      ? stuffed.substring(0, stuffed.length - 2)
      : stuffed;
}

/// MAIL FROM, a RCPT TO for each recipient, then DATA, reading every reply.
///
/// enough_mail's own version reads only the reply to the last RCPT. A
/// mistyped Bcc anywhere but last was refused, the message went to the rest,
/// and the app said it was sent; a refused MAIL FROM surfaced as the "MAIL
/// first" that followed it rather than the reason. Here any refused
/// recipient stops the send before DATA, naming the addresses, so nobody
/// gets a copy until the list is right. A refused MAIL FROM or DATA ends it
/// with the server's own words.
class EnvelopeCommand extends SmtpCommand {
  EnvelopeCommand({
    required this.text,
    required this.from,
    required this.recipients,
  }) : super('MAIL FROM:<$from>');

  /// What goes between DATA and the final dot: [wireText].
  final String text;
  final String from;
  final List<String> recipients;

  /// Each recipient the server refused, with what it said.
  final refused = <String, String>{};

  var _step = _EnvelopeStep.mailFrom;
  var _index = 0;

  @override
  String? nextCommand(em.SmtpResponse response) {
    switch (_step) {
      case _EnvelopeStep.mailFrom:
        if (!response.isOkStatus) return null;
        if (recipients.isEmpty) {
          throw const SendFailed('The message has nobody to go to.');
        }
        _step = _EnvelopeStep.recipients;
        return 'RCPT TO:<${recipients.first}>';
      case _EnvelopeStep.recipients:
        if (!response.isOkStatus) {
          refused[recipients[_index]] =
              response.message ?? '${response.code}';
        }
        _index++;
        if (_index < recipients.length) {
          return 'RCPT TO:<${recipients[_index]}>';
        }
        if (refused.isNotEmpty) throw RecipientsRefused(refused);
        _step = _EnvelopeStep.data;
        return 'DATA';
      case _EnvelopeStep.data:
        if (response.code != 354) return null;
        _step = _EnvelopeStep.done;
        return '$text\r\n.';
      case _EnvelopeStep.done:
        return null;
    }
  }
}

enum _EnvelopeStep { mailFrom, recipients, data, done }

/// The server would not take some of the recipients, so nothing was sent.
class RecipientsRefused extends SendFailed {
  RecipientsRefused(this.refused) : super(_describe(refused));

  final Map<String, String> refused;

  static String _describe(Map<String, String> refused) {
    final lines = [
      for (final MapEntry(:key, :value) in refused.entries) '$key: $value',
    ];
    return 'The mail server would not take '
        '${refused.length == 1 ? 'this address' : 'these addresses'}, so '
        'nothing was sent:\n${lines.join('\n')}';
  }
}

/// SMTP over TLS for one account.
class SmtpSender {
  const SmtpSender({
    required this.host,
    required this.user,
    required this.credentials,
    this.port = 465,
    this.useStartTls = false,
    this.isLogEnabled = false,
  });

  /// Everything one provider needs to submit mail.
  SmtpSender.forProvider({
    required MailProvider provider,
    required this.user,
    required this.credentials,
    this.isLogEnabled = false,
  })  : host = smtpHostFor(provider),
        port = portFor(provider),
        useStartTls = usesStartTlsFor(provider);

  final String host;
  final String user;
  final MailCredentials credentials;
  final int port;

  /// Whether the connection starts in the clear and is upgraded, rather than
  /// being encrypted from the first byte.
  ///
  /// The two providers disagree, and getting it wrong does not degrade
  /// gracefully — it hangs or is refused outright. Gmail takes implicit TLS
  /// on 465. Microsoft does not listen on 465 at all: SMTP AUTH submission is
  /// port 587, in the clear, upgraded with STARTTLS before anything secret is
  /// sent.
  final bool useStartTls;
  final bool isLogEnabled;

  static String smtpHostFor(MailProvider provider) => switch (provider) {
        MailProvider.gmail => 'smtp.gmail.com',
        MailProvider.outlook => 'smtp.office365.com',
      };

  static int portFor(MailProvider provider) => switch (provider) {
        MailProvider.gmail => 465,
        MailProvider.outlook => 587,
      };

  static bool usesStartTlsFor(MailProvider provider) => switch (provider) {
        MailProvider.gmail => false,
        MailProvider.outlook => true,
      };

  /// How long each step may take before the server is taken to have gone.
  ///
  /// enough_mail limits nothing past the socket's own connect, and does not
  /// fail a command whose connection drops, so without these a send on a
  /// dying connection never returned: the Send button spun, and a reply from
  /// a notification hung its isolate until Android killed it.
  static const stepLimit = Duration(seconds: 60);

  /// For handing over the message itself, which can be large.
  static const transferLimit = Duration(minutes: 10);

  Future<void> send(em.MimeMessage message) async {
    final client = em.SmtpClient('myemail', isLogEnabled: isLogEnabled);
    try {
      try {
        await client.connectToServer(host, port, isSecure: !useStartTls);
        await client.ehlo().timeout(stepLimit);
        if (useStartTls) {
          final upgraded = await client.startTls().timeout(stepLimit);
          if (!upgraded.isOkStatus) {
            // Stop here rather than carrying on. Authenticating now would put
            // the app password, or the OAuth token, onto the wire as plain
            // text on a connection that never became private.
            throw const ConnectionFailed(
              'The mail server would not start an encrypted connection, so '
              'nothing was sent.',
            );
          }
        }
      } on ConnectionFailed {
        rethrow;
      } on Exception catch (e) {
        throw ConnectionFailed('Could not reach $host. ($e)');
      }

      try {
        switch (credentials) {
          case PasswordCredentials(:final password):
            // PLAIN is what Gmail accepts with an app password; LOGIN is the
            // fallback for servers that do not advertise PLAIN.
            final mechanism =
                client.serverInfo.supportsAuth(em.AuthMechanism.plain)
                    ? em.AuthMechanism.plain
                    : em.AuthMechanism.login;
            await client
                .authenticate(user, password, mechanism)
                .timeout(stepLimit);
          case OAuthCredentials(:final accessToken):
            // enough_mail builds the SASL XOAUTH2 string itself, so this
            // wants the bare access token and not a base64 anything.
            final token = await accessToken();
            await client
                .authenticate(user, token, em.AuthMechanism.xoauth2)
                .timeout(stepLimit);
        }
      } on em.SmtpException catch (e) {
        throw AuthenticationFailed(sendSignInFailureMessage(e.message));
      } on TimeoutException {
        throw ConnectionFailed(
          '$host stopped answering while signing in, so nothing was sent.',
        );
      }

      // Text of our own making, not sendMessage: see wireText for the two
      // things enough_mail's own framing gets wrong. And an envelope of our
      // own making: see EnvelopeCommand for what its envelope gets wrong.
      final em.SmtpResponse response;
      try {
        response = await client
            .sendCommand(EnvelopeCommand(
              text: wireText(message),
              from: message.from!.first.email,
              recipients: [
                for (final a in envelopeRecipients(message)) a.email,
              ],
            ))
            .timeout(transferLimit);
      } on TimeoutException {
        // The message may be on the server already; only its answer is
        // missing. Saying it failed outright could make someone send twice.
        throw const SendFailed(
          'The mail server stopped answering while the message was being '
          'handed over, so it may or may not have been sent. Check Sent '
          'before sending it again.',
        );
      }
      if (!response.isOkStatus) {
        throw SendFailed(
          'The server would not accept the message: '
          '${response.message ?? response.code}',
        );
      }
    } on em.SmtpException catch (e) {
      throw SendFailed('Sending failed: ${e.message ?? e.toString()}');
    } finally {
      await _hangUp(client);
    }
  }

  /// Say goodbye if there is anyone to say it to, and never wait long.
  ///
  /// QUIT on a connection that was never made used to wait forever: the
  /// socket had never been assigned, the write failed out of sight, and the
  /// command it was waiting for never completed. So a send while offline
  /// never reported that it could not connect.
  static Future<void> _hangUp(em.SmtpClient client) async {
    if (client.isConnected) {
      try {
        await client.quit().timeout(const Duration(seconds: 5));
        return;
      } catch (_) {
        // The message is already sent or already failed; a rude disconnect
        // changes nothing.
      }
    }
    try {
      await client.disconnect().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Turn the server's refusal to let us send into something actionable.
  ///
  /// The Microsoft case is the one worth naming. Some mailboxes answer a
  /// perfectly valid OAuth token with
  ///
  ///   535 5.7.139 SmtpClientAuthentication is disabled for the Mailbox
  ///
  /// which is SMTP submission being switched off for that mailbox rather than
  /// anything wrong with the sign-in. Who can switch it back on depends
  /// entirely on whose mailbox it is, and the two answers are far apart: on a
  /// work or school account an administrator runs one command, while on a
  /// personal Outlook.com account there is no such switch and no documented
  /// way round it. Reading keeps working either way, so the message has to
  /// say that this is sending only, and has to name the administrator,
  /// because telling someone with an IT department that nothing can be done
  /// would be wrong.
  static String sendSignInFailureMessage(String? raw) {
    final text = raw ?? '';
    if (text.contains('5.7.139') ||
        text.contains('SmtpClientAuthentication is disabled')) {
      return 'Microsoft has sending over SMTP switched off for this mailbox, '
          'so this account can receive mail here but not send it. That is a '
          'restriction on the mailbox rather than a problem with the sign-in. '
          'On a work or school account an administrator can switch it back '
          'on. On a personal Outlook.com account there is no such setting.';
    }
    if (text.isEmpty) {
      return 'The mail server refused the sign-in for sending, without saying '
          'why.';
    }
    return 'The mail server refused the sign-in for sending. ($text)';
  }
}
