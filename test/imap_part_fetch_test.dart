import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/imap/enough_mail_transport.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/domain/mail_credentials.dart';

/// Parts of a message fetched one at a time, `BODY[n]`, asked of a small
/// server on this machine through the real transport. The server sends each
/// part as Gmail does, in its transfer encoding and without its headers.
void main() {
  group('a part on its own', () {
    test('base64 comes back as the bytes, line breaks and all', () {
      final bytes = List<int>.generate(200, (i) => i);
      expect(decodePart(ascii.encode(_wrapped(bytes)), 'BASE64'), bytes);
    });

    test('quoted-printable comes back as the bytes it stands for', () {
      expect(
        decodePart(ascii.encode('Caf=C3=A9 at=\r\n noon=\nnow\r\n'),
            'quoted-printable'),
        utf8.encode('Café at noon' 'now\r\n'),
      );
    });

    test('a stray = in quoted-printable is kept, not a failure', () {
      expect(decodePart(ascii.encode('a=ZZ b='), 'quoted-printable'),
          ascii.encode('a=ZZ b='));
    });

    test('an unencoded part keeps every byte, line breaks included', () {
      final raw = [...ascii.encode('one\r\ntwo\r\n'), 0xE9];
      expect(decodePart(raw, '8bit'), raw);
      expect(decodePart(raw, '7BIT'), raw);
      expect(decodePart(raw, null), raw);
    });
  });

  group('over the wire', () {
    late _PartServer server;

    setUp(() async => server = await _PartServer.start());
    tearDown(() => server.close());

    EnoughMailTransport transport() {
      final t = EnoughMailTransport(
        host: '127.0.0.1',
        port: server.port,
        user: 'ron@example.com',
        credentials: const PasswordCredentials('app-password'),
        useTls: false,
        commandLimit: const Duration(seconds: 5),
        transferLimit: const Duration(seconds: 5),
      );
      addTearDown(t.close);
      return t;
    }

    test('an attached file comes back as the file, not its base64', () async {
      // Gmail sends every file in base64. Fetched with nothing to say so,
      // the PDF handed to the viewer was the base64 text, and "corrupt".
      final bytes = await transport().fetchAttachment('INBOX', 7, '2');

      expect(bytes, _pdf);
      expect(server.fetches.single, contains('BODYSTRUCTURE'),
          reason: 'the structure is what says how the part is encoded');
    });

    test('a picture the body shows comes back as the picture', () async {
      // Base64 of base64 in its data: URI, and a broken image.
      expect(await transport().fetchAttachment('INBOX', 7, '3'), _png);
    });

    test('an unencoded file keeps its line breaks', () async {
      // An attached email lost every one and no longer parsed as an email.
      expect(
        await transport().fetchAttachment('INBOX', 7, '4'),
        ascii.encode('line one\r\nline two\r\n'),
      );
    });

    test('a quoted-printable file comes back decoded', () async {
      expect(
        utf8.decode(await transport().fetchAttachment('INBOX', 7, '5')),
        'BEGIN:VCALENDAR\r\nSUMMARY:Café at noon\r\nEND:VCALENDAR\r\n',
      );
    });

    test('opening a message fetches its text and leaves its files', () async {
      // The whole message came down to show a few lines: every file on it,
      // a 20 MB video as 27 MB of base64, with nothing else for the account
      // able to run until it was in.
      final body = await transport().fetchBody('INBOX', 7);

      // Each in its own encoding and charset, as the structure gives them.
      expect(body.text.trim(), 'Café at noon, see you there.');
      expect(body.html, '<p>Café at noon, see you there.</p>');
      expect(body.calendar, contains('SUMMARY:Café at noon'),
          reason: 'an invitation sent as a file is still the invitation');
      final asked = server.fetches.join('\n');
      expect(asked, isNot(contains('BODY.PEEK[]')));
      for (final file in ['2', '3', '4']) {
        expect(asked, isNot(contains('BODY.PEEK[$file]')),
            reason: 'part $file is a file, not the text');
      }
    });

    test('a message of one part is fetched whole, which is all it is',
        () async {
      server.onePart = true;

      final body = await transport().fetchBody('INBOX', 7);

      expect(body.html, '<p>Café at noon, see you there.</p>');
      expect(body.text, 'Café at noon, see you there.');
      expect(server.fetches.last, contains('BODY.PEEK[]'));
    });
  });
}

/// A PDF's first bytes and then every byte value, so nothing survives a
/// decoding it should not have had.
final _pdf = [...ascii.encode('%PDF-1.4\n'), for (var i = 0; i < 256; i++) i];
const _png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];

/// Base64 in lines of 76, as mail carries it.
String _wrapped(List<int> bytes) {
  final text = base64.encode(bytes);
  return [
    for (var i = 0; i < text.length; i += 76)
      text.substring(i, i + 76 > text.length ? text.length : i + 76),
  ].join('\r\n');
}

/// One part of the message the server holds: its structure as BODYSTRUCTURE
/// gives it, its headers for the whole message, and its content as sent.
class _Part {
  _Part(this.id, this.structure, this.headers, String content)
      : content = latin1.encode(content);

  final String id;
  final String structure;
  final String headers;
  final Uint8List content;
}

/// A Gmail message: a plain and an HTML body side by side, then a PDF, a
/// logo the HTML shows, an attached text file and an invitation file.
final _parts = [
  _Part(
    '1.1',
    '("TEXT" "PLAIN" ("CHARSET" "iso-8859-1") NIL NIL "QUOTED-PRINTABLE" '
        r'$size 2 NIL NIL NIL NIL)',
    'Content-Type: text/plain; charset=iso-8859-1\r\n'
        'Content-Transfer-Encoding: quoted-printable\r\n',
    'Caf=E9 at noon, see=\r\n you there.\r\n',
  ),
  _Part(
    '1.2',
    '("TEXT" "HTML" ("CHARSET" "utf-8") NIL NIL "BASE64" '
        r'$size 1 NIL NIL NIL NIL)',
    'Content-Type: text/html; charset=utf-8\r\n'
        'Content-Transfer-Encoding: base64\r\n',
    _wrapped(utf8.encode('<p>Café at noon, see you there.</p>')),
  ),
  _Part(
    '2',
    '("APPLICATION" "PDF" ("NAME" "Quote.pdf") NIL NIL "BASE64" '
        r'$size NIL ("ATTACHMENT" ("FILENAME" "Quote.pdf")) NIL NIL)',
    'Content-Type: application/pdf; name="Quote.pdf"\r\n'
        'Content-Disposition: attachment; filename="Quote.pdf"\r\n'
        'Content-Transfer-Encoding: base64\r\n',
    _wrapped(_pdf),
  ),
  _Part(
    '3',
    '("IMAGE" "PNG" ("NAME" "logo.png") "<logo@acme>" NIL "BASE64" '
        r'$size NIL ("INLINE" ("FILENAME" "logo.png")) NIL NIL)',
    'Content-Type: image/png; name="logo.png"\r\n'
        'Content-ID: <logo@acme>\r\n'
        'Content-Disposition: inline; filename="logo.png"\r\n'
        'Content-Transfer-Encoding: base64\r\n',
    _wrapped(_png),
  ),
  _Part(
    '4',
    '("TEXT" "PLAIN" ("CHARSET" "us-ascii" "NAME" "notes.txt") NIL NIL "7BIT" '
        r'$size 2 NIL ("ATTACHMENT" ("FILENAME" "notes.txt")) NIL NIL)',
    'Content-Type: text/plain; charset=us-ascii; name="notes.txt"\r\n'
        'Content-Disposition: attachment; filename="notes.txt"\r\n'
        'Content-Transfer-Encoding: 7bit\r\n',
    'line one\r\nline two\r\n',
  ),
  _Part(
    '5',
    '("APPLICATION" "ICS" ("NAME" "invite.ics") NIL NIL "QUOTED-PRINTABLE" '
        r'$size NIL ("ATTACHMENT" ("FILENAME" "invite.ics")) NIL NIL)',
    'Content-Type: application/ics; name="invite.ics"\r\n'
        'Content-Disposition: attachment; filename="invite.ics"\r\n'
        'Content-Transfer-Encoding: quoted-printable\r\n',
    'BEGIN:VCALENDAR\r\nSUMMARY:Caf=C3=A9 =\r\nat noon\r\nEND:VCALENDAR\r\n',
  ),
];

class _PartServer {
  _PartServer._(this._socket);

  final ServerSocket _socket;
  final _clients = <Socket>[];

  /// Every FETCH command, as sent.
  final fetches = <String>[];

  /// The message is HTML alone, in a single part, rather than [_parts].
  bool onePart = false;

  int get port => _socket.port;

  static final _html = _wrapped(utf8.encode(
    '<p>Café at noon, see you there.</p>',
  ));

  static Future<_PartServer> start() async {
    final server = _PartServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._socket.listen(server._serve);
    return server;
  }

  static _Part? _part(String id) {
    for (final p in _parts) {
      if (p.id == id) return p;
    }
    return null;
  }

  String get _structure {
    if (onePart) {
      return '("TEXT" "HTML" ("CHARSET" "utf-8") NIL NIL "BASE64" '
          '${_html.length} 1 NIL NIL NIL NIL)';
    }
    String of(String id) {
      final p = _part(id)!;
      return p.structure.replaceFirst(r'$size', '${p.content.length}');
    }

    return '((${of('1.1')}${of('1.2')} "ALTERNATIVE" ("BOUNDARY" "alt") '
        'NIL NIL NIL)${of('2')}${of('3')}${of('4')}${of('5')} '
        '"MIXED" ("BOUNDARY" "mix") NIL NIL NIL)';
  }

  /// The whole message, as `BODY[]` sends it.
  Uint8List get _message {
    if (onePart) {
      return ascii.encode('From: Dana <dana@example.com>\r\n'
          'Subject: Lunch\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: text/html; charset=utf-8\r\n'
          'Content-Transfer-Encoding: base64\r\n\r\n'
          '$_html\r\n');
    }
    final out = BytesBuilder()
      ..add(ascii.encode('From: Dana <dana@example.com>\r\n'
          'Subject: Lunch\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: multipart/mixed; boundary="mix"\r\n\r\n'
          '--mix\r\n'
          'Content-Type: multipart/alternative; boundary="alt"\r\n\r\n'));
    for (final p in _parts) {
      final boundary = p.id.startsWith('1.') ? 'alt' : 'mix';
      out
        ..add(ascii.encode('--$boundary\r\n${p.headers}\r\n'))
        ..add(p.content)
        ..add(ascii.encode('\r\n'));
      if (p.id == '1.2') out.add(ascii.encode('--alt--\r\n'));
    }
    out.add(ascii.encode('--mix--\r\n'));
    return out.takeBytes();
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
      } else if (verb.startsWith('UID FETCH')) {
        fetches.add(command);
        // The parts first and the structure after, as a server may: what a
        // part is decoded with cannot depend on which came first.
        final out = BytesBuilder()..add(ascii.encode('* 1 FETCH (UID 7'));
        for (final m in RegExp(r'BODY\.PEEK\[([^\]]*)\]').allMatches(command)) {
          final id = m.group(1)!;
          final bytes = id.isEmpty ? _message : _part(id)?.content;
          if (bytes == null) continue;
          out
            ..add(ascii.encode(' BODY[$id] {${bytes.length}}\r\n'))
            ..add(bytes);
        }
        if (verb.contains('BODYSTRUCTURE')) {
          out.add(ascii.encode(' BODYSTRUCTURE $_structure'));
        }
        out.add(ascii.encode(')\r\n$tag OK FETCH done\r\n'));
        client.add(out.takeBytes());
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
