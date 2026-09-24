import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
/// HTML and a text rendering of it, in a multipart/related with the pictures
/// the HTML shows when there are any, plus any attachments.
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

  // A picture the HTML shows in place goes beside it, in a
  // multipart/related, under its Content-ID; the cid: link finds it there.
  final pictures = [
    for (final a in draft.attachments)
      if (a.contentId != null) a,
  ];
  final body = pictures.isEmpty
      ? builder
      : builder.addPart(mediaSubtype: em.MediaSubtype.multipartRelated);
  final html = restoreBlockedImages(draft.htmlBody);
  body.addMultipartAlternative(
    plainText: plainTextFromHtml(html),
    htmlText: html,
  );
  for (final picture in pictures) {
    _addFile(body, picture);
  }

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
    if (attachment.contentId == null) _addFile(builder, attachment);
  }

  final message = builder.buildMimeMessage();
  // RFC 2045 allows a multipart no transfer encoding but 7bit, 8bit or
  // binary, and enough_mail gives the top of every message base64. Its parts
  // carry their own.
  if (message.mediaType.isMultipart) {
    message.removeHeader('Content-Transfer-Encoding');
  }
  return message;
}

/// One file as a part of [parent]: inline under its Content-ID if the HTML
/// shows it, attached otherwise.
///
/// The name is written here rather than by enough_mail, which puts it in the
/// header as it is. A Hebrew name went out as raw UTF-8 in a 7-bit session,
/// which strict and older clients show as rubbish, and a quote in a name
/// ended it early for any reader that follows the rules.
void _addFile(em.PartBuilder parent, DraftAttachment file) {
  final cid = file.contentId;
  final disposition = em.ContentDispositionHeader.from(
    cid == null ? em.ContentDisposition.attachment : em.ContentDisposition.inline,
    size: file.size,
  );
  final part = parent.addBinary(
    file.bytes,
    em.MediaType.guessFromFileName(file.fileName),
    disposition: disposition,
  );
  final name = file.fileName;
  if (_isPlainName(name)) {
    disposition.filename = name;
    part.contentType?.parameters['name'] = '"$name"';
  } else {
    // RFC 2231 is what readers look for first. The name in Content-Type is
    // for the ones that do not: encoded words, as Outlook and Thunderbird
    // write it, which nearly everything reads.
    disposition.parameters.addAll(_rfc2231('filename', name));
    part.contentType?.parameters['name'] = '"${_encodedWords(name)}"';
  }
  if (cid != null) part.setHeader('Content-ID', '<$cid>');
}

/// A name that can go in a header between quotes as it is: printable ASCII,
/// nothing that would end the quotes or split the header, and short enough
/// not to be folded.
bool _isPlainName(String name) =>
    name.length <= 60 &&
    name.runes.every((c) =>
        c >= 0x20 && c < 0x7f && c != 0x22 && c != 0x5c && c != 0x3b);

/// [name]=[value] as RFC 2231 has it: UTF-8, percent-encoded, and in
/// numbered pieces when it is long.
///
/// The pieces are short on purpose. enough_mail folds a header only at a
/// semicolon or a space, and a stretch with neither that is too long for
/// the line it cuts wherever it reaches the limit, through the middle of a
/// value.
Map<String, String> _rfc2231(String name, String value) {
  final pieces = <String>[];
  final piece = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final token = _attributeChar(byte)
        ? String.fromCharCode(byte)
        : '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}';
    if (piece.length + token.length > 40) {
      pieces.add(piece.toString());
      piece.clear();
    }
    piece.write(token);
  }
  pieces.add(piece.toString());
  if (pieces.length == 1) return {'$name*': "UTF-8''${pieces.single}"};
  return {
    for (final (i, p) in pieces.indexed) '$name*$i*': i == 0 ? "UTF-8''$p" : p,
  };
}

/// What RFC 2231 lets stand for itself in an encoded value.
bool _attributeChar(int byte) =>
    (byte >= 0x30 && byte <= 0x39) ||
    (byte >= 0x41 && byte <= 0x5a) ||
    (byte >= 0x61 && byte <= 0x7a) ||
    '!#\$&+-.^_`|~'.codeUnits.contains(byte);

/// [value] as RFC 2047 encoded words, none splitting a character, and each
/// short enough to have a line to itself for the reason [_rfc2231] gives.
String _encodedWords(String value) {
  final words = <String>[];
  var bytes = <int>[];
  for (final rune in value.runes) {
    final encoded = utf8.encode(String.fromCharCode(rune));
    if (bytes.length + encoded.length > 30) {
      words.add('=?UTF-8?B?${base64Encode(bytes)}?=');
      bytes = [];
    }
    bytes.addAll(encoded);
  }
  words.add('=?UTF-8?B?${base64Encode(bytes)}?=');
  return words.join(' ');
}

/// [draft] with each picture its HTML carries as a `data:` URI taken out
/// into a part of its own, which the HTML then names by Content-ID.
///
/// A signature keeps its logo as data (see inlineRemoteImages), and a pasted
/// picture arrives as data too. Gmail strips a data: picture from mail it
/// receives and Outlook for Windows does not show one, so those recipients
/// saw a broken logo in every signature. A part beside the HTML is what
/// every client shows, Graph's MIME send included.
///
/// For sending only. A saved draft keeps its pictures as data, which the
/// editor can show when it is reopened and a cid: link it cannot.
Draft withPicturesAsParts(Draft draft) {
  final pattern = RegExp(
    r'''(<img\b[^>]*?\bsrc\s*=\s*)(["'])data:(image/[\w.+-]+);base64,([^"']*)\2''',
    caseSensitive: false,
  );
  if (!pattern.hasMatch(draft.htmlBody)) return draft;

  // One part for one picture, however often the HTML shows it.
  final idFor = <String, String>{};
  final pictures = <DraftAttachment>[];
  final html = draft.htmlBody.replaceAllMapped(pattern, (m) {
    final type = m[3]!.toLowerCase();
    final data = m[4]!.replaceAll(RegExp(r'\s'), '');
    var id = idFor['$type,$data'];
    if (id == null) {
      final Uint8List bytes;
      try {
        bytes = base64Decode(data);
      } on FormatException {
        return m[0]!;
      }
      id = '${em.MessageBuilder.createRandomId()}@myemail';
      idFor['$type,$data'] = id;
      pictures.add(DraftAttachment(
        fileName: 'picture${pictures.length + 1}.${_extensionFor(type)}',
        mimeType: type,
        bytes: bytes,
        contentId: id,
      ));
    }
    return '${m[1]}${m[2]}cid:$id${m[2]}';
  });
  if (pictures.isEmpty) return draft;
  return draft.copyWith(
    htmlBody: html,
    attachments: [...draft.attachments, ...pictures],
  );
}

/// A file extension for an image type, which is what buildMimeMessage reads
/// the part's type from.
String _extensionFor(String imageType) =>
    switch (imageType.split('/').last) {
      'jpeg' || 'pjpeg' => 'jpg',
      'svg+xml' => 'svg',
      'x-icon' || 'vnd.microsoft.icon' => 'ico',
      final other => other,
    };

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
