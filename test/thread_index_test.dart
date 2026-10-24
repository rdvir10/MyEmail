import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/compose/graph_sender.dart';
import 'package:myemail/data/compose/thread_index.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;

/// Keeping a reply sent through Graph in its conversation. Exchange files a
/// message by its Thread-Index, not by In-Reply-To: without one, "Re: A
/// teacher in Iceland" sent from here had a conversation id of its own, in
/// Outlook as much as in the app.
void main() {
  // A thread begun at a known time: the header is 1, the top 40 bits of
  // that FILETIME, then a GUID.
  const began = 133735040000000000; // 100 ns steps since 1601, autumn 2024
  List<int> header() {
    final top = began >> 24;
    return [
      1,
      for (var shift = 32; shift >= 0; shift -= 8) (top >> shift) & 0xFF,
      for (var i = 0; i < 16; i++) 0xA0 + i,
    ];
  }

  DateTime at(int filetime) => DateTime.fromMicrosecondsSinceEpoch(
        filetime ~/ 10 - 11644473600000000,
        isUtc: true,
      );

  group('a reply\'s Thread-Index', () {
    test('keeps the thread\'s 22 bytes and adds five of its own', () {
      final parent = header();
      final reply =
          base64Decode(replyThreadIndex(base64Encode(parent), at(began))!);
      expect(reply, hasLength(27));
      expect(reply.sublist(0, 22), parent,
          reason: 'the header is what Exchange files the conversation by');
    });

    test('says how long after the thread began it was written', () {
      const anHour = 36000000000; // 100 ns steps
      final reply = base64Decode(replyThreadIndex(
        base64Encode(header()),
        at((began >> 24 << 24) + anHour),
      )!);
      final block = (reply[22] << 24) | (reply[23] << 16) | (reply[24] << 8) |
          reply[25];
      expect(block & 0x80000000, 0, reason: 'well under 1.7 years: fine steps');
      expect(block, anHour >> 18);
    });

    test('a reply to a reply grows by another five', () {
      final first = replyThreadIndex(base64Encode(header()), at(began))!;
      final second = base64Decode(replyThreadIndex(first, at(began))!);
      expect(second, hasLength(32));
      expect(second.sublist(0, 22), header());
    });

    test('is not made from something that is not an index', () {
      expect(replyThreadIndex('not base64!', DateTime.now()), isNull);
      expect(replyThreadIndex(base64Encode([1, 2, 3]), DateTime.now()), isNull);
      expect(
        replyThreadIndex(base64Encode([0, ...header().skip(1)]), DateTime.now()),
        isNull,
        reason: 'a header begins with 1',
      );
    });
  });

  test('the Thread-Topic is the subject without the Re: and Fw: in front', () {
    expect(threadTopic('RE: Fw: A teacher in Iceland'), 'A teacher in Iceland');
    expect(threadTopic('Quote 4411'), 'Quote 4411');
  });

  test('a Graph send carries the thread headers it is given', () async {
    late String mime;
    final sender = GraphSender(
      accessToken: ({bool force = false}) async => 'token',
      httpClient: http_testing.MockClient((request) async {
        mime = utf8.decode(base64Decode(request.body));
        return http.Response('', 202);
      }),
    );
    final index = replyThreadIndex(base64Encode(header()), at(began))!;

    await sender.sendDraft(
      draft: const Draft(
        accountId: 'a',
        kind: ComposeKind.reply,
        to: [MailAddress(email: 'julia@example.com')],
        subject: 'Re: A teacher in Iceland',
        htmlBody: '<p>Thanks for the heads-up.</p>',
      ),
      account: const Account(
        id: 'a',
        displayName: 'MyHomeStudio',
        emailAddress: 'ron@myhomestudio.club',
        provider: MailProvider.outlook,
        authMethod: AuthMethod.oauth,
        colorValue: 0xFF0F6CBD,
      ),
      threadHeaders: {
        'Thread-Index': index,
        'Thread-Topic': 'A teacher in Iceland',
      },
    );

    expect(mime, contains('Thread-Index: $index'));
    expect(mime, contains('Thread-Topic: A teacher in Iceland'));
  });
}
