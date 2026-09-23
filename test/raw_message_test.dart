import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/compose/mime_parts.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/mail_engine.dart';

/// A message as it arrived, kept byte for byte on its way to an `.eml`: a
/// forward as attachment, a copy, a drag into Files.
void main() {
  // Hebrew in 8-bit, the way Thunderbird sends it: bytes past 0x7F that are
  // UTF-8, with no transfer encoding over them. Encoded again as UTF-8,
  // each became two and the recipient saw mojibake.
  final wire = Uint8List.fromList([
    ...ascii.encode(
      'From: dana@example.com\r\n'
      'Subject: hi\r\n'
      'MIME-Version: 1.0\r\n'
      'Content-Type: multipart/mixed; boundary="b"\r\n'
      '\r\n'
      '--b\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      'Content-Transfer-Encoding: 8bit\r\n'
      '\r\n',
    ),
    ...utf8.encode('שלום'),
    ...ascii.encode(
      '\r\n--b\r\n'
      'Content-Type: text/plain; charset=utf-8; name="note.txt"\r\n'
      'Content-Disposition: attachment; filename="note.txt"\r\n'
      'Content-Transfer-Encoding: 8bit\r\n'
      '\r\n',
    ),
    ...utf8.encode('תודה'),
    ...ascii.encode('\r\n--b--\r\n'),
  ]);

  test('what IMAP hands back goes back to the bytes it came as', () {
    // fetchRaw renders the fetched message, which enough_mail holds as
    // bytes and renders one character per byte.
    final raw = em.MimeMessage.parseFromData(wire).renderMessage();

    expect(rawMessageBytes(raw), wire);
    expect(utf8.encode(raw), isNot(wire), reason: 'what used to be done');
  });

  test("text of the app's own making is taken as UTF-8", () {
    expect(rawMessageBytes('שלום'), utf8.encode('שלום'));
  });

  test('a file inside it comes out with its own bytes', () {
    // How a forward and a reopened draft get their files back.
    final files = attachmentsInMime(latin1.decode(wire));

    expect(files.single.fileName, 'note.txt');
    // Trimmed: enough_mail keeps the line break before the boundary.
    expect(utf8.decode(files.single.bytes).trim(), 'תודה');
  });

  test("Microsoft's copy is kept byte for byte too", () async {
    // Decoded as UTF-8, every 8-bit byte that was not UTF-8 became U+FFFD.
    final sent = Uint8List.fromList([...wire, 0xE9]); // a stray Latin-1 é
    final api = GraphMailApi(
      accessToken: ({bool force = false}) async => 'token',
      httpClient: http_testing.MockClient(
        (request) async => http.Response.bytes(sent, 200),
      ),
    );

    expect(rawMessageBytes(await api.mime('m1')), sent);
  });
}
