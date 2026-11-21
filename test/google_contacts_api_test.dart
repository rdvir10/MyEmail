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
import 'package:myemail/data/contacts/google_contacts_api.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/error_report.dart';

import 'fakes/fake_google_people.dart';

/// Contact sync's Google client against the fake People API: paging and
/// sync tokens, their expiry, re-keys, reads by name, batches, etags,
/// throttling, consent, and what its failures and log leave out.
void main() {
  late FakeGooglePeople google;
  late List<Duration> slept;
  late List<bool> forced;

  GoogleContactsApi api({http.Client? client}) => GoogleContactsApi(
    accessToken: ({bool force = false}) async {
      forced.add(force);
      return force ? 'fresh' : 'token';
    },
    httpClient: client ?? google.client,
    sleep: (d) async => slept.add(d),
    clock: () => google.now,
  );

  List<String> captureLog() {
    final logged = <String>[];
    final was = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        logged.add(message ?? '');
    addTearDown(() => debugPrint = was);
    return logged;
  }

  Map<String, Object?> person(String given, String family, String email) => {
    'names': [
      {'givenName': given, 'familyName': family},
    ],
    'emailAddresses': [
      {'value': email, 'type': 'home'},
    ],
  };

  setUp(() {
    google = FakeGooglePeople()..lagWrites = false;
    slept = [];
    forced = [];
  });

  group('listing', () {
    test('a full listing reads every page, with the mask, the source and a '
        'token asked for on each', () async {
      for (var i = 0; i < 5; i++) {
        google.seed(person('P$i', 'Family', 'p$i@example.com'));
      }
      google.maxPageSize = 2;

      final read = await api().listAll();

      expect(read.people, hasLength(5));
      expect(read.complete, isTrue);
      expect(read.deleted, isEmpty);
      expect(read.syncToken, isNotNull);
      expect(read.pages, 3);
      final asked = google.requestsTo('/connections');
      expect(asked, hasLength(3));
      for (final r in asked) {
        final q = r.url.queryParameters;
        expect(q['personFields'], googleContactFields);
        expect(q['sources'], 'READ_SOURCE_TYPE_CONTACT');
        expect(q['requestSyncToken'], 'true');
        expect(q['pageSize'], '1000');
        expect(q.containsKey('syncToken'), isFalse);
      }
      expect(asked[0].url.queryParameters.containsKey('pageToken'), isFalse);
      expect(asked[1].url.queryParameters['pageToken'], isNotNull);
      expect(google.fullListings, 1);
    });

    test('the field mask is the versioned one the plan names', () {
      // A change to the mask without a new version would send an old
      // token with new parameters, which Google refuses.
      expect(
        googleContactFields,
        'names,nicknames,emailAddresses,phoneNumbers,addresses,'
        'organizations,birthdays,biographies,relations,urls,imClients,'
        'memberships,clientData,metadata',
      );
      expect(googleContactFieldsVersion, 1);
    });

    test('a listing of every field asks for no token', () async {
      google.seed(person('Ann', 'Lee', 'ann@example.com'));

      final read = await api().listAll(everyField: true);

      expect(read.people, hasLength(1));
      expect(read.syncToken, isNull);
      final q = google.requestsTo('/connections').single.url.queryParameters;
      expect(q['personFields'], googleEveryField);
      expect(q['sources'], 'READ_SOURCE_TYPE_CONTACT');
      expect(q.containsKey('requestSyncToken'), isFalse);
    });

    test('changes since a token: edits, additions and deletions, sent with '
        'the same parameters as the listing that made it', () async {
      final ann = google.seed(person('Ann', 'Lee', 'ann@example.com'));
      final bob = google.seed(person('Bob', 'Day', 'bob@example.com'));
      google.seed(person('Cat', 'Fox', 'cat@example.com'));
      final client = api();
      final first = await client.listAll();

      google.editFromGmail(ann, {
        'nicknames': [
          {'value': 'Annie'},
        ],
      });
      google.deleteFromGmail(bob);
      final dan = google.addFromGmail(person('Dan', 'Ray', 'dan@example.com'));
      google.maxPageSize = 1;
      final changes = await client.listChanges(first.syncToken!);

      expect(changes.complete, isFalse);
      expect(
        changes.people.map((p) => p['resourceName']),
        unorderedEquals([ann, dan]),
      );
      expect(changes.deleted, {bob});
      expect(changes.syncToken, isNot(first.syncToken));
      final asked = google.requestsTo('/connections').skip(1).toList();
      expect(asked, hasLength(3), reason: 'every page read');
      for (final r in asked) {
        final q = r.url.queryParameters;
        expect(q['syncToken'], first.syncToken);
        expect(q['personFields'], googleContactFields);
        expect(q['sources'], 'READ_SOURCE_TYPE_CONTACT');
        expect(q['requestSyncToken'], 'true');
        expect(q['pageSize'], '1000');
      }
    });

    test("writes show in the fake's listings only once published, and in "
        'reads by name at once', () async {
      google.lagWrites = true;
      final client = api();
      final first = await client.listAll();

      final made = await client.create(person('Eve', 'Hart', 'e@x.com'));
      final name = made['resourceName']! as String;

      expect((await client.listChanges(first.syncToken!)).people, isEmpty);
      expect(await client.get(name), isNotNull);
      google.publish();
      final later = await client.listChanges(first.syncToken!);
      expect(later.people.single['resourceName'], name);
    });

    test('a re-key is applied before a deletion is believed, wherever the '
        'pages fall', () async {
      final ann = google.seed(person('Ann', 'Lee', 'ann@example.com'));
      google.seed(person('Zed', 'Ash', 'zed@example.com'));
      final client = api();
      final first = await client.listAll();

      final now = google.rekeyFromGmail(ann);
      google.maxPageSize = 1;
      final changes = await client.listChanges(first.syncToken!);

      expect(changes.deleted, isEmpty, reason: 'the old name is a re-key');
      expect(changes.rekeyed, {ann: now});
      expect(changes.people.single['resourceName'], now);
      expect(changes.pages, 2, reason: 'the deletion and the re-key apart');
    });

    test('folding keeps the last entry of a contact and follows a re-key '
        'of a re-key', () {
      final read = GoogleContactsApi.foldListing(
        [
          {'resourceName': 'people/a'},
          {
            'resourceName': 'people/b',
            'metadata': {'deleted': true},
          },
          {
            'resourceName': 'people/c',
            'metadata': {
              'previousResourceNames': ['people/b'],
            },
          },
          {
            'resourceName': 'people/d',
            'metadata': {
              'previousResourceNames': ['people/c'],
            },
          },
          {
            'resourceName': 'people/a',
            'names': [
              {'givenName': 'New'},
            ],
          },
          {
            'resourceName': 'people/e',
            'metadata': {'deleted': true},
          },
        ],
        syncToken: 't',
        complete: false,
      );

      expect(read.rekeyed, {'people/b': 'people/d', 'people/c': 'people/d'});
      expect(read.deleted, {'people/e'});
      expect(
        read.people.map((p) => p['resourceName']),
        unorderedEquals(['people/a', 'people/d']),
      );
      expect(
        read.people.firstWhere((p) => p['resourceName'] == 'people/a')['names'],
        isNotNull,
        reason: 'its last entry',
      );
    });

    for (final style in FakeTokenExpiry.values) {
      test('an expired token ($style) is ContactFeedExpired', () async {
        google.seed(person('Ann', 'Lee', 'ann@example.com'));
        final client = api();
        final first = await client.listAll();
        google
          ..expiry = style
          ..expireSyncTokens();

        await expectLater(
          client.listChanges(first.syncToken!),
          throwsA(isA<ContactFeedExpired>()),
        );
      });
    }

    test('a token from a full listing over a week ago has expired, however '
        'often it was used since', () async {
      google.seed(person('Ann', 'Lee', 'ann@example.com'));
      final client = api();
      var token = (await client.listAll()).syncToken!;
      for (var day = 0; day < 6; day++) {
        google.now = google.now.add(const Duration(days: 1));
        token = (await client.listChanges(token)).syncToken!;
      }
      google.now = google.now.add(const Duration(days: 2));

      await expectLater(
        client.listChanges(token),
        throwsA(isA<ContactFeedExpired>()),
      );
    });

    test('another 400 on a listing with a token is not expiry', () async {
      final client = api(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 400,
                'message': 'Request contains an invalid argument.',
                'status': 'INVALID_ARGUMENT',
              },
            }),
            400,
          ),
        ),
      );

      await expectLater(
        client.listChanges('t'),
        throwsA(
          isA<ContactRefused>().having((e) => e.status, 'status', 400),
        ),
      );
    });
  });

  group('reading by name', () {
    test('get asks with the mask and the source, and a contact not there '
        'is null', () async {
      final ann = google.seed(person('Ann', 'Lee', 'ann@example.com'));
      final client = api();

      final got = await client.get(ann);
      expect(got!['resourceName'], ann);
      final q = google.requests.last.url.queryParameters;
      expect(q['personFields'], googleContactFields);
      expect(q['sources'], 'READ_SOURCE_TYPE_CONTACT');

      final whole = await client.get(ann, everyField: true);
      expect(whole, isNotNull);
      expect(
        google.requests.last.url.queryParameters['personFields'],
        googleEveryField,
      );

      google.deleteFromGmail(ann);
      expect(await client.get(ann), isNull);
    });

    test("a contact's version is its contact source's etag, the same in "
        "every read; the Person's own etag is not", () async {
      final ann = google.seed(person('Ann', 'Lee', 'ann@example.com'));
      final client = api();

      final listed = (await client.listAll()).people.single;
      final byName = (await client.get(ann))!;
      final whole = (await client.get(ann, everyField: true))!;
      final batched = (await client.getBatch([ann])).found[ann]!;

      // Google's top-level etag is the entity tag of one answer.
      final topLevel = {
        for (final p in [listed, byName, whole, batched]) p['etag'],
      };
      expect(topLevel, hasLength(4));
      // The version the sync keeps is the same in all of them.
      final versions = {
        for (final p in [listed, byName, whole, batched])
          GoogleContact.fromPerson(p).etag,
      };
      expect(versions, {googleContactEtag(listed)});
      expect(versions.single, isNotNull);

      google.editFromGmail(ann, {
        'nicknames': [
          {'value': 'Annie'},
        ],
      });
      final edited = (await client.get(ann))!;
      expect(googleContactEtag(edited), isNot(versions.single));
    });

    test('getBatch asks 200 at a time; only NOT_FOUND is gone, and a '
        'contact under a new name is a re-key', () async {
      final ann = google.seed(person('Ann', 'Lee', 'ann@example.com'));
      final bob = google.seed(person('Bob', 'Day', 'bob@example.com'));
      final cat = google.seed(person('Cat', 'Fox', 'cat@example.com'));
      google.deleteFromGmail(bob);
      final catNow = google.rekeyFromGmail(cat);
      final names = [
        ann,
        bob,
        cat,
        for (var i = 0; i < 247; i++) 'people/c9$i',
      ];

      final read = await api().getBatch(names);

      expect(read.found.keys, unorderedEquals([ann, cat]));
      expect(read.rekeyed, {cat: catNow});
      expect(read.notFound, contains(bob));
      expect(read.notFound, hasLength(248));
      expect(read.unknown, isEmpty);
      final asked = google.requestsTo('people:batchGet');
      expect(
        asked.map((r) => r.url.queryParametersAll['resourceNames']!.length),
        [200, 50],
      );
      for (final r in asked) {
        expect(r.url.queryParameters['sources'], 'READ_SOURCE_TYPE_CONTACT');
        expect(r.url.queryParameters['personFields'],
            googleContactFields);
      }
    });

    test('a name Google answers anything but NOT_FOUND about is unknown, '
        'never gone', () async {
      final client = api(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'responses': [
                {
                  'requestedResourceName': 'people/a',
                  'status': {'code': 13, 'message': 'Internal error.'},
                },
                {
                  'requestedResourceName': 'people/b',
                  'httpStatusCode': 404,
                  'status': {'code': 5},
                },
              ],
            }),
            200,
          ),
        ),
      );

      final read = await client.getBatch(['people/a', 'people/b', 'people/c']);

      expect(read.notFound, {'people/b'});
      expect(read.unknown, {'people/a', 'people/c'});
    });
  });

  group('writing', () {
    test('create sends the mask and the source, and the tag beside the '
        "other apps' data", () async {
      final client = api();

      final made = await client.create({
        ...person('Ann', 'Lee', 'ann@example.com'),
        'clientData': [
          {'key': 'other.app', 'value': 'kept'},
          {'key': googleLinkKey, 'value': 'stale'},
        ],
      }, tag: 'AAkALg-1');

      final name = made['resourceName']! as String;
      expect(google.tagOf(name), 'AAkALg-1');
      expect(GoogleContactsApi.tagOf(made), 'AAkALg-1');
      final data = google.person(name)!['clientData']! as List;
      expect(data.map((e) => (e as Map)['key']), [
        'other.app',
        googleLinkKey,
      ]);
      final q = google.requestsTo('people:createContact').single.url
          .queryParameters;
      expect(q['personFields'], googleContactFields);
      expect(q['sources'], 'READ_SOURCE_TYPE_CONTACT');
    });

    test('a batch create holds the contacts Google names as refused and '
        'sends the rest again', () async {
      google.refuse = (p) => jsonEncode(p).contains('Refuse');
      final asked = [
        (person: person('Ann', 'Lee', 'a@x.com'), tag: 'g-0'),
        (person: person('Refuse', 'Me', 'r@x.com'), tag: 'g-1'),
        (person: person('Cat', 'Fox', 'c@x.com'), tag: 'g-2'),
      ];

      final answers = await api().createBatch(asked);

      expect(answers[1].contact, isNull);
      expect(
        answers[1].failure,
        isA<ContactRefused>().having((e) => e.status, 'status', 400),
      );
      expect(GoogleContactsApi.tagOf(answers[0].contact!), 'g-0');
      expect(GoogleContactsApi.tagOf(answers[2].contact!), 'g-2');
      expect(answers[0].failure, isNull);
      expect(google.count, 2);
      final sent = google.requestsTo('people:batchCreateContacts');
      expect(sent, hasLength(2));
      final second = jsonDecode(sent.last.body) as Map;
      expect(second['contacts'], hasLength(2));
      expect(second['readMask'], googleContactFields);
      expect(second['sources'], ['READ_SOURCE_TYPE_CONTACT']);
    });

    test('a batch create goes 200 at a time, each answer in its place '
        'whatever order Google answers in', () async {
      final asked = [
        for (var i = 0; i < 201; i++)
          (person: person('P$i', 'F', 'p$i@x.com'), tag: 'g-$i'),
      ];

      final answers = await api().createBatch(asked);

      expect(answers, hasLength(201));
      for (var i = 0; i < 201; i++) {
        expect(GoogleContactsApi.tagOf(answers[i].contact!), 'g-$i');
      }
      expect(
        google.requestsTo('people:batchCreateContacts').map(
          (r) => ((jsonDecode(r.body) as Map)['contacts'] as List).length,
        ),
        [200, 1],
      );
    });

    test('a batch that fails part way keeps what the batches before it '
        'made, and sends none after it', () async {
      var batches = 0;
      final client = api(
        client: MockClient((r) async {
          if (r.url.path.endsWith(':batchCreateContacts') && ++batches == 2) {
            google.fail(1, status: 502);
          }
          return google.handle(r);
        }),
      );
      final asked = [
        for (var i = 0; i < 450; i++)
          (person: person('P$i', 'F', 'p$i@x.com'), tag: 'g-$i'),
      ];

      final answers = await client.createBatch(asked);

      expect(answers, hasLength(450));
      for (var i = 0; i < 200; i++) {
        expect(GoogleContactsApi.tagOf(answers[i].contact!), 'g-$i');
      }
      for (var i = 200; i < 450; i++) {
        expect(answers[i].contact, isNull);
        expect(answers[i].failure, isA<ConnectionFailed>());
        expect(answers[i].failure, isA<Retryable>());
      }
      expect(google.requestsTo('people:batchCreateContacts'), hasLength(2));
      expect(google.count, 200);
    });

    test('a batch refused without a contact named is the batch\'s failure, '
        'not its contacts\', and the next batch goes on', () async {
      final logged = captureLog();
      google.refuseBatchesWhole = 1;
      final asked = [
        (person: person('Zebediah', 'Quill', 'zeb@x.com'), tag: 'g-0'),
        for (var i = 1; i < 250; i++)
          (person: person('P$i', 'F', 'p$i@x.com'), tag: 'g-$i'),
      ];

      final answers = await api().createBatch(asked);

      for (var i = 0; i < 200; i++) {
        expect(answers[i].contact, isNull);
        expect(answers[i].failure, isA<ContactBatchRefused>());
        expect(answers[i].failure, isNot(isA<ContactRefused>()));
      }
      for (var i = 200; i < 250; i++) {
        expect(GoogleContactsApi.tagOf(answers[i].contact!), 'g-$i');
      }
      expect(google.count, 50);
      final said = ['${answers.first.failure}', ...logged].join('\n');
      expect(said, isNot(contains('Zebediah')));
      expect(said, contains('HTTP 400'));
    });

    test('a batch create needs a tag of its own for each contact', () async {
      await expectLater(
        api().createBatch([
          (person: person('Ann', 'Lee', 'a@x.com'), tag: 'same'),
          (person: person('Bob', 'Day', 'b@x.com'), tag: 'same'),
        ]),
        throwsArgumentError,
      );
      expect(google.requests, isEmpty);
    });

    test('update writes the fields named with the etag read, and a stale '
        'etag is ContactChangedMeanwhile', () async {
      final ann = google.seed(person('Ann', 'Lee', 'ann@example.com'));
      final client = api();
      final read = (await client.get(ann))!;

      final written = await client.update(
        ann,
        {
          'etag': read['etag'],
          'metadata': read['metadata'],
          'nicknames': [
            {'value': 'Annie'},
          ],
        },
        fields: ['nicknames'],
      );

      expect(written['etag'], isNot(read['etag']));
      expect(google.person(ann)!['nicknames'], isNotNull);
      final q = google.requestsTo(':updateContact').single.url
          .queryParameters;
      expect(q['updatePersonFields'], 'nicknames');
      expect(q['personFields'], googleContactFields);
      expect(q['sources'], 'READ_SOURCE_TYPE_CONTACT');

      await expectLater(
        client.update(
          ann,
          {'etag': read['etag'], 'metadata': read['metadata']},
          fields: ['nicknames'],
        ),
        throwsA(isA<ContactChangedMeanwhile>()),
      );
    });

    test('updating a contact that has gone is ContactGone', () async {
      final ann = google.seed(person('Ann', 'Lee', 'ann@example.com'));
      final client = api();
      final read = (await client.get(ann))!;
      google.deleteFromGmail(ann);

      await expectLater(
        client.update(ann, {'etag': read['etag']}, fields: ['names']),
        throwsA(isA<ContactGone>()),
      );
    });

    test('delete is true when it deleted, false when it was gone', () async {
      final ann = google.seed(person('Ann', 'Lee', 'ann@example.com'));
      final client = api();

      expect(await client.delete(ann), isTrue);
      expect(google.person(ann), isNull);
      expect(await client.delete(ann), isFalse);
      expect(
        google.requestsTo(':deleteContact').first.method,
        'DELETE',
      );
    });

    test('a name that is not a person is never sent', () async {
      await expectLater(
        api().get('contactGroups/myContacts'),
        throwsArgumentError,
      );
      expect(google.requests, isEmpty);
    });
  });

  group('throttling', () {
    test('a 429 without Retry-After is waited out, twice as long each time',
        () async {
      google
        ..seed(person('Ann', 'Lee', 'ann@example.com'))
        ..throttle(3);

      final read = await api().listAll();

      expect(read.people, hasLength(1));
      expect(slept, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
    });

    test('a Retry-After is waited for as asked', () async {
      google.throttle(1, retryAfter: 7);

      await api().listAll();

      expect(slept, [const Duration(seconds: 7)]);
    });

    test('after a minute of waiting the run stops, to be tried again',
        () async {
      google.throttle(20);

      Object? failure;
      try {
        await api().listAll();
      } catch (e) {
        failure = e;
      }

      expect(failure, isA<ConnectionFailed>());
      expect(failure, isA<Retryable>());
      expect(slept, [
        for (final s in [1, 2, 4, 8, 16, 29]) Duration(seconds: s),
      ]);
      expect(
        slept.fold(Duration.zero, (a, b) => a + b),
        GoogleContactsApi.longestBackoff,
      );
    });

    test('a Retry-After longer than is left of the minute is not waited',
        () async {
      google
        ..throttle(1, retryAfter: 50)
        ..throttle(1, retryAfter: 20);

      await expectLater(api().listAll(), throwsA(isA<ConnectionFailed>()));
      expect(slept, [const Duration(seconds: 50)]);
    });

    test("Google's older 403 rateLimitExceeded is a throttle too", () async {
      google.throttle(1, asForbidden: true);

      final read = await api().listAll();

      expect(read.people, isEmpty);
      expect(slept, [const Duration(seconds: 1)]);
      expect(google.requestsTo('/connections'), hasLength(2));
    });

    test('a server in trouble is not asked again: the run is', () async {
      google.fail(1, status: 503);

      Object? failure;
      try {
        await api().listAll();
      } catch (e) {
        failure = e;
      }

      expect(failure, isA<ConnectionFailed>());
      expect(failure, isA<Retryable>());
      expect(google.requests, hasLength(1));
      expect(slept, isEmpty);
    });

    test('a daily quota is not waited for: nothing goes until 08:00 UTC',
        () async {
      google
        ..now = DateTime.utc(2026, 11, 20, 9, 30)
        ..throttle(1, daily: true);

      await expectLater(
        api().create(person('Ann', 'Lee', 'ann@example.com')),
        throwsA(
          isA<ContactQuotaSpent>().having(
            (e) => e.until,
            'until',
            DateTime.utc(2026, 11, 21, 8),
          ),
        ),
      );
      expect(slept, isEmpty);
    });

    test('the quota day starts at Pacific midnight, in both seasons and '
        'around each change of the clocks', () {
      DateTime next(DateTime now) => GoogleContactsApi.nextQuotaDay(now);
      final cases = {
        // Winter, standard time: midnight is 08:00 UTC.
        DateTime.utc(2026, 1, 15, 7, 59): DateTime.utc(2026, 1, 15, 8),
        DateTime.utc(2026, 1, 15, 8): DateTime.utc(2026, 1, 16, 8),
        DateTime.utc(2026, 11, 20, 9, 30): DateTime.utc(2026, 11, 21, 8),
        // Summer time: midnight is 07:00 UTC, and 07:30 is past it.
        DateTime.utc(2026, 7, 15, 6, 59): DateTime.utc(2026, 7, 15, 7),
        DateTime.utc(2026, 7, 15, 7, 30): DateTime.utc(2026, 7, 16, 7),
        // Summer time starts on Sunday 8 March 2026 at 10:00 UTC.
        DateTime.utc(2026, 3, 8, 7, 30): DateTime.utc(2026, 3, 8, 8),
        DateTime.utc(2026, 3, 8, 9, 30): DateTime.utc(2026, 3, 9, 7),
        DateTime.utc(2026, 3, 8, 10, 30): DateTime.utc(2026, 3, 9, 7),
        DateTime.utc(2026, 3, 9, 6, 30): DateTime.utc(2026, 3, 9, 7),
        // And ends on Sunday 1 November 2026 at 09:00 UTC.
        DateTime.utc(2026, 11, 1, 6, 30): DateTime.utc(2026, 11, 1, 7),
        DateTime.utc(2026, 11, 1, 7, 30): DateTime.utc(2026, 11, 2, 8),
        DateTime.utc(2026, 11, 1, 8, 30): DateTime.utc(2026, 11, 2, 8),
        DateTime.utc(2026, 11, 1, 9, 30): DateTime.utc(2026, 11, 2, 8),
        DateTime.utc(2026, 11, 2, 7, 30): DateTime.utc(2026, 11, 2, 8),
        // A year whose change falls on other dates: 2027, 14 March and
        // 7 November.
        DateTime.utc(2027, 3, 14, 9, 59): DateTime.utc(2027, 3, 15, 7),
        DateTime.utc(2027, 11, 7, 7, 30): DateTime.utc(2027, 11, 8, 8),
        DateTime.utc(2027, 11, 6, 7, 30): DateTime.utc(2027, 11, 7, 7),
      };
      for (final MapEntry(key: now, value: renewed) in cases.entries) {
        expect(next(now), renewed, reason: 'after $now');
      }
    });
  });

  group('the fake refuses what Google refuses', () {
    late GoogleContactsApi client;
    late String ann;
    late Map<String, Object?> read;

    setUp(() async {
      client = api();
      ann = google.seed(person('Ann', 'Lee', 'ann@example.com'));
      read = (await client.get(ann))!;
    });

    test('an update without the contact source, or with its etag stale',
        () async {
      await expectLater(
        client.update(ann, {'etag': read['etag']}, fields: ['nicknames']),
        throwsA(isA<ContactRefused>()),
      );
      google.editFromGmail(ann, {
        'nicknames': [
          {'value': 'A'},
        ],
      });
      final now = (await client.get(ann))!;
      await expectLater(
        client.update(
          ann,
          {'etag': now['etag'], 'metadata': read['metadata']},
          fields: ['nicknames'],
        ),
        throwsA(isA<ContactChangedMeanwhile>()),
      );
    });

    test('two values on a field that holds one, made or written', () async {
      final twoNames = {
        'names': [
          {'givenName': 'Ann'},
          {'givenName': 'Anne'},
        ],
      };
      await expectLater(
        client.create(twoNames),
        throwsA(isA<ContactRefused>()),
      );
      await expectLater(
        client.update(
          ann,
          {...read, ...twoNames},
          fields: ['names'],
        ),
        throwsA(isA<ContactRefused>()),
      );
      final answers = await client.createBatch([(person: twoNames, tag: 't')]);
      expect(answers.single.failure, isA<ContactRefused>());
    });

    test('a field updatePersonFields cannot name', () async {
      for (final field in ['metadata', 'photos']) {
        await expectLater(
          client.update(ann, read, fields: [field]),
          throwsA(isA<ContactRefused>()),
          reason: field,
        );
      }
    });

    test('contact groups written with no contact group in them', () async {
      await expectLater(
        client.update(
          ann,
          {
            ...read,
            'memberships': [
              {
                'domainMembership': {'inViewerDomain': true},
              },
            ],
          },
          fields: ['memberships'],
        ),
        throwsA(isA<ContactRefused>()),
      );
    });
  });

  group('refusals', () {
    test('a token without contacts is SignInNeedsConsent', () async {
      google.consentMissing = true;

      await expectLater(
        api().listAll(),
        throwsA(isA<SignInNeedsConsent>()),
      );
    });

    test('the People API switched off says so, and is no sign-in matter',
        () async {
      google.switchedOff = true;

      Object? failure;
      try {
        await api().listAll();
      } catch (e) {
        failure = e;
      }

      expect(failure, isA<ContactsSwitchedOff>());
      expect(failure, isNot(isA<NeedsSignIn>()));
      expect((failure! as ReadableError).message, contains('People API'));
    });

    test('a token turned away is refreshed once', () async {
      google.rejectTokens.add('token');

      await api().listAll();

      expect(forced, [false, true]);
      expect(
        google.requests.last.headers['Authorization'],
        'Bearer fresh',
      );
    });

    test('a token turned away twice is AuthenticationFailed', () async {
      google.rejectTokens.addAll(['token', 'fresh']);

      await expectLater(
        api().listAll(),
        throwsA(isA<AuthenticationFailed>()),
      );
    });

    test("a refused contact's error and the log name only the status and "
        'the code, never what Google quoted back', () async {
      final logged = captureLog();
      google.refuse = (_) => true;

      Object? failure;
      try {
        await api().create(
          person('Zebediah', 'Quillfeather', 'zeb.q@example.com'),
        );
      } catch (e) {
        failure = e;
      }

      expect(failure, isA<ContactRefused>());
      final refused = failure! as ContactRefused;
      expect(refused.status, 400);
      expect(refused.reason, 'INVALID_ARGUMENT');
      final said = [refused.message, '$refused', ...logged].join('\n');
      expect(google.requests.single.body, contains('Zebediah'),
          reason: 'the fake does quote it back');
      for (final secret in ['Zebediah', 'Quillfeather', 'zeb.q']) {
        expect(said, isNot(contains(secret)));
      }
      expect(logged.join('\n'), contains('HTTP 400'));
    });

    test('a batch refusal keeps no quoted text either', () async {
      final logged = captureLog();
      google.refuse = (p) => jsonEncode(p).contains('Zebediah');

      final answers = await api().createBatch([
        (person: person('Zebediah', 'Quill', 'zeb@x.com'), tag: 't'),
      ]);

      expect(answers.single.failure, isA<ContactRefused>());
      final said = [
        for (final a in answers) '${a.failure}',
        ...logged,
      ].join('\n');
      expect(said, isNot(contains('Zebediah')));
      expect(said, isNot(contains('zeb@')));
    });
  });

  group('timeouts', () {
    testWidgets('a request never answered is given up on as no connection',
        (tester) async {
      Object? failed;
      unawaited(
        api(client: MockClient((_) => Completer<http.Response>().future))
            .listAll()
            .then<void>((_) {}, onError: (Object e) => failed = e),
      );

      await tester.pump(answerWithin - const Duration(seconds: 1));
      expect(failed, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(failed, isA<ConnectionFailed>());
      expect(failed, isA<Retryable>());
    });
  });
}
