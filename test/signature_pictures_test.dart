import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/compose/graph_sender.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_credentials.dart';
import 'package:myemail/domain/mail_message.dart';

import 'fakes/fake_imap_transport.dart';

/// Pictures written into a message as `data:` URIs, which is how a
/// signature keeps its logo and how a pasted picture arrives.
///
/// Gmail strips a data: picture from the mail it receives and Outlook for
/// Windows does not show one, so those recipients saw a broken logo in every
/// signature. They go out as parts of their own, named by Content-ID.
void main() {
  final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 7, 7]);
  final logo = 'data:image/png;base64,${base64Encode(png)}';

  Draft signed({List<DraftAttachment> attachments = const []}) => Draft(
        accountId: 'a',
        kind: ComposeKind.newMessage,
        to: const [MailAddress(email: 'dana@example.com')],
        subject: 'Hello',
        htmlBody: '<p>Hi</p><p>Ron<br><img src="$logo" width="80"></p>'
            '<p>Again: <img src=\'$logo\'></p>',
        attachments: attachments,
      );

  /// The HTML of [message], and each inline part's bytes by Content-ID.
  ({String html, Map<String, Uint8List> parts, bool related}) read(
    em.MimeMessage message,
  ) {
    final parsed = em.MimeMessage.parseFromText(message.renderMessage());
    return (
      html: parsed.decodeTextHtmlPart() ?? '',
      parts: {
        for (final p in parsed.allPartsFlat)
          if (p.getHeaderValue('content-id') case final id?)
            id.replaceAll(RegExp('[<>]'), ''): p.decodeContentBinary()!,
      },
      related: parsed.allPartsFlat
          .any((p) => p.mediaType.sub == em.MediaSubtype.multipartRelated),
    );
  }

  group('withPicturesAsParts', () {
    test('each picture becomes a part the HTML names by Content-ID', () {
      final out = withPicturesAsParts(signed());

      expect(out.htmlBody, isNot(contains('data:')));
      final ids = RegExp(r'''src=["']cid:([^"']+)["']''')
          .allMatches(out.htmlBody)
          .map((m) => m[1])
          .toSet();
      expect(ids, hasLength(1), reason: 'the same logo twice is one part');
      final picture = out.attachments.single;
      expect(picture.contentId, ids.single);
      expect(picture.bytes, png);
      expect(picture.mimeType, 'image/png');
      expect(out.htmlBody, contains('width="80"'),
          reason: 'the rest of the tag is left alone');
    });

    test('a message with none is left as it was', () {
      final plain = signed().copyWith(htmlBody: '<p>Hi</p>');
      expect(identical(withPicturesAsParts(plain), plain), isTrue);
    });

    test('files already on the message keep their place', () {
      final pdf = DraftAttachment(
        fileName: 'a.pdf',
        mimeType: 'application/pdf',
        bytes: Uint8List.fromList([1]),
      );
      final out = withPicturesAsParts(signed(attachments: [pdf]));
      expect(out.attachments.first, same(pdf));
      expect(out.attachments, hasLength(2));
    });
  });

  group('sending', () {
    late FakeImapTransport server;
    late CachedImapEngine engine;
    final sentOverSmtp = <em.MimeMessage>[];
    final postedToGraph = <String>[];

    setUp(() {
      sentOverSmtp.clear();
      postedToGraph.clear();
      server = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox)
        ..folder('Drafts', role: FolderRole.drafts);
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
        senderFactory: (_, _) => _Recording(sentOverSmtp),
      );
    });

    test('Gmail gets the logo as a part beside the HTML', () async {
      final account = await engine.addAccount(
        displayName: 'Ron',
        emailAddress: 'ron@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );

      await engine.sendDraft(signed().copyWith(accountId: account.id));

      final sent = read(sentOverSmtp.single);
      expect(sent.html, isNot(contains('data:')));
      final cid = RegExp(r'cid:([^"]+)"').firstMatch(sent.html)![1]!;
      expect(sent.parts[cid], png);
      expect(sent.related, isTrue);
    });

    test('and so does a message sent through Graph', () async {
      // Without an SMTP sender, which would otherwise take every account.
      final engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
        graphSenderFactory: (_, _) => GraphSender(
          accessToken: ({bool force = false}) async => 'graph-token',
          httpClient: http_testing.MockClient((request) async {
            postedToGraph.add(request.body);
            return http.Response('', 202);
          }),
        ),
      );
      final account = await engine.addOAuthAccount(
        displayName: 'Ron',
        emailAddress: 'ron@hadco.example',
        provider: MailProvider.outlook,
        token: OAuthToken(
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );

      await engine.sendDraft(signed().copyWith(accountId: account.id));

      final mime = utf8.decode(base64Decode(postedToGraph.single));
      final sent = read(em.MimeMessage.parseFromText(mime));
      expect(sent.html, isNot(contains('data:')));
      final cid = RegExp(r'cid:([^"]+)"').firstMatch(sent.html)![1]!;
      expect(sent.parts[cid], png);
    });

    test('a saved draft keeps its pictures as they were', () async {
      // The editor shows a data: picture when the draft is reopened, and
      // has nothing to show a cid: one with.
      final account = await engine.addAccount(
        displayName: 'Ron',
        emailAddress: 'ron@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );

      await engine.saveDraft(signed().copyWith(accountId: account.id));

      final saved = em.MimeMessage.parseFromText(server.appended.single);
      expect(saved.decodeTextHtmlPart(), contains('data:image/png'));
    });
  });
}

class _Recording extends SmtpSender {
  _Recording(this.sent)
      : super(
          host: 'smtp.example',
          user: '',
          credentials: const PasswordCredentials(''),
        );

  final List<em.MimeMessage> sent;

  @override
  Future<void> send(em.MimeMessage message) async => sent.add(message);
}
