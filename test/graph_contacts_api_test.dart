import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myemail/data/answer_limit.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/contacts/contact_mapping.dart';
import 'package:myemail/data/contacts/contact_wire_errors.dart';
import 'package:myemail/data/graph/graph_contacts_api.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/error_report.dart';

import 'fakes/fake_graph_contacts.dart';

/// Contact sync's Graph client against the fake mailbox: the immutable-id
/// header everywhere, the main folder, delta and its expiry, reads by id,
/// the tag, batches, the device claim, throttling, consent, and what its
/// failures and log leave out.
void main() {
  late FakeGraphContacts graph;
  late List<Duration> slept;
  late List<bool> forced;

  GraphContactsApi api({
    http.Client? client,
    Future<String> Function({bool force})? mailAccessToken,
  }) => GraphContactsApi(
    accessToken: ({bool force = false}) async {
      forced.add(force);
      return force ? 'fresh' : 'token';
    },
    mailAccessToken: mailAccessToken,
    httpClient: client ?? graph.client,
    sleep: (d) async => slept.add(d),
  );

  List<String> captureLog() {
    final logged = <String>[];
    final was = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        logged.add(message ?? '');
    addTearDown(() => debugPrint = was);
    return logged;
  }

  Map<String, Object?> contact(String given, String surname, String email) =>
      {
        'givenName': given,
        'surname': surname,
        'emailAddresses': [
          {'address': email, 'name': '$given $surname'},
        ],
      };

  const main = FakeGraphContacts.mainFolderId;

  setUp(() {
    graph = FakeGraphContacts();
    slept = [];
    forced = [];
  });

  test('the header is the one the plan names', () {
    expect(
      GraphContactsApi.prefer,
      'IdType="ImmutableId", odata.maxpagesize=200',
    );
    expect(graphContactSelectVersion, 1);
  });

  test('the tag and the claim are fixed for ever', () {
    // Contacts already tagged in Hadco are found again only under these
    // exact ids, and each name takes a slot in the mailbox: never change
    // them, and never add another.
    expect(myEmailPropertySet, '{958f81ac-dee9-4f9e-a713-9043484f5b0f}');
    expect(
      graphLinkPropertyId,
      'String {958f81ac-dee9-4f9e-a713-9043484f5b0f} Name MyEmailLink',
    );
    expect(
      graphDevicePropertyId,
      'String {958f81ac-dee9-4f9e-a713-9043484f5b0f} Name MyEmailSyncDevice',
    );
  });

  test('the tag replaces one the contact carries under the same id in '
      'other letters, and keeps every other property', () {
    const other = {
      'id': 'String {00000000-0000-0000-0000-000000000001} Name MyEmailLink',
      'value': 'another app',
    };
    final tagged = GraphContactsApi.withTag({
      'givenName': 'Ann',
      'singleValueExtendedProperties': [
        other,
        {
          'id': 'String {958F81AC-DEE9-4F9E-A713-9043484F5B0F} Name '
              'MyEmailLink',
          'value': 'people/old',
        },
      ],
    }, 'people/new');

    expect(tagged['givenName'], 'Ann');
    expect(tagged['singleValueExtendedProperties'], [
      other,
      {'id': graphLinkPropertyId, 'value': 'people/new'},
    ]);
    expect(GraphContactsApi.tagOf(tagged), 'people/new');
    final untouched = {'givenName': 'Ann'};
    expect(GraphContactsApi.withTag(untouched, null), same(untouched));
  });

  test('every request, and every request inside a batch, carries the one '
      'Prefer header', () async {
    final client = api();
    final ann = graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
    await client.mainFolderId();
    await client.listAll();
    await client.listAll(folderId: main, whole: true);
    final first = await client.delta(folderId: main);
    await client.delta(folderId: main, deltaLink: first.deltaLink);
    await client.get(ann, withTag: true);
    await client.findByEmail('ann@example.com');
    await client.deletedItemsFolderId();
    final made = await client.create(contact('Bob', 'Day', 'b@x.com'));
    await client.createBatch([
      (contact: contact('Cat', 'Fox', 'c@x.com'), tag: 'g-1'),
      (contact: contact('Dan', 'Ray', 'd@x.com'), tag: 'g-2'),
    ]);
    await client.update(made['id']! as String, {'nickName': 'Bobby'});
    await client.delete(made['id']! as String);
    await client.writeClaim(main, device: 'phone', at: DateTime.utc(2026));
    await client.readClaim(main);
    await client.getBatch([ann]);
    await client.photos([ann]);
    await client.putPhoto(ann, [1, 2, 3], 'image/jpeg');
    await client.photoBytes(ann);
    final cat = graph.idWithEmail('c@x.com')!;
    await client.deleteBatch([cat]);

    expect(graph.requestsTo(r'$batch'), hasLength(4));
    expect(graph.requests.length, greaterThan(15));
    for (final r in graph.requests) {
      expect(
        r.headers['Prefer'],
        GraphContactsApi.prefer,
        reason: '${r.method} ${r.url.path}',
      );
    }
  });

  test('the fake refuses a request without the header', () async {
    final response = await graph.client.get(
      Uri.parse('https://graph.microsoft.com/v1.0/me/contacts'),
      headers: {'Authorization': 'Bearer t'},
    );

    expect(response.statusCode, 400);
  });

  group('the main folder', () {
    test('is the parentFolderId of any contact, and unknown while there are '
        'none', () async {
      final client = api();

      expect(await client.mainFolderId(), isNull);
      graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
      expect(await client.mainFolderId(), main);
      expect(graph.requests.last.url.queryParameters[r'$top'], '1');
    });

    test('a contact created answers with it', () async {
      final made = await api().create(contact('Ann', 'Lee', 'a@x.com'));

      expect(made['parentFolderId'], main);
      expect(graph.requests.single.url.path, '/v1.0/me/contacts');
    });
  });

  group('listing', () {
    test('every page, with the select or whole', () async {
      for (var i = 0; i < 5; i++) {
        graph.seed(contact('P$i', 'F', 'p$i@x.com'));
      }
      graph.maxPageSize = 2;
      final client = api();

      final selected = await client.listAll();
      expect(selected, hasLength(5));
      expect(selected.first.containsKey('fileAs'), isFalse);
      expect(
        graph.requests.first.url.queryParameters[r'$select'],
        graphContactSelect,
      );
      expect(graph.requests.first.url.queryParameters[r'$top'], '200');
      expect(graph.requests, hasLength(3));

      final whole = await client.listAll(folderId: main, whole: true);
      expect(whole, hasLength(5));
      expect(whole.first.containsKey('fileAs'), isTrue);
      expect(
        graph.requests[3].url.path,
        '/v1.0/me/contactFolders/$main/contacts',
      );
      expect(graph.requests[3].url.queryParameters.containsKey(r'$select'),
          isFalse);
    });
  });

  group('delta', () {
    test('the first round lists the folder, the select sent once', () async {
      for (var i = 0; i < 5; i++) {
        graph.seed(contact('P$i', 'F', 'p$i@x.com'));
      }
      graph.seed(
        contact('Sub', 'Folder', 's@x.com'),
        folderId: graph.addFolder(),
      );
      graph.maxPageSize = 2;

      final round = await api().delta(folderId: main);

      expect(round.complete, isTrue);
      expect(round.contacts, hasLength(5));
      expect(round.removed, isEmpty);
      expect(round.pages, 3);
      expect(round.deltaLink, contains(r'$deltatoken='));
      final asked = graph.requestsTo('/delta');
      expect(asked.first.url.queryParameters[r'$select'],
          graphContactSelect);
      for (final r in asked.skip(1)) {
        expect(r.url.queryParameters.containsKey(r'$select'), isFalse,
            reason: 'Graph built it into the link');
      }
    });

    test('later rounds: changes, additions, and contacts gone from the '
        'folder, deleted or moved', () async {
      final ann = graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
      final bob = graph.seed(contact('Bob', 'Day', 'bob@example.com'));
      final cat = graph.seed(contact('Cat', 'Fox', 'cat@example.com'));
      final client = api();
      final first = await client.delta(folderId: main);

      graph
        ..editFromOutlook(ann, {'mobilePhone': '+1 555 0100'})
        ..deleteFromOutlook(bob)
        ..moveFromOutlook(cat, graph.addFolder());
      final dan = graph.seed(contact('Dan', 'Ray', 'dan@example.com'));
      final round = await client.delta(
        folderId: main,
        deltaLink: first.deltaLink,
      );

      expect(round.complete, isFalse);
      expect(
        round.contacts.map((c) => c['id']),
        unorderedEquals([ann, dan]),
      );
      expect(round.removed, {bob, cat});
      expect(
        round.contacts.firstWhere((c) => c['id'] == ann)['mobilePhone'],
        '+1 555 0100',
      );
    });

    test('a sparse change comes with only what changed, which the client '
        'hands on as it came', () async {
      final ann = graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
      graph.sparseDelta = true;
      final client = api();
      final first = await client.delta(folderId: main);

      graph.editFromOutlook(ann, {'nickName': 'Annie'});
      final round = await client.delta(
        folderId: main,
        deltaLink: first.deltaLink,
      );

      final changed = round.contacts.single;
      expect(changed['nickName'], 'Annie');
      expect(changed.containsKey('surname'), isFalse);
    });

    for (final (status, code) in [
      (410, 'SyncStateNotFound'),
      (400, 'syncStateNotFound'),
      (404, 'SyncStateNotFound'),
      (400, 'SyncStateInvalid'),
      (410, 'resyncRequired'),
    ]) {
      test('an expired link ($status $code) is ContactFeedExpired', () async {
        graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
        final client = api();
        final first = await client.delta(folderId: main);
        graph.expireDeltaLinks(status: status, code: code);

        await expectLater(
          client.delta(folderId: main, deltaLink: first.deltaLink),
          throwsA(
            isA<ContactFeedExpired>().having((e) => e.status, 'status', status),
          ),
        );
      });
    }

    test('a link part way through a round can expire too', () async {
      for (var i = 0; i < 3; i++) {
        graph.seed(contact('P$i', 'F', 'p$i@x.com'));
      }
      graph.maxPageSize = 1;
      var pages = 0;
      final client = api(
        client: MockClient((r) async {
          final answer = await graph.handle(r);
          if (++pages == 1) graph.expireDeltaLinks();
          return answer;
        }),
      );

      await expectLater(
        client.delta(folderId: main),
        throwsA(isA<ContactFeedExpired>()),
      );
    });

    test('a folder not there is ContactGone, not expiry', () async {
      await expectLater(
        api().delta(folderId: 'AAMkADnoSuchFolder'),
        throwsA(isA<ContactGone>()),
      );
    });

    test('a stored link answered 400, whatever the code, has expired',
        () async {
      graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
      final client = api();
      final first = await client.delta(folderId: main);
      graph.expireDeltaLinks(status: 400, code: 'ErrorInvalidRequest');

      await expectLater(
        client.delta(folderId: main, deltaLink: first.deltaLink),
        throwsA(isA<ContactFeedExpired>()),
      );
    });

    test('a fresh delta answered 400 is a refusal, not expiry: a fresh one '
        'again would meet it again', () async {
      final client = api(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': 'ErrorInvalidRequest', 'message': 'No.'},
            }),
            400,
          ),
        ),
      );

      await expectLater(
        client.delta(folderId: main),
        throwsA(isA<ContactRefused>()),
      );
    });

    test('a folder gone is ContactGone, at the latest after one fresh try',
        () async {
      final folder = graph.addFolder();
      graph.seed(contact('Ann', 'Lee', 'ann@example.com'), folderId: folder);
      final first = await api().delta(folderId: folder);
      graph.removeFolder(folder);

      // Answered 404, it is gone at once.
      await expectLater(
        api().delta(folderId: folder, deltaLink: first.deltaLink),
        throwsA(isA<ContactGone>()),
      );

      // Answered 400, the link is let go of, and the fresh delta finds the
      // folder gone.
      var calls = 0;
      final client = api(
        client: MockClient((r) async {
          if (++calls == 1) {
            return http.Response(
              jsonEncode({
                'error': {'code': 'ErrorInvalidIdMalformed'},
              }),
              400,
            );
          }
          return graph.handle(r);
        }),
      );
      await expectLater(
        client.delta(folderId: folder, deltaLink: first.deltaLink),
        throwsA(isA<ContactFeedExpired>()),
      );
      await expectLater(
        client.delta(folderId: folder),
        throwsA(isA<ContactGone>()),
      );
    });

    test("a link that is not Graph's is never sent the token", () async {
      await expectLater(
        api().delta(
          folderId: main,
          deltaLink: 'https://example.com/v1.0/me/contacts/delta?t=1',
        ),
        throwsA(isA<ContactFeedExpired>()),
      );
      expect(graph.requests, isEmpty);
    });
  });

  group('reading by id', () {
    test('with the select, whole, and with the tag; null when not there',
        () async {
      final ann = graph.seed(
        contact('Ann', 'Lee', 'ann@example.com'),
        tag: 'people/c1',
      );
      final client = api();

      final selected = (await client.get(ann))!;
      expect(selected['id'], ann);
      expect(GraphContactsApi.tagOf(selected), isNull);
      expect(graph.requests.last.url.queryParameters[r'$select'],
          graphContactSelect);

      final whole = (await client.get(ann, whole: true, withTag: true))!;
      expect(whole.containsKey('fileAs'), isTrue);
      expect(GraphContactsApi.tagOf(whole), 'people/c1');
      final q = graph.requests.last.url.queryParameters;
      expect(q.containsKey(r'$select'), isFalse);
      expect(
        q[r'$expand'],
        "singleValueExtendedProperties(\$filter=id eq "
        "'$graphLinkPropertyId')",
      );

      graph.purgeFromOutlook(ann);
      expect(await client.get(ann), isNull);
    });

    test('a contact Outlook deleted is found in Deleted Items', () async {
      final ann = graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
      graph.deleteFromOutlook(ann);
      final client = api();

      final found = (await client.get(ann))!;
      expect(found['parentFolderId'], await client.deletedItemsFolderId());
    });

    test('the Deleted Items id is asked for with the mail token where one '
        'is given', () async {
      final used = <String>[];
      final client = api(
        mailAccessToken: ({bool force = false}) async => 'mail',
        client: MockClient((r) async {
          used.add(r.headers['Authorization']!);
          return graph.handle(r);
        }),
      );

      expect(
        await client.deletedItemsFolderId(),
        FakeGraphContacts.deletedItemsId,
      );
      expect(used, ['Bearer mail']);
      expect(
        graph.requests.single.url.path,
        '/v1.0/me/mailFolders/deleteditems',
      );
    });

    test('findByEmail filters on the address and brings the tag', () async {
      graph.seed(contact('Ann', 'Lee', "o'neil@example.com"), tag: 'people/c9');
      graph.seed(contact('Bob', 'Day', 'bob@example.com'));

      final found = await api().findByEmail("O'Neil@example.com");

      expect(found, hasLength(1));
      expect(GraphContactsApi.tagOf(found.single), 'people/c9');
      expect(
        graph.requests.single.url.queryParameters[r'$filter'],
        "emailAddresses/any(a:a/address eq 'O''Neil@example.com')",
      );
    });

    test('findByEmail reads every page: the tagged copy of an address '
        'many contacts share can be past the first', () async {
      for (var i = 0; i < 11; i++) {
        graph.seed(contact('Family$i', 'Lee', 'home@lee.example'));
      }
      graph.seed(
        contact('Ann', 'Lee', 'home@lee.example'),
        tag: 'people/c42',
      );

      final found = await api().findByEmail('home@lee.example');

      expect(found, hasLength(12));
      expect(found.map(GraphContactsApi.tagOf), contains('people/c42'));
      expect(graph.requests.first.url.queryParameters[r'$top'], '200');

      // And past Graph's largest page too.
      graph
        ..requests.clear()
        ..maxPageSize = 5;
      expect(await api().findByEmail('home@lee.example'), hasLength(12));
      expect(graph.requests, hasLength(3));
    });

    test('getBatch reads twenty to a batch, each part with the select and '
        'the header: there wherever it is, not there, or not known',
        () async {
      final ids = [
        for (var i = 0; i < 23; i++)
          graph.seed(contact('P$i', 'F', 'p$i@x.com')),
      ];
      graph
        ..deleteFromOutlook(ids[1])
        ..purgeFromOutlook(ids[2])
        // The first part is turned away, and asked again after its wait.
        ..throttleInBatch(1, retryAfter: 3);

      final read = await api().getBatch([...ids, ids[0]]);

      expect(read.found.keys.toSet(), {...ids}..remove(ids[2]));
      expect(read.notFound, {ids[2]});
      expect(read.unknown, isEmpty);
      expect(read.found[ids[0]]!['givenName'], 'P0');
      expect(read.found[ids[0]]!.containsKey('fileAs'), isFalse);
      expect(
        read.found[ids[1]]!['parentFolderId'],
        FakeGraphContacts.deletedItemsId,
      );
      expect(slept, [const Duration(seconds: 3)]);
      final batches = graph.requestsTo(r'$batch');
      expect(
        batches.map(
          (r) => ((jsonDecode(r.body) as Map)['requests'] as List).length,
        ),
        [20, 1, 3],
      );
      for (final b in batches) {
        expect(b.headers['Prefer'], GraphContactsApi.prefer);
        for (final part in (jsonDecode(b.body) as Map)['requests'] as List) {
          expect(part['method'], 'GET');
          expect(part['headers'], {'Prefer': GraphContactsApi.prefer});
          final url = Uri.parse('${part['url']}');
          expect(url.path, startsWith('/me/contacts/'));
          expect(url.queryParameters[r'$select'], graphContactSelect);
        }
      }

      // One asking for longer than is worth waiting is not waited for:
      // nothing is known of it.
      graph.throttleInBatch(1, retryAfter: 60);
      final again = await api().getBatch([ids[0], ids[3]]);
      expect(again.unknown, {ids[0]});
      expect(again.found.keys, [ids[3]]);
      expect(again.notFound, isEmpty);
      expect(slept, [const Duration(seconds: 3)]);
    });

    test('getBatch throws when a batch fails as a whole, as get would',
        () async {
      final ann = graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
      final client = api(
        client: MockClient((r) async {
          if (r.url.path.endsWith(r'$batch')) return http.Response('{}', 500);
          return graph.handle(r);
        }),
      );

      await expectLater(
        client.getBatch([ann]),
        throwsA(isA<ConnectionFailed>()),
      );
    });
  });

  group('photos and deletes', () {
    test('photos asks twenty to a batch which have a photo, each part with '
        'the header; a throttled part is asked again after its wait',
        () async {
      final ids = [
        for (var i = 0; i < 23; i++)
          graph.seed(contact('P$i', 'F', 'p$i@x.com')),
      ];
      for (final i in [0, 5, 21]) {
        graph.setPhotoFromOutlook(ids[i], [i, 1, 2]);
      }
      graph.throttleInBatch(1, retryAfter: 3);

      final checked = await api().photos([...ids, ids[0]]);

      expect(checked.have, {ids[0], ids[5], ids[21]});
      expect(checked.none, {...ids}..removeAll([ids[0], ids[5], ids[21]]));
      expect(checked.unknown, isEmpty);
      expect(slept, [const Duration(seconds: 3)]);
      final batches = graph.requestsTo(r'$batch');
      expect(
        batches.map(
          (r) => ((jsonDecode(r.body) as Map)['requests'] as List).length,
        ),
        [20, 1, 3],
      );
      for (final b in batches) {
        for (final part in (jsonDecode(b.body) as Map)['requests'] as List) {
          expect(part['method'], 'GET');
          expect(part['headers'], {'Prefer': GraphContactsApi.prefer});
          expect('${part['url']}', matches(r'^/me/contacts/[^/]+/photo$'));
        }
      }

      // One asking for longer than is worth waiting is not known.
      graph.throttleInBatch(1, retryAfter: 60);
      final again = await api().photos([ids[5], ids[6]]);
      expect(again.unknown, {ids[5]});
      expect(again.none, {ids[6]});
    });

    test('photoBytes reads the bytes and their type, null with none; '
        'putPhoto gives a contact one', () async {
      final ann = graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
      final bob = graph.seed(contact('Bob', 'Day', 'bob@example.com'));
      graph.setPhotoFromOutlook(ann, [9, 8, 7, 6], type: 'image/png');
      final client = api();

      final photo = (await client.photoBytes(ann))!;
      expect(photo.bytes, [9, 8, 7, 6]);
      expect(photo.type, 'image/png');
      expect(await client.photoBytes(bob), isNull);

      final before = graph.contact(bob)!['changeKey'];
      await client.putPhoto(bob, photo.bytes, photo.type);
      expect(graph.photoOf(bob)!.bytes, [9, 8, 7, 6]);
      expect(graph.photoOf(bob)!.type, 'image/png');
      expect(graph.contact(bob)!['changeKey'], isNot(before));
      final put = graph.requests.last;
      expect(put.method, 'PUT');
      expect(put.url.path, endsWith('/photo/\$value'));
      expect(put.headers['Content-Type'], startsWith('image/png'));

      graph.purgeFromOutlook(bob);
      await expectLater(
        client.putPhoto(bob, photo.bytes, photo.type),
        throwsA(isA<ContactGone>()),
      );
    });

    test('deleteBatch deletes twenty to a batch: deleted, gone, or failed; '
        'a throttled part is asked again after its wait', () async {
      final ids = [
        for (var i = 0; i < 23; i++)
          graph.seed(contact('P$i', 'F', 'p$i@x.com')),
      ];
      graph
        ..purgeFromOutlook(ids[2])
        ..throttleInBatch(1, retryAfter: 3);

      final gone = await api().deleteBatch([...ids, ids[0]]);

      expect(gone.deleted, {...ids}..remove(ids[2]));
      expect(gone.gone, {ids[2]});
      expect(gone.failed, isEmpty);
      for (final id in ids) {
        expect(graph.contact(id), isNull);
      }
      expect(slept, [const Duration(seconds: 3)]);
      final batches = graph.requestsTo(r'$batch');
      expect(
        batches.map(
          (r) => ((jsonDecode(r.body) as Map)['requests'] as List).length,
        ),
        [20, 1, 3],
      );
      for (final b in batches) {
        for (final part in (jsonDecode(b.body) as Map)['requests'] as List) {
          expect(part['method'], 'DELETE');
          expect(part['headers'], {'Prefer': GraphContactsApi.prefer});
          expect('${part['url']}', matches(r'^/me/contacts/[^/]+$'));
        }
      }

      // One asking for longer than is worth waiting failed: still there.
      final left = graph.seed(contact('Left', 'F', 'l@x.com'));
      graph.throttleInBatch(1, retryAfter: 60);
      final again = await api().deleteBatch([left]);
      expect(again.failed, {left});
      expect(graph.contact(left), isNotNull);
    });

    test('a batch of deletes that fails as a whole throws, as delete would',
        () async {
      final ann = graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
      final client = api(
        client: MockClient((r) async {
          if (r.url.path.endsWith(r'$batch')) return http.Response('{}', 500);
          return graph.handle(r);
        }),
      );

      await expectLater(
        client.deleteBatch([ann]),
        throwsA(isA<ConnectionFailed>()),
      );
      expect(graph.contact(ann), isNotNull);
    });
  });

  group('writing', () {
    test('create carries the hidden tag, any other property kept', () async {
      final made = await api().create({
        ...contact('Ann', 'Lee', 'ann@example.com'),
        'singleValueExtendedProperties': [
          {
            'id': 'String {00000000-0000-0000-0000-000000000001} Name X',
            'value': 'kept',
          },
          {'id': graphLinkPropertyId.toUpperCase(), 'value': 'stale'},
        ],
      }, tag: 'people/c42');

      final id = made['id']! as String;
      expect(graph.tagOf(id), 'people/c42');
      final sent = jsonDecode(graph.requests.single.body) as Map;
      final props = sent['singleValueExtendedProperties'] as List;
      expect(props, hasLength(2));
      expect(props.last, {
        'id': graphLinkPropertyId,
        'value': 'people/c42',
      });
    });

    test('a batch goes twenty to a request, each part with its own '
        'headers, answered in the order asked whatever order Graph '
        'answers in', () async {
      final asked = [
        for (var i = 0; i < 25; i++)
          (contact: contact('P$i', 'F', 'p$i@x.com'), tag: 'people/c$i'),
      ];

      final answers = await api().createBatch(asked);

      expect(answers, hasLength(25));
      for (var i = 0; i < 25; i++) {
        final made = answers[i].contact!;
        expect(answers[i].failure, isNull);
        expect(graph.tagOf(made['id']! as String), 'people/c$i');
        expect(made['givenName'], 'P$i');
      }
      final batches = graph.requestsTo(r'$batch');
      expect(
        batches.map(
          (r) => ((jsonDecode(r.body) as Map)['requests'] as List).length,
        ),
        [20, 5],
      );
      for (final b in batches) {
        expect(b.headers['Prefer'], GraphContactsApi.prefer);
        for (final part in (jsonDecode(b.body) as Map)['requests'] as List) {
          expect(part['headers'], {
            'Content-Type': 'application/json',
            'Prefer': GraphContactsApi.prefer,
          });
        }
      }
    });

    test('a batch reads each part: one refused is that contact\'s failure, '
        'one throttled is sent again after its wait', () async {
      graph
        ..refuse = ((c) => c['givenName'] == 'Refuse')
        ..throttleInBatch(1, retryAfter: 3);
      final answers = await api().createBatch([
        (contact: contact('Ann', 'Lee', 'a@x.com'), tag: 'people/c1'),
        (contact: contact('Refuse', 'Me', 'r@x.com'), tag: 'people/c2'),
        (contact: contact('Cat', 'Fox', 'c@x.com'), tag: 'people/c3'),
      ]);

      expect(answers[0].contact, isNotNull);
      expect(answers[1].failure, isA<ContactRefused>());
      expect(answers[2].contact, isNotNull);
      expect(slept, [const Duration(seconds: 3)]);
      expect(graph.count, 2);
      expect(graph.requestsTo(r'$batch'), hasLength(2));
      final again = jsonDecode(graph.requestsTo(r'$batch').last.body) as Map;
      expect(again['requests'], hasLength(1));
    });

    test('update patches and answers with the contact; a contact not there '
        'is ContactGone', () async {
      final ann = graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
      final client = api();
      final before = graph.contact(ann)!['changeKey'];

      final after = await client.update(ann, {
        'surname': 'Lee-Hart',
        'displayName': 'Ann Lee-Hart',
      });

      expect(after['surname'], 'Lee-Hart');
      expect(after['changeKey'], isNot(before));
      expect(graph.requests.single.method, 'PATCH');

      graph.purgeFromOutlook(ann);
      await expectLater(
        client.update(ann, {'nickName': 'A'}),
        throwsA(isA<ContactGone>()),
      );
    });

    test('delete is true when it deleted, false when it was gone', () async {
      final ann = graph.seed(contact('Ann', 'Lee', 'ann@example.com'));
      final client = api();

      expect(await client.delete(ann), isTrue);
      expect(graph.contact(ann), isNull);
      expect(await client.delete(ann), isFalse);
    });

    test('a batch that fails part way keeps what the batches before it '
        'made, and sends none after it', () async {
      var batches = 0;
      final client = api(
        client: MockClient((r) async {
          if (r.url.path.endsWith(r'$batch') && ++batches == 2) {
            graph.throttle(1, status: 500);
          }
          return graph.handle(r);
        }),
      );
      final asked = [
        for (var i = 0; i < 45; i++)
          (contact: contact('P$i', 'F', 'p$i@x.com'), tag: 'people/c$i'),
      ];

      final answers = await client.createBatch(asked);

      expect(answers, hasLength(45));
      for (var i = 0; i < 20; i++) {
        expect(answers[i].contact!['givenName'], 'P$i');
      }
      for (var i = 20; i < 45; i++) {
        expect(answers[i].contact, isNull);
        expect(answers[i].failure, isA<ConnectionFailed>());
      }
      expect(graph.requestsTo(r'$batch'), hasLength(2));
      expect(graph.count, 20);
    });

    test('a batch refused as a whole is the batch\'s failure, not its '
        'contacts\', and the next batch goes on', () async {
      var batches = 0;
      final client = api(
        client: MockClient((r) async {
          if (r.url.path.endsWith(r'$batch') && ++batches == 1) {
            return http.Response(
              jsonEncode({
                'error': {'code': 'BadRequest', 'message': 'Zebediah'},
              }),
              400,
            );
          }
          return graph.handle(r);
        }),
      );
      final asked = [
        for (var i = 0; i < 25; i++)
          (contact: contact('P$i', 'F', 'p$i@x.com'), tag: 'people/c$i'),
      ];

      final answers = await client.createBatch(asked);

      for (var i = 0; i < 20; i++) {
        expect(answers[i].failure, isA<ContactBatchRefused>());
        expect(answers[i].failure, isNot(isA<ContactRefused>()));
        expect('${answers[i].failure}', isNot(contains('Zebediah')));
      }
      for (var i = 20; i < 25; i++) {
        expect(answers[i].contact!['givenName'], 'P$i');
      }
      expect(graph.count, 5);
    });

    test('a batch answered 503 as a whole is not sent again: its parts may '
        'have been made', () async {
      graph.throttle(1, status: 503, retryAfter: 1);

      final answers = await api().createBatch([
        (contact: contact('Ann', 'Lee', 'a@x.com'), tag: 'people/c1'),
        (contact: contact('Bob', 'Day', 'b@x.com'), tag: 'people/c2'),
      ]);

      expect(slept, isEmpty);
      expect(graph.requestsTo(r'$batch'), hasLength(1));
      for (final a in answers) {
        expect(a.contact, isNull);
        expect(a.failure, isA<ConnectionFailed>());
        expect(a.failure, isA<Retryable>());
      }
    });

    test('nor is one create answered 503; a 429 is', () async {
      graph.throttle(1, status: 503, retryAfter: 1);
      await expectLater(
        api().create(contact('Ann', 'Lee', 'a@x.com')),
        throwsA(isA<ConnectionFailed>()),
      );
      expect(slept, isEmpty);
      expect(graph.requests, hasLength(1));

      graph.throttle(1, retryAfter: 2);
      final made = await api().create(contact('Ann', 'Lee', 'a@x.com'));
      expect(made['id'], isNotNull);
      expect(slept, [const Duration(seconds: 2)]);
    });

    test('a batch answered 429 as a whole is sent again after its wait',
        () async {
      graph.throttle(1, retryAfter: 2);

      final answers = await api().createBatch([
        (contact: contact('Ann', 'Lee', 'a@x.com'), tag: 'people/c1'),
      ]);

      expect(answers.single.contact, isNotNull);
      expect(slept, [const Duration(seconds: 2)]);
    });

    test('a part answered 500 or 503 is not sent again, since it may have '
        'been made; one answered 429 is', () async {
      graph
        ..throttleInBatch(1, status: 500, retryAfter: 1)
        ..throttleInBatch(1, status: 503, retryAfter: 1)
        ..throttleInBatch(1, retryAfter: 2);

      final answers = await api().createBatch([
        (contact: contact('Ann', 'Lee', 'a@x.com'), tag: 'people/c1'),
        (contact: contact('Bob', 'Day', 'b@x.com'), tag: 'people/c2'),
        (contact: contact('Cat', 'Fox', 'c@x.com'), tag: 'people/c3'),
      ]);

      for (final i in [0, 1]) {
        expect(answers[i].contact, isNull);
        expect(answers[i].failure, isA<ConnectionFailed>());
        expect(answers[i].failure, isA<Retryable>());
      }
      expect(answers[2].contact!['givenName'], 'Cat');
      expect(slept, [const Duration(seconds: 2)]);
      final batches = graph.requestsTo(r'$batch');
      expect(batches, hasLength(2));
      final again = (jsonDecode(batches.last.body) as Map)['requests'] as List;
      expect(again.map((r) => (r as Map)['id']), ['2']);
      expect(graph.count, 1);
    });

    test('a part asking for a wait over 30 s is not waited for', () async {
      graph.throttleInBatch(1, retryAfter: 45);

      final answers = await api().createBatch([
        (contact: contact('Ann', 'Lee', 'a@x.com'), tag: 'people/c1'),
        (contact: contact('Bob', 'Day', 'b@x.com'), tag: 'people/c2'),
      ]);

      expect(slept, isEmpty);
      expect(graph.requestsTo(r'$batch'), hasLength(1));
      expect(answers[0].failure, isA<ConnectionFailed>());
      expect(answers[0].failure, isA<Retryable>());
      expect(answers[1].contact, isNotNull);
    });
  });

  group('the fake keeps to the contact resource', () {
    test('a property a contact does not have is refused, made or changed',
        () async {
      final client = api();
      await expectLater(
        client.create({...contact('Ann', 'Lee', 'a@x.com'), 'faxNumber': '1'}),
        throwsA(isA<ContactRefused>()),
      );
      final made = await client.create(contact('Ann', 'Lee', 'a@x.com'));
      await expectLater(
        client.update(made['id']! as String, {'anniversary': '2001-01-01'}),
        throwsA(isA<ContactRefused>()),
      );
      expect(
        () => graph.seed({'givenName': 'Ann', 'gender': 'f'}),
        throwsArgumentError,
      );
    });

    test('a whole read shows the three email slots', () async {
      final ann = graph.seed({
        'givenName': 'Ann',
        'emailAddresses': [
          {'address': 'a1@x.com'},
          {'address': 'a2@x.com'},
        ],
      });

      final whole = (await api().get(ann, whole: true))!;

      expect(whole['primaryEmailAddress'], {'address': 'a1@x.com'});
      expect(whole['secondaryEmailAddress'], {'address': 'a2@x.com'});
      expect(whole.containsKey('tertiaryEmailAddress'), isTrue);
      expect(whole['tertiaryEmailAddress'], isNull);
    });
  });

  group('the device claim', () {
    test('is read and written on the folder', () async {
      final client = api();

      expect(await client.readClaim(main), isNull);
      await client.writeClaim(
        main,
        device: 'dev-phone-1',
        at: DateTime.utc(2026, 11, 20, 10, 42),
      );

      expect(graph.claim, 'dev-phone-1 2026-11-20T10:42:00.000Z');
      expect(
        await client.readClaim(main),
        GraphDeviceClaim(
          device: 'dev-phone-1',
          at: DateTime.utc(2026, 11, 20, 10, 42),
        ),
      );
      final patch = graph.requests.firstWhere((r) => r.method == 'PATCH');
      expect(patch.url.path, '/v1.0/me/contactFolders/$main');
    });

    test('one that does not read as a claim is none', () {
      expect(GraphDeviceClaim.parse('nonsense'), isNull);
      expect(GraphDeviceClaim.parse('dev 2026-11-20T10:42:00Z')!.device, 'dev');
    });
  });

  group('throttling', () {
    test('a 429 or a 503 is waited out as Retry-After asks', () async {
      graph
        ..throttle(1, retryAfter: 4)
        ..throttle(1, status: 503, retryAfter: 2);

      await api().listAll();

      expect(slept, [const Duration(seconds: 4), const Duration(seconds: 2)]);
    });

    test('a wait longer than is worth sitting through is not sat through',
        () async {
      graph.throttle(1, retryAfter: 600);

      Object? failure;
      try {
        await api().listAll();
      } catch (e) {
        failure = e;
      }

      expect(slept, isEmpty);
      expect(failure, isA<ConnectionFailed>());
      expect(failure, isA<Retryable>());
    });
  });

  group('refusals', () {
    test('a 403 is SignInNeedsConsent', () async {
      graph.consentMissing = true;

      await expectLater(
        api().delta(folderId: main),
        throwsA(isA<SignInNeedsConsent>()),
      );
    });

    test('a token turned away is refreshed once, then AuthenticationFailed',
        () async {
      graph.rejectTokens.add('token');
      await api().listAll();
      expect(forced, [false, true]);

      graph.rejectTokens.add('fresh');
      await expectLater(
        api().listAll(),
        throwsA(isA<AuthenticationFailed>()),
      );
    });

    test("a refused contact's error and the log name only the status and "
        'the code, never what Graph quoted back', () async {
      final logged = captureLog();
      graph.refuse = (_) => true;

      Object? failure;
      try {
        await api().create({
          ...contact('Zebediah', 'Quillfeather', 'zeb.q@example.com'),
          'mobilePhone': '+44 7700 900123',
        });
      } catch (e) {
        failure = e;
      }

      expect(failure, isA<ContactRefused>());
      final refused = failure! as ContactRefused;
      expect(refused.status, 400);
      expect(refused.reason, 'ErrorInvalidProperty');
      final said = [refused.message, '$refused', ...logged].join('\n');
      for (final secret in ['Zebediah', 'Quillfeather', 'zeb.q', '900123']) {
        expect(said, isNot(contains(secret)));
      }
      expect(logged.join('\n'), contains('HTTP 400'));
    });
  });

  group('timeouts', () {
    testWidgets('a request never answered is given up on as no connection',
        (tester) async {
      Object? failed;
      unawaited(
        api(client: MockClient((_) => Completer<http.Response>().future))
            .delta(folderId: main)
            .then<void>((_) {}, onError: (Object e) => failed = e),
      );

      await tester.pump(answerWithin - const Duration(seconds: 1));
      expect(failed, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(failed, isA<ConnectionFailed>());
    });
  });
}
