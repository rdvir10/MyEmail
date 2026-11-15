import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/imap/enough_mail_transport.dart';
import 'package:myemail/domain/mail_credentials.dart';

/// What a list row is read from over IMAP, asked of a small server on this
/// machine through the real transport.
void main() {
  late _HeaderServer server;

  setUp(() async => server = await _HeaderServer.start());
  tearDown(() => server.close());

  EnoughMailTransport transport() {
    final t = EnoughMailTransport(
      host: '127.0.0.1',
      port: server.port,
      user: 'ron@example.com',
      credentials: const PasswordCredentials('app-password'),
      useTls: false,
      commandLimit: const Duration(seconds: 5),
    );
    addTearDown(t.close);
    return t;
  }

  test('a Google sign-in logs in with its token, not a password', () async {
    // XOAUTH2, the one mechanism Gmail takes a token by: the address and
    // the access token, base64 together, in the AUTHENTICATE line itself.
    final t = EnoughMailTransport(
      host: '127.0.0.1',
      port: server.port,
      user: 'ron@example.com',
      credentials: OAuthCredentials(({bool force = false}) async => 'ya29.t'),
      useTls: false,
      commandLimit: const Duration(seconds: 5),
    );
    addTearDown(t.close);

    await t.listFolders();

    expect(server.logins, hasLength(1));
    expect(server.logins.single, startsWith('AUTHENTICATE XOAUTH2 '));
    final blob = utf8.decode(
      base64Decode(server.logins.single.split(' ').last.trim()),
    );
    expect(blob, contains('user=ron@example.com'));
    expect(blob, contains('auth=Bearer ya29.t'));
  });

  test('a header fetch asks when each message arrived, and keeps it',
      () async {
    // The Date header is the sender's word, and missing here. INTERNALDATE
    // is when the server took the message in: what a message with no
    // usable Date is dated by, and what the widget counts new mail by.
    final t = transport();

    final headers = await t.fetchHeadersBySequence('INBOX', 1, 1);

    expect(server.fetches.single, contains('INTERNALDATE'));
    final h = headers.single;
    expect(h.uid, 7);
    // And its size, as Outlook shows it for Gmail.
    expect(server.fetches.single, contains('RFC822.SIZE'));
    expect(h.sizeBytes, 48213);
    expect(h.arrived!.toUtc(), DateTime.utc(2019, 10, 25, 14, 35, 31));
    expect(h.date.toUtc(), DateTime.utc(2019, 10, 25, 14, 35, 31));
  });

  test('a subject and a name in Hebrew charsets are read, not left encoded',
      () async {
    // windows-1255 and iso-8859-8-i, which enough_mail has no table for:
    // it left the encoded words as they came, and the row showed
    // "=?windows-1255?B?...?=" for a subject.
    final payment = [0xFA, 0xF9, 0xEC, 0xE5, 0xED, 0x20, 0xA4, 0x31, 0x32];
    server
      ..subject = '=?windows-1255?B?${base64.encode(payment)}?='
      ..fromName = '=?iso-8859-8-i?Q?=E3=F0=E4_=EB=E4=EF?=';

    final h = (await transport().fetchHeadersBySequence('INBOX', 1, 1)).single;

    expect(h.subject, 'תשלום ₪12');
    expect(h.from.name, 'דנה כהן');
    expect(h.from.email, 'dana@example.com');
  });

  test('a meeting request from Outlook is a meeting by its structure',
      () async {
    // How Exchange sends every meeting request: text, HTML and the
    // invitation side by side, none of them marked attachment or inline.
    // The header fetch brings the structure and none of the parts, and
    // only a calendar part with a disposition was looked for: no meeting
    // mark on the row, no Accept and Decline on the notification.
    server.structure = '(("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL '
        '"QUOTED-PRINTABLE" 120 4 NIL NIL NIL NIL)'
        '("TEXT" "HTML" ("CHARSET" "utf-8") NIL NIL '
        '"QUOTED-PRINTABLE" 900 20 NIL NIL NIL NIL)'
        '("TEXT" "CALENDAR" ("CHARSET" "utf-8" "METHOD" "REQUEST") NIL NIL '
        '"BASE64" 1500 20 NIL NIL NIL NIL) '
        '"ALTERNATIVE" ("BOUNDARY" "_000_") NIL NIL NIL)';

    final h = (await transport().fetchHeadersBySequence('INBOX', 1, 1)).single;

    expect(h.isMeeting, isTrue);
    expect(h.hasAttachments, isFalse, reason: 'the invitation is no file');
  });

  test('a reply and a forward made elsewhere come with the header', () async {
    // \Answered is IMAP's own flag, and $Forwarded the keyword every mail
    // app that marks a forward uses: another app, or this one on another
    // device.
    server.flags = r'\Seen \Answered $Forwarded';
    final t = transport();

    final h = (await t.fetchHeadersBySequence('INBOX', 1, 1)).single;

    expect(h.isAnswered, isTrue);
    expect(h.isForwarded, isTrue);
  });

  test('and with the flags a sync reads again', () async {
    // What a folder already cached is brought up to date with.
    server.flags = r'\Seen $Forwarded';
    final t = transport();

    final flags = (await t.fetchFlags('INBOX', 7, 7)).single;

    expect(flags.isAnswered, isFalse);
    expect(flags.isForwarded, isTrue);
    // The size too, so rows cached without one get it.
    expect(server.fetches.single, contains('RFC822.SIZE'));
    expect(flags.sizeBytes, 48213);
  });

  test('news of another message during a header fetch is not a row',
      () async {
    // A server may say what changed in another message while it answers,
    // and the library keeps the line in the result as a message of its
    // own. Read as a header, it was a row with no subject, no sender, and
    // the time of the sync for its date.
    server.before = r'* 2 FETCH (UID 9 FLAGS (\Seen))';
    final t = transport();

    for (final headers in [
      await t.fetchHeadersBySequence('INBOX', 1, 1),
      await t.fetchHeadersFromUid('INBOX', 7),
      await t.fetchHeadersByUids('INBOX', [7]),
    ]) {
      expect([for (final h in headers) h.uid], [7]);
      expect(headers.single.subject, 'Hello');
    }
  });

  test('nor news of the same message after its answer', () async {
    // Not next to the answer, so not joined to it: a second header for
    // the message, the later one, which is what a cache keeps.
    server.after = '* 2 FETCH (UID 9 FLAGS (\\Seen))\r\n'
        '* 1 FETCH (UID 7 FLAGS (\\Seen))';

    final headers = await transport().fetchHeadersBySequence('INBOX', 1, 1);

    expect([for (final h in headers) h.uid], [7]);
    final h = headers.single;
    expect(h.subject, 'Hello');
    expect(h.from.email, 'dana@example.com');
    expect(h.messageId, isNotNull);
  });

  test('an answer whose envelope could not be read is still a row', () async {
    // An empty subject sent as {0}: the library takes the line after it
    // for its value, and the envelope with it. The arrival and the size
    // came before it, so it is an answer, and shows as the row it was.
    server.envelopeBroken = true;

    final headers = await transport().fetchHeadersBySequence('INBOX', 1, 1);

    expect([for (final h in headers) h.uid], [7]);
    expect(headers.single.sizeBytes, 48213);
    expect(headers.single.arrived, isNotNull);
  });

  test('a server that sends no size leaves it unknown', () async {
    server.sendSize = false;
    final t = transport();

    expect((await t.fetchHeadersBySequence('INBOX', 1, 1)).single.sizeBytes, 0);
    expect((await t.fetchFlags('INBOX', 7, 7)).single.sizeBytes, isNull);
  });

  test(r'a reply marks the original \Answered, a forward $Forwarded',
      () async {
    final t = transport();

    await t.markAnswered('INBOX', 7);
    await t.markAnswered('INBOX', 7, toAll: true);
    await t.markForwarded('INBOX', 7);

    expect(server.stores, [
      r'UID STORE 7 +FLAGS.SILENT (\Answered)',
      r'UID STORE 7 +FLAGS.SILENT (\Answered)',
      r'UID STORE 7 +FLAGS.SILENT ($Forwarded)',
    ]);
    expect(t.keepsBothMarks, isTrue);
  });
}

class _HeaderServer {
  _HeaderServer._(this._socket);

  final ServerSocket _socket;
  final _clients = <Socket>[];

  /// Every FETCH command, as sent.
  final fetches = <String>[];

  /// Every STORE command, as sent.
  final stores = <String>[];

  /// Every LOGIN or AUTHENTICATE command, as sent.
  final logins = <String>[];

  /// The message's FLAGS, as the server sends them.
  /// Whether FETCH answers carry RFC822.SIZE.
  bool sendSize = true;

  String flags = '';

  /// The subject and the sender's name, as the ENVELOPE carries them.
  String subject = 'Hello';
  String fromName = 'Dana';

  /// The message's BODYSTRUCTURE: plain text alone, unless a test says.
  String structure = '("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "7BIT" 5 1)';

  /// Lines about messages sent ahead of and after each FETCH answer.
  String? before;
  String? after;

  /// The subject sent as an empty literal, `{0}`, which the library reads
  /// the rest of the line into.
  bool envelopeBroken = false;

  int get port => _socket.port;

  static Future<_HeaderServer> start() async {
    final server = _HeaderServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._socket.listen(server._serve);
    return server;
  }

  void _serve(Socket client) {
    _clients.add(client);
    client.write('* OK [CAPABILITY IMAP4rev1] fake ready\r\n');
    client
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final space = line.indexOf(' ');
      if (space < 0) return;
      final tag = line.substring(0, space);
      final command = line.substring(space + 1);
      final verb = command.toUpperCase();
      if (verb.startsWith('LOGIN') || verb.startsWith('AUTHENTICATE')) {
        logins.add(command);
        client.write('$tag OK [CAPABILITY IMAP4rev1] signed in\r\n');
      } else if (verb.startsWith('CAPABILITY')) {
        client.write('* CAPABILITY IMAP4rev1\r\n$tag OK done\r\n');
      } else if (verb.startsWith('LIST')) {
        client.write('* LIST (\\HasNoChildren) "/" INBOX\r\n'
            '* STATUS INBOX (MESSAGES 1 UNSEEN 1)\r\n'
            '$tag OK LIST done\r\n');
      } else if (verb.startsWith('SELECT') || verb.startsWith('EXAMINE')) {
        client.write('* 1 EXISTS\r\n'
            '* OK [UIDVALIDITY 1] valid\r\n'
            '* OK [UIDNEXT 8] next\r\n'
            '$tag OK [READ-WRITE] selected\r\n');
      } else if (verb.startsWith('FETCH') || verb.startsWith('UID FETCH')) {
        fetches.add(command);
        client.write('${before == null ? '' : '$before\r\n'}'
            '* 1 FETCH (UID 7 FLAGS ($flags) '
            '${sendSize ? 'RFC822.SIZE 48213 ' : ''}'
            'INTERNALDATE "25-Oct-2019 16:35:31 +0200" '
            'ENVELOPE (NIL ${envelopeBroken ? '{0}\r\n' : '"$subject"'} '
            '(("$fromName" NIL "dana" "example.com")) '
            'NIL NIL NIL NIL NIL NIL "<m-1@example.com>") '
            'BODYSTRUCTURE $structure)\r\n'
            '${after == null ? '' : '$after\r\n'}'
            '$tag OK FETCH done\r\n');
      } else if (verb.startsWith('STORE') || verb.startsWith('UID STORE')) {
        stores.add(command);
        client.write('$tag OK STORE done\r\n');
      } else if (verb.startsWith('LOGOUT')) {
        client.write('* BYE\r\n$tag OK bye\r\n');
        client.destroy();
      } else {
        client.write('$tag OK\r\n');
      }
    }, onError: (_) {}, cancelOnError: true);
  }

  Future<void> close() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _socket.close();
  }
}
