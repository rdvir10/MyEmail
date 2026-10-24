import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/graph/graph_id_map.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/graph/graph_transport.dart';

/// What batch 2 asks of Microsoft Graph: the files' names for list rows,
/// a message's own headers (for Unsubscribe), and the mail kept after
/// Deleted Items is emptied.
void main() {
  late List<http.Request> sent;
  late http.Response Function(http.Request) answer;
  late MemoryGraphIdMap ids;
  late GraphTransport transport;

  setUp(() {
    sent = [];
    ids = MemoryGraphIdMap();
    transport = GraphTransport(
      accountId: 'acct-1',
      idMap: ids,
      api: GraphMailApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          return answer(request);
        }),
        sleep: (_) async {},
      ),
    );
  });

  http.Response json(Object body, {int status = 200}) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  test('file names for rows: twenty messages to a request, files only, an '
      'attached email named as one', () async {
    final uids = await ids.uidsFor('acct-1', 'Inbox', ['m1', 'm2', 'm3']);
    answer = (request) {
      final asked = (jsonDecode(request.body) as Map)['requests'] as List;
      return json({
        'responses': [
          for (final r in asked.cast<Map>())
            switch ('${r['url']}') {
              final url when url.contains('/m1/') => {
                  'id': r['id'],
                  'status': 200,
                  'body': {
                    'value': [
                      {'id': 'a', 'name': 'Quote.pdf', 'isInline': false},
                      {'id': 'b', 'name': 'logo.png', 'isInline': true},
                      {
                        'id': 'c',
                        'name': 'Re: Prices',
                        'isInline': false,
                        '@odata.type': '#microsoft.graph.itemAttachment',
                      },
                    ],
                  },
                },
              final url when url.contains('/m2/') => {
                  'id': r['id'],
                  'status': 404,
                  'body': {
                    'error': {'code': 'ErrorItemNotFound'},
                  },
                },
              _ => {
                  'id': r['id'],
                  'status': 200,
                  'body': {'value': <Object>[]},
                },
            },
        ],
      });
    };

    final names = await transport.attachmentNames(
      'Inbox',
      [uids['m1']!, uids['m2']!, uids['m3']!],
    );

    expect(sent, hasLength(1), reason: 'one batch for the three');
    expect(sent.single.url.path, endsWith(r'/$batch'));
    final urls = [
      for (final r in ((jsonDecode(sent.single.body) as Map)['requests']
              as List)
          .cast<Map>())
        '${r['url']}',
    ];
    expect(urls.first, contains(r'/attachments?$select='));
    expect(urls.first, isNot(contains('contentBytes')));
    expect(names, {
      uids['m1']!: ['Quote.pdf', 'Re_ Prices.eml'],
      // Gone: left out, to be asked again by a pass that still has it.
      uids['m3']!: <String>[],
    });
  });

  test("a message's own headers, the ones asked for, by name in lower case",
      () async {
    final uids = await ids.uidsFor('acct-1', 'Inbox', ['m1']);
    answer = (request) => json({
          'internetMessageHeaders': [
            {'name': 'Received', 'value': 'from somewhere'},
            {
              'name': 'List-Unsubscribe',
              'value': '<https://shop.example.com/u>',
            },
            {
              'name': 'List-Unsubscribe-Post',
              'value': 'List-Unsubscribe=One-Click',
            },
          ],
        });

    final headers = await transport.headerValues(
      'Inbox',
      uids['m1']!,
      const ['List-Unsubscribe', 'List-Unsubscribe-Post'],
    );

    expect(sent.single.url.queryParameters[r'$select'],
        'internetMessageHeaders');
    expect(headers, {
      'list-unsubscribe': '<https://shop.example.com/u>',
      'list-unsubscribe-post': 'List-Unsubscribe=One-Click',
    });
  });

  group('recover deleted items', () {
    Map<String, Object?> kept(String id, {String? deleted}) => {
          'id': id,
          'subject': 'Subject $id',
          'from': {
            'emailAddress': {'address': 'dana@example.com', 'name': 'Dana'},
          },
          'receivedDateTime': '2026-10-0${id.length}T09:00:00Z',
          'hasAttachments': true,
          'bodyPreview': 'Preview',
          if (deleted != null)
            'singleValueExtendedProperties': [
              {'id': 'SystemTime 0x668f', 'value': deleted},
            ],
        };

    test('newest received first, from the hidden folder, with when each was '
        'deleted', () async {
      answer = (_) => json({
            'value': [
              kept('r1', deleted: '2026-10-20T08:30:00Z'),
              kept('r2'),
            ],
          });

      final found = await transport.recoverable(skip: 50);

      final url = sent.single.url;
      expect(url.path, endsWith('/me/mailFolders/recoverableitemsdeletions/messages'));
      expect(url.queryParameters[r'$orderby'], 'receivedDateTime desc');
      expect(url.queryParameters[r'$skip'], '50');
      expect(url.queryParameters[r'$expand'], contains('0x668F'));
      expect(found.map((m) => m.id), ['r1', 'r2']);
      expect(found.first.from.display, 'Dana');
      expect(found.first.deletedOn, DateTime.utc(2026, 10, 20, 8, 30).toLocal());
      expect(found.last.deletedOn, isNull);
    });

    test('a search is the server\'s, in its own order', () async {
      answer = (_) => json({'value': <Object>[]});
      await transport.recoverable(query: 'invoice "march"');
      final query = sent.single.url.queryParameters;
      expect(query[r'$search'], '"invoice march"');
      expect(query.containsKey(r'$orderby'), isFalse);
      expect(query.containsKey(r'$skip'), isFalse);
    });

    test('put back in the Inbox, and counted', () async {
      answer = (request) {
        final asked = (jsonDecode(request.body) as Map)['requests'] as List;
        return json({
          'responses': [
            for (final (i, r) in asked.cast<Map>().indexed)
              {
                'id': r['id'],
                'status': i == 0 ? 201 : 404,
                'body': i == 0
                    ? {'id': 'new-id'}
                    : {
                        'error': {'code': 'ErrorItemNotFound'},
                      },
              },
          ],
        });
      };

      expect(await transport.recover(['r1', 'r2']), 1);
      final asked = ((jsonDecode(sent.single.body) as Map)['requests'] as List)
          .cast<Map>();
      expect(asked.map((r) => r['url']), [
        '/me/messages/r1/move',
        '/me/messages/r2/move',
      ]);
      expect(asked.first['body'], {'destinationId': 'inbox'});
    });
  });
}
