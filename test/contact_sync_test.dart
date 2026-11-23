import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart'
    show SignInNeedsConsent;
import 'package:myemail/data/contacts/contact_sync.dart';
import 'package:myemail/data/contacts/contact_sync_service.dart';
import 'package:myemail/data/contacts/contact_sync_store.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/auth/oauth_refresher.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/auth/oauth_token_repository.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/error_report.dart';

import 'fakes/fake_google_people.dart';
import 'fakes/fake_graph_contacts.dart';
import 'fakes/fake_imap_transport.dart';

/// Contact sync end to end: the runner against both fake servers and the
/// Memory store, as the phone would run it, a run at a time.
class Harness {
  Harness({
    bool lagWrites = false,
    ContactSyncStore Function(DateTime Function() clock)? store,
  }) {
    google.lagWrites = lagWrites;
    this.store = store?.call(() => _now) ??
        MemoryContactSyncStore(clock: () => _now);
  }

  DateTime _now = DateTime.utc(2026, 11, 20, 9);
  DateTime get now => _now;
  set now(DateTime at) {
    _now = at;
    google.now = at;
    graph.now = at;
  }

  void pass(Duration d) => now = now.add(d);

  final google = FakeGooglePeople();
  final graph = FakeGraphContacts();
  late final ContactSyncStore store;

  static const gmail = Account(
    id: 'acct-gmail',
    displayName: 'Gmail',
    emailAddress: 'ron@gmail.com',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.oauth,
    colorValue: 0,
  );
  static const hadco = Account(
    id: 'acct-hadco',
    displayName: 'Hadco',
    emailAddress: 'ron@hadco.com',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 1,
  );

  List<Account> accounts = [gmail, hadco];

  /// Accounts whose contacts permission is not given.
  final refusing = <String>{};

  /// The accounts tokens were asked for, in order.
  final tokensFor = <String>[];

  /// Every request, both servers.
  final requests = <http.Request>[];

  /// Called with each request before it is answered.
  Future<void> Function(http.Request request)? before;

  /// Called with each request after it is answered: throwing loses the
  /// answer, as a dropped connection does.
  void Function(http.Request request)? after;

  /// An answer in place of the server's, where it gives one.
  http.Response? Function(http.Request request)? answer;

  /// The server's answer as the client gets it, changed where it returns
  /// another.
  http.Response? Function(http.Request request, http.Response response)?
  reshape;

  late ContactSync sync = make();

  ContactSync make({String device = 'phone', ContactSyncStore? on}) =>
      ContactSync(
        store: on ?? store,
        accounts: () => accounts,
        accessToken:
            (String id, {bool force = false, List<String>? scopes}) async {
              tokensFor.add(id);
              if (refusing.contains(id)) {
                throw const SignInNeedsConsent('Contacts not allowed.');
              }
              return 'token-$id';
            },
        deviceId: () async => device,
        region: () => 'US',
        httpClient: MockClient((request) async {
          requests.add(request);
          await before?.call(request);
          if (answer?.call(request) case final given?) return given;
          final response = request.url.host == 'people.googleapis.com'
              ? await google.handle(request)
              : await graph.handle(request);
          after?.call(request);
          return reshape?.call(request, response) ?? response;
        }),
        sleep: (_) async {},
        clock: () => _now,
      );

  Future<void> choose([ContactSync? on]) => (on ?? sync).choose(
    googleAccountId: gmail.id,
    graphAccountId: hadco.id,
  );

  /// Choose the accounts and run the first sync to its end.
  Future<void> firstSync() async {
    await choose();
    await sync.start();
  }

  /// A run an hour later, as the shell would start one.
  Future<ContactSyncStatus> later({
    Duration after = const Duration(hours: 2),
  }) async {
    pass(after);
    await sync.syncNow();
    return sync.status();
  }

  Future<ContactSyncStatus> status() => sync.status();

  Future<ContactPair> pair() async =>
      (await store.pairs()).where((p) => !p.isDetached).single;

  Future<List<ContactLink>> links() async =>
      store.links((await pair()).pairId);

  Future<List<ContactLink>> paired() async => [
    for (final l in await links())
      if (l.isPaired) l,
  ];

  List<http.Request> writesTo(String host) => [
    for (final r in requests)
      if (r.url.host == host && r.method != 'GET') r,
  ];

  /// Requests that change contacts, either side (the claim's PATCH on the
  /// folder left out).
  List<http.Request> get contactWrites => [
    for (final r in requests)
      if (r.method != 'GET' && !r.url.path.contains('contactFolders')) r,
  ];
}

Map<String, Object?> person(
  String given,
  String family, {
  String? email,
  String? mobile,
  String? company,
  String? street,
}) => {
  'names': [
    {'givenName': given, 'familyName': family},
  ],
  if (email != null)
    'emailAddresses': [
      {'value': email, 'type': 'home'},
    ],
  if (mobile != null)
    'phoneNumbers': [
      {'value': mobile, 'type': 'mobile'},
    ],
  if (company != null)
    'organizations': [
      {'name': company},
    ],
  if (street != null)
    'addresses': [
      {'type': 'home', 'streetAddress': street, 'city': 'Springfield'},
    ],
};

Map<String, Object?> outlook(
  String given,
  String surname, {
  String? email,
  String? mobile,
  String? company,
}) => {
  'givenName': given,
  'surname': surname,
  if (email != null)
    'emailAddresses': [
      {'address': email, 'name': '$given $surname'},
    ],
  'mobilePhone': ?mobile,
  'companyName': ?company,
};

/// [n] people in both address books, alike, so the first sync pairs them.
List<({String google, String graph})> seedPairs(
  Harness h,
  int n, {
  bool mobiles = false,
}) => [
  for (var i = 0; i < n; i++)
    (
      google: h.google.seed(
        person(
          'P$i',
          'Fam$i',
          email: 'p$i@example.com',
          mobile: mobiles ? '+1 202 555 01${10 + i}' : null,
        ),
      ),
      graph: h.graph.seed(
        outlook(
          'P$i',
          'Fam$i',
          email: 'p$i@example.com',
          mobile: mobiles ? '+1 202 555 01${10 + i}' : null,
        ),
      ),
    ),
];

String? mobileOf(Map<String, Object?>? contact) {
  if (contact == null) return null;
  if (contact['mobilePhone'] case final String m) return m;
  final phones = contact['phoneNumbers'];
  for (final p in phones is List ? phones : const []) {
    if (p is Map && p['type'] == 'mobile') return p['value'] as String?;
  }
  return null;
}

String? companyOf(Map<String, Object?>? contact) {
  if (contact == null) return null;
  if (contact['companyName'] case final String c) return c;
  final orgs = contact['organizations'];
  if (orgs is List && orgs.isNotEmpty) return (orgs.first as Map)['name'] as String?;
  return null;
}

void main() {
  late Harness h;

  setUp(() => h = Harness());

  group('the first sync', () {
    test('the preview writes nothing; Start copies each side to the other '
        'and pairs those in both', () async {
      h.google.seed(person('Ann', 'Lee', email: 'ann@example.com'));
      h.google.seed(person('Bob', 'Ray', email: 'bob@example.com'));
      h.graph.seed(outlook('Bob', 'Ray', email: 'bob@example.com'));
      h.graph.seed(outlook('Cy', 'Day', email: 'cy@example.com'));
      await h.choose();

      final preview = await h.sync.preview();
      expect(preview.googleListed, 2);
      expect(preview.graphListed, 2);
      expect(preview.addToGraph, 1);
      expect(preview.addToGoogle, 1);
      expect(preview.pairUp, 1);
      expect(preview.deletions, 0);
      expect(h.contactWritesOf(), isEmpty);
      expect((await h.status()).firstStarted, isFalse);

      await h.sync.start();
      final status = await h.status();
      expect(status.halt, isNull);
      expect(status.firstDone, isTrue);
      expect(status.last!.addedToGraph, 1);
      expect(status.last!.addedToGoogle, 1);
      expect(status.last!.paired, 1);
      expect(h.graph.count, 3);
      expect(h.google.count, 3);
      expect(await h.paired(), hasLength(3));
      // Each copy carries the hidden tag naming its source.
      final ann = h.google.nameWithEmail('ann@example.com')!;
      expect(h.graph.tagOf(h.graph.idWithEmail('ann@example.com')!), ann);
      final cy = h.graph.idWithEmail('cy@example.com')!;
      expect(h.google.tagOf(h.google.nameWithEmail('cy@example.com')!), cy);
      // The claim says this device syncs; the counts are kept.
      expect(h.graph.claim, startsWith('phone '));
      expect(status.googleCount, 3);
      expect(status.graphCount, 3);
    });

    test('Sync now does nothing until Start', () async {
      h.google.seed(person('Ann', 'Lee', email: 'ann@example.com'));
      await h.choose();
      await h.sync.syncNow();
      expect(await h.sync.startIfDue(), isFalse);
      expect(h.requests, isEmpty);
      expect(h.graph.count, 0);
    });

    test('stopped part way, it carries on at the next opening, and '
        'nothing is made twice', () async {
      for (var i = 0; i < 4; i++) {
        h.graph.seed(outlook('O$i', 'Out', email: 'o$i@example.com'));
      }
      h.google.seed(person('Ann', 'Lee', email: 'ann@example.com'));
      var made = 0;
      h.before = (r) async {
        if (r.url.path.endsWith(':createContact') && ++made == 2) {
          // MyEmail put away while the second create is in hand.
          unawaited(h.sync.stop());
        }
      };
      await h.firstSync();
      var status = await h.status();
      expect(status.halt!.kind, ContactSyncHaltKind.putAway);
      expect(status.halt!.pausesRuns, isFalse);
      expect(status.firstUnfinished, isTrue);
      expect(status.last!.complete, isFalse);
      expect(status.last!.done, lessThan(status.last!.planned));
      expect(h.google.count, 3); // Ann and two copies so far

      // An unfinished first sync is always due.
      h.before = null;
      h.pass(const Duration(minutes: 1));
      expect(await h.sync.startIfDue(), isTrue);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(status.firstDone, isTrue);
      expect(h.google.count, 5);
      expect(h.graph.count, 5);
      expect(await h.paired(), hasLength(5));
      // Due again only an hour after a completed run.
      expect(await h.sync.startIfDue(), isFalse);
      h.pass(const Duration(minutes: 61));
      expect(await h.sync.startIfDue(), isTrue);
      await h.sync.syncNow();
    });
  });

  group('later runs', () {
    test('a second run finds its own writes as echoes and writes nothing',
        () async {
      h.google.seed(person('Ann', 'Lee', email: 'ann@example.com'));
      h.graph.seed(outlook('Cy', 'Day', email: 'cy@example.com'));
      await h.firstSync();
      h.requests.clear();
      final status = await h.later();
      expect(status.halt, isNull);
      expect(status.last!.added + status.last!.changed, 0);
      expect(status.needsALook, isEmpty);
      expect(h.contactWritesOf(), isEmpty);
    });

    test('a change on either side reaches the other, and a new contact is '
        'copied', () async {
      final pairs = seedPairs(h, 2, mobiles: true);
      await h.firstSync();

      h.google.editFromGmail(pairs[0].google, {
        'phoneNumbers': [
          {'value': '+1 202 555 0177', 'type': 'mobile'},
        ],
      });
      h.graph.editFromOutlook(pairs[1].graph, {'companyName': 'Acme'});
      h.google.addFromGmail(person('Dee', 'New', email: 'dee@example.com'));
      final status = await h.later();
      expect(status.halt, isNull);
      expect(mobileOf(h.graph.contact(pairs[0].graph)), '+1 202 555 0177');
      expect(companyOf(h.google.person(pairs[1].google)), 'Acme');
      expect(h.graph.idWithEmail('dee@example.com'), isNotNull);
      expect(status.last!.changedGraph, 1);
      expect(status.last!.changedGoogle, 1);
      expect(status.last!.addedToGraph, 1);

      // And then nothing more.
      h.requests.clear();
      await h.later();
      expect(h.contactWritesOf(), isEmpty);
    });

    test("Google's full listing is taken again after six days, and when "
        'its token expires; nothing is written for it', () async {
      seedPairs(h, 2);
      await h.firstSync();
      final full = h.google.fullListings;
      await h.later(after: const Duration(days: 1));
      expect(h.google.fullListings, full);

      h.requests.clear();
      await h.later(after: const Duration(days: 6));
      expect(h.google.fullListings, full + 1);
      expect(h.contactWritesOf(), isEmpty);

      h.google.expireSyncTokens();
      final p = h.google.addFromGmail(
        person('Eve', 'Late', email: 'eve@example.com'),
      );
      final status = await h.later();
      expect(status.halt, isNull);
      expect(h.google.fullListings, full + 2);
      expect(h.graph.idWithEmail('eve@example.com'), isNotNull);
      expect(h.graph.tagOf(h.graph.idWithEmail('eve@example.com')!), p);
      expect(h.graph.count, 3);
    });

    test('an expired Outlook delta starts a new one, reconciled with the '
        'rows: nothing doubled, a change still synced', () async {
      final pairs = seedPairs(h, 3);
      await h.firstSync();
      h.graph.editFromOutlook(pairs[2].graph, {'companyName': 'NewCo'});
      h.graph.expireDeltaLinks();
      final status = await h.later();
      expect(status.halt, isNull);
      expect(h.graph.count, 3);
      expect(h.google.count, 3);
      expect(companyOf(h.google.person(pairs[2].google)), 'NewCo');
      expect(
        h.requests.where((r) => r.url.path.endsWith('/delta')).length,
        greaterThanOrEqualTo(2),
      );
    });
  });

  group('interrupted writes', () {
    test('a create whose answer was lost is settled by its tag, and not '
        'made twice while Google lags', () async {
      h = Harness(lagWrites: true);
      h.graph.seed(outlook('Cy', 'Day', email: 'cy@example.com'));
      h.after = (r) {
        if (r.url.path.endsWith(':createContact')) {
          throw http.ClientException('connection lost');
        }
      };
      await h.firstSync();
      var status = await h.status();
      expect(status.halt!.kind, ContactSyncHaltKind.failed);
      expect(status.halt!.error, isA<Retryable>());
      expect(h.google.count, 1);
      expect(await h.store.ops((await h.pair()).pairId), hasLength(1));

      // Google's listing does not show the copy yet: nothing is made again.
      h.after = null;
      status = await h.later(after: const Duration(minutes: 10));
      expect(status.halt, isNull);
      expect(h.google.count, 1);
      expect(h.requestsTo(':createContact'), hasLength(1));

      // Once it shows, it is paired by its tag.
      h.google.publish();
      status = await h.later(after: const Duration(minutes: 10));
      expect(status.halt, isNull);
      expect(h.google.count, 1);
      expect(await h.paired(), hasLength(1));
      expect(await h.store.ops((await h.pair()).pairId), isEmpty);
      expect(h.graph.count, 1);
    });

    test('an Outlook create whose answer was lost is found by its tag',
        () async {
      h.google.seed(person('Ann', 'Lee', email: 'ann@example.com'));
      h.after = (r) {
        if (r.method == 'POST' && r.url.path.endsWith('/me/contacts')) {
          throw http.ClientException('connection lost');
        }
      };
      await h.firstSync();
      expect((await h.status()).halt!.kind, ContactSyncHaltKind.failed);
      expect(h.graph.count, 1);

      h.after = null;
      final status = await h.later();
      expect(status.halt, isNull);
      expect(h.graph.count, 1);
      expect(await h.paired(), hasLength(1));
    });

    test("Copy it anyway cut short before Outlook made the contact is kept, "
        'and carried out once its create is given up', () async {
      h.google.seed(person('Jo', 'Smith', email: 'jo@home.example'));
      h.graph.seed(outlook('Jo', 'Smith', email: 'jo@work.example'));
      await h.firstSync();
      final look = (await h.status()).needsALook.single;
      expect(look.side, ContactSide.google);
      // The connection drops before Outlook makes anything.
      h.before = (r) async {
        if (r.method == 'POST' && r.url.path.endsWith('/me/contacts')) {
          throw http.ClientException('connection lost');
        }
      };
      await h.sync.answerLook(look.id, ContactSyncChoice.copyAnyway);
      await h.sync.syncNow();
      h.before = null;
      expect(h.graph.count, 1);
      expect(await h.store.ops((await h.pair()).pairId), hasLength(1));

      // Within the hour the copy may still show: Ron's answer is kept.
      var status = await h.later(after: const Duration(minutes: 6));
      expect(status.halt, isNull);
      expect(h.graph.count, 1);

      // An hour on and not found: made, and paired.
      status = await h.later(after: const Duration(minutes: 70));
      expect(status.halt, isNull);
      expect(h.graph.count, 2);
      final jo = h.google.nameWithEmail('jo@home.example');
      expect((await h.paired()).where((l) => l.googleName == jo), hasLength(1));
      expect(await h.store.ops((await h.pair()).pairId), isEmpty);
    });

    test('an interrupted Outlook create is settled by the tag read with '
        'the copy, where nothing else would pair them', () async {
      // A name and a landline: no email to look the copy up by, and no
      // mobile to match it with.
      h.google.seed({
        'names': [
          {'givenName': 'Solo', 'familyName': 'Name'},
        ],
        'phoneNumbers': [
          {'value': '+1 202 555 0101', 'type': 'home'},
        ],
      });
      h.after = (r) {
        if (r.method == 'POST' && r.url.path.endsWith('/me/contacts')) {
          throw http.ClientException('connection lost');
        }
      };
      await h.firstSync();
      expect(h.graph.count, 1);
      h.after = null;
      var status = await h.later(after: const Duration(minutes: 2));
      expect(status.halt, isNull);
      expect(status.needsALook, isEmpty);
      expect(await h.paired(), hasLength(1));
      status = await h.later();
      expect(h.graph.count, 1);
      expect(h.google.count, 1);
    });

    test('a delete cut short between the bin and the server is finished '
        'the next run, and kept once', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.deleteFromGmail(pairs[0].google);
      var deletes = 0;
      h.before = (r) async {
        if (r.method == 'DELETE' && ++deletes == 1) {
          throw http.ClientException('connection lost');
        }
      };
      var status = await h.later();
      expect(status.halt!.kind, ContactSyncHaltKind.failed);
      expect(h.graph.contact(pairs[0].graph), isNotNull);
      expect(status.recentlyDeleted.single.state,
          ContactSyncDeletedState.deleting);

      h.before = null;
      status = await h.later(after: const Duration(minutes: 6));
      expect(status.halt, isNull);
      expect(h.graph.contact(pairs[0].graph), isNull);
      expect(status.recentlyDeleted.single.state,
          ContactSyncDeletedState.deleted);
      expect(await h.paired(), hasLength(1));
    });

    test('a delete the server made but whose answer was lost is marked '
        'done', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.deleteFromGmail(pairs[0].google);
      h.after = (r) {
        if (r.method == 'DELETE') throw http.ClientException('lost');
      };
      await h.later();
      h.after = null;
      final status = await h.later(after: const Duration(minutes: 6));
      expect(status.halt, isNull);
      expect(status.recentlyDeleted.single.state,
          ContactSyncDeletedState.deleted);
      expect(await h.links(), hasLength(1));
      expect(h.graph.count, 1);
    });

    test('a contact the sync just deleted, still in a lagging Google '
        'listing, is not copied back', () async {
      h = Harness(lagWrites: true);
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.graph.deleteFromOutlook(pairs[0].graph);
      var status = await h.later();
      expect(status.last!.deletedGoogle, 1);
      expect(h.google.person(pairs[0].google), isNull);

      // A full listing taken before Google shows the delete.
      h.google.expireSyncTokens();
      status = await h.later(after: const Duration(minutes: 5));
      expect(status.halt, isNull);
      expect(h.graph.count, 1);
      expect(h.graph.idWithEmail('p0@example.com'), isNull);
      expect(status.last!.addedToGraph, 0);
    });

    test('a contact the sync wrote, listed by a lagging Google listing as '
        'it was, is not written back', () async {
      h = Harness(lagWrites: true);
      final pairs = seedPairs(h, 1, mobiles: true);
      await h.firstSync();
      h.graph.editFromOutlook(pairs[0].graph, {'mobilePhone': '+1 202 555 0188'});
      await h.later();
      expect(mobileOf(h.google.person(pairs[0].google)), '+1 202 555 0188');

      h.google.expireSyncTokens();
      final status = await h.later(after: const Duration(minutes: 5));
      expect(status.halt, isNull);
      expect(mobileOf(h.graph.contact(pairs[0].graph)), '+1 202 555 0188');
      expect(status.last!.changedGraph, 0);
    });

    test('two interrupted creates whose sources Ron then merged do not '
        'stop every run', () async {
      h.google.seed(person('Ann', 'Lee', email: 'ann@example.com'));
      h.google.seed(person('Ann', 'Lee', email: 'ann2@example.com'));
      h.after = (r) {
        if (r.url.path.endsWith(r'$batch')) throw http.ClientException('x');
      };
      await h.firstSync();
      expect(await h.store.ops((await h.pair()).pairId), hasLength(2));
      final names = [
        h.google.nameWithEmail('ann@example.com')!,
        h.google.nameWithEmail('ann2@example.com')!,
      ];
      h.google.mergeInGmail(names[0], names[1]);
      h.after = null;
      var status = await h.later();
      expect(status.halt, isNull);
      // No third Ann.
      expect(h.graph.count, 2);
      // One pair; the copy of the contact merged away is held under
      // "merged in Gmail", not paired with the one that stays nor copied
      // back.
      expect(await h.paired(), hasLength(1));
      final look = status.needsALook.single;
      expect(look.kind, ContactReviewKind.mergedInGoogle);
      expect(look.choices, [
        ContactSyncChoice.deleteHereToo,
        ContactSyncChoice.keepOnlyHere,
      ]);
      expect(await h.store.ops((await h.pair()).pairId), isEmpty);
      status = await h.later();
      expect(h.google.count, 1);
      expect(h.graph.count, 2);
      expect(status.needsALook, hasLength(1));
    });
  });

  group('refusals and failures', () {
    test('a refused contact is held, listed, and does not stop the rest; '
        'Retry copies it', () async {
      h.graph.seed(outlook('Good', 'One', email: 'g1@example.com'));
      h.graph.seed(outlook('Bad', 'Apple', email: 'bad@example.com'));
      h.graph.seed(outlook('Good', 'Two', email: 'g2@example.com'));
      h.google.refuse = (p) => '${p['names']}'.contains('Bad');
      await h.firstSync();
      var status = await h.status();
      expect(status.halt, isNull);
      expect(status.firstDone, isTrue);
      expect(status.last!.refused, 1);
      expect(h.google.count, 2);
      final look = status.needsALook.single;
      expect(look.kind, ContactReviewKind.refused);
      expect(look.side, ContactSide.google);
      expect(look.title, 'Bad Apple');
      expect(look.choices, [ContactSyncChoice.retry]);

      h.google.refuse = null;
      await h.sync.answerLook(look.id, ContactSyncChoice.retry);
      await h.sync.syncNow();
      status = await h.status();
      expect(h.google.count, 3);
      expect(status.needsALook, isEmpty);
      expect(await h.paired(), hasLength(3));
    });

    test('a batch refused whole is sent one at a time', () async {
      for (var i = 0; i < ContactSync.googleBatchFloor; i++) {
        h.graph.seed(outlook('O$i', 'Out', email: 'o$i@example.com'));
      }
      h.google.refuseBatchesWhole = 1;
      await h.firstSync();
      final status = await h.status();
      expect(status.halt, isNull);
      expect(h.google.count, ContactSync.googleBatchFloor);
      expect(h.requestsTo(':batchCreateContacts'), hasLength(1));
      expect(
        h.requestsTo(':createContact'),
        hasLength(ContactSync.googleBatchFloor),
      );
      expect(await h.paired(), hasLength(ContactSync.googleBatchFloor));
    });

    test('a small remainder goes one at a time, not as a batch', () async {
      for (var i = 0; i < 5; i++) {
        h.graph.seed(outlook('O$i', 'Out', email: 'o$i@example.com'));
      }
      await h.firstSync();
      expect(h.requestsTo(':batchCreateContacts'), isEmpty);
      expect(h.requestsTo(':createContact'), hasLength(5));
    });

    for (final side in ContactSide.values) {
      test('contacts not allowed on the ${side.name} side stop the run, '
          'naming that account', () async {
        seedPairs(h, 1);
        final account = side == ContactSide.google ? Harness.gmail : Harness.hadco;
        h.refusing.add(account.id);
        await h.firstSync();
        final halt = (await h.status()).halt!;
        expect(halt.kind, ContactSyncHaltKind.notAllowed);
        expect(halt.side, side);
        // Access is asked first: neither server was sent a thing.
        expect(h.requests, isEmpty);
        final error = halt.error! as ContactSyncNeedsSignIn;
        expect(error.accountId, account.id);
        expect(error, isA<NeedsSignIn>());
        expect(h.contactWritesOf(), isEmpty);
        expect(
          (await h.sync.access(account.id)).state,
          ContactSyncAccessState.needsSignIn,
        );

        // Within five minutes the shell does not try again; a sign-in
        // since lifts that.
        h.refusing.clear();
        h.pass(const Duration(minutes: 1));
        expect(await h.sync.startIfDue(), isFalse);
        h.sync.forget(account.id);
        expect(await h.sync.startIfDue(), isTrue);
        await h.sync.syncNow();
        expect((await h.status()).halt, isNull);
      });
    }

    test('the preview names the account not allowed, and the access line '
        'says which state each is in', () async {
      h.refusing.add(Harness.hadco.id);
      await h.choose();
      await expectLater(
        h.sync.preview(),
        throwsA(
          isA<ContactSyncNeedsSignIn>()
              .having((e) => e.side, 'side', ContactSide.graph)
              .having((e) => e.accountId, 'account', Harness.hadco.id),
        ),
      );
      expect(
        (await h.sync.access(Harness.gmail.id)).state,
        ContactSyncAccessState.allowed,
      );
      expect(
        (await h.sync.access(Harness.hadco.id)).state,
        ContactSyncAccessState.needsSignIn,
      );
      expect(
        (await h.sync.access('no-such-account')).state,
        ContactSyncAccessState.notPossible,
      );
    });

    test('a stop is told once, when MyEmail is next opened', () async {
      seedPairs(h, 1);
      h.refusing.add(Harness.hadco.id);
      await h.firstSync();
      var status = await h.status();
      expect(status.notice!.halt!.kind, ContactSyncHaltKind.notAllowed);
      await h.sync.noticeSeen(status.notice!.at);
      status = await h.status();
      expect(status.notice, isNull);
      // A later stop is a new notice.
      await h.later(after: const Duration(minutes: 10));
      expect((await h.status()).notice, isNotNull);
    });

    test("a server's own refusal of the permission (403) names the account",
        () async {
      seedPairs(h, 1);
      h.graph.consentMissing = true;
      await h.firstSync();
      final halt = (await h.status()).halt!;
      expect(halt.kind, ContactSyncHaltKind.notAllowed);
      expect(halt.side, ContactSide.graph);
      expect((halt.error! as ContactSyncNeedsSignIn).accountId,
          Harness.hadco.id);
    });

    test("Google's daily quota stops runs until it is renewed", () async {
      seedPairs(h, 1);
      await h.firstSync();
      h.google.addFromGmail(person('New', 'One', email: 'new@example.com'));
      h.google.throttle(1, daily: true);
      var status = await h.later();
      final halt = status.halt!;
      expect(halt.kind, ContactSyncHaltKind.quota);
      expect(halt.until!.isAfter(h.now), isTrue);

      // Neither the shell nor Sync now asks Google again before then.
      h.pass(const Duration(minutes: 30));
      expect(await h.sync.startIfDue(), isFalse);
      final asked = h.requests.length;
      await h.sync.syncNow();
      expect(
        h.requests.skip(asked).where(
          (r) => r.url.host == 'people.googleapis.com',
        ),
        isEmpty,
      );

      h.now = halt.until!.add(const Duration(minutes: 1));
      expect(await h.sync.startIfDue(), isTrue);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(h.graph.idWithEmail('new@example.com'), isNotNull);
    });
  });

  group('the brakes', () {
    test('more than five deletions are held and asked about; Delete them '
        'deletes them', () async {
      final pairs = seedPairs(h, 8);
      await h.firstSync();
      for (var i = 0; i < 6; i++) {
        h.google.deleteFromGmail(pairs[i].google);
      }
      h.google.editFromGmail(pairs[7].google, {
        'organizations': [
          {'name': 'Still synced'},
        ],
      });
      var status = await h.later();
      expect(status.halt, isNull);
      expect(h.graph.count, 8);
      // Everything else is applied meanwhile.
      expect(companyOf(h.graph.contact(pairs[7].graph)), 'Still synced');
      final q = status.questions.single;
      expect(q.kind, ContactSyncQuestionKind.deletions);
      expect(q.items, hasLength(6));
      expect(q.items.first.side, ContactSide.google);
      expect(q.items.map((i) => i.title), contains('P0 Fam0'));
      expect(status.notice!.heldDeletions, 6);
      await h.sync.noticeSeen(status.notice!.at);
      expect((await h.status()).notice, isNull);

      // Held still, whatever the next run would count.
      status = await h.later();
      expect(h.graph.count, 8);
      expect(status.questions.single.items, hasLength(6));

      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.deleteThem,
      );
      await h.sync.syncNow();
      status = await h.status();
      expect(h.graph.count, 2);
      expect(status.questions, isEmpty);
      expect(status.recentlyDeleted, hasLength(6));
    });

    test('Delete them deletes only the contacts its question named, across '
        'a stopped run', () async {
      final pairs = seedPairs(h, 14);
      await h.firstSync();
      for (var i = 0; i < 6; i++) {
        h.google.deleteFromGmail(pairs[i].google);
      }
      var status = await h.later();
      expect(status.questions.single.items, hasLength(6));

      // Ron deletes six more, then answers the first question; the run that
      // carries it out holds the new six under a question of their own,
      // and is put away after two deletes.
      for (var i = 6; i < 12; i++) {
        h.google.deleteFromGmail(pairs[i].google);
      }
      var deletes = 0;
      h.before = (r) async {
        if (r.method == 'DELETE' && ++deletes == 2) unawaited(h.sync.stop());
      };
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.deleteThem,
      );
      await h.sync.syncNow();
      expect((await h.status()).halt!.kind, ContactSyncHaltKind.putAway);
      h.before = null;
      status = await h.later(after: const Duration(minutes: 1));
      expect(status.halt, isNull);
      // The first six are gone; the second six wait for their own answer.
      expect(h.graph.count, 8);
      for (var i = 0; i < 6; i++) {
        expect(h.graph.contact(pairs[i].graph), isNull);
      }
      for (var i = 6; i < 12; i++) {
        expect(h.graph.contact(pairs[i].graph), isNotNull);
      }
      final q = status.questions.single;
      expect(q.answer, isNull);
      expect(q.items, hasLength(6));
    });

    test("Don't delete them keeps the copies, unpaired, under Needs a look",
        () async {
      final pairs = seedPairs(h, 6);
      await h.firstSync();
      for (final p in pairs) {
        h.google.deleteFromGmail(p.google);
      }
      await h.later();
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.dontDelete,
      );
      await h.sync.syncNow();
      final status = await h.status();
      expect(h.graph.count, 6);
      expect(status.questions, isEmpty);
      expect(status.needsALook, hasLength(6));
      expect(status.needsALook.first.kind, ContactReviewKind.kept);
      expect(status.needsALook.first.reason, ContactReviewReason.notDeleted);
      expect(await h.paired(), isEmpty);
    });

    test("a held row's gone partner is kept while it is held, and cleared "
        'when the plan clears it', () async {
      final pairs = seedPairs(h, 6);
      await h.firstSync();
      for (final p in pairs) {
        h.google.deleteFromGmail(p.google);
      }
      await h.later();
      var rows = await h.links();
      expect(rows.every((l) => l.reason == ContactHeldReason.deletionBrake),
          isTrue);
      expect(rows.every((l) => l.partnerId != null && l.partnerBase != null),
          isTrue);

      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.dontDelete,
      );
      await h.sync.syncNow();
      var status = await h.status();
      final kept = status.needsALook;
      expect(kept, hasLength(6));
      // Keep it only here on one: held as left out, its partner gone.
      await h.sync.answerLook(kept[0].id, ContactSyncChoice.keepOnlyHere);
      // Copy it back on another: paired again, no partner kept.
      await h.sync.answerLook(kept[1].id, ContactSyncChoice.copyBack);
      await h.sync.syncNow();
      rows = await h.links();
      final leftOut = rows.where((l) => l.reason == ContactHeldReason.leftOut);
      expect(leftOut, hasLength(1));
      expect(leftOut.single.partnerId, isNull);
      expect(leftOut.single.partnerBase, isNull);
      final paired = rows.where((l) => l.isPaired);
      expect(paired, hasLength(1));
      expect(paired.single.partnerId, isNull);
      expect(paired.single.partnerBase, isNull);
    });

    test('more than ten contacts losing details are held; Copy them back '
        'puts the details back', () async {
      final pairs = seedPairs(h, 11, mobiles: true);
      await h.firstSync();
      for (final p in pairs) {
        h.google.editFromGmail(p.google, {'phoneNumbers': null});
      }
      var status = await h.later();
      expect(status.questions.single.kind, ContactSyncQuestionKind.changes);
      expect(status.questions.single.items, hasLength(11));
      expect(mobileOf(h.graph.contact(pairs[0].graph)), isNotNull);

      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.copyThemBack,
      );
      await h.sync.syncNow();
      status = await h.status();
      expect(status.questions, isEmpty);
      expect(mobileOf(h.google.person(pairs[0].google)), isNotNull);
      expect(mobileOf(h.graph.contact(pairs[0].graph)), isNotNull);
    });

    test('Apply them applies the held changes', () async {
      final pairs = seedPairs(h, 11, mobiles: true);
      await h.firstSync();
      for (final p in pairs) {
        h.google.editFromGmail(p.google, {'phoneNumbers': null});
      }
      await h.later();
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.applyThem,
      );
      await h.sync.syncNow();
      expect((await h.status()).questions, isEmpty);
      expect(mobileOf(h.graph.contact(pairs[0].graph)), isNull);
    });

    test('a listing with far fewer contacts stops the run before any '
        "write; That's right, carry on accepts it", () async {
      final pairs = seedPairs(h, 12);
      await h.firstSync();
      for (var i = 0; i < 7; i++) {
        h.graph.purgeFromOutlook(pairs[i].graph);
      }
      h.graph.expireDeltaLinks();
      h.requests.clear();
      var status = await h.later();
      expect(status.halt!.kind, ContactSyncHaltKind.emptyAnswer);
      expect(status.halt!.side, ContactSide.graph);
      expect(h.contactWritesOf(), isEmpty);
      final q = status.questions.single;
      expect(q.kind, ContactSyncQuestionKind.emptyAnswer);
      expect(q.listed, 5);
      expect(q.expected, 12);
      expect(status.notice!.halt!.kind, ContactSyncHaltKind.emptyAnswer);

      // Keep waiting changes nothing.
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.emptyAnswer,
        ContactSyncChoice.keepWaiting,
      );
      expect((await h.status()).questions.single.answer, isNull);

      await h.sync.answerQuestion(
        ContactSyncQuestionKind.emptyAnswer,
        ContactSyncChoice.carryOn,
      );
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      // The seven gone are more than five deletions: asked about.
      expect(status.questions.single.kind, ContactSyncQuestionKind.deletions);
      expect(h.google.count, 12);
      expect(status.graphCount, 5);
    });

    test('a Gmail re-key moves the tag of the Outlook copy the sync made, '
        'and gives none to a contact that had none', () async {
      final made = h.google.seed(person('Ann', 'Lee', email: 'ann@example.com'));
      final pairs = seedPairs(h, 1);
      await h.firstSync();
      final copy = h.graph.idWithEmail('ann@example.com')!;
      expect(h.graph.tagOf(copy), made);
      final annNow = h.google.rekeyFromGmail(made);
      final p0Now = h.google.rekeyFromGmail(pairs[0].google);
      final status = await h.later();
      expect(status.halt, isNull);
      expect(h.graph.tagOf(copy), annNow);
      expect(h.graph.tagOf(pairs[0].graph), isNull);
      final rows = await h.paired();
      expect(rows.map((l) => l.googleName), containsAll([annNow, p0Now]));
      // The patch's own changeKey is kept: no change read back from it.
      h.requests.clear();
      await h.later();
      expect(h.contactWritesOf(), isEmpty);
    });

    test("an Outlook edit made as the tag moves still reads as one: the "
        "partner's delete then keeps it", () async {
      final made = h.google.seed(person('Ann', 'Lee', email: 'ann@example.com'));
      seedPairs(h, 1);
      await h.firstSync();
      final copy = h.graph.idWithEmail('ann@example.com')!;
      final annNow = h.google.rekeyFromGmail(made);
      h.before = (r) async {
        // The read just before the tag's patch.
        if (r.method == 'GET' &&
            r.url.path.endsWith('/me/contacts/$copy') &&
            (r.url.queryParameters[r'$expand'] ?? '').isNotEmpty) {
          h.before = null;
          h.graph.editFromOutlook(copy, {'jobTitle': 'Chief'});
        }
      };
      await h.later();
      expect(h.graph.tagOf(copy), annNow);
      // Ron deletes the Gmail contact: the Outlook one changed since it was
      // last synced, so it is kept, not deleted.
      h.google.deleteFromGmail(annNow);
      final status = await h.later();
      expect(h.graph.contact(copy), isNotNull);
      expect(status.needsALook.single.kind, ContactReviewKind.kept);
    });

    test('a re-key reaches a held brake and an open review', () async {
      final pairs = seedPairs(h, 6);
      h.google.seed(person('Kim', 'Shared', email: 'family@example.com'));
      h.google.seed(person('Lou', 'Shared', email: 'family@example.com'));
      h.graph.seed(outlook('Kim', 'Shared', email: 'family@example.com'));
      await h.firstSync();
      var status = await h.status();
      final review = status.needsALook.firstWhere(
        (l) => l.kind == ContactReviewKind.newContact,
      );
      for (final p in pairs) {
        h.graph.deleteFromOutlook(p.graph);
      }
      await h.later();
      // The deletions held are of Gmail contacts; one is re-keyed, and so
      // is the subject of the review.
      final moved = h.google.rekeyFromGmail(pairs[0].google);
      final subject = (await h.store.reviews((await h.pair()).pairId))
          .firstWhere((r) => r.reviewId == review.id);
      final subjectName = subject.googleName ?? subject.graphId!;
      String? movedSubject;
      if (subject.googleName != null) {
        movedSubject = h.google.rekeyFromGmail(subjectName);
      }
      status = await h.later();
      expect(status.halt, isNull);
      final pairId = (await h.pair()).pairId;
      final pairRow = await h.pair();
      expect(pairRow.held, contains(moved));
      expect(pairRow.held, isNot(contains(pairs[0].google)));
      if (movedSubject != null) {
        final r = (await h.store.reviews(pairId))
            .firstWhere((r) => r.reviewId == review.id);
        expect(r.googleName, movedSubject);
      }

      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.deleteThem,
      );
      await h.sync.syncNow();
      status = await h.status();
      expect(status.questions, isEmpty);
      for (final p in pairs.skip(1)) {
        expect(h.google.person(p.google), isNull);
      }
      // The re-keyed one was found under its new name, read again before
      // its delete, and kept: the re-key moved its version, which reads
      // as a change since it was last synced.
      expect(h.google.person(moved), isNotNull);
      final kept = await h.store.reviews(pairId);
      expect(
        kept.where((r) => r.kind == 'kept').single.googleName,
        moved,
      );
    });
  });

  group('Needs a look', () {
    test('Use Gmail\'s, planned again after the contact changed meanwhile, '
        'is still applied', () async {
      final ann = h.google.seed(
        person('Ann', 'Lee', email: 'ann@example.com', company: 'Acme'),
      );
      final annH = h.graph.seed(
        outlook('Ann', 'Lee', email: 'ann@example.com', company: 'Acme Corp'),
      );
      await h.firstSync();
      var status = await h.status();
      final look = status.needsALook.single;
      expect(look.kind, ContactReviewKind.differing);
      expect(look.fields, [ContactField.company]);
      expect(look.googleValues[ContactField.company], 'Acme');
      expect(look.graphValues[ContactField.company], 'Acme Corp');

      // Ron edits the job title in Outlook just as the run reads the
      // contact again before writing it (its first read is for the plan).
      var reads = 0;
      var edited = false;
      h.before = (r) async {
        if (r.method == 'GET' &&
            r.url.path.endsWith('/me/contacts/$annH') &&
            ++reads == 2) {
          edited = true;
          h.graph.editFromOutlook(annH, {'jobTitle': 'Boss'});
        }
      };
      await h.sync.answerLook(look.id, ContactSyncChoice.useGoogle);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(edited, isTrue);
      // Read a third time, after the change: the pair was planned again.
      expect(reads, greaterThanOrEqualTo(3));
      expect(companyOf(h.graph.contact(annH)), 'Acme');
      final orgs = h.google.person(ann)!['organizations']! as List;
      expect((orgs.first as Map)['title'], 'Boss');
      expect(status.needsALook, isEmpty);
    });

    test('a Gmail contact changed after its Outlook partner was written is '
        'planned again knowing that write', () async {
      final pairs = seedPairs(h, 1, mobiles: true);
      await h.firstSync();
      final g = pairs[0].google;
      final o = pairs[0].graph;
      h.google.editFromGmail(g, {
        'phoneNumbers': [
          {'value': '+1 202 555 0177', 'type': 'mobile'},
        ],
      });
      h.graph.editFromOutlook(o, {'companyName': 'Acme'});
      var edited = false;
      h.before = (r) async {
        // The read of the Gmail contact just before its write.
        if (!edited &&
            r.method == 'GET' &&
            r.url.path.endsWith('/v1/$g') &&
            h.writesTo('graph.microsoft.com').isNotEmpty) {
          edited = true;
          h.google.editFromGmail(g, {
            'nicknames': [
              {'value': 'Bo'},
            ],
          });
        }
      };
      final status = await h.later();
      expect(status.halt, isNull);
      expect(edited, isTrue);
      final outlook = h.graph.contact(o)!;
      expect(mobileOf(outlook), '+1 202 555 0177');
      expect(outlook['nickName'], 'Bo');
      final gmail = h.google.person(g)!;
      expect(companyOf(gmail), 'Acme');
      expect((gmail['nicknames']! as List).length, 1);
      expect(mobileOf(gmail), '+1 202 555 0177');
      expect(status.needsALook, isEmpty);

      h.before = null;
      h.requests.clear();
      await h.later();
      expect(h.contactWritesOf(), isEmpty);
    });

    test('after a reinstall, copies the sync made pair again by their tags, '
        'nothing made', () async {
      // A name and a landline: only the hidden tags can pair these.
      final wolf = h.google.seed({
        'names': [
          {'givenName': 'Lone', 'familyName': 'Wolf'},
        ],
        'phoneNumbers': [
          {'value': '+1 202 555 0101', 'type': 'home'},
        ],
      });
      h.graph.seed(
        {
          'givenName': 'Lone',
          'surname': 'Wolf',
          'homePhones': ['+1 202 555 0101'],
        },
        tag: wolf,
      );
      final ann = h.graph.seed(
        outlook('Ann', 'Lee', email: 'ann@example.com'),
      );
      h.google.seed({
        ...person('Ann', 'Lee', email: 'ann@example.com'),
        'clientData': [
          {'key': 'myemail.link', 'value': ann},
        ],
      });
      // A store with nothing in it, as after a reinstall.
      await h.firstSync();
      final status = await h.status();
      expect(status.halt, isNull);
      expect(status.needsALook, isEmpty);
      expect(await h.paired(), hasLength(2));
      expect(h.google.count, 2);
      expect(h.graph.count, 2);
      expect(h.contactWritesOf().where((r) => r.method == 'POST'), isEmpty);
    });

    test("an Outlook write's answer that lacks a property is read whole and "
        "still taken as the sync's own write", () async {
      final pairs = seedPairs(h, 1, mobiles: true);
      await h.firstSync();
      final g = pairs[0].google;
      final o = pairs[0].graph;
      Map<String, Object?> phone(String n) => {
        'phoneNumbers': [
          {'value': n, 'type': 'mobile'},
        ],
      };
      h.google.editFromGmail(g, phone('+1 202 555 0177'));
      h.graph.editFromOutlook(o, {'companyName': 'Acme'});
      // The PATCH's answer leaves out a property, as Graph may.
      h.reshape = (r, response) {
        if (r.method != 'PATCH' || !r.url.path.endsWith('/me/contacts/$o')) {
          return null;
        }
        final json = jsonDecode(response.body) as Map<String, Object?>
          ..remove('imAddresses');
        return http.Response(
          jsonEncode(json),
          response.statusCode,
          headers: response.headers,
        );
      };
      // Ron changes the mobile again in Gmail as the run reads Outlook
      // before its write; the write is made a minute after his edit.
      var edited = false;
      h.before = (r) async {
        if (!edited &&
            r.method == 'GET' &&
            r.url.path.endsWith('/me/contacts/$o')) {
          edited = true;
          h.google.editFromGmail(g, phone('+1 202 555 0199'));
          h.pass(const Duration(minutes: 1));
        }
      };
      final status = await h.later();
      expect(status.halt, isNull);
      expect(edited, isTrue);
      // Ron's edit wins over the value the sync had just written.
      expect(mobileOf(h.google.person(g)), '+1 202 555 0199');
      expect(mobileOf(h.graph.contact(o)), '+1 202 555 0199');
      expect(companyOf(h.google.person(g)), 'Acme');
      expect(
        status.needsALook.where((l) => l.kind == ContactReviewKind.clash),
        isEmpty,
      );
    });

    test('...and one changed again since the write is left for the next '
        "run, Ron's edit kept", () async {
      final pairs = seedPairs(h, 1, mobiles: true);
      await h.firstSync();
      final g = pairs[0].google;
      final o = pairs[0].graph;
      h.google.editFromGmail(g, {
        'phoneNumbers': [
          {'value': '+1 202 555 0177', 'type': 'mobile'},
        ],
      });
      h.graph.editFromOutlook(o, {'companyName': 'Acme'});
      h.reshape = (r, response) {
        if (r.method != 'PATCH' || !r.url.path.endsWith('/me/contacts/$o')) {
          return null;
        }
        final json = jsonDecode(response.body) as Map<String, Object?>
          ..remove('imAddresses');
        return http.Response(
          jsonEncode(json),
          response.statusCode,
          headers: response.headers,
        );
      };
      var gets = 0;
      h.before = (r) async {
        if (r.method == 'GET' && r.url.path.endsWith('/v1/$g') && ++gets == 1) {
          // Gmail changed under the run, and Ron changes in Outlook the
          // mobile the sync has just written there.
          h.google.editFromGmail(g, {
            'nicknames': [
              {'value': 'Bo'},
            ],
          });
          h.pass(const Duration(minutes: 1));
          h.graph.editFromOutlook(o, {'mobilePhone': '+1 202 555 0155'});
        }
      };
      var status = await h.later();
      expect(status.halt, isNull);
      h.before = null;
      h.reshape = null;
      status = await h.later();
      expect(status.halt, isNull);
      // His Outlook edit reaches Gmail: it was not taken for the sync's.
      final gmail = h.google.person(g)!;
      expect(mobileOf(gmail), '+1 202 555 0155');
      expect(mobileOf(h.graph.contact(o)), '+1 202 555 0155');
      expect(companyOf(gmail), 'Acme');
      expect(h.graph.contact(o)!['nickName'], 'Bo');
    });

    test('Same person pairs a new contact with its candidate', () async {
      h.google.seed(person('Jo', 'Smith', email: 'jo@home.example'));
      h.graph.seed(outlook('Jo', 'Smith', email: 'jo@work.example'));
      await h.firstSync();
      final look = (await h.status()).needsALook.single;
      expect(look.reason, ContactReviewReason.sameName);
      expect(look.choices, contains(ContactSyncChoice.samePerson));
      await h.sync.answerLook(look.id, ContactSyncChoice.samePerson);
      await h.sync.syncNow();
      expect(await h.paired(), hasLength(1));
      expect(h.google.count, 1);
      expect(h.graph.count, 1);
    });

    test('merged in Gmail: Delete it here too deletes the other Outlook '
        'contact', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.mergeInGmail(pairs[0].google, pairs[1].google);
      var status = await h.later();
      expect(status.halt, isNull);
      final look = status.needsALook.single;
      expect(look.kind, ContactReviewKind.mergedInGoogle);
      expect(look.choices, [
        ContactSyncChoice.deleteHereToo,
        ContactSyncChoice.keepOnlyHere,
      ]);
      // Merged away in Gmail: "here" is the Outlook contact left.
      expect(look.side, ContactSide.google);
      expect(h.graph.count, 2);
      await h.sync.answerLook(look.id, ContactSyncChoice.deleteHereToo);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.needsALook, isEmpty);
      expect(h.graph.count, 1);
      expect(h.google.count, 1);
      expect(await h.paired(), hasLength(1));
      expect(status.recentlyDeleted.single.side, ContactSide.graph);
    });

    test('kept: Copy it back makes the partner again', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.deleteFromGmail(pairs[0].google);
      h.before = (r) async {
        if (r.method == 'GET' &&
            r.url.path.endsWith('/me/contacts/${pairs[0].graph}') &&
            !r.url.queryParameters.containsKey(r'$select')) {
          h.before = null;
          h.graph.editFromOutlook(pairs[0].graph, {'jobTitle': 'Chief'});
        }
      };
      var status = await h.later();
      final look = status.needsALook.single;
      expect(look.kind, ContactReviewKind.kept);
      await h.sync.answerLook(look.id, ContactSyncChoice.copyBack);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.needsALook, isEmpty);
      expect(h.google.nameWithEmail('p0@example.com'), isNotNull);
      expect(await h.paired(), hasLength(2));
      expect(h.google.count, 2);
    });

    test('an answer applied on an item a re-key folds into another is not '
        'applied again', () async {
      final x1 = h.google.seed(person('Jo', 'Smith', email: 'jo1@example.com'));
      final x2 = h.google.seed(person('Jo', 'Smith', email: 'jo2@example.com'));
      h.graph.seed(outlook('Jo', 'Smith', email: 'jo3@example.com'));
      await h.firstSync();
      var status = await h.status();
      final looks = [
        for (final l in status.needsALook)
          if (l.kind == ContactReviewKind.newContact &&
              l.side == ContactSide.google)
            l,
      ];
      expect(looks, hasLength(2));
      final pairId = (await h.pair()).pairId;
      Future<ContactReview> reviewOf(String name) async =>
          (await h.store.reviews(pairId)).firstWhere(
            (r) => r.googleName == name,
          );
      final older = await reviewOf(x1);
      final answered = await reviewOf(x2);
      expect(older.reviewId! < answered.reviewId!, isTrue);

      // Ron leaves out the second, then merges it into the first in Gmail:
      // the run's re-key brings the two items onto one contact.
      await h.sync.answerLook(answered.reviewId!, ContactSyncChoice.leaveOut);
      await h.sync.stop();
      h.google.mergeInGmail(x1, x2);
      status = await h.later();
      expect(status.halt, isNull);
      final kept = (await h.store.reviews(pairId)).where(
        (r) => r.googleName == x1,
      );
      // The older item is not handed the answer that was carried out.
      expect(kept.every((r) => r.answer == null), isTrue);
      expect((await h.pair()).held ?? '', isNot(contains('leaveOut')));
    });

    test("the item of a contact a Gmail merge folds away goes; it is not "
        "moved onto the merged contact", () async {
      final away = h.google.seed(person('Jo', 'Smith', email: 'j1@example.com'));
      final stays = h.google.seed(person('Jo', 'Smith', email: 'j2@example.com'));
      h.graph.seed(outlook('Jo', 'Smith', email: 'j3@example.com'));
      await h.firstSync();
      final pairId = (await h.pair()).pairId;
      final before = await h.store.reviews(pairId);
      final awayItem = before.firstWhere((r) => r.googleName == away);
      final staysItem = before.firstWhere((r) => r.googleName == stays);
      expect(awayItem.reviewId! < staysItem.reviewId!, isTrue);

      h.google.mergeInGmail(stays, away);
      final status = await h.later();
      expect(status.halt, isNull);
      final after = await h.store.reviews(pairId);
      expect(after.map((r) => r.reviewId), isNot(contains(awayItem.reviewId)));
      expect(
        after.where((r) => r.googleName == stays).single.reviewId,
        staysItem.reviewId,
      );
    });

    test('Leave as they are just takes the item away', () async {
      h.google.seed(person('Ann', 'Lee', email: 'a@example.com', company: 'A'));
      h.graph.seed(outlook('Ann', 'Lee', email: 'a@example.com', company: 'B'));
      await h.firstSync();
      final look = (await h.status()).needsALook.single;
      h.requests.clear();
      await h.sync.answerLook(look.id, ContactSyncChoice.leaveAsTheyAre);
      expect((await h.status()).needsALook, isEmpty);
      expect(h.requests, isEmpty);
    });
  });

  group('Outlook entries read short', () {
    test('an entry with a missing property is read by id, counted, and '
        'never read as cleared', () async {
      final pairs = seedPairs(h, 1, mobiles: true);
      await h.firstSync();
      h.graph.leaveOutEmpty = true;
      h.graph.editFromOutlook(pairs[0].graph, {'companyName': 'Acme'});
      h.requests.clear();
      var status = await h.later();
      expect(status.halt, isNull);
      expect(status.last!.passedOver, 1);
      expect(
        h.requests.where(
          (r) => r.method == 'GET' &&
              r.url.path.endsWith('/me/contacts/${pairs[0].graph}'),
        ),
        isNotEmpty,
      );
      // Nothing it left out was cleared in Gmail.
      final gmail = h.google.person(pairs[0].google)!;
      expect(gmail['names'], isNotNull);
      expect(gmail['emailAddresses'], isNotNull);
      expect(mobileOf(gmail), isNotNull);
      expect(h.writesTo('people.googleapis.com'), isEmpty);

      // Read whole again later, its change goes through.
      h.graph.leaveOutEmpty = false;
      status = await h.later();
      expect(status.last!.passedOver, 0);
      expect(companyOf(h.google.person(pairs[0].google)), 'Acme');
    });
  });

  group('deletions', () {
    test('a contact deleted in Gmail is deleted in Outlook, read in full '
        'into Recently deleted first', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.graph.editFromOutlook(pairs[0].graph, {'profession': 'Pilot'});
      await h.later();
      h.google.deleteFromGmail(pairs[0].google);
      final status = await h.later();
      expect(h.graph.contact(pairs[0].graph), isNull);
      final entry = status.recentlyDeleted.single;
      expect(entry.side, ContactSide.graph);
      expect(entry.title, 'P0 Fam0');
      // The whole contact, what the sync does not copy included.
      final kept = (await h.store.bin((await h.pair()).pairId)).single;
      expect(kept.raw, contains('Pilot'));
      expect(kept.partnerId, pairs[0].google);
      expect(await h.paired(), hasLength(1));
    });

    test('a contact changed just before its delete is kept, and asked '
        'about', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.deleteFromGmail(pairs[0].google);
      h.before = (r) async {
        // The read in full just before the delete has no select.
        if (r.method == 'GET' &&
            r.url.path.endsWith('/me/contacts/${pairs[0].graph}') &&
            !r.url.queryParameters.containsKey(r'$select')) {
          h.before = null;
          h.graph.editFromOutlook(pairs[0].graph, {'jobTitle': 'Chief'});
        }
      };
      final status = await h.later();
      expect(status.halt, isNull);
      expect(h.graph.contact(pairs[0].graph), isNotNull);
      expect(status.recentlyDeleted, isEmpty);
      final look = status.needsALook.single;
      expect(look.kind, ContactReviewKind.kept);
      expect(look.reason, ContactReviewReason.changedSince);
      expect(look.side, ContactSide.google);
      final row = (await h.links()).firstWhere(
        (l) => l.graphId == pairs[0].graph,
      );
      expect(row.reason, ContactHeldReason.kept);
      expect(row.googleName, isNull);
    });

    test('kept at its delete, the contact is kept as it is now: Delete it '
        'here too then deletes it, and keeps it again after a change',
        () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      final g = pairs[0].google;
      Future<void> Function(http.Request) editOnce(String company) {
        var done = false;
        return (r) async {
          // The read in full just before the delete.
          if (!done &&
              r.method == 'GET' &&
              r.url.path == '/v1/$g' &&
              (r.url.queryParameters['personFields'] ?? '').contains(
                'userDefined',
              )) {
            done = true;
            h.google.editFromGmail(g, {
              'organizations': [
                {'name': company},
              ],
            });
          }
        };
      }

      h.graph.deleteFromOutlook(pairs[0].graph);
      h.before = editOnce('Edited');
      var status = await h.later();
      h.before = null;
      expect(h.google.person(g), isNotNull);
      final row = (await h.links()).firstWhere((l) => l.googleName == g);
      expect(row.reason, ContactHeldReason.kept);
      final now = h.google.person(g)!;
      final source = ((now['metadata']! as Map)['sources']! as List).first
          as Map;
      expect(row.googleEtag, source['etag']);
      expect(row.googleBase, contains('Edited'));

      // Changed again while the answer's run reads it: kept again.
      var look = status.needsALook.single;
      h.before = editOnce('Edited again');
      await h.sync.answerLook(look.id, ContactSyncChoice.deleteHereToo);
      await h.sync.syncNow();
      h.before = null;
      status = await h.status();
      expect(h.google.person(g), isNotNull);
      look = status.needsALook.single;
      expect(look.kind, ContactReviewKind.kept);

      // Nothing changed since: Delete it here too deletes it.
      await h.sync.answerLook(look.id, ContactSyncChoice.deleteHereToo);
      await h.sync.syncNow();
      expect(h.google.person(g), isNull);
      expect((await h.status()).needsALook, isEmpty);
    });

    test('a delete with no version known is kept, unless Ron asked for it',
        () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      final row = (await h.links()).firstWhere(
        (l) => l.graphId == pairs[0].graph,
      );
      await h.store.saveLink(row.copyWith(graphChangeKey: null));
      h.google.deleteFromGmail(pairs[0].google);
      final status = await h.later();
      expect(h.graph.contact(pairs[0].graph), isNotNull);
      expect(status.needsALook.single.kind, ContactReviewKind.kept);
    });

    test('a contact moved out of Contacts just before its delete is kept',
        () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      final folder = h.graph.addFolder();
      h.google.deleteFromGmail(pairs[0].google);
      h.before = (r) async {
        if (r.method == 'GET' &&
            r.url.path.endsWith('/me/contacts/${pairs[0].graph}') &&
            !r.url.queryParameters.containsKey(r'$select')) {
          h.before = null;
          h.graph.moveFromOutlook(pairs[0].graph, folder, keepChangeKey: true);
        }
      };
      final status = await h.later();
      expect(status.halt, isNull);
      expect(h.graph.contact(pairs[0].graph), isNotNull);
      expect(status.recentlyDeleted, isEmpty);
      expect(status.needsALook.single.kind, ContactReviewKind.kept);
    });

    test('an Outlook contact moved to another folder is held, not deleted, '
        'and pairs again when it comes back', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      final folder = h.graph.addFolder();
      h.graph.moveFromOutlook(pairs[0].graph, folder);
      var status = await h.later();
      expect(status.halt, isNull);
      expect(h.google.person(pairs[0].google), isNotNull);
      final row = (await h.links()).firstWhere(
        (l) => l.graphId == pairs[0].graph,
      );
      expect(row.reason, ContactHeldReason.movedOut);

      h.graph.moveFromOutlook(pairs[0].graph, FakeGraphContacts.mainFolderId);
      h.graph.editFromOutlook(pairs[0].graph, {'companyName': 'Back Inc'});
      status = await h.later();
      expect(status.halt, isNull);
      expect(await h.paired(), hasLength(2));
      expect(companyOf(h.google.person(pairs[0].google)), 'Back Inc');
      expect(h.google.count, 2);
      expect(h.graph.count, 2);
    });

    test('an Outlook contact deleted by Outlook (Deleted Items) is a '
        'deletion', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.graph.deleteFromOutlook(pairs[1].graph);
      final status = await h.later();
      expect(h.google.person(pairs[1].google), isNull);
      expect(status.last!.deletedGoogle, 1);
    });
  });

  group('Recently deleted', () {
    test('Restore brings the contact back on both sides, an anniversary '
        'and a custom field with it', () async {
      final ann = h.google.seed({
        ...person('Ann', 'Lee', email: 'ann@example.com'),
        'events': [
          {
            'type': 'anniversary',
            'date': {'year': 2010, 'month': 6, 'day': 1},
          },
        ],
        'userDefined': [
          {'key': 'Shoe size', 'value': '38'},
        ],
        'memberships': [
          for (final label in ['friends', 'gone'])
            {
              'contactGroupMembership': {
                'contactGroupResourceName': 'contactGroups/$label',
              },
            },
        ],
      });
      final annH = h.graph.seed(outlook('Ann', 'Lee', email: 'ann@example.com'));
      h.google.labels['contactGroups/friends'] = 'Friends';
      await h.firstSync();
      h.graph.deleteFromOutlook(annH);
      var status = await h.later();
      expect(h.google.person(ann), isNull);
      final deleted = status.recentlyDeleted.single;
      expect(deleted.side, ContactSide.google);
      expect(deleted.title, 'Ann Lee');
      expect(deleted.state, ContactSyncDeletedState.deleted);

      await h.sync.restore(deleted.id);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(status.recentlyDeleted, isEmpty);
      final back = h.google.nameWithEmail('ann@example.com')!;
      final again = h.google.person(back)!;
      expect(again['events'], isNotNull);
      expect(again['userDefined'], isNotNull);
      // Back in the labels that still exist, and in My Contacts.
      final labels = {
        for (final m in again['memberships']! as List)
          ((m as Map)['contactGroupMembership'] as Map)['contactGroupResourceName'],
      };
      expect(labels, contains('contactGroups/friends'));
      expect(labels, contains('contactGroups/myContacts'));
      expect(labels, isNot(contains('contactGroups/gone')));
      expect(h.graph.idWithEmail('ann@example.com'), isNotNull);
      expect(await h.paired(), hasLength(1));
      expect(h.google.count, 1);
      expect(h.graph.count, 1);
      // A later run leaves them as they are.
      h.requests.clear();
      await h.later();
      expect(h.contactWritesOf(), isEmpty);
    });

    test('a Restore a server refuses is taken back, says why, and stops '
        'nothing else', () async {
      h = Harness(lagWrites: true);
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.publish();
      h.graph.deleteFromOutlook(pairs[0].graph);
      var status = await h.later();
      h.google.publish();
      final deleted = status.recentlyDeleted.single;
      expect(deleted.side, ContactSide.google);

      // Outlook will not take the partner made again.
      h.graph.refuse = (c) => '${c['givenName']}' == 'P0';
      h.graph.editFromOutlook(pairs[1].graph, {'companyName': 'Still on'});
      await h.sync.restore(deleted.id);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      final entry = status.recentlyDeleted.single;
      expect(entry.restoreAsked, isFalse);
      expect(
        entry.restoreProblem,
        'Could not restore. Microsoft would not take the contact '
        '(HTTP 400, ErrorInvalidProperty).',
      );
      // The rest of the run went on.
      expect(companyOf(h.google.person(pairs[1].google)), 'Still on');
      expect(h.google.nameWithEmail('p0@example.com'), isNull);

      // Later runs do not try again by themselves.
      h.requests.clear();
      status = await h.later(after: const Duration(minutes: 10));
      expect(status.halt, isNull);
      expect(h.contactWritesOf(), isEmpty);

      // Pressed again, once Outlook takes it: both back, paired, once.
      h.graph.refuse = null;
      await h.sync.restore(entry.id);
      expect(
        (await h.status()).recentlyDeleted.single.restoreProblem,
        isNull,
      );
      await h.sync.syncNow();
      h.google.publish();
      status = await h.later(after: const Duration(minutes: 10));
      expect(status.recentlyDeleted, isEmpty);
      expect(h.graph.count, 2);
      expect(h.google.count, 2);
      expect(await h.paired(), hasLength(2));
    });

    test("a Restore's create whose answer was lost is found by its tag, "
        'and not made again while Google lags', () async {
      h = Harness(lagWrites: true);
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.publish();
      h.graph.deleteFromOutlook(pairs[0].graph);
      var status = await h.later();
      h.google.publish();
      h.after = (r) {
        if (r.url.path.endsWith(':createContact')) {
          throw http.ClientException('connection lost');
        }
      };
      await h.sync.restore(status.recentlyDeleted.single.id);
      await h.sync.syncNow();
      expect((await h.status()).halt!.kind, ContactSyncHaltKind.failed);
      expect(h.google.count, 2);
      h.after = null;

      // Ten minutes on, Google has not listed the contact made yet.
      status = await h.later(after: const Duration(minutes: 10));
      expect(status.halt, isNull);
      expect(h.google.count, 2);
      expect(h.requestsTo(':createContact'), hasLength(1));

      // Once listed, it is taken as made, and paired with its partner.
      h.google.publish();
      status = await h.later(after: const Duration(minutes: 10));
      expect(status.halt, isNull);
      expect(status.recentlyDeleted, isEmpty);
      expect(h.google.count, 2);
      expect(h.graph.count, 2);
      expect(await h.paired(), hasLength(2));
      expect(h.requestsTo(':createContact'), hasLength(1));
    });

    test('a Restore stopped between its two creates makes only the one '
        'left', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.deleteFromGmail(pairs[0].google);
      var status = await h.later();
      expect(h.graph.contact(pairs[0].graph), isNull);
      h.before = (r) async {
        if (r.method == 'POST' && r.url.path.endsWith('/me/contacts')) {
          unawaited(h.sync.stop());
        }
      };
      await h.sync.restore(status.recentlyDeleted.single.id);
      await h.sync.syncNow();
      expect((await h.status()).halt!.kind, ContactSyncHaltKind.putAway);
      expect(h.graph.count, 2);
      expect(h.google.count, 1);
      h.before = null;
      status = await h.later(after: const Duration(minutes: 1));
      expect(status.halt, isNull);
      expect(status.recentlyDeleted, isEmpty);
      expect(h.graph.count, 2);
      expect(h.google.count, 2);
      expect(await h.paired(), hasLength(2));
    });

    test('a Restore stopped after its Outlook create, then refused on the '
        'Gmail one: the Outlook contact is placed, and Restore again makes '
        'nothing twice', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.deleteFromGmail(pairs[0].google);
      var status = await h.later();
      expect(h.graph.contact(pairs[0].graph), isNull);
      final binId = status.recentlyDeleted.single.id;
      h.before = (r) async {
        if (r.method == 'POST' && r.url.path.endsWith('/me/contacts')) {
          unawaited(h.sync.stop());
        }
      };
      await h.sync.restore(binId);
      await h.sync.syncNow();
      h.before = null;
      final made = h.graph.idWithEmail('p0@example.com')!;

      // Google will not take the Gmail side made again.
      h.google.refuse = (p) => '${p['names']}'.contains('P0');
      status = await h.later(after: const Duration(minutes: 1));
      expect(status.recentlyDeleted.single.restoreProblem, isNotNull);
      // The Outlook contact it made has a row, so it is read again.
      final row = (await h.links()).firstWhere((l) => l.graphId == made);
      expect(row.state, ContactLinkState.held);

      // Once Google takes it, it is placed: copied to Gmail and paired.
      h.google.refuse = null;
      status = await h.later();
      status = await h.later();
      expect(h.google.nameWithEmail('p0@example.com'), isNotNull);
      expect(
        (await h.links()).firstWhere((l) => l.graphId == made).isPaired,
        isTrue,
      );

      // Restore pressed again finds both back.
      await h.sync.restore(binId);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(status.recentlyDeleted, isEmpty);
      expect(h.graph.count, 2);
      expect(h.google.count, 2);
    });

    test('a Restore whose bin row goes while it waits leaves what it made '
        'placed, nothing doubled', () async {
      h = Harness(lagWrites: true);
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.publish();
      h.google.deleteFromGmail(pairs[0].google);
      h.google.publish();
      var status = await h.later();
      expect(h.graph.contact(pairs[0].graph), isNull);

      // Restore: Outlook's contact is made; the answer to Gmail's is lost.
      h.after = (r) {
        if (r.url.path.endsWith(':createContact')) {
          throw http.ClientException('connection lost');
        }
      };
      await h.sync.restore(status.recentlyDeleted.single.id);
      await h.sync.syncNow();
      h.after = null;
      final made = h.graph.idWithEmail('p0@example.com')!;

      // The Gmail copy not listed yet: the Restore waits, and this run,
      // which completes, moves the Outlook feed past the contact made.
      status = await h.later(after: const Duration(minutes: 10));
      expect(status.halt, isNull);
      expect(status.recentlyDeleted.single.restoreAsked, isTrue);

      // Not opened for a month: the bin row is pruned, the Restore with it.
      h.google.publish();
      status = await h.later(after: const Duration(days: 31));
      expect(status.halt, isNull);
      expect(status.recentlyDeleted, isEmpty);
      status = await h.later();
      // The contact the Restore made was read and placed: paired with the
      // Gmail copy, not copied a second time.
      expect(h.graph.count, 2);
      expect(h.google.count, 2);
      expect(
        (await h.links()).firstWhere((l) => l.graphId == made).isPaired,
        isTrue,
      );
      expect(status.needsALook, isEmpty);
    });

    test('a restored pair whose two sides differ is listed, as a new pair '
        'is', () async {
      final ann = h.google.seed(
        person('Ann', 'Lee', email: 'ann@example.com', company: 'Acme'),
      );
      final annH = h.graph.seed(
        outlook('Ann', 'Lee', email: 'ann@example.com', company: 'Acme Corp'),
      );
      await h.firstSync();
      var status = await h.status();
      await h.sync.answerLook(
        status.needsALook.single.id,
        ContactSyncChoice.leaveAsTheyAre,
      );
      h.graph.deleteFromOutlook(annH);
      status = await h.later();
      expect(h.google.person(ann), isNull);
      await h.sync.restore(status.recentlyDeleted.single.id);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.recentlyDeleted, isEmpty);
      expect(await h.paired(), hasLength(1));
      final look = status.needsALook.single;
      expect(look.kind, ContactReviewKind.differing);
      expect(look.fields, [ContactField.company]);
    });

    test('a contact Ron made again and the sync copied is Already back: '
        'Restore makes nothing', () async {
      final pairs = seedPairs(h, 1);
      await h.firstSync();
      h.google.deleteFromGmail(pairs[0].google);
      var status = await h.later();
      expect(h.graph.count, 0);
      h.google.addFromGmail(person('P0', 'Fam0', email: 'p0@example.com'));
      status = await h.later();
      expect(h.graph.count, 1);
      await h.sync.restore(status.recentlyDeleted.single.id);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.recentlyDeleted, isEmpty);
      expect(h.graph.count, 1);
      expect(h.google.count, 1);
    });
  });

  group('the backup', () {
    test('both address books, whole, as a vCard and an Outlook CSV',
        () async {
      h.google.seed({
        ...person('Ann', 'Lee', email: 'ann@example.com'),
        'memberships': [
          {
            'contactGroupMembership': {
              'contactGroupResourceName': 'contactGroups/friends',
            },
          },
        ],
      });
      h.google.labels['contactGroups/friends'] = 'Friends';
      h.graph.seed({
        ...outlook('Cy', 'Day', email: 'cy@example.com'),
        'profession': 'Pilot',
      });
      await h.choose();
      final files = await h.sync.backup();
      expect(files, hasLength(2));
      final vcf = files.firstWhere((f) => f.side == ContactSide.google);
      final csv = files.firstWhere((f) => f.side == ContactSide.graph);
      expect(vcf.mimeType, 'text/x-vcard');
      expect(vcf.fileName, endsWith('.vcf'));
      expect(vcf.count, 1);
      expect(vcf.contents, contains('BEGIN:VCARD'));
      expect(vcf.contents, contains('CATEGORIES:Friends'));
      expect(csv.mimeType, 'text/csv');
      expect(csv.fileName, endsWith('.csv'));
      expect(csv.count, 1);
      expect(csv.contents, contains('Pilot'));
      // Nothing changed, and nothing kept.
      expect(h.contactWritesOf(), isEmpty);
      expect((await h.status()).firstStarted, isFalse);
    });

    test('needs the accounts chosen first', () async {
      expect(h.sync.backup, throwsA(isA<ContactSyncRefused>()));
      expect(h.sync.preview, throwsA(isA<ContactSyncRefused>()));
    });
  });

  group('one device', () {
    test("another device's claim stops a run until Sync here", () async {
      seedPairs(h, 2);
      await h.firstSync();
      expect(h.graph.claim, startsWith('phone '));

      final tablet = h.make(device: 'tablet', on: MemoryContactSyncStore());
      await h.choose(tablet);
      h.requests.clear();
      await tablet.start();
      var status = await tablet.status();
      expect(status.halt!.kind, ContactSyncHaltKind.otherDevice);
      expect(status.halt!.claimedAt, isNotNull);
      expect(h.contactWritesOf(), isEmpty);

      await tablet.syncHere();
      await tablet.syncNow();
      status = await tablet.status();
      expect(status.halt, isNull);
      expect(h.graph.claim, startsWith('tablet '));
      expect(h.graph.count, 2);
      expect(h.google.count, 2);

      await h.later();
      expect((await h.status()).halt!.kind, ContactSyncHaltKind.otherDevice);

      // A week later the claim has lapsed.
      await h.later(after: const Duration(days: 8));
      expect((await h.status()).halt, isNull);
    });
  });

  group('the claim', () {
    test('Sync here takes the claim at once, and holds until a run of its '
        'completes', () async {
      seedPairs(h, 1);
      await h.firstSync();
      for (var i = 0; i < 3; i++) {
        h.graph.seed(outlook('O$i', 'New', email: 'o$i@example.com'));
      }
      final tablet = h.make(device: 'tablet', on: MemoryContactSyncStore());
      await h.choose(tablet);
      await tablet.start();
      expect(
        (await tablet.status()).halt!.kind,
        ContactSyncHaltKind.otherDevice,
      );

      // Sync here, and the tablet is put away after its first create.
      h.before = (r) async {
        if (r.url.path.endsWith(':createContact')) unawaited(tablet.stop());
      };
      await tablet.syncHere();
      await tablet.syncNow();
      h.before = null;
      expect((await tablet.status()).halt!.kind, ContactSyncHaltKind.putAway);
      expect(h.graph.claim, startsWith('tablet '));

      // The phone sees the tablet's claim and stops.
      final made = h.google.count;
      await h.later();
      expect((await h.status()).halt!.kind, ContactSyncHaltKind.otherDevice);
      expect(h.google.count, made);

      // The tablet carries on, still taking over, and completes.
      h.pass(const Duration(minutes: 1));
      await tablet.syncNow();
      expect((await tablet.status()).halt, isNull);
      expect(h.google.count, 4);
      expect(h.graph.count, 4);
    });

    test('Sync here still holds when the folder will not take the claim',
        () async {
      seedPairs(h, 1);
      await h.firstSync();
      for (var i = 0; i < 2; i++) {
        h.graph.seed(outlook('O$i', 'New', email: 'o$i@example.com'));
      }
      h.graph.claimRefused = true;
      final tablet = h.make(device: 'tablet', on: MemoryContactSyncStore());
      await h.choose(tablet);
      await tablet.start();
      expect(
        (await tablet.status()).halt!.kind,
        ContactSyncHaltKind.otherDevice,
      );
      h.before = (r) async {
        if (r.url.path.endsWith(':createContact')) unawaited(tablet.stop());
      };
      await tablet.syncHere();
      await tablet.syncNow();
      h.before = null;
      expect((await tablet.status()).halt!.kind, ContactSyncHaltKind.putAway);
      h.pass(const Duration(minutes: 1));
      await tablet.syncNow();
      expect((await tablet.status()).halt, isNull);
      expect(h.google.count, 3);
    });

    for (final status in [400, 404]) {
      test('a folder that will not give its claim (HTTP $status) does not '
          'stop the run', () async {
        seedPairs(h, 1);
        h.google.addFromGmail(person('New', 'One', email: 'n@example.com'));
        h.answer = (r) =>
            r.method == 'GET' &&
                r.url.path.endsWith(FakeGraphContacts.mainFolderId)
            ? http.Response(
                '{"error":{"code":"ErrorInvalidRequest","message":"x"}}',
                status,
                headers: {'content-type': 'application/json'},
              )
            : null;
        await h.firstSync();
        final s = await h.status();
        expect(s.halt, isNull);
        expect(h.graph.count, 2);
      });
    }

    test('a lost connection on the claim read still stops the run',
        () async {
      seedPairs(h, 1);
      h.before = (r) async {
        if (r.method == 'GET' &&
                r.url.path.endsWith(FakeGraphContacts.mainFolderId)) {
          throw http.ClientException('connection lost');
        }
      };
      await h.firstSync();
      expect((await h.status()).halt!.kind, ContactSyncHaltKind.failed);
    });
  });

  group('the switch and the accounts', () {
    test('off and on: a contact deleted meanwhile is deleted at the next '
        'run', () async {
      final pairs = seedPairs(h, 3);
      await h.firstSync();
      // Off: no runs for days.
      h.google.deleteFromGmail(pairs[0].google);
      h.google.deleteFromGmail(pairs[1].google);
      final status = await h.later(after: const Duration(days: 3));
      expect(status.halt, isNull);
      expect(h.graph.count, 1);
      expect(status.last!.deletedGraph, 2);
    });

    test('an account removed detaches the pair, and added again carries '
        'on with nothing doubled', () async {
      seedPairs(h, 2);
      h.google.seed(person('Only', 'Gmail', email: 'og@example.com'));
      await h.firstSync();
      expect(h.graph.count, 3);

      await h.sync.accountRemoved(Harness.hadco.id);
      h.accounts = [Harness.gmail];
      var status = await h.status();
      expect(status.chosen, isFalse);
      expect(await h.sync.startIfDue(), isFalse);

      const again = Account(
        id: 'acct-hadco-2',
        displayName: 'Hadco',
        emailAddress: 'Ron@Hadco.com',
        provider: MailProvider.outlook,
        authMethod: AuthMethod.oauth,
        colorValue: 1,
      );
      h.accounts = [Harness.gmail, again];
      await h.sync.accountAdded(again);
      status = await h.status();
      expect(status.graphAccountId, again.id);
      expect(status.firstDone, isTrue);

      status = await h.later(after: const Duration(days: 2));
      expect(status.halt, isNull);
      expect(h.graph.count, 3);
      expect(h.google.count, 3);
      expect(await h.paired(), hasLength(3));
    });

    test('an account removed while a run goes stops it first', () async {
      seedPairs(h, 1);
      for (var i = 0; i < 3; i++) {
        h.graph.seed(outlook('O$i', 'Only', email: 'o$i@example.com'));
      }
      await h.choose();
      final gate = Completer<void>();
      h.before = (r) async {
        if (r.url.path.endsWith(':createContact')) await gate.future;
      };
      final run = h.sync.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.sync.isRunning, isTrue);
      final removed = h.sync.accountRemoved(Harness.hadco.id);
      gate.complete();
      await removed;
      await run;
      expect(h.sync.isRunning, isFalse);
      final pair = (await h.store.pairs()).single;
      expect(pair.isDetached, isTrue);
      // The create in hand finished; nothing after it was sent.
      expect(h.google.count, 2);
      expect(h.requestsTo(':createContact'), hasLength(1));
      expect(pair.lastResult, contains('putAway'));
    });

    test('a re-attached pair does not take an account already in another',
        () async {
      await h.choose();
      await h.sync.accountRemoved(Harness.hadco.id);
      const home = Account(
        id: 'acct-home',
        displayName: 'Home',
        emailAddress: 'ron@home.example',
        provider: MailProvider.outlook,
        authMethod: AuthMethod.oauth,
        colorValue: 2,
      );
      h.accounts = [Harness.gmail, home];
      await h.sync.choose(
        googleAccountId: Harness.gmail.id,
        graphAccountId: home.id,
      );
      const back = Account(
        id: 'acct-hadco-2',
        displayName: 'Hadco',
        emailAddress: 'ron@hadco.com',
        provider: MailProvider.outlook,
        authMethod: AuthMethod.oauth,
        colorValue: 1,
      );
      h.accounts = [Harness.gmail, home, back];
      await h.sync.accountAdded(back);
      final attached = [
        for (final p in await h.store.pairs())
          if (!p.isDetached) p,
      ];
      expect(attached.single.graphAccountId, home.id);
    });

    test('choosing the same two accounts again changes nothing, even '
        'while a run goes', () async {
      seedPairs(h, 1);
      await h.firstSync();
      final before = await h.pair();
      final events = <void>[];
      final listening = h.sync.changed.listen(events.add);
      addTearDown(listening.cancel);
      final gate = Completer<void>();
      h.before = (r) async => gate.future;
      h.pass(const Duration(hours: 2));
      final run = h.sync.syncNow();
      await Future<void>.delayed(Duration.zero);
      events.clear();
      await h.choose();
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      gate.complete();
      h.before = null;
      await run;
      final after = await h.pair();
      expect(after.pairId, before.pairId);
      expect(after.firstStartedAt, before.firstStartedAt);
      expect(await h.store.pairs(), hasLength(1));
    });

    test('status reads only what this device keeps, and a stop is '
        'announced on changed', () async {
      seedPairs(h, 1);
      h.refusing.add(Harness.hadco.id);
      final events = <void>[];
      final listening = h.sync.changed.listen(events.add);
      addTearDown(listening.cancel);
      await h.firstSync();
      await Future<void>.delayed(Duration.zero);
      final status = await h.status();
      expect(status.notice, isNotNull);
      expect(events, isNotEmpty);
      h.requests.clear();
      await h.status();
      await h.status();
      expect(h.requests, isEmpty);
    });

    test('choosing refuses an account that cannot sync', () async {
      h.accounts = [
        Harness.gmail.copyWithAuth(AuthMethod.appPassword),
        Harness.hadco,
      ];
      expect(h.choose, throwsA(isA<ContactSyncRefused>()));
      expect(
        (await h.sync.access(Harness.gmail.id)).state,
        ContactSyncAccessState.notPossible,
      );
    });
  });

  group('the engine', () {
    late FakeImapTransport server;
    late MemoryAccountStore accounts;
    late CachedImapEngine engine;
    late MemoryContactSyncStore store;

    setUp(() {
      server = FakeImapTransport()..folder('INBOX', role: FolderRole.inbox);
      accounts = MemoryAccountStore();
      store = MemoryContactSyncStore();
      engine = CachedImapEngine(
        accountStore: accounts,
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        contactSyncStore: store,
        transportFactory: (_, _) => server,
      );
    });

    Future<Account> add(String address, MailProvider provider) =>
        engine.addAccount(
          displayName: address,
          emailAddress: address,
          provider: provider,
          secret: 'abcdabcdabcdabcd',
        );

    test("signing in again lifts the pause a refused run left", () async {
      final secrets = MemoryCredentialStore();
      final token = OAuthToken(
        accessToken: 'old',
        refreshToken: 'refresh',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ).toStoredJson();
      await secrets.writeSecret(Harness.gmail.id, token);
      await secrets.writeSecret(Harness.hadco.id, token);
      final refresher = _Refresher()
        ..refuse = const SignInNeedsConsent('Contacts not allowed.');
      final h = Harness();
      seedPairs(h, 1);
      final engine = CachedImapEngine(
        accountStore: MemoryAccountStore([Harness.gmail, Harness.hadco]),
        credentialStore: secrets,
        cache: MemoryCacheStore(),
        contactSyncStore: store,
        oauthTokens: OAuthTokenRepository(
          credentialStore: secrets,
          oauthClient: (_) => refresher,
        ),
        contactSyncHttpClient: MockClient(
          (r) => r.url.host == 'people.googleapis.com'
              ? h.google.handle(r)
              : h.graph.handle(r),
        ),
        transportFactory: (_, _) => server,
      );
      final sync = engine.contactSync;
      await sync.choose(
        googleAccountId: Harness.gmail.id,
        graphAccountId: Harness.hadco.id,
      );
      await sync.start();
      expect((await sync.status()).halt!.kind, ContactSyncHaltKind.notAllowed);
      expect(await sync.startIfDue(), isFalse);

      // Ron signs in again, allowing contacts.
      refresher.refuse = null;
      await engine.updateOAuthToken(
        accountId: Harness.gmail.id,
        token: OAuthToken(
          accessToken: 'new',
          refreshToken: 'refresh-2',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );
      expect(await sync.startIfDue(), isTrue);
      await sync.syncNow();
      expect((await sync.status()).halt, isNull);
    });

    test('removing an account detaches its pair, and adding the address '
        'again attaches it under the new account', () async {
      final gmail = await add('ron@gmail.com', MailProvider.gmail);
      final hadco = await add('ron@hadco.com', MailProvider.outlook);
      final pair = await store.ensurePair(
        googleAccountId: gmail.id,
        googleAddress: gmail.emailAddress,
        graphAccountId: hadco.id,
        graphAddress: hadco.emailAddress,
      );
      expect(engine.contactSync, isA<ContactSync>());

      await engine.removeAccount(hadco.id);
      expect((await store.pair(pair.pairId))!.isDetached, isTrue);
      expect((await engine.contactSync.status()).chosen, isFalse);

      final again = await add('Ron@Hadco.com', MailProvider.outlook);
      final back = (await store.pair(pair.pairId))!;
      expect(back.isDetached, isFalse);
      expect(back.graphAccountId, again.id);
      expect((await engine.contactSync.status()).graphAccountId, again.id);
    });
  });

  group('in the database', () {
    late MailDatabase db;

    setUp(() {
      db = MailDatabase(NativeDatabase.memory());
      h = Harness(
        store: (clock) => DriftContactSyncStore(db, clock: clock),
      );
    });

    tearDown(() => db.close());

    test('a first sync, a change, a held deletion answered, a refusal '
        'and a Restore keep to the store', () async {
      final pairs = seedPairs(h, 7, mobiles: true);
      h.graph.seed(outlook('Bad', 'Apple', email: 'bad@example.com'));
      h.google.refuse = (p) => '${p['names']}'.contains('Bad');
      await h.firstSync();
      var status = await h.status();
      expect(status.halt, isNull);
      expect(status.needsALook.single.kind, ContactReviewKind.refused);

      h.google.editFromGmail(pairs[6].google, {
        'organizations': [
          {'name': 'Kept going'},
        ],
      });
      for (var i = 0; i < 6; i++) {
        h.google.deleteFromGmail(pairs[i].google);
      }
      status = await h.later();
      expect(status.halt, isNull);
      expect(companyOf(h.graph.contact(pairs[6].graph)), 'Kept going');
      expect(status.questions.single.items, hasLength(6));

      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.deleteThem,
      );
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(status.recentlyDeleted, hasLength(6));
      expect(h.graph.count, 2);

      await h.sync.restore(status.recentlyDeleted.first.id);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(status.recentlyDeleted, hasLength(5));
      // A deletion the brake held kept its gone partner: Restore makes
      // both sides again and pairs them, in the one run.
      expect(h.google.count, 2);
      expect(await h.paired(), hasLength(2));
      h.requests.clear();
      status = await h.later();
      expect(status.halt, isNull);
      expect(h.contactWritesOf(), isEmpty);
    });
  });

  group('promises to the screen', () {
    test('startIfDue keeps every rule', () async {
      final pairs = seedPairs(h, 2);
      await h.choose();
      // Not started: never.
      expect(await h.sync.startIfDue(), isFalse);

      // A first sync put away part way is always due, at once.
      h.graph.seed(outlook('O1', 'New', email: 'o1@example.com'));
      h.graph.seed(outlook('O2', 'New', email: 'o2@example.com'));
      h.before = (r) async {
        if (r.url.path.endsWith(':createContact')) unawaited(h.sync.stop());
      };
      await h.sync.start();
      h.before = null;
      expect((await h.status()).halt!.kind, ContactSyncHaltKind.putAway);
      expect(await h.sync.startIfDue(), isTrue);
      // ...and not while one goes.
      expect(await h.sync.startIfDue(), isFalse);
      await h.sync.syncNow();
      expect((await h.status()).firstDone, isTrue);

      // Done: not again within the hour, then due.
      h.pass(const Duration(minutes: 59));
      expect(await h.sync.startIfDue(), isFalse);
      h.pass(const Duration(minutes: 2));
      expect(await h.sync.startIfDue(), isTrue);
      await h.sync.syncNow();

      // A failed run: not within five minutes, whatever the hour says.
      h.pass(const Duration(hours: 2));
      h.graph.consentMissing = true;
      await h.sync.syncNow();
      h.graph.consentMissing = false;
      h.pass(const Duration(minutes: 4));
      expect(await h.sync.startIfDue(), isFalse);
      h.pass(const Duration(minutes: 2));
      expect(await h.sync.startIfDue(), isTrue);
      await h.sync.syncNow();

      // A put-away is no failure: no pause after it.
      h.pass(const Duration(hours: 2));
      for (final p in pairs) {
        h.google.editFromGmail(p.google, {
          'organizations': [
            {'name': 'X'},
          ],
        });
      }
      h.before = (r) async {
        if (r.method == 'PATCH') unawaited(h.sync.stop());
      };
      await h.sync.syncNow();
      h.before = null;
      expect((await h.status()).halt!.kind, ContactSyncHaltKind.putAway);
      expect(await h.sync.startIfDue(), isTrue);
      await h.sync.syncNow();

      // Google's daily quota: not until it is renewed.
      h.pass(const Duration(hours: 2));
      h.google.throttle(1, daily: true);
      await h.sync.syncNow();
      final until = (await h.status()).halt!.until!;
      h.pass(const Duration(hours: 1));
      expect(await h.sync.startIfDue(), isFalse);
      h.now = until.add(const Duration(minutes: 1));
      expect(await h.sync.startIfDue(), isTrue);
      await h.sync.syncNow();
    });

    test('Start sets the first sync started before anything can stop it, '
        'and a second Start joins the first', () async {
      seedPairs(h, 1);
      h.refusing.add(Harness.hadco.id);
      await h.choose();
      await h.sync.start();
      var status = await h.status();
      expect(status.halt!.kind, ContactSyncHaltKind.notAllowed);
      expect(status.firstStarted, isTrue);

      h.refusing.clear();
      h.pass(const Duration(minutes: 6));
      final listings = h.google.fullListings;
      await Future.wait([h.sync.start(), h.sync.start()]);
      status = await h.status();
      expect(status.halt, isNull);
      expect(h.google.fullListings, listings + 1);
    });

    test('Sync now, Sync here and answers never start a first sync',
        () async {
      seedPairs(h, 1);
      await h.choose();
      await h.sync.syncNow();
      await h.sync.syncHere();
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.deleteThem,
      );
      await h.sync.syncNow();
      expect(h.requests, isEmpty);
      expect((await h.status()).firstStarted, isFalse);
      // Nor does a Sync here pressed before Start take the claim over once
      // Start is pressed.
      final tablet = h.make(device: 'tablet', on: MemoryContactSyncStore());
      await h.firstSync();
      await h.choose(tablet);
      await tablet.syncHere();
      await tablet.start();
      expect(
        (await tablet.status()).halt!.kind,
        ContactSyncHaltKind.otherDevice,
      );
    });

    test('answerAllDiffering leaves an item already answered as it was',
        () async {
      final a = h.google.seed(
        person('Ann', 'Lee', email: 'a@example.com', company: 'GA'),
      );
      final aH = h.graph.seed(
        outlook('Ann', 'Lee', email: 'a@example.com', company: 'HA'),
      );
      final b = h.google.seed(
        person('Bob', 'Ray', email: 'b@example.com', company: 'GB'),
      );
      final bH = h.graph.seed(
        outlook('Bob', 'Ray', email: 'b@example.com', company: 'HB'),
      );
      await h.firstSync();
      final looks = (await h.status()).needsALook;
      expect(looks, hasLength(2));
      final annLook = looks.firstWhere((l) => l.title == 'Ann Lee');
      await h.sync.answerLook(annLook.id, ContactSyncChoice.useGraph);
      await h.sync.answerAllDiffering(ContactSyncChoice.useGoogle);
      await h.sync.syncNow();
      expect(companyOf(h.google.person(a)), 'HA');
      expect(companyOf(h.graph.contact(aH)), 'HA');
      expect(companyOf(h.graph.contact(bH)), 'GB');
      expect(companyOf(h.google.person(b)), 'GB');
    });

    test('noticeSeen fires changed', () async {
      seedPairs(h, 1);
      h.refusing.add(Harness.hadco.id);
      await h.firstSync();
      final notice = (await h.status()).notice!;
      final events = <void>[];
      final listening = h.sync.changed.listen(events.add);
      addTearDown(listening.cancel);
      await h.sync.noticeSeen(notice.at);
      await Future<void>.delayed(Duration.zero);
      expect(events, isNotEmpty);
    });

    test('the preview and the backup are of the pair chosen last', () async {
      const home = Account(
        id: 'acct-home',
        displayName: 'Home',
        emailAddress: 'ron@home.example',
        provider: MailProvider.outlook,
        authMethod: AuthMethod.oauth,
        colorValue: 2,
      );
      h.accounts = [Harness.gmail, Harness.hadco, home];
      await h.choose();
      await h.sync.choose(
        googleAccountId: Harness.gmail.id,
        graphAccountId: home.id,
      );
      h.tokensFor.clear();
      await h.sync.preview();
      await h.sync.backup();
      expect(h.tokensFor, contains(home.id));
      expect(h.tokensFor, isNot(contains(Harness.hadco.id)));
    });

    test('a pair chosen again within 30 days is taken up intact', () async {
      final pairs = seedPairs(h, 2);
      await h.firstSync();
      h.google.deleteFromGmail(pairs[0].google);
      await h.later();
      final before = await h.pair();
      final rows = (await h.links()).length;
      const home = Account(
        id: 'acct-home',
        displayName: 'Home',
        emailAddress: 'ron@home.example',
        provider: MailProvider.outlook,
        authMethod: AuthMethod.oauth,
        colorValue: 2,
      );
      h.accounts = [Harness.gmail, Harness.hadco, home];
      await h.sync.choose(
        googleAccountId: Harness.gmail.id,
        graphAccountId: home.id,
      );
      expect((await h.status()).graphAccountId, home.id);
      expect((await h.status()).firstStarted, isFalse);
      h.pass(const Duration(days: 29));
      await h.choose();
      final status = await h.status();
      final after = await h.pair();
      expect(after.pairId, before.pairId);
      expect(status.firstDone, isTrue);
      expect(status.recentlyDeleted, hasLength(1));
      expect((await h.links()).length, rows);
    });
  });

  group('copies of one person', () {
    /// A person once in Gmail and [hadco] times in Hadco, alike.
    ({String google, List<String> graph}) person2(
      Harness h,
      String given,
      String family, {
      int gmail = 1,
      int hadco = 2,
      bool mobiles = true,
    }) {
      final email = '${given.toLowerCase()}@example.com';
      final mobile = mobiles
          ? '+1 202 555 01${given.length}${family.length}'
          : null;
      String? first;
      for (var i = 0; i < gmail; i++) {
        final name = h.google.seed(
          person(given, family, email: email, mobile: mobile),
        );
        first ??= name;
      }
      return (
        google: first ?? '',
        graph: [
          for (var i = 0; i < hadco; i++)
            h.graph.seed(outlook(given, family, email: email, mobile: mobile)),
        ],
      );
    }

    int heldCopies(List<ContactLink> rows) => rows
        .where((l) => l.reason == ContactHeldReason.duplicate)
        .length;

    test("the tablet's pattern: twice in Hadco, once in Gmail is one pair "
        'and one held copy, nothing to look at', () async {
      person2(h, 'Ann', 'Cole');
      person2(h, 'Bob', 'Ray', hadco: 1);
      await h.choose();
      final preview = await h.sync.preview();
      expect(preview.duplicateCopies, 1);
      expect(preview.needsALook, 0);
      expect(preview.addToGoogle + preview.addToGraph, 0);
      expect(preview.pairUp, 2);

      await h.sync.start();
      final status = await h.status();
      expect(status.halt, isNull);
      expect(status.needsALook, isEmpty);
      expect(h.google.count, 2);
      expect(h.graph.count, 3);
      expect(await h.paired(), hasLength(2));
      expect(heldCopies(await h.links()), 1);
      final group = status.duplicates.single;
      expect(group.title, 'Ann Cole');
      expect(group.googleCopies, 1);
      expect(group.graphCopies, 2);
      expect(group.googleSynced, isTrue);
      expect(group.graphSynced, isTrue);

      // Ron's edit to the held copy does nothing on the other side.
      final held = (await h.links())
          .firstWhere((l) => l.reason == ContactHeldReason.duplicate)
          .graphId!;
      h.graph.editFromOutlook(held, {'companyName': 'Only here'});
      h.requests.clear();
      await h.later();
      expect(h.contactWritesOf(), isEmpty);
    });

    test('status lists the groups after a restart, with no network',
        () async {
      person2(h, 'Ann', 'Cole', hadco: 3);
      await h.firstSync();
      final restarted = h.make();
      h.requests.clear();
      final status = await restarted.status();
      expect(h.requests, isEmpty);
      final group = status.duplicates.single;
      expect(group.title, 'Ann Cole');
      expect(group.graphCopies, 3);
      expect(group.googleCopies, 1);
      await restarted.close();
    });

    test('a run put away part way lists the groups it held', () async {
      person2(h, 'Ann', 'Cole');
      h.graph.seed(outlook('O1', 'New', email: 'o1@example.com'));
      h.graph.seed(outlook('O2', 'New', email: 'o2@example.com'));
      h.before = (r) async {
        if (r.url.path.endsWith(':createContact')) unawaited(h.sync.stop());
      };
      await h.firstSync();
      final status = await h.status();
      expect(status.halt!.kind, ContactSyncHaltKind.putAway);
      expect(status.duplicates.single.graphCopies, 2);
    });

    test('a stopped run keeps the groups it last listed', () async {
      final pairs = seedPairs(h, 12);
      person2(h, 'Ann', 'Cole');
      await h.firstSync();
      expect((await h.status()).duplicates, hasLength(1));
      for (var i = 0; i < 8; i++) {
        h.graph.purgeFromOutlook(pairs[i].graph);
      }
      h.graph.expireDeltaLinks();
      final status = await h.later();
      expect(status.halt!.kind, ContactSyncHaltKind.emptyAnswer);
      expect(status.duplicates, hasLength(1));
    });

    test('Ron deleting the synced copy in Outlook while a copy is left: '
        'nothing is deleted in Gmail, the pair moves', () async {
      final ann = person2(h, 'Ann', 'Cole');
      await h.firstSync();
      final synced = (await h.links())
          .firstWhere((l) => l.isPaired && l.googleName == ann.google)
          .graphId!;
      final left = ann.graph.firstWhere((id) => id != synced);
      h.graph.deleteFromOutlook(synced);
      final status = await h.later();
      expect(status.halt, isNull);
      expect(h.google.person(ann.google), isNotNull);
      expect(status.recentlyDeleted, isEmpty);
      expect(status.last!.deleted, 0);
      final row = (await h.links()).firstWhere(
        (l) => l.googleName == ann.google,
      );
      expect(row.isPaired, isTrue);
      expect(row.graphId, left);
      expect(heldCopies(await h.links()), 0);
      expect(status.duplicates, isEmpty);
    });

    test('Ron deleting a held copy: its row goes, nothing else', () async {
      final ann = person2(h, 'Ann', 'Cole', hadco: 3);
      await h.firstSync();
      final heldIds = [
        for (final l in await h.links())
          if (l.reason == ContactHeldReason.duplicate) l.graphId!,
      ];
      expect(heldIds, hasLength(2));
      h.graph.deleteFromOutlook(heldIds.first);
      final status = await h.later();
      expect(status.halt, isNull);
      expect(h.google.person(ann.google), isNotNull);
      expect(status.last!.deleted, 0);
      expect(heldCopies(await h.links()), 1);
      expect(status.duplicates.single.graphCopies, 2);
    });

    test('six held copies deleted at once raise no brake', () async {
      for (final given in ['Ann', 'Bea', 'Cal', 'Dee', 'Eve', 'Fay']) {
        person2(h, given, 'Cole', mobiles: false);
      }
      await h.firstSync();
      final heldIds = [
        for (final l in await h.links())
          if (l.reason == ContactHeldReason.duplicate) l.graphId!,
      ];
      expect(heldIds, hasLength(6));
      expect((await h.status()).questions, isEmpty);
      for (final id in heldIds) {
        h.graph.deleteFromOutlook(id);
      }
      final status = await h.later();
      expect(status.halt, isNull);
      expect(status.questions, isEmpty);
      expect(status.notice, isNull);
      expect(h.google.count, 6);
      expect(await h.paired(), hasLength(6));
      expect(heldCopies(await h.links()), 0);
    });

    test('a later copy joining a person is held, not copied', () async {
      final ann = person2(h, 'Ann', 'Cole', hadco: 1);
      await h.firstSync();
      expect((await h.status()).duplicates, isEmpty);
      h.graph.addFromOutlook(
        outlook('Ann', 'Cole', email: 'ann@example.com'),
      );
      final status = await h.later();
      expect(status.halt, isNull);
      expect(status.last!.addedToGoogle, 0);
      expect(h.google.count, 1);
      expect(status.needsALook, isEmpty);
      expect(heldCopies(await h.links()), 1);
      expect(status.duplicates.single.graphCopies, 2);
      expect(h.google.person(ann.google), isNotNull);
    });

    test('Merge & fix in Gmail, the held copy merged into the synced one: '
        'the pair stands', () async {
      final ann = person2(h, 'Ann', 'Cole', gmail: 2, hadco: 1);
      await h.firstSync();
      final rows = await h.links();
      final synced = rows.firstWhere((l) => l.isPaired).googleName!;
      final copy = rows
          .firstWhere((l) => l.reason == ContactHeldReason.duplicate)
          .googleName!;
      final pairedWith = rows.firstWhere((l) => l.isPaired).graphId;
      h.google.mergeInGmail(synced, copy);
      final status = await h.later();
      expect(status.halt, isNull);
      expect(status.needsALook, isEmpty);
      expect(status.last!.deleted, 0);
      final after = await h.links();
      expect(after.where((l) => l.isPaired).single.googleName, synced);
      expect(after.where((l) => l.isPaired).single.graphId, pairedWith);
      expect(heldCopies(after), 0);
      expect(h.graph.count, 1);
      expect(ann.graph, hasLength(1));
      expect(status.duplicates, isEmpty);
    });

    test('Merge & fix in Gmail, the synced copy merged into the held one: '
        'the pair moves to it', () async {
      person2(h, 'Ann', 'Cole', gmail: 2, hadco: 1);
      await h.firstSync();
      final rows = await h.links();
      final synced = rows.firstWhere((l) => l.isPaired).googleName!;
      final copy = rows
          .firstWhere((l) => l.reason == ContactHeldReason.duplicate)
          .googleName!;
      final pairedWith = rows.firstWhere((l) => l.isPaired).graphId;
      h.google.mergeInGmail(copy, synced);
      final status = await h.later();
      expect(status.halt, isNull);
      expect(status.needsALook, isEmpty);
      expect(status.last!.deleted, 0);
      final after = await h.links();
      final pair = after.where((l) => l.isPaired).single;
      expect(pair.googleName, copy);
      expect(pair.graphId, pairedWith);
      expect(heldCopies(after), 0);
      expect(h.graph.count, 1);
      expect(h.google.count, 1);
      expect(status.duplicates, isEmpty);
    });

    test('a first sync put away after the held copy is saved but before the '
        'pair is written: the resumed run pairs once', () async {
      h.google.seed(
        person(
          'Ann',
          'Cole',
          email: 'ann@example.com',
          mobile: '+1 202 555 0144',
          company: 'Acme',
        ),
      );
      for (var i = 0; i < 2; i++) {
        h.graph.seed(
          outlook(
            'Ann',
            'Cole',
            email: 'ann@example.com',
            mobile: '+1 202 555 0144',
          ),
        );
      }
      h.graph.seed(outlook('Ola', 'Only', email: 'ola@example.com'));
      // Creates go first: the stop lands before Ann's pair is written.
      h.before = (r) async {
        if (r.url.path.endsWith(':createContact')) unawaited(h.sync.stop());
      };
      await h.firstSync();
      h.before = null;
      var status = await h.status();
      expect(status.halt!.kind, ContactSyncHaltKind.putAway);
      expect(heldCopies(await h.links()), 1);

      h.pass(const Duration(minutes: 1));
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(status.needsALook, isEmpty);
      expect(await h.paired(), hasLength(2));
      expect(heldCopies(await h.links()), 1);
      expect(h.google.count, 2);
      expect(h.graph.count, 3);
      final group = status.duplicates.single;
      expect(group.googleCopies, 1);
      expect(group.graphCopies, 2);
      h.requests.clear();
      await h.later();
      expect(h.contactWritesOf(), isEmpty);
    });

    test('an incremental run put away likewise: the resumed run pairs once',
        () async {
      seedPairs(h, 1);
      h.graph.seed(outlook('Ola', 'Only', email: 'ola@example.com'));
      await h.firstSync();
      h.google.addFromGmail(
        person(
          'Ann',
          'Cole',
          email: 'ann@example.com',
          mobile: '+1 202 555 0144',
          company: 'Acme',
        ),
      );
      for (var i = 0; i < 2; i++) {
        h.graph.addFromOutlook(
          outlook(
            'Ann',
            'Cole',
            email: 'ann@example.com',
            mobile: '+1 202 555 0144',
          ),
        );
      }
      h.graph.addFromOutlook(outlook('Pia', 'Only', email: 'pia@example.com'));
      h.before = (r) async {
        if (r.url.path.endsWith(':createContact')) unawaited(h.sync.stop());
      };
      var status = await h.later();
      h.before = null;
      expect(status.halt!.kind, ContactSyncHaltKind.putAway);
      status = await h.later(after: const Duration(minutes: 1));
      expect(status.halt, isNull);
      expect(status.needsALook, isEmpty);
      // P0, Ola, Ann and Pia, each paired once; Ann's second Hadco copy held.
      expect(await h.paired(), hasLength(4));
      expect(heldCopies(await h.links()), 1);
      expect(h.google.count, 4);
      expect(h.graph.count, 5);
    });

    for (final which in ['held', 'synced']) {
      test('a Gmail re-key of the $which copy changes nothing but its name',
          () async {
        person2(h, 'Ann', 'Cole', gmail: 2, hadco: 1);
        await h.firstSync();
        final rows = await h.links();
        final target = which == 'held'
            ? rows
                  .firstWhere((l) => l.reason == ContactHeldReason.duplicate)
                  .googleName!
            : rows.firstWhere((l) => l.isPaired).googleName!;
        final now = h.google.rekeyFromGmail(target);
        h.requests.clear();
        var status = await h.later();
        expect(status.halt, isNull);
        expect(status.needsALook, isEmpty);
        expect(h.contactWritesOf(), isEmpty);
        final after = await h.links();
        expect(after.any((l) => l.googleName == now), isTrue);
        expect(after.any((l) => l.googleName == target), isFalse);
        expect(await h.paired(), hasLength(1));
        expect(heldCopies(after), 1);
        status = await h.later();
        final group = status.duplicates.single;
        expect(group.googleCopies, 2);
        expect(group.graphCopies, 1);
        expect(group.googleSynced && group.graphSynced, isTrue);
      });
    }

    test('the synced Outlook copy moved to another folder while a copy is '
        'left: nothing deleted, the pair moves', () async {
      final ann = person2(h, 'Ann', 'Cole');
      await h.firstSync();
      final synced = (await h.links()).firstWhere((l) => l.isPaired).graphId!;
      final left = ann.graph.firstWhere((id) => id != synced);
      h.graph.moveFromOutlook(synced, h.graph.addFolder());
      final status = await h.later();
      expect(status.halt, isNull);
      expect(status.last!.deleted, 0);
      expect(status.needsALook, isEmpty);
      expect(h.google.person(ann.google), isNotNull);
      final pair = (await h.links()).where((l) => l.isPaired).single;
      expect(pair.googleName, ann.google);
      expect(pair.graphId, left);
      expect(h.graph.contact(synced), isNotNull);
    });

    test('the synced Gmail copy deleted while a Gmail copy is left: nothing '
        'deleted in Outlook, the pair moves', () async {
      person2(h, 'Ann', 'Cole', gmail: 2, hadco: 1);
      await h.firstSync();
      final rows = await h.links();
      final pair = rows.firstWhere((l) => l.isPaired);
      final copy = rows
          .firstWhere((l) => l.reason == ContactHeldReason.duplicate)
          .googleName!;
      h.google.deleteFromGmail(pair.googleName!);
      final status = await h.later();
      expect(status.halt, isNull);
      expect(status.last!.deleted, 0);
      expect(status.recentlyDeleted, isEmpty);
      expect(h.graph.count, 1);
      final moved = (await h.links()).where((l) => l.isPaired).single;
      expect(moved.googleName, copy);
      expect(moved.graphId, pair.graphId);
    });

    test('copies on one side only: one is copied once, the rest held',
        () async {
      person2(h, 'Ann', 'Cole', gmail: 3, hadco: 0);
      await h.firstSync();
      final status = await h.status();
      expect(status.halt, isNull);
      expect(h.graph.count, 1);
      expect(heldCopies(await h.links()), 2);
      expect(await h.paired(), hasLength(1));
      // Listed at once as the run leaves them: one copy of each synced.
      final group = status.duplicates.single;
      expect(group.googleCopies, 3);
      expect(group.graphCopies, 1);
      expect(group.googleSynced, isTrue);
      expect(group.graphSynced, isTrue);
      // Nothing more next time.
      h.requests.clear();
      await h.later();
      expect(h.contactWritesOf(), isEmpty);
    });
  });

  group('answered contact by contact', () {
    /// Eleven pairs whose Gmail mobiles Ron removed: a change brake of
    /// eleven, each would lose its mobile in Hadco.
    Future<List<({String google, String graph})>> heldChanges() async {
      final pairs = seedPairs(h, 11, mobiles: true);
      await h.firstSync();
      for (final p in pairs) {
        h.google.editFromGmail(p.google, {'phoneNumbers': null});
      }
      final status = await h.later();
      expect(status.questions.single.kind, ContactSyncQuestionKind.changes);
      expect(status.questions.single.items, hasLength(11));
      return pairs;
    }

    ({String google, String graph}) pairOf(
      List<({String google, String graph})> pairs,
      ContactSyncQuestionItem item,
    ) => pairs[int.parse(RegExp(r'^P(\d+) ').firstMatch(item.title)![1]!)];

    test('each item has a key of its own', () async {
      final pairs = await heldChanges();
      final items = (await h.status()).questions.single.items;
      final keys = {for (final i in items) i.key};
      expect(keys, hasLength(11));
      expect(keys, isNot(contains('')));
      // Minted for it, not taken from its contacts, whose ids can change.
      expect(
        keys.intersection({
          for (final p in pairs) ...[p.google, p.graph],
        }),
        isEmpty,
      );
    });

    test('Copy them back for one contact: only it, the others stay held '
        'and open', () async {
      final pairs = await heldChanges();
      var q = (await h.status()).questions.single;
      final one = pairOf(pairs, q.items.first);
      final firstTitle = q.items.first.title;
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.copyThemBack,
        items: {q.items.first.key},
      );
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.halt, isNull);
      q = status.questions.single;
      expect(q.items, hasLength(10));
      expect(q.answer, isNull);
      expect(q.items.every((i) => i.answer == null), isTrue);
      expect(q.items.map((i) => i.title), isNot(contains(firstTitle)));
      // Its mobile is back in Gmail, and kept in Hadco.
      expect(mobileOf(h.google.person(one.google)), isNotNull);
      expect(mobileOf(h.graph.contact(one.graph)), isNotNull);
      expect(
        (await h.links()).firstWhere((l) => l.graphId == one.graph).isPaired,
        isTrue,
      );
      // The others are as they were: nothing written for them.
      for (final p in pairs.where((p) => p != one)) {
        expect(mobileOf(h.google.person(p.google)), isNull);
        expect(mobileOf(h.graph.contact(p.graph)), isNotNull);
      }
      expect(status.notice!.heldChanges, 10);
    });

    test('Apply them for one contact: only it loses the detail', () async {
      final pairs = await heldChanges();
      final q = (await h.status()).questions.single;
      final one = pairOf(pairs, q.items.last);
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.applyThem,
        items: {q.items.last.key},
      );
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.questions.single.items, hasLength(10));
      expect(mobileOf(h.graph.contact(one.graph)), isNull);
      for (final p in pairs.where((p) => p != one)) {
        expect(mobileOf(h.graph.contact(p.graph)), isNotNull);
      }
    });

    test("an item's answer shows until a run carries it out, after a "
        'restart too; the whole answer covers the rest', () async {
      final pairs = await heldChanges();
      var q = (await h.status()).questions.single;
      final one = pairOf(pairs, q.items.first);
      final key = q.items.first.key;
      // Hadco's permission lapses: the runs these answers start stop
      // before carrying them out.
      h.refusing.add(Harness.hadco.id);
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.copyThemBack,
        items: {q.items.first.key},
      );
      await h.sync.syncNow();
      // The message counts only what still waits for Ron.
      expect((await h.status()).notice!.heldChanges, 10);
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.applyThem,
      );
      await h.sync.syncNow();
      var status = await h.status();
      expect(status.halt!.kind, ContactSyncHaltKind.notAllowed);
      q = status.questions.single;
      expect(q.answer, ContactSyncChoice.applyThem);
      expect(
        q.items.firstWhere((i) => i.key == key).answer,
        ContactSyncChoice.copyThemBack,
      );
      expect(q.items.where((i) => i.answer != null), hasLength(1));
      expect(status.notice!.heldChanges, 0);

      // MyEmail restarted: the same, from what the device keeps.
      final restarted = h.make();
      q = (await restarted.status()).questions.single;
      expect(
        q.items.firstWhere((i) => i.key == key).answer,
        ContactSyncChoice.copyThemBack,
      );
      expect(q.answer, ContactSyncChoice.applyThem);
      await restarted.close();

      // Allowed again: the item's own answer for it, the whole's for the
      // rest, and the question done with.
      h.refusing.clear();
      h.pass(const Duration(minutes: 6));
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(status.questions, isEmpty);
      expect(mobileOf(h.google.person(one.google)), isNotNull);
      expect(mobileOf(h.graph.contact(one.graph)), isNotNull);
      for (final p in pairs.where((p) => p != one)) {
        expect(mobileOf(h.graph.contact(p.graph)), isNull);
      }
    });

    test('for all, an item answered on its own keeps its answer; named '
        'alone, it takes the new one', () async {
      await heldChanges();
      // Runs stop before planning: the answers stay to be seen.
      h.refusing.add(Harness.hadco.id);
      var q = (await h.status()).questions.single;
      final ann = q.items.first.key;
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.applyThem,
        items: {ann},
      );
      // Copy them back for all, from a screen that still showed Ann open.
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.copyThemBack,
        items: {for (final i in q.items) i.key},
      );
      await h.sync.syncNow();
      q = (await h.status()).questions.single;
      expect(
        q.items.firstWhere((i) => i.key == ann).answer,
        ContactSyncChoice.applyThem,
      );
      expect(
        q.items
            .where((i) => i.key != ann)
            .every((i) => i.answer == ContactSyncChoice.copyThemBack),
        isTrue,
      );
      // Named alone, Ann takes the new answer.
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.copyThemBack,
        items: {ann},
      );
      await h.sync.syncNow();
      q = (await h.status()).questions.single;
      expect(
        q.items.firstWhere((i) => i.key == ann).answer,
        ContactSyncChoice.copyThemBack,
      );
    });

    test('an answer given while a run carries out another is kept, and '
        'carried out next', () async {
      final pairs = await heldChanges();
      final q = (await h.status()).questions.single;
      final a = pairOf(pairs, q.items[0]);
      final b = pairOf(pairs, q.items[1]);
      var given = false;
      h.before = (r) async {
        // As the run writes A back to Gmail, Ron answers B the same way.
        if (!given &&
            r.method == 'PATCH' &&
            r.url.path.endsWith('/v1/${a.google}:updateContact')) {
          given = true;
          await h.sync.answerQuestion(
            ContactSyncQuestionKind.changes,
            ContactSyncChoice.copyThemBack,
            items: {q.items[1].key},
          );
        }
      };
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.copyThemBack,
        items: {q.items[0].key},
      );
      await h.sync.syncNow();
      h.before = null;
      expect(given, isTrue);
      final status = await h.status();
      expect(status.questions.single.items, hasLength(9));
      expect(mobileOf(h.google.person(a.google)), isNotNull);
      expect(mobileOf(h.google.person(b.google)), isNotNull);
    });

    test('an answer given while a run goes is not said to wait before a '
        'run has tried it', () async {
      final pairs = seedPairs(h, 8);
      await h.firstSync();
      for (var i = 0; i < 6; i++) {
        h.google.deleteFromGmail(pairs[i].google);
      }
      final q = (await h.later()).questions.single;
      final key = q.items.first.key;
      var given = false;
      ContactSyncQuestionItem? between;
      h.before = (r) async {
        if (!given && r.url.path.endsWith('/delta')) {
          given = true;
          await h.sync.answerQuestion(
            ContactSyncQuestionKind.deletions,
            ContactSyncChoice.deleteThem,
            items: {key},
          );
        } else if (given &&
            between == null &&
            r.method == 'PATCH' &&
            r.url.path.contains('contactFolders')) {
          // That run is done (its claim goes last), and the one it starts
          // for the answer has not begun.
          between = (await h.sync.status()).questions.single.items
              .firstWhere((i) => i.key == key);
        }
      };
      h.pass(const Duration(hours: 2));
      await h.sync.syncNow();
      h.before = null;
      expect(between!.answer, ContactSyncChoice.deleteThem);
      expect(between!.answerProblem, isNull);
      // The run it started carried it out.
      expect((await h.status()).questions.single.items, hasLength(5));
    });

    test('deletions one by one: Delete one, keep another, the rest wait',
        () async {
      final pairs = seedPairs(h, 8);
      await h.firstSync();
      for (var i = 0; i < 6; i++) {
        h.google.deleteFromGmail(pairs[i].google);
      }
      var q = (await h.later()).questions.single;
      expect(q.kind, ContactSyncQuestionKind.deletions);
      expect(q.items, hasLength(6));
      final gone = pairOf(pairs, q.items[0]);
      final kept = pairOf(pairs, q.items[1]);
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.deleteThem,
        items: {q.items[0].key},
      );
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.dontDelete,
        items: {q.items[1].key},
      );
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.halt, isNull);
      expect(h.graph.contact(gone.graph), isNull);
      expect(status.recentlyDeleted, hasLength(1));
      expect(h.graph.contact(kept.graph), isNotNull);
      expect(
        status.needsALook.where((l) => l.kind == ContactReviewKind.kept),
        hasLength(1),
      );
      q = status.questions.single;
      expect(q.items, hasLength(4));
      expect(q.items.every((i) => i.answer == null), isTrue);
      expect(h.graph.count, 7);
    });

    test('Delete them for the contacts shown leaves those raised since open',
        () async {
      final pairs = seedPairs(h, 14);
      await h.firstSync();
      for (var i = 0; i < 6; i++) {
        h.google.deleteFromGmail(pairs[i].google);
      }
      var q = (await h.later()).questions.single;
      final shown = {for (final i in q.items) i.key};
      expect(shown, hasLength(6));
      // Six more go in Gmail, and a run holds them in the same question
      // before Ron answers what his screen shows.
      for (var i = 6; i < 12; i++) {
        h.google.deleteFromGmail(pairs[i].google);
      }
      q = (await h.later()).questions.single;
      expect(q.items, hasLength(12));
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.deleteThem,
        items: shown,
      );
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.halt, isNull);
      for (var i = 0; i < 6; i++) {
        expect(h.graph.contact(pairs[i].graph), isNull);
      }
      for (var i = 6; i < 12; i++) {
        expect(h.graph.contact(pairs[i].graph), isNotNull);
      }
      q = status.questions.single;
      expect(q.items, hasLength(6));
      expect(q.items.every((i) => i.answer == null), isTrue);
      expect(q.items.map((i) => i.key).toSet().intersection(shown), isEmpty);
    });

    test("an item's key stays the same through a Gmail re-key, and a key "
        'the question no longer has is refused', () async {
      final pairs = seedPairs(h, 8);
      await h.firstSync();
      // Ron deletes six in Outlook: the copies held are Gmail contacts.
      for (var i = 0; i < 6; i++) {
        h.graph.deleteFromOutlook(pairs[i].graph);
      }
      var q = (await h.later()).questions.single;
      final item = q.items.first;
      final answered = pairOf(pairs, item);
      final now = h.google.rekeyFromGmail(answered.google);
      q = (await h.later()).questions.single;
      expect(q.items, hasLength(6));
      expect(q.items.map((i) => i.key), contains(item.key));

      // Keys from a screen read before the question changed: nothing is
      // answered, and the screen is told.
      await expectLater(
        h.sync.answerQuestion(
          ContactSyncQuestionKind.deletions,
          ContactSyncChoice.deleteThem,
          items: {item.key, 'no-such-item'},
        ),
        throwsA(isA<ContactSyncRefused>()),
      );
      q = (await h.status()).questions.single;
      expect(q.items.every((i) => i.answer == null), isTrue);
      expect(q.answer, isNull);

      // The key shown before the re-key still answers that contact.
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.deleteThem,
        items: {item.key},
      );
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.halt, isNull);
      q = status.questions.single;
      expect(q.items, hasLength(5));
      expect(q.items.map((i) => i.key), isNot(contains(item.key)));
      expect(q.items.every((i) => i.answer == null), isTrue);
      // Carried out on it under its new name, read again before the
      // delete and kept: the re-key moved its version (as for Delete them
      // for all), so it is asked about.
      expect(h.google.person(now), isNotNull);
      final kept = await h.store.reviews((await h.pair()).pairId);
      expect(kept.where((r) => r.kind == 'kept').single.googleName, now);
      // The others are not answered: still there.
      for (final p in pairs.take(6)) {
        if (p == answered) continue;
        expect(h.google.person(p.google), isNotNull);
      }
    });

    test('an item held before keys were keeps the key it was first shown '
        'with, through a Gmail re-key', () async {
      final pairs = seedPairs(h, 8);
      await h.firstSync();
      for (var i = 0; i < 6; i++) {
        h.graph.deleteFromOutlook(pairs[i].graph);
      }
      await h.later();
      // As 3.20.0 kept the question: no keys.
      final pairId = (await h.pair()).pairId;
      await h.store.updatePair(pairId, (p) {
        final held = jsonDecode(p.held!) as Map<String, Object?>;
        held.remove('lastKey');
        for (final q in held['questions']! as List) {
          for (final i in (q as Map)['items']! as List) {
            (i as Map).remove('key');
          }
        }
        return p.copyWith(held: jsonEncode(held));
      });
      var q = (await h.status()).questions.single;
      final item = q.items.first;
      final answered = pairOf(pairs, item);
      // Keyed by its Gmail contact's name, which a re-key then changes.
      expect(item.key, answered.google);
      final now = h.google.rekeyFromGmail(answered.google);
      q = (await h.later()).questions.single;
      expect(q.items.map((i) => i.key), contains(item.key));
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.deletions,
        ContactSyncChoice.deleteThem,
        items: {item.key},
      );
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.halt, isNull);
      expect(status.questions.single.items, hasLength(5));
      final kept = await h.store.reviews(pairId);
      expect(kept.where((r) => r.kind == 'kept').single.googleName, now);
    });
  });

  group('what a held change would do', () {
    /// Eleven pairs with a mobile and a job title; Ron changes each job
    /// title in Gmail and takes each mobile out: a change brake of eleven,
    /// each would lose its mobile and its title in Hadco.
    Future<List<({String google, String graph})>> heldChanges({
      String title = 'Sales manager',
      String newTitle = 'Purchasing manager',
    }) async {
      final pairs = [
        for (var i = 0; i < 11; i++)
          (
            google: h.google.seed({
              ...person(
                'P$i',
                'Fam$i',
                email: 'p$i@example.com',
                mobile: '+1 202 555 01${10 + i}',
              ),
              'organizations': [
                {'name': 'Acme', 'title': title},
              ],
            }),
            graph: h.graph.seed({
              ...outlook(
                'P$i',
                'Fam$i',
                email: 'p$i@example.com',
                mobile: '+1 202 555 01${10 + i}',
                company: 'Acme',
              ),
              'jobTitle': title,
            }),
          ),
      ];
      await h.firstSync();
      for (final p in pairs) {
        h.google.editFromGmail(p.google, {
          'phoneNumbers': null,
          'organizations': [
            {'name': 'Acme', 'title': newTitle},
          ],
        });
      }
      final status = await h.later();
      expect(status.questions.single.items, hasLength(11));
      return pairs;
    }

    test('each held change says what it would remove or replace', () async {
      await heldChanges();
      final q = (await h.status()).questions.single;
      final item = q.items.firstWhere((i) => i.title == 'P0 Fam0');
      expect(item.side, ContactSide.graph);
      expect(item.hint, isNull);
      final byField = {for (final c in item.changes) c.field: c};
      expect(
        byField.keys,
        containsAll([ContactField.mobile, ContactField.jobTitle]),
      );
      expect(byField[ContactField.mobile]!.before, '+1 202 555 0110');
      expect(byField[ContactField.mobile]!.after, isNull);
      expect(byField[ContactField.jobTitle]!.before, 'Sales manager');
      expect(byField[ContactField.jobTitle]!.after, 'Purchasing manager');
      // Each says the side it lands on (here the item's), and none is a
      // detail changed on both sides.
      for (final c in item.changes) {
        expect(c.side, ContactSide.graph);
        expect(c.clash, isFalse);
      }
    });

    test('a question held before details were kept gets them at the next '
        'run, not doubled, and keeps them after a restart', () async {
      await heldChanges();
      // As a question stored by 3.20.0: its items with no details, and
      // no keys of their own.
      final pairId = (await h.pair()).pairId;
      await h.store.updatePair(pairId, (p) {
        final held = jsonDecode(p.held!) as Map<String, Object?>;
        held.remove('lastKey');
        for (final q in held['questions']! as List) {
          for (final i in (q as Map)['items']! as List) {
            (i as Map)
              ..remove('changes')
              ..remove('key');
          }
        }
        return p.copyWith(held: jsonEncode(held));
      });
      var q = (await h.status()).questions.single;
      expect(q.items.every((i) => i.changes.isEmpty), isTrue);
      // Each keyed by its contacts meanwhile, and from then on.
      final keys = [for (final i in q.items) i.key];
      expect(keys.toSet(), hasLength(11));

      // MyEmail updated and opened: the next run fills them in.
      final restarted = h.make();
      h.pass(const Duration(hours: 2));
      await restarted.syncNow();
      var status = await restarted.status();
      expect(status.halt, isNull);
      q = status.questions.single;
      expect(q.items, hasLength(11));
      expect([for (final i in q.items) i.key], keys);
      expect(q.items.every((i) => i.changes.length == 2), isTrue);
      // Still news only once: nothing new was held.
      await restarted.close();

      // And after another restart, from what the device keeps, with no
      // network.
      final again = h.make();
      h.requests.clear();
      status = await again.status();
      expect(h.requests, isEmpty);
      expect(
        status.questions.single.items.every((i) => i.changes.length == 2),
        isTrue,
      );
      expect([for (final i in status.questions.single.items) i.key], keys);
      await again.close();
    });

    test('an item whose answer waits keeps it, and the details it had, as '
        'the others are refreshed', () async {
      final pairs = await heldChanges();
      var q = (await h.status()).questions.single;
      final first = q.items.first;
      final had = first.changes;
      // Its Outlook contact moved out of Contacts: Copy them back waits
      // for it, and no run reads it whole meanwhile.
      h.graph.moveFromOutlook(
        pairs[int.parse(RegExp(r'^P(\d+) ').firstMatch(first.title)![1]!)]
            .graph,
        h.graph.addFolder(),
      );
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.copyThemBack,
        items: {first.key},
      );
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.halt, isNull);
      q = status.questions.single;
      expect(q.items, hasLength(11));
      final waiting = q.items.firstWhere((i) => i.key == first.key);
      expect(waiting.answer, ContactSyncChoice.copyThemBack);
      expect(
        waiting.answerProblem,
        'Its Outlook contact is not in Contacts: it is carried out once it '
        'is back.',
      );
      expect(
        q.items.where((i) => i != waiting).every((i) => i.answerProblem == null),
        isTrue,
      );
      expect(waiting.changes.map((c) => c.field), had.map((c) => c.field));
      expect(
        q.items.where((i) => i.key != first.key).every(
          (i) => i.changes.length == 2 && i.answer == null,
        ),
        isTrue,
      );
    });

    test("an answer changed while a run goes loses the old one's reason "
        'until a run has tried it', () async {
      final pairs = await heldChanges();
      var q = (await h.status()).questions.single;
      final first = q.items.firstWhere((i) => i.title == 'P0 Fam0');
      // Copy them back waits for P0's Outlook contact, moved out.
      h.graph.moveFromOutlook(pairs[0].graph, h.graph.addFolder());
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.copyThemBack,
        items: {first.key},
      );
      await h.sync.syncNow();
      q = (await h.status()).questions.single;
      expect(
        q.items.firstWhere((i) => i.key == first.key).answerProblem,
        isNotNull,
      );
      // At the next run Ron makes it Apply them, as the run goes.
      var given = false;
      ContactSyncQuestionItem? between;
      h.before = (r) async {
        if (!given && r.url.path.endsWith('/delta')) {
          given = true;
          await h.sync.answerQuestion(
            ContactSyncQuestionKind.changes,
            ContactSyncChoice.applyThem,
            items: {first.key},
          );
        } else if (given &&
            between == null &&
            r.method == 'PATCH' &&
            r.url.path.contains('contactFolders')) {
          between = (await h.sync.status()).questions.single.items
              .firstWhere((i) => i.key == first.key);
        }
      };
      h.pass(const Duration(hours: 2));
      await h.sync.syncNow();
      h.before = null;
      expect(between!.answer, ContactSyncChoice.applyThem);
      expect(between!.answerProblem, isNull);
    });

    test('a held change lists what it would take on both sides, each '
        'with its side, and flags a detail changed on both', () async {
      final pairs = [
        for (var i = 0; i < 11; i++)
          (
            google: h.google.seed({
              ...person(
                'P$i',
                'Fam$i',
                email: 'p$i@example.com',
                mobile: '+1 202 555 01${10 + i}',
              ),
              'organizations': [
                {'name': 'Acme', 'title': 'Buyer'},
              ],
            }),
            graph: h.graph.seed({
              ...outlook(
                'P$i',
                'Fam$i',
                email: 'p$i@example.com',
                mobile: '+1 202 555 01${10 + i}',
                company: 'Acme',
              ),
              'jobTitle': 'Buyer',
            }),
          ),
      ];
      await h.firstSync();
      // Hadco takes each mobile out and gives another title; later, Gmail
      // renames the company and gives a title of its own.
      for (final p in pairs) {
        h.graph.editFromOutlook(p.graph, {
          'mobilePhone': null,
          'jobTitle': 'Lead buyer',
        });
      }
      h.pass(const Duration(minutes: 10));
      for (final p in pairs) {
        h.google.editFromGmail(p.google, {
          'organizations': [
            {'name': 'Acme Corp', 'title': 'Manager'},
          ],
        });
      }
      final q = (await h.later()).questions.single;
      expect(q.items, hasLength(11));
      final item = q.items.firstWhere((i) => i.title == 'P0 Fam0');
      expect(item.side, ContactSide.graph, reason: 'Hadco loses more');
      expect(
        [
          for (final c in item.changes)
            (c.side, c.field, c.before, c.after, c.clash),
        ],
        [
          (
            ContactSide.google,
            ContactField.mobile,
            '+1 202 555 0110',
            null,
            false,
          ),
          (ContactSide.graph, ContactField.company, 'Acme', 'Acme Corp', false),
          (
            ContactSide.graph,
            ContactField.jobTitle,
            'Lead buyer',
            'Manager',
            true,
          ),
        ],
      );
    });

    test("a held deletion says which contact it is: its first email",
        () async {
      final pairs = seedPairs(h, 7);
      await h.firstSync();
      for (var i = 0; i < 6; i++) {
        h.google.deleteFromGmail(pairs[i].google);
      }
      final q = (await h.later()).questions.single;
      expect(q.kind, ContactSyncQuestionKind.deletions);
      for (final item in q.items) {
        final i = int.parse(RegExp(r'^P(\d+) ').firstMatch(item.title)![1]!);
        expect(item.hint, 'p$i@example.com');
        expect(item.changes, isEmpty);
      }
    });

    test('the details are never in the log', () async {
      final logged = <String>[];
      final was = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) =>
          logged.add(message ?? '');
      addTearDown(() => debugPrint = was);
      await heldChanges(
        title: 'Zanzibar Quartermaster',
        newTitle: 'Xylophone Curator',
      );
      final q = (await h.status()).questions.single;
      expect(q.items.first.changes, isNotEmpty);
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.applyThem,
        items: {q.items.first.key},
      );
      await h.sync.syncNow();
      await h.later();
      final all = logged.join('\n');
      for (final secret in [
        'Zanzibar',
        'Quartermaster',
        'Xylophone',
        'Curator',
        '555 0110',
        '5550110',
        'p0@example.com',
        'Fam0',
      ]) {
        expect(all, isNot(contains(secret)), reason: secret);
      }
    });

    /// The job title each held change shows Hadco's taking.
    String? titleAfter(ContactSyncQuestionItem item) => item.changes
        .firstWhere((c) => c.field == ContactField.jobTitle)
        .after;

    test('an item whose pair this run could not read keeps the details it '
        'had; one whose row is held no longer goes', () async {
      final pairs = await heldChanges();
      // P0's Outlook contact moved out of Contacts: its row still held,
      // its pair not read whole this run.
      h.graph.moveFromOutlook(pairs[0].graph, h.graph.addFolder());
      // P1 deleted in Gmail: its row is held no more.
      h.google.deleteFromGmail(pairs[1].google);
      // The rest given another title in Gmail.
      for (final p in pairs.skip(2)) {
        h.google.editFromGmail(p.google, {
          'organizations': [
            {'name': 'Acme', 'title': 'Buyer'},
          ],
        });
      }
      final status = await h.later();
      expect(status.halt, isNull);
      final q = status.questions.single;
      expect(q.items, hasLength(10));
      expect(q.items.map((i) => i.title), isNot(contains('P1 Fam1')));
      final away = q.items.singleWhere((i) => i.title == 'P0 Fam0');
      expect(away.changes, hasLength(2));
      expect(titleAfter(away), 'Purchasing manager');
      expect(away.answer, isNull);
      for (final i in q.items.where((i) => i != away)) {
        expect(i.changes, hasLength(2), reason: i.title);
        expect(titleAfter(i), 'Buyer', reason: i.title);
      }
    });

    test("Hadco's reads of the held pairs go twenty to a batch; one that "
        'fails leaves their items as they were, and the run goes on',
        () async {
      final pairs = await heldChanges();
      for (final p in pairs) {
        h.google.editFromGmail(p.google, {
          'organizations': [
            {'name': 'Acme', 'title': 'Buyer'},
          ],
        });
      }
      h.google.addFromGmail(person('New', 'Person', email: 'n@example.com'));
      h.requests.clear();
      var refused = 0;
      h.answer = (r) {
        if (!r.url.path.endsWith(r'$batch') ||
            !r.body.contains('"method":"GET"')) {
          return null;
        }
        refused++;
        return http.Response('{}', 500);
      };
      var status = await h.later();
      h.answer = null;
      expect(refused, greaterThan(0));
      expect(status.halt, isNull);
      // The rest of the run was done: the new contact is in Hadco.
      expect(h.graph.count, 12);
      var q = status.questions.single;
      expect(q.items, hasLength(11));
      expect(
        q.items.every((i) => titleAfter(i) == 'Purchasing manager'),
        isTrue,
      );
      // Each contact asked for inside a batch, none by a GET of its own.
      final held = {for (final p in pairs) p.graph};
      expect(
        h.requests.where(
          (r) => r.method == 'GET' && held.contains(r.url.pathSegments.last),
        ),
        isEmpty,
      );

      // Answered at the next run: the details as they now are.
      h.requests.clear();
      status = await h.later();
      expect(status.halt, isNull);
      q = status.questions.single;
      expect(q.items.every((i) => titleAfter(i) == 'Buyer'), isTrue);
      expect(
        h.requests.where((r) => r.url.path.endsWith(r'$batch')),
        hasLength(1),
      );
    });

    test("a failed read of the held pairs' Gmail contacts does not stop "
        'the run either', () async {
      await heldChanges();
      h.google.addFromGmail(person('New', 'Person', email: 'n@example.com'));
      var refused = 0;
      h.answer = (r) {
        if (!r.url.path.endsWith('people:batchGet')) return null;
        refused++;
        return http.Response('{}', 500);
      };
      final status = await h.later();
      h.answer = null;
      expect(refused, greaterThan(0));
      expect(status.halt, isNull);
      expect(h.graph.count, 12);
      final q = status.questions.single;
      expect(q.items, hasLength(11));
      expect(
        q.items.every((i) => titleAfter(i) == 'Purchasing manager'),
        isTrue,
      );
    });
  });

  group('reads of the held pairs refused', () {
    /// Eleven pairs whose Gmail mobiles Ron removed and whose Gmail job
    /// titles he changed: a change brake of eleven.
    Future<List<({String google, String graph})>> heldChanges() async {
      final pairs = [
        for (var i = 0; i < 11; i++)
          (
            google: h.google.seed({
              ...person(
                'P$i',
                'Fam$i',
                email: 'p$i@example.com',
                mobile: '+1 202 555 01${10 + i}',
              ),
              'organizations': [
                {'name': 'Acme', 'title': 'Sales manager'},
              ],
            }),
            graph: h.graph.seed({
              ...outlook(
                'P$i',
                'Fam$i',
                email: 'p$i@example.com',
                mobile: '+1 202 555 01${10 + i}',
                company: 'Acme',
              ),
              'jobTitle': 'Sales manager',
            }),
          ),
      ];
      await h.firstSync();
      for (final p in pairs) {
        h.google.editFromGmail(p.google, {
          'phoneNumbers': null,
          'organizations': [
            {'name': 'Acme', 'title': 'Purchasing manager'},
          ],
        });
      }
      expect((await h.later()).questions.single.items, hasLength(11));
      return pairs;
    }

    http.Response refusal(String code) => http.Response(
      '{"error":{"code":$code,"message":"x"}}',
      400,
      headers: {'content-type': 'application/json'},
    );

    test('a batch read Graph refuses is read a contact at a time: an answer '
        'is carried out all the same', () async {
      final pairs = await heldChanges();
      var refused = 0;
      h.answer = (r) {
        if (!r.url.path.endsWith(r'$batch') ||
            !r.body.contains('"method":"GET"')) {
          return null;
        }
        refused++;
        return refusal('"BadRequest"');
      };
      var q = (await h.status()).questions.single;
      final one = q.items.firstWhere((i) => i.title == 'P0 Fam0');
      h.requests.clear();
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.applyThem,
        items: {one.key},
      );
      await h.sync.syncNow();
      h.answer = null;
      final status = await h.status();
      expect(refused, greaterThan(0));
      expect(status.halt, isNull);
      q = status.questions.single;
      expect(q.items, hasLength(10));
      expect(q.items.map((i) => i.key), isNot(contains(one.key)));
      expect(q.items.every((i) => i.answerProblem == null), isTrue);
      // Applied: Hadco lost the mobile and took Gmail's title.
      final hadco = h.graph.contact(pairs[0].graph)!;
      expect(mobileOf(hadco), isNull);
      expect(hadco['jobTitle'], 'Purchasing manager');
      // Each held contact asked for with a GET of its own.
      for (final p in pairs) {
        expect(
          h.requests.any(
            (r) => r.method == 'GET' && r.url.pathSegments.last == p.graph,
          ),
          isTrue,
        );
      }
    });

    test("a Gmail name that spoils Google's batch read: the others are read "
        'alone, and the answer waiting on it says why', () async {
      final pairs = await heldChanges();
      final bad = pairs[0].google;
      h.answer = (r) {
        if (r.url.host != 'people.googleapis.com' || r.method != 'GET') {
          return null;
        }
        final inBatch =
            r.url.path.endsWith('people:batchGet') &&
            r.url.queryParametersAll['resourceNames']!.contains(bad);
        if (!inBatch && !r.url.path.endsWith('/$bad')) return null;
        return refusal('400,"status":"INVALID_ARGUMENT"');
      };
      var q = (await h.status()).questions.single;
      String keyOf(int i) =>
          q.items.firstWhere((x) => x.title == 'P$i Fam$i').key;
      final waiting = keyOf(0);
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.copyThemBack,
        items: {waiting, keyOf(1)},
      );
      await h.sync.syncNow();
      var status = await h.status();
      expect(status.halt, isNull);
      q = status.questions.single;
      // P1, read alone, was copied back; P0 waits, answered, and says why.
      expect(q.items, hasLength(10));
      expect(mobileOf(h.google.person(pairs[1].google)), isNotNull);
      expect(mobileOf(h.google.person(bad)), isNull);
      final item = q.items.singleWhere((i) => i.key == waiting);
      expect(item.answer, ContactSyncChoice.copyThemBack);
      expect(
        item.answerProblem,
        'Could not be read just now: it is carried out when it can be.',
      );
      expect(
        q.items
            .where((i) => i.key != waiting)
            .every((i) => i.answerProblem == null),
        isTrue,
      );

      // Read again: carried out, and nothing more to say.
      h.answer = null;
      status = await h.later();
      q = status.questions.single;
      expect(q.items, hasLength(9));
      expect(
        q.items.every((i) => i.answer == null && i.answerProblem == null),
        isTrue,
      );
      expect(mobileOf(h.google.person(bad)), isNotNull);
    });

    test('an answer changed after a run said why the last one waited shows '
        'no reason before a run has tried it', () async {
      await heldChanges();
      // Hadco's batch reads fail (no connection): the held pairs unread.
      h.answer = (r) =>
          r.url.path.endsWith(r'$batch') && r.body.contains('"method":"GET"')
          ? http.Response('{}', 503)
          : null;
      final key = (await h.status()).questions.single.items.first.key;
      ContactSyncQuestionItem itemOf(ContactSyncStatus s) =>
          s.questions.single.items.firstWhere((i) => i.key == key);
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.applyThem,
        items: {key},
      );
      await h.sync.syncNow();
      expect(itemOf(await h.status()).answerProblem, isNotNull);
      // Hadco's permission lapses: the next run stops before planning.
      h.refusing.add(Harness.hadco.id);
      await h.sync.answerQuestion(
        ContactSyncQuestionKind.changes,
        ContactSyncChoice.copyThemBack,
        items: {key},
      );
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.halt!.kind, ContactSyncHaltKind.notAllowed);
      expect(itemOf(status).answer, ContactSyncChoice.copyThemBack);
      expect(itemOf(status).answerProblem, isNull);
    });
  });

  group("merging Hadco's copies of one person", () {
    /// [given] [family] once in Gmail and [copies] times in Hadco, every
    /// copy alike: the first sync pairs one Hadco copy and holds the
    /// others as copies of one person.
    ({String google, List<String> graph}) copiesOf(
      String given,
      String family, {
      int copies = 2,
      String? jobTitle,
      String? notes,
    }) {
      final email = '${given.toLowerCase()}@example.com';
      return (
        google: h.google.seed({
          ...person(given, family, email: email),
          if (jobTitle != null)
            'organizations': [
              {'name': 'Acme', 'title': jobTitle},
            ],
          if (notes != null)
            'biographies': [
              {'value': notes, 'contentType': 'TEXT_PLAIN'},
            ],
        }),
        graph: [
          for (var i = 0; i < copies; i++)
            h.graph.seed({
              ...outlook(
                given,
                family,
                email: email,
                company: jobTitle == null ? null : 'Acme',
              ),
              'jobTitle': ?jobTitle,
              'personalNotes': ?notes,
            }),
        ],
      );
    }

    bool photoCheck(http.Request r) =>
        r.url.path.endsWith(r'$batch') && r.body.contains('/photo');

    /// The Hadco copy paired with [p]'s Gmail contact, and the others.
    Future<({String synced, List<String> others})> hadcoOf(
      ({String google, List<String> graph}) p,
    ) async {
      final synced = (await h.paired())
          .firstWhere((l) => l.googleName == p.google)
          .graphId!;
      return (
        synced: synced,
        others: [
          for (final id in p.graph)
            if (id != synced) id,
        ],
      );
    }

    /// The version the status shows for the person [key].
    Future<String> versionOf(String key) async => (await h.status())
        .copies
        .differing
        .firstWhere((p) => p.key == key)
        .version;

    String? gmailTitle(String name) {
      final orgs = h.google.person(name)?['organizations'];
      if (orgs is! List || orgs.isEmpty) return null;
      return (orgs.first as Map)['title'] as String?;
    }

    test('the tablet pattern: copies the same are deleted, a detail only '
        'another copy has is added first, copies that differ are listed, '
        'and Gmail loses nothing', () async {
      final logged = <String>[];
      final was = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) =>
          logged.add(message ?? '');
      addTearDown(() => debugPrint = was);
      final ann = copiesOf('Ann', 'Cole');
      final bob = copiesOf('Bob', 'Ray', copies: 3);
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      final dan = copiesOf('Dan', 'Lee');
      final eve = copiesOf('Eve', 'Moss');
      final fay = copiesOf('Fay', 'Gold');
      for (final id in fay.graph) {
        h.graph.editFromOutlook(id, {
          'homeAddress': {
            'street': '1 Main St, Apt 2',
            'city': 'Springfield',
            'countryOrRegion': 'United States',
          },
        });
      }
      seedPairs(h, 3);
      await h.firstSync();
      final a = await hadcoOf(ann);
      final b = await hadcoOf(bob);
      final c = await hadcoOf(cat);
      final d = await hadcoOf(dan);
      final e = await hadcoOf(eve);
      final f = await hadcoOf(fay);
      // Ron's held copies, as they are on the tablet: two with details
      // the synced copy lacks (a job title, another email), one with
      // another job title, one with a photo, two photos that are not the
      // same, and one laid out otherwise (a line break for a comma, the
      // country dropped, an email in capitals with another name).
      h.graph.editFromOutlook(b.others.first, {'jobTitle': 'Quartermaster'});
      h.graph.editFromOutlook(b.others.last, {
        'emailAddresses': [
          {'address': 'bob@example.com', 'name': 'Bob Ray'},
          {'address': 'bob.work@example.com', 'name': 'Bob at work'},
        ],
      });
      h.graph.editFromOutlook(f.others.single, {
        'homeAddress': {'street': '1 Main St\nApt 2', 'city': 'Springfield'},
        'emailAddresses': [
          {'address': 'FAY@example.com', 'name': 'Fay at home'},
        ],
      });
      h.graph.editFromOutlook(c.others.single, {
        'jobTitle': 'Navigator',
        'nickName': 'Kit',
      });
      h.graph.setPhotoFromOutlook(d.others.single, [1, 2, 3]);
      h.graph.setPhotoFromOutlook(e.synced, [4, 5, 6]);
      h.graph.setPhotoFromOutlook(e.others.single, [7, 8, 9]);
      var status = await h.later();
      expect(status.copies.people, 6);
      expect(status.copies.extras, 7);
      expect(status.copies.notSynced, 0);
      expect(status.copies.asked, isFalse);
      final gmail = h.google.count;
      h.requests.clear();

      await h.sync.mergeCopies();
      expect((await h.status()).copies.asked, isTrue);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(status.copies.asked, isFalse);
      final last = status.copies.last!;
      expect(last.people, 5);
      expect(last.deleted, 6);
      expect(last.added, 3);
      expect(last.differing, 1);
      expect(last.failed, 0);
      // Ann's, Dan's, Eve's and Fay's copy, and Bob's two, are gone; the
      // synced copies stay, Bob's with the job title and the other email,
      // Dan's with the photo, Eve's with its own photo, Fay's as it was.
      for (final id in [
        ...a.others,
        ...b.others,
        ...d.others,
        ...e.others,
        ...f.others,
      ]) {
        expect(h.graph.contact(id), isNull);
      }
      for (final id in [a.synced, b.synced, d.synced, e.synced, f.synced]) {
        expect(h.graph.contact(id), isNotNull);
      }
      expect(h.graph.photoOf(e.synced)!.bytes, [4, 5, 6]);
      // A photo's bytes read only for the copy Dan's synced copy took its
      // photo from.
      expect(
        [
          for (final r in h.requests)
            if (r.method == 'GET' && r.url.path.endsWith(r'/$value'))
              r.url.pathSegments[r.url.pathSegments.length - 3],
        ],
        [...d.others],
      );
      final bobNow = h.graph.contact(b.synced)!;
      expect(bobNow['jobTitle'], 'Quartermaster');
      expect(
        [
          for (final m in bobNow['emailAddresses']! as List)
            (m as Map)['address'],
        ],
        ['bob@example.com', 'bob.work@example.com'],
      );
      expect(h.graph.photoOf(d.synced)!.bytes, [1, 2, 3]);
      final fayNow = h.graph.contact(f.synced)!['homeAddress']! as Map;
      expect(fayNow['countryOrRegion'], 'United States');
      // Cat's copies differ: all there, listed for Ron, the synced copy
      // first.
      for (final id in [c.synced, ...c.others]) {
        expect(h.graph.contact(id), isNotNull);
      }
      // Nothing written to Cat's without Ron, not even the nickname only
      // the other copy has.
      expect(h.graph.contact(c.synced)!['nickName'], isNull);
      expect(
        {for (final p in status.copies.differing) p.title},
        {'Cat Fox'},
      );
      final listed = status.copies.differing.firstWhere(
        (p) => p.title == 'Cat Fox',
      );
      expect(listed.key, c.synced);
      expect(listed.answer, isNull);
      expect([for (final x in listed.copies) x.key], [c.synced, ...c.others]);
      expect([for (final x in listed.copies) x.synced], [true, false]);
      expect(
        [for (final x in listed.copies.first.details) (x.label, x.value)],
        [('Job title', 'Buyer')],
      );
      expect(
        [for (final x in listed.copies.last.details) (x.label, x.value)],
        [('Job title', 'Navigator')],
      );
      // Nothing deleted, nor held, in Gmail; the next run gave Gmail Bob's
      // job title; the held rows of the copies deleted are gone.
      expect(h.google.count, gmail);
      expect(
        h.requests.where(
          (r) => r.url.host == 'people.googleapis.com' && r.method == 'DELETE',
        ),
        isEmpty,
      );
      expect(status.questions, isEmpty);
      expect(status.recentlyDeleted, isEmpty);
      expect(gmailTitle(bob.google), 'Quartermaster');
      expect(
        [
          for (final m in h.google.person(bob.google)!['emailAddresses']!
              as List)
            (m as Map)['value'],
        ],
        containsAll(['bob@example.com', 'bob.work@example.com']),
      );
      expect(
        (await h.links())
            .where((l) => l.reason == ContactHeldReason.duplicate)
            .map((l) => l.graphId)
            .toSet(),
        {...c.others},
      );
      expect(status.graphCount, 16 - 6);
      // Cat, listed under the rules of now, is shown for Ron, and not
      // counted: a merge would only list her again.
      expect(status.copies.people, 0);
      // The log has counts only.
      final all = logged.join('\n');
      expect(all, contains('copies: 5 people, 6 deleted, 3 added'));
      for (final secret in [
        'Quartermaster',
        'Navigator',
        'bob.work',
        'Springfield',
        'Cole',
        'Moss',
      ]) {
        expect(all, isNot(contains(secret)), reason: secret);
      }
    });

    test("Ron's answers: another copy's details for eleven go to Gmail as "
        "his, never held by the change brake; the synced copy's for the "
        'rest', () async {
      final people = [
        for (var i = 0; i < 12; i++)
          copiesOf('P$i', 'Fam$i', jobTitle: 'Buyer'),
      ];
      await h.firstSync();
      final hadco = [for (final p in people) await hadcoOf(p)];
      for (final x in hadco) {
        h.graph.editFromOutlook(x.others.single, {'jobTitle': 'Manager'});
      }
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      var status = await h.status();
      expect(status.copies.differing, hasLength(12));
      // Answered while the runs cannot reach Hadco, then carried out in
      // one run.
      h.refusing.add(Harness.hadco.id);
      for (var i = 0; i < 11; i++) {
        await h.sync.answerCopies(
          hadco[i].synced,
          hadco[i].others.single,
          await versionOf(hadco[i].synced),
        );
      }
      await h.sync.answerAllCopies({
        for (final p in status.copies.differing) p.key: p.version,
      });
      await h.sync.syncNow();
      status = await h.status();
      expect(
        {for (final p in status.copies.differing) p.key: p.answer},
        {
          for (var i = 0; i < 11; i++)
            hadco[i].synced: hadco[i].others.single,
          hadco[11].synced: hadco[11].synced,
        },
      );
      h.refusing.clear();
      await h.sync.syncNow();
      status = await h.status();
      expect(status.halt, isNull);
      expect(status.questions, isEmpty);
      expect(status.copies.differing, isEmpty);
      expect(status.copies.last!.people, 12);
      for (var i = 0; i < 11; i++) {
        expect(h.graph.contact(hadco[i].synced)!['jobTitle'], 'Manager');
        expect(h.graph.contact(hadco[i].others.single), isNull);
        expect(gmailTitle(people[i].google), 'Manager');
      }
      expect(h.graph.contact(hadco[11].synced)!['jobTitle'], 'Buyer');
      expect(h.graph.contact(hadco[11].others.single), isNull);
      expect(gmailTitle(people[11].google), 'Buyer');
    });

    test('an answer on differences that have changed since is dropped, and '
        'the person listed again as it now is', () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      await h.firstSync();
      final c = await hadcoOf(cat);
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Manager'});
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final listed = (await h.status()).copies.differing.single;
      // Ron changes that copy in Outlook, then answers from the list he
      // saw before.
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Director'});
      await h.sync.answerCopies(listed.key, c.others.single, listed.version);
      await h.sync.syncNow();
      final again = (await h.status()).copies.differing.single;
      expect(again.answer, isNull);
      expect(
        again.copies.last.details.map((d) => d.value).join(' '),
        contains('Director'),
      );
      expect(h.graph.contact(c.synced)!['jobTitle'], 'Buyer');
      expect(h.graph.contact(c.others.single), isNotNull);

      // Answered on these: carried out, its copies read by id, not the
      // folder whole.
      h.requests.clear();
      await h.sync.answerCopies(again.key, c.others.single, again.version);
      await h.sync.syncNow();
      expect(h.requestsTo('/contacts'), isEmpty);
      expect(
        h.requests.where(
          (r) => r.method == 'GET' && r.url.pathSegments.last == c.synced,
        ),
        isNotEmpty,
      );
      expect((await h.status()).copies.differing, isEmpty);
      expect(h.graph.contact(c.synced)!['jobTitle'], 'Director');
      expect(h.graph.contact(c.others.single), isNull);
    });

    test('an answer given while a merge goes, on the differences listed, '
        'stands', () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      await h.firstSync();
      final c = await hadcoOf(cat);
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Manager'});
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      expect((await h.status()).copies.differing.single.answer, isNull);
      // Another person to merge; as that merge checks the photos, Ron
      // answers Cat from the list.
      copiesOf('Ann', 'Cole');
      await h.later();
      var given = false;
      ContactSyncStatus? between;
      h.before = (r) async {
        if (!given &&
            r.url.path.endsWith(r'$batch') &&
            r.body.contains('/photo')) {
          given = true;
          await h.sync.answerCopies(
            c.synced,
            c.others.single,
            await versionOf(c.synced),
          );
        } else if (given &&
            between == null &&
            r.method == 'PATCH' &&
            r.url.path.contains('contactFolders')) {
          // The pass is done (its claim goes last); the run it starts for
          // the answer has not begun.
          between = await h.sync.status();
        }
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.before = null;
      expect(given, isTrue);
      // Cat, answered, is not among those the pass left differing.
      expect(between!.copies.last!.people, 1);
      expect(between!.copies.last!.differing, 0);
      expect(between!.copies.differing.single.answer, c.others.single);
      final status = await h.status();
      expect(status.copies.differing, isEmpty);
      expect(h.graph.contact(c.synced)!['jobTitle'], 'Manager');
      expect(h.graph.contact(c.others.single), isNull);
    });

    test('a person whose copies are merged in Outlook goes from the list',
        () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      await h.firstSync();
      final c = await hadcoOf(cat);
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Manager'});
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      expect((await h.status()).copies.differing, hasLength(1));
      h.graph.deleteFromOutlook(c.others.single);
      final status = await h.later();
      expect(status.copies.differing, isEmpty);
      expect(status.copies.people, 0);
    });

    test('a copy whose photo cannot be checked passes its person over this '
        'time; nothing of theirs is deleted', () async {
      final ann = copiesOf('Ann', 'Cole');
      final bob = copiesOf('Bob', 'Ray');
      await h.firstSync();
      final a = await hadcoOf(ann);
      final b = await hadcoOf(bob);
      // The first copy asked about in the merge's first batch is turned
      // away for longer than is worth waiting.
      h.graph.throttleInBatch(1, retryAfter: 60);
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.copies.asked, isFalse);
      expect(status.copies.last!.failed, 0);
      expect(status.copies.last!.passedOver, 1);
      expect(status.copies.last!.people, 1);
      final left = [
        for (final id in [...a.others, ...b.others])
          if (h.graph.contact(id) != null) id,
      ];
      expect(left, hasLength(1));
      // Still to merge.
      expect(status.copies.people, 1);
    });

    test('a photo whose bytes cannot be read passes its person over too',
        () async {
      final dan = copiesOf('Dan', 'Lee');
      final ann = copiesOf('Ann', 'Cole');
      await h.firstSync();
      final d = await hadcoOf(dan);
      final a = await hadcoOf(ann);
      h.graph.setPhotoFromOutlook(d.others.single, [1, 2, 3]);
      await h.later();
      h.answer = (r) => r.method == 'GET' && r.url.path.endsWith(r'/$value')
          ? http.Response('{}', 500)
          : null;
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.answer = null;
      final status = await h.status();
      expect(status.copies.last!.people, 1);
      expect(status.copies.last!.failed, 0);
      expect(status.copies.last!.passedOver, 1);
      expect(h.graph.contact(d.others.single), isNotNull);
      expect(h.graph.photoOf(d.synced), isNull);
      expect(h.graph.contact(a.others.single), isNull);
      expect(status.copies.people, 1);
    });

    test('a copy that shares only the name with the synced copy is left as '
        'it is, and counted with the people left out', () async {
      // Ann's copies: the second joined to the synced one by the email,
      // the third to the second by a mobile.
      final g = h.google.seed(
        person(
          'Ann',
          'Cole',
          email: 'ann@example.com',
          mobile: '+1 202 555 0101',
        ),
      );
      final a = h.graph.seed(
        outlook(
          'Ann',
          'Cole',
          email: 'ann@example.com',
          mobile: '+1 202 555 0101',
        ),
      );
      final b = h.graph.seed(
        outlook(
          'Ann',
          'Cole',
          email: 'ann@example.com',
          mobile: '+1 202 555 0102',
        ),
      );
      final c = h.graph.seed(
        outlook(
          'Ann',
          'Cole',
          email: 'ann.c@example.com',
          mobile: '+1 202 555 0102',
        ),
      );
      await h.firstSync();
      final synced = (await h.paired())
          .firstWhere((l) => l.googleName == g)
          .graphId;
      expect(synced, a);
      // Ron takes the second copy's mobile out: the third now shares only
      // the name with the others.
      h.graph.editFromOutlook(b, {'mobilePhone': null});
      var status = await h.later();
      expect(status.copies.people, 1);
      expect(status.copies.extras, 1);
      expect(status.copies.notSynced, 1);

      await h.sync.mergeCopies();
      await h.sync.syncNow();
      status = await h.status();
      expect(status.copies.last!.people, 1);
      expect(status.copies.last!.deleted, 1);
      expect(h.graph.contact(b), isNull);
      expect(h.graph.contact(c), isNotNull);
      expect(status.copies.differing, isEmpty);
      expect(status.copies.people, 0);
      expect(status.copies.notSynced, 1);
    });

    test('a copy a delete could not delete fails its person; the others '
        'are merged', () async {
      final ann = copiesOf('Ann', 'Cole');
      final bob = copiesOf('Bob', 'Ray');
      await h.firstSync();
      final a = await hadcoOf(ann);
      final b = await hadcoOf(bob);
      h.before = (r) async {
        if (r.url.path.endsWith(r'$batch') &&
            r.body.contains('"method":"DELETE"')) {
          // The first copy in it is turned away for longer than is worth
          // waiting.
          h.graph.throttleInBatch(1, retryAfter: 60);
        }
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.before = null;
      final status = await h.status();
      expect(status.copies.last!.people, 1);
      expect(status.copies.last!.failed, 1);
      expect(status.copies.last!.deleted, 1);
      final left = [
        for (final id in [...a.others, ...b.others])
          if (h.graph.contact(id) != null) id,
      ];
      expect(left, hasLength(1));
      expect(status.graphCount, h.graph.count);
      // Its row stays, for the next merge.
      expect(
        (await h.links()).where((l) => l.graphId == left.single),
        hasLength(1),
      );
    });

    test("Keep the synced copy's for all answers only the people shown, at "
        'the differences shown, with no answer yet', () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      final dan = copiesOf('Dan', 'Lee', jobTitle: 'Buyer');
      final eve = copiesOf('Eve', 'Moss', jobTitle: 'Buyer');
      await h.firstSync();
      final c = await hadcoOf(cat);
      final d = await hadcoOf(dan);
      final e = await hadcoOf(eve);
      for (final x in [c, d, e]) {
        h.graph.editFromOutlook(x.others.single, {'jobTitle': 'Manager'});
      }
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final shown = (await h.status()).copies.differing;
      expect(shown, hasLength(3));
      String v(String key) => shown.firstWhere((p) => p.key == key).version;
      // Runs cannot carry the answers out meanwhile.
      h.refusing.add(Harness.hadco.id);
      // Dan answered on his own; Eve not on the screen the tap came from.
      await h.sync.answerCopies(d.synced, d.others.single, v(d.synced));
      await h.sync.answerAllCopies({
        c.synced: v(c.synced),
        d.synced: v(d.synced),
      });
      await h.sync.syncNow();
      expect(
        {for (final p in (await h.status()).copies.differing) p.key: p.answer},
        {c.synced: c.synced, d.synced: d.others.single, e.synced: null},
      );
      // Nothing left to answer among those shown, or a version not the one
      // listed: refused, and nothing answered.
      await expectLater(
        h.sync.answerAllCopies({
          c.synced: v(c.synced),
          d.synced: v(d.synced),
        }),
        throwsA(isA<ContactSyncRefused>()),
      );
      await expectLater(
        h.sync.answerAllCopies({e.synced: 'not this one'}),
        throwsA(isA<ContactSyncRefused>()),
      );
      expect(
        (await h.status()).copies.differing
            .firstWhere((p) => p.key == e.synced)
            .answer,
        isNull,
      );
    });

    test('a merge asked makes a run due, within the hour too', () async {
      copiesOf('Ann', 'Cole');
      await h.firstSync();
      // The merge's run cannot reach Hadco: the ask waits.
      h.refusing.add(Harness.hadco.id);
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      expect((await h.status()).copies.asked, isTrue);
      h.refusing.clear();
      h.pass(const Duration(minutes: 10));
      expect(await h.sync.startIfDue(), isTrue);
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.copies.asked, isFalse);
      expect(status.copies.last!.people, 1);
      // Nothing waiting: not due within the hour.
      h.pass(const Duration(minutes: 10));
      expect(await h.sync.startIfDue(), isFalse);
    });

    test("Hadco's backup alone reads nothing of Gmail", () async {
      copiesOf('Ann', 'Cole');
      await h.firstSync();
      h.requests.clear();
      final files = await h.sync.backup(only: ContactSide.graph);
      expect(files.single.side, ContactSide.graph);
      expect(files.single.count, 2);
      expect(
        h.requests.where((r) => r.url.host == 'people.googleapis.com'),
        isEmpty,
      );
      // Both, as before, without it.
      expect(
        [for (final f in await h.sync.backup()) f.side],
        [ContactSide.google, ContactSide.graph],
      );
    });

    test('a copy Ron changes after the read is not deleted: the person is '
        'passed over, nothing of theirs deleted', () async {
      final ann = copiesOf('Ann', 'Cole');
      await h.firstSync();
      final a = await hadcoOf(ann);
      var edited = false;
      h.before = (r) async {
        if (!edited && photoCheck(r)) {
          edited = true;
          h.graph.editFromOutlook(a.others.single, {'jobTitle': 'Surgeon'});
        }
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.before = null;
      final status = await h.status();
      expect(edited, isTrue);
      expect(h.graph.contact(a.others.single), isNotNull);
      expect(status.copies.last!.people, 0);
      expect(status.copies.last!.passedOver, 1);
      expect(status.copies.people, 1);
    });

    test('a synced copy Ron changes after the read is not written over: '
        'the person is passed over', () async {
      final bob = copiesOf('Bob', 'Ray');
      await h.firstSync();
      final b = await hadcoOf(bob);
      h.graph.editFromOutlook(b.others.single, {
        'emailAddresses': [
          {'address': 'bob@example.com', 'name': 'Bob Ray'},
          {'address': 'bob.work@example.com', 'name': 'Bob at work'},
        ],
      });
      await h.later();
      var edited = false;
      h.before = (r) async {
        if (!edited && photoCheck(r)) {
          edited = true;
          h.graph.editFromOutlook(b.synced, {
            'emailAddresses': [
              {'address': 'bob@example.com', 'name': 'Bob Ray'},
              {'address': 'bob.home@example.com', 'name': 'Bob at home'},
            ],
          });
        }
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.before = null;
      final status = await h.status();
      expect(edited, isTrue);
      expect(
        [
          for (final m in h.graph.contact(b.synced)!['emailAddresses']!
              as List)
            (m as Map)['address'],
        ],
        ['bob@example.com', 'bob.home@example.com'],
      );
      expect(h.graph.contact(b.others.single), isNotNull);
      expect(status.copies.last!.passedOver, 1);
      expect(status.copies.last!.added, 0);
    });

    test('a copy renamed to another person after the plan is left as it is',
        () async {
      final ann = copiesOf('Ann', 'Cole');
      await h.firstSync();
      final a = await hadcoOf(ann);
      var renamed = false;
      h.before = (r) async {
        // The whole read of the folder for the merge.
        if (!renamed &&
            r.method == 'GET' &&
            r.url.path.contains('/contactFolders/') &&
            r.url.path.endsWith('/contacts') &&
            !r.url.queryParameters.containsKey(r'$select')) {
          renamed = true;
          h.graph.editFromOutlook(a.others.single, {
            'givenName': 'Bob',
            'displayName': 'Bob Cole',
          });
        }
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.before = null;
      final status = await h.status();
      expect(renamed, isTrue);
      expect(h.graph.contact(a.others.single), isNotNull);
      expect(status.copies.last!.people, 0);
      expect(status.copies.differing, isEmpty);
    });

    test("the merge's own replacements (a longer note) go to Gmail as its "
        'answers, never held by the change brake', () async {
      final people = [
        for (var i = 0; i < 11; i++)
          copiesOf('P$i', 'Fam$i', notes: 'Met at the fair.'),
      ];
      await h.firstSync();
      for (final p in people) {
        final x = await hadcoOf(p);
        h.graph.editFromOutlook(x.others.single, {
          'personalNotes': 'Met at the fair. Likes tea.',
        });
      }
      await h.later();
      // Each answer kept on the pair as soon as its write is done, before
      // the deletes.
      String? pendingAtDelete;
      h.before = (r) async {
        if (pendingAtDelete == null &&
            r.url.path.endsWith(r'$batch') &&
            r.body.contains('"method":"DELETE"')) {
          pendingAtDelete = (await h.pair()).held;
        }
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.before = null;
      expect(
        RegExp('useGraph').allMatches(pendingAtDelete!).length,
        11,
      );
      final status = await h.status();
      expect(status.halt, isNull);
      expect(status.questions, isEmpty);
      expect(status.copies.last!.people, 11);
      for (final p in people) {
        final bio = h.google.person(p.google)!['biographies']! as List;
        expect((bio.single as Map)['value'], 'Met at the fair. Likes tea.');
      }
    });

    test('passes that keep stopping short wait the usual hour, and after '
        'three the merge is given up, as its result says', () async {
      copiesOf('Ann', 'Cole');
      await h.firstSync();
      h.answer = (r) => photoCheck(r)
          ? http.Response(
              '{"error":{"code":"BadRequest","message":"x"}}',
              400,
              headers: {'content-type': 'application/json'},
            )
          : null;
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      var status = await h.status();
      expect(status.halt, isNull);
      expect(status.copies.asked, isTrue);
      expect(status.copies.shortStops, 1);
      // Not at every opening: the usual hour applies.
      h.pass(const Duration(minutes: 10));
      expect(await h.sync.startIfDue(), isFalse);
      for (var i = 2; i <= 3; i++) {
        h.pass(const Duration(hours: 1));
        expect(await h.sync.startIfDue(), isTrue);
        await h.sync.syncNow();
        expect((await h.status()).copies.shortStops, i == 3 ? 0 : i);
      }
      h.answer = null;
      status = await h.status();
      expect(status.copies.asked, isFalse);
      expect(status.copies.last!.stoppedShort, isTrue);
      expect(h.graph.count, 2);
    });

    test("a photo Graph did not keep fails its person: the copy with it "
        'stays', () async {
      final dan = copiesOf('Dan', 'Lee');
      await h.firstSync();
      final d = await hadcoOf(dan);
      h.graph.setPhotoFromOutlook(d.others.single, [1, 2, 3]);
      await h.later();
      h.answer = (r) => r.method == 'PUT' && r.url.path.endsWith(r'/$value')
          ? http.Response('', 200)
          : null;
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.answer = null;
      final status = await h.status();
      expect(h.graph.contact(d.others.single), isNotNull);
      expect(status.copies.last!.failed, 1);
      expect(status.copies.last!.people, 0);
    });

    test('a write Graph answers with other line breaks or spaces holds',
        () async {
      final ann = copiesOf('Ann', 'Cole', notes: 'Met at the fair.');
      await h.firstSync();
      final a = await hadcoOf(ann);
      h.graph.editFromOutlook(a.others.single, {
        'personalNotes': 'Met at the fair.\nLikes  tea.',
      });
      await h.later();
      h.reshape = (r, response) {
        if (r.method != 'PATCH' || r.url.pathSegments.last != a.synced) {
          return null;
        }
        final json = jsonDecode(response.body) as Map<String, Object?>;
        json['personalNotes'] =
            '${json['personalNotes']}'.replaceAll('\n', '\r\n  ');
        return http.Response(
          jsonEncode(json),
          200,
          headers: {'content-type': 'application/json'},
        );
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.reshape = null;
      final status = await h.status();
      expect(status.copies.last!.failed, 0);
      expect(status.copies.last!.people, 1);
      expect(h.graph.contact(a.others.single), isNull);
    });

    test("a merge's answer waiting while Gmail is out of reach is dropped "
        'once Ron edits that contact in Gmail: his newer edit stands',
        () async {
      String? gmailNotes(String name) {
        final bio = h.google.person(name)?['biographies'];
        if (bio is! List || bio.isEmpty) return null;
        return (bio.first as Map)['value'] as String?;
      }

      final ann = copiesOf('Ann', 'Cole', notes: 'Met at the fair.');
      await h.firstSync();
      final a = await hadcoOf(ann);
      h.graph.editFromOutlook(a.others.single, {
        'personalNotes': 'Met at the fair. Likes tea.',
      });
      await h.later();
      // Gmail goes out of reach as the merge deletes: the run after it
      // cannot carry the merge's answer out.
      h.before = (r) async {
        if (r.url.path.endsWith(r'$batch') &&
            r.body.contains('"method":"DELETE"')) {
          h.refusing.add(Harness.gmail.id);
        }
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.before = null;
      expect(gmailNotes(ann.google), 'Met at the fair.');
      expect((await h.pair()).held, contains('useGraph'));
      // Days later, Ron edits the note in Gmail.
      h.pass(const Duration(days: 2));
      h.google.editFromGmail(ann.google, {
        'biographies': [
          {
            'value': 'Met at the fair. Moved to Leeds.',
            'contentType': 'TEXT_PLAIN',
          },
        ],
      });
      h.refusing.clear();
      final status = await h.later();
      expect(status.halt, isNull);
      expect(gmailNotes(ann.google), 'Met at the fair. Moved to Leeds.');
      expect((await h.pair()).held, isNot(contains('useGraph')));
    });

    test('short stops count only the passes of a merge asked, and a new '
        'ask starts afresh', () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      copiesOf('Ann', 'Cole');
      await h.firstSync();
      final c = await hadcoOf(cat);
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Manager'});
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final listed = (await h.status()).copies.differing.single;
      http.Response? unread(http.Request r) => r.method == 'GET' &&
              [c.synced, ...c.others].contains(r.url.pathSegments.last)
          ? http.Response(
              '{"error":{"code":"x","message":"x"}}',
              503,
              headers: {'content-type': 'application/json'},
            )
          : null;
      // Ron answers; the runs for his answer cannot read Cat's copies.
      h.answer = unread;
      await h.sync.answerCopies(listed.key, c.others.single, listed.version);
      await h.sync.syncNow();
      for (var i = 0; i < 3; i++) {
        h.pass(const Duration(hours: 2));
        await h.sync.syncNow();
      }
      h.answer = null;
      var status = await h.status();
      expect(status.copies.shortStops, 0);
      expect(status.copies.differing.single.answer, c.others.single);

      // A merge asked anew starts its short stops afresh, whatever count
      // was left: its first pass that stops short is one, not a give-up.
      copiesOf('Dan', 'Lee');
      await h.later();
      expect((await h.status()).copies.differing, isEmpty);
      final pairId = (await h.pair()).pairId;
      await h.store.updatePair(pairId, (p) {
        final held = jsonDecode(p.held!) as Map<String, Object?>;
        (held['copies']! as Map)['shortStops'] = 2;
        return p.copyWith(held: jsonEncode(held));
      });
      expect((await h.status()).copies.shortStops, 2);
      h.answer = (r) => r.method == 'GET' &&
              r.url.path.contains('/contactFolders/') &&
              r.url.path.endsWith('/contacts') &&
              !r.url.queryParameters.containsKey(r'$select')
          ? http.Response(
              '{"error":{"code":"x","message":"x"}}',
              503,
              headers: {'content-type': 'application/json'},
            )
          : null;
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.answer = null;
      status = await h.status();
      expect(status.copies.asked, isTrue);
      expect(status.copies.shortStops, 1);
      expect(status.copies.last?.stoppedShort ?? false, isFalse);
    });

    test("the tablet's photos (3.22.1): copies with a photo each merge as "
        "the same, the synced copy's photo kept and none read; one without "
        "takes the first other copy's", () async {
      final people = [for (var i = 0; i < 3; i++) copiesOf('P$i', 'Fam$i')];
      final zed = copiesOf('Zed', 'Ray', copies: 3);
      await h.firstSync();
      final hadco = [for (final p in people) await hadcoOf(p)];
      for (final (i, x) in hadco.indexed) {
        h.graph.setPhotoFromOutlook(x.synced, [i, 1]);
        h.graph.setPhotoFromOutlook(x.others.single, [i, 2]);
      }
      // Zed's synced copy has none; both others have one.
      final z = await hadcoOf(zed);
      final byId = [...z.others]..sort();
      h.graph.setPhotoFromOutlook(byId.last, [9, 9]);
      h.graph.setPhotoFromOutlook(byId.first, [8, 8]);
      final status0 = await h.later();
      expect(status0.copies.people, 4);
      h.requests.clear();

      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.copies.differing, isEmpty);
      expect(status.copies.last!.people, 4);
      expect(status.copies.last!.differing, 0);
      for (final (i, x) in hadco.indexed) {
        expect(h.graph.photoOf(x.synced)!.bytes, [i, 1]);
        expect(h.graph.contact(x.others.single), isNull);
      }
      expect(h.graph.photoOf(z.synced)!.bytes, [8, 8]);
      for (final id in z.others) {
        expect(h.graph.contact(id), isNull);
      }
      // Only that one photo's bytes were read.
      expect(
        [
          for (final r in h.requests)
            if (r.method == 'GET' && r.url.path.endsWith(r'/$value'))
              r.url.pathSegments[r.url.pathSegments.length - 3],
        ],
        [byId.first],
      );
    });

    test("people 3.22.0 listed for their photos are hidden, counted to merge "
        "and merged; Keep these on another copy brings that copy's photo",
        () async {
      final eve = copiesOf('Eve', 'Moss');
      final fay = copiesOf('Fay', 'Gold');
      await h.firstSync();
      final e = await hadcoOf(eve);
      final f = await hadcoOf(fay);
      for (final x in [e, f]) {
        h.graph.setPhotoFromOutlook(x.synced, [1]);
        h.graph.setPhotoFromOutlook(x.others.single, [2]);
      }
      await h.later();
      // As 3.22.0 left them: listed for their photos, Fay answered.
      final pairId = (await h.pair()).pairId;
      await h.store.updatePair(pairId, (p) {
        final held = jsonDecode(p.held!) as Map<String, Object?>;
        final copies =
            (held['copies'] as Map<String, Object?>?) ?? <String, Object?>{};
        copies['differing'] = [
          for (final (x, title, answer) in [
            (e, 'Eve Moss', null),
            (f, 'Fay Gold', f.others.single),
          ])
            {
              'key': x.synced,
              'title': title,
              'fingerprint': '0' * 64,
              'answer': ?answer,
              'copies': [
                {
                  'key': x.synced,
                  'synced': true,
                  'details': [
                    {'label': 'Photo', 'value': 'a photo'},
                  ],
                },
                {
                  'key': x.others.single,
                  'details': [
                    {'label': 'Photo', 'value': 'another photo'},
                  ],
                },
              ],
            },
        ];
        held['copies'] = copies;
        return p.copyWith(held: jsonEncode(held));
      });

      // Eve, listed by 3.22.0 for her photos alone and not answered, is
      // not shown (her differences are no more); Fay, answered, is.
      expect(
        [for (final p in (await h.status()).copies.differing) p.title],
        ['Fay Gold'],
      );
      // The run for Fay's answer reads her copies again, under today's
      // rules: nothing differing, so her Keep these on the other copy
      // brings that copy's photo, and she is merged.
      var status = await h.later();
      expect(h.graph.contact(f.others.single), isNull);
      expect(h.graph.photoOf(f.synced)!.bytes, [2]);
      expect(status.copies.differing, isEmpty);
      // Eve is counted for the merge to offer.
      expect(status.copies.people, 1);
      expect(status.copies.extras, 1);

      await h.sync.mergeCopies();
      await h.sync.syncNow();
      status = await h.status();
      expect(status.copies.differing, isEmpty);
      expect(status.copies.people, 0);
      expect(h.graph.contact(e.others.single), isNull);
      expect(h.graph.photoOf(e.synced)!.bytes, [1]);
    });

    test('a person whose copies really differ, listed and not answered, '
        'is shown and not offered to merge again', () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      await h.firstSync();
      final c = await hadcoOf(cat);
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Manager'});
      expect((await h.later()).copies.people, 1);
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.copies.differing.single.title, 'Cat Fox');
      expect(status.copies.people, 0);
      expect(status.copies.extras, 0);
      // Nothing to merge: nothing asked.
      await h.sync.mergeCopies();
      expect((await h.status()).copies.asked, isFalse);
    });

    test('a person Ron left under 3.22.0 stays left, whatever a merge '
        'would say now', () async {
      final eve = copiesOf('Eve', 'Moss');
      copiesOf('Ann', 'Cole');
      await h.firstSync();
      final e = await hadcoOf(eve);
      h.graph.setPhotoFromOutlook(e.synced, [1]);
      h.graph.setPhotoFromOutlook(e.others.single, [2]);
      await h.later();
      final pairId = (await h.pair()).pairId;
      await h.store.updatePair(pairId, (p) {
        final held = jsonDecode(p.held!) as Map<String, Object?>;
        final copies =
            (held['copies'] as Map<String, Object?>?) ?? <String, Object?>{};
        copies['left'] = {e.synced: '0' * 64};
        held['copies'] = copies;
        return p.copyWith(held: jsonEncode(held));
      });
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.copies.last!.people, 1);
      expect(h.graph.contact(e.others.single), isNotNull);
      expect(status.copies.differing, isEmpty);
    });

    test('Leave them always stands: answered under 3.22.0 or since, the '
        'person is left until one of its copies changes', () async {
      final eve = copiesOf('Eve', 'Moss');
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      await h.firstSync();
      final e = await hadcoOf(eve);
      final c = await hadcoOf(cat);
      h.graph.setPhotoFromOutlook(e.synced, [1]);
      h.graph.setPhotoFromOutlook(e.others.single, [2]);
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Manager'});
      await h.later();
      // Eve: listed by 3.22.0 for her photos, Ron's Leave them given
      // before the update and not yet carried out.
      final pairId = (await h.pair()).pairId;
      await h.store.updatePair(pairId, (p) {
        final held = jsonDecode(p.held!) as Map<String, Object?>;
        final copies =
            (held['copies'] as Map<String, Object?>?) ?? <String, Object?>{};
        copies['differing'] = [
          {
            'key': e.synced,
            'title': 'Eve Moss',
            'fingerprint': '0' * 64,
            'answer': 'leave',
            'copies': [
              {
                'key': e.synced,
                'synced': true,
                'details': [
                  {'label': 'Photo', 'value': 'a photo'},
                ],
              },
              {
                'key': e.others.single,
                'details': [
                  {'label': 'Photo', 'value': 'another photo'},
                ],
              },
            ],
          },
        ];
        held['copies'] = copies;
        return p.copyWith(held: jsonEncode(held));
      });
      // The next run carries the leave out: never merged.
      var status = await h.later();
      expect(h.graph.contact(e.others.single), isNotNull);
      expect(status.copies.differing, isEmpty);
      // Cat: listed under the rules of now, Ron leaves her too.
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final listed = (await h.status()).copies.differing.single;
      expect(listed.title, 'Cat Fox');
      await h.sync.answerCopies(listed.key, null, listed.version);
      await h.sync.syncNow();
      status = await h.status();
      expect(status.copies.differing, isEmpty);
      // Merging again passes both over.
      copiesOf('Ann', 'Cole');
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      status = await h.status();
      expect(status.copies.last!.people, 1);
      expect(h.graph.contact(e.others.single), isNotNull);
      expect(h.graph.contact(c.others.single), isNotNull);
      expect(status.copies.differing, isEmpty);
      // Cat's copy changes: read again as any other, and listed again;
      // Eve's do not.
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Director'});
      copiesOf('Dan', 'Lee');
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      status = await h.status();
      expect([for (final p in status.copies.differing) p.title], [
        'Cat Fox',
      ]);
      expect(h.graph.contact(e.others.single), isNotNull);
    });

    test("Keep these on another copy, on today's listing, takes its details "
        "and never the photo: the synced copy's own stays", () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      await h.firstSync();
      final c = await hadcoOf(cat);
      h.graph.setPhotoFromOutlook(c.synced, [1]);
      h.graph.setPhotoFromOutlook(c.others.single, [2]);
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Manager'});
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final listed = (await h.status()).copies.differing.single;
      // Not a photo among what differs.
      expect(
        [
          for (final x in listed.copies)
            for (final d in x.details) d.label,
        ],
        ['Job title', 'Job title'],
      );
      h.requests.clear();
      await h.sync.answerCopies(listed.key, c.others.single, listed.version);
      await h.sync.syncNow();
      expect((await h.status()).copies.differing, isEmpty);
      expect(h.graph.contact(c.synced)!['jobTitle'], 'Manager');
      expect(h.graph.photoOf(c.synced)!.bytes, [1]);
      expect(h.graph.contact(c.others.single), isNull);
      // No photo read, nor given.
      expect(
        h.requests.where((r) => r.url.path.endsWith(r'/$value')),
        isEmpty,
      );
    });

    test('an answer on a 3.22.0 listing whose copies still differ is '
        'dropped, the person listed again as it is', () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      final dan = copiesOf('Dan', 'Lee', jobTitle: 'Buyer');
      await h.firstSync();
      final c = await hadcoOf(cat);
      final d = await hadcoOf(dan);
      for (final x in [c, d]) {
        h.graph.editFromOutlook(x.others.single, {'jobTitle': 'Manager'});
      }
      await h.later();
      // Listed by 3.22.0 (a fingerprint of its own): Cat answered with
      // the synced copy's, Dan with the other copy's.
      final pairId = (await h.pair()).pairId;
      await h.store.updatePair(pairId, (p) {
        final held = jsonDecode(p.held!) as Map<String, Object?>;
        final copies =
            (held['copies'] as Map<String, Object?>?) ?? <String, Object?>{};
        copies['differing'] = [
          for (final (x, title, answer) in [
            (c, 'Cat Fox', c.synced),
            (d, 'Dan Lee', d.others.single),
          ])
            {
              'key': x.synced,
              'title': title,
              'fingerprint': '0' * 64,
              'answer': answer,
              'copies': [
                {'key': x.synced, 'synced': true, 'details': <Object?>[]},
                {'key': x.others.single, 'details': <Object?>[]},
              ],
            },
        ];
        held['copies'] = copies;
        return p.copyWith(held: jsonEncode(held));
      });
      final status = await h.later();
      // Neither answer counts on differences Ron did not see: both listed
      // again under the rules of now, nothing written or deleted.
      expect(
        {for (final p in status.copies.differing) p.title: p.answer},
        {'Cat Fox': null, 'Dan Lee': null},
      );
      for (final x in [c, d]) {
        expect(h.graph.contact(x.synced)!['jobTitle'], 'Buyer');
        expect(h.graph.contact(x.others.single), isNotNull);
      }
    });

    test('photo checks: the synced copies first, then only the copies of '
        'one without a photo; a copy not checked never passes one with a '
        'photo over', () async {
      final ann = copiesOf('Ann', 'Cole');
      final bob = copiesOf('Bob', 'Ray');
      await h.firstSync();
      final a = await hadcoOf(ann);
      final b = await hadcoOf(bob);
      h.graph.setPhotoFromOutlook(a.synced, [1]);
      h.graph.setPhotoFromOutlook(a.others.single, [2]);
      h.graph.setPhotoFromOutlook(b.others.single, [3]);
      await h.later();
      h.requests.clear();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final checks = [
        for (final r in h.requests)
          if (r.url.path.endsWith(r'$batch') && r.body.contains('/photo'))
            {
              for (final part in (jsonDecode(r.body) as Map)['requests']
                  as List)
                Uri.parse('${(part as Map)['url']}').pathSegments[2],
            },
      ];
      expect(checks.first, {a.synced, b.synced});
      expect(checks[1], {b.others.single});
      final status = await h.status();
      expect(status.copies.last!.people, 2);
      expect(status.copies.last!.passedOver, 0);
      expect(h.graph.photoOf(a.synced)!.bytes, [1]);
      expect(h.graph.photoOf(b.synced)!.bytes, [3]);
    });

    test('a leave 3.22.0 kept is stamped with the differences of now by the '
        'first pass, and stays: an added detail never lifts it, a real '
        'difference lists the person for Ron', () async {
      final eve = copiesOf('Eve', 'Moss');
      copiesOf('Ann', 'Cole');
      await h.firstSync();
      final e = await hadcoOf(eve);
      h.graph.setPhotoFromOutlook(e.synced, [1]);
      h.graph.setPhotoFromOutlook(e.others.single, [2]);
      await h.later();
      final pairId = (await h.pair()).pairId;
      await h.store.updatePair(pairId, (p) {
        final held = jsonDecode(p.held!) as Map<String, Object?>;
        final copies =
            (held['copies'] as Map<String, Object?>?) ?? <String, Object?>{};
        copies['left'] = {e.synced: '0' * 64};
        held['copies'] = copies;
        return p.copyWith(held: jsonEncode(held));
      });
      // Ron adds an office to the other copy: an added detail.
      h.graph.editFromOutlook(e.others.single, {'officeLocation': 'B2'});
      var status = await h.later();
      // Never counted while left.
      expect(status.copies.people, 1);
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      status = await h.status();
      // Ann merged; Eve stamped with the differences of now (none), left.
      expect(status.copies.last!.people, 1);
      expect(h.graph.contact(e.others.single), isNotNull);
      expect(h.graph.contact(e.synced)!['officeLocation'], isNull);
      final left = ((jsonDecode((await h.pair()).held!) as Map)['copies']
          as Map)['left'] as Map;
      expect(left[e.synced], {'fingerprint': '', 'rules': 2});
      expect(status.copies.people, 0);
      // A real difference appears: the next pass lifts the leave and
      // lists Eve for Ron, nothing written or deleted.
      h.graph.editFromOutlook(e.others.single, {'jobTitle': 'Pilot'});
      h.graph.editFromOutlook(e.synced, {'jobTitle': 'Clerk'});
      copiesOf('Dan', 'Lee');
      status = await h.later();
      expect(status.copies.people, 1);
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      status = await h.status();
      expect([for (final p in status.copies.differing) p.title], [
        'Eve Moss',
      ]);
      expect(h.graph.contact(e.others.single), isNotNull);
      expect(h.graph.contact(e.synced)!['jobTitle'], 'Clerk');
    });

    test("a leave of today: the sync's own write to the synced copy never "
        'lifts it; the differences left gone, the person merges', () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      copiesOf('Ann', 'Cole');
      await h.firstSync();
      final c = await hadcoOf(cat);
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Manager'});
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      final listed = (await h.status()).copies.differing.single;
      await h.sync.answerCopies(listed.key, null, listed.version);
      await h.sync.syncNow();
      expect((await h.status()).copies.differing, isEmpty);
      // Ron gives Cat a nickname in Gmail; the sync writes it to Hadco.
      h.google.editFromGmail(cat.google, {
        'nicknames': [
          {'value': 'Kit'},
        ],
      });
      var status = await h.later();
      expect(h.graph.contact(c.synced)!['nickName'], 'Kit');
      expect(status.copies.people, 0);
      // A merge asked for another passes Cat over: still the differences
      // Ron left.
      copiesOf('Dan', 'Lee');
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      status = await h.status();
      expect(status.copies.last!.people, 1);
      expect(status.copies.differing, isEmpty);
      expect(h.graph.contact(c.others.single), isNotNull);
      // Ron makes the other copy's job title the synced one's: the
      // difference he left is gone, and the next pass merges Cat.
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Buyer'});
      copiesOf('Eve', 'Moss');
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      status = await h.status();
      expect(status.copies.last!.people, 2);
      expect(h.graph.contact(c.others.single), isNull);
      expect(status.copies.differing, isEmpty);
    });

    test('an answer on a 3.22.0 listing that showed no photo brings no '
        'photo', () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      await h.firstSync();
      final c = await hadcoOf(cat);
      h.graph.setPhotoFromOutlook(c.synced, [1]);
      h.graph.setPhotoFromOutlook(c.others.single, [2]);
      await h.later();
      // Listed by 3.22.0 for the job title alone (since made the same),
      // answered with the other copy's.
      final pairId = (await h.pair()).pairId;
      await h.store.updatePair(pairId, (p) {
        final held = jsonDecode(p.held!) as Map<String, Object?>;
        final copies =
            (held['copies'] as Map<String, Object?>?) ?? <String, Object?>{};
        copies['differing'] = [
          {
            'key': c.synced,
            'title': 'Cat Fox',
            'fingerprint': '0' * 64,
            'answer': c.others.single,
            'copies': [
              {
                'key': c.synced,
                'synced': true,
                'details': [
                  {'label': 'Job title', 'value': 'Buyer'},
                ],
              },
              {
                'key': c.others.single,
                'details': [
                  {'label': 'Job title', 'value': 'Manager'},
                ],
              },
            ],
          },
        ];
        held['copies'] = copies;
        return p.copyWith(held: jsonEncode(held));
      });
      await h.later();
      expect(h.graph.contact(c.others.single), isNull);
      expect(h.graph.photoOf(c.synced)!.bytes, [1]);
    });

    test('a person no longer listed, or a copy not its own, is refused',
        () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      await h.firstSync();
      final c = await hadcoOf(cat);
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Manager'});
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      await expectLater(
        h.sync.answerCopies('no-such-person', null, ''),
        throwsA(isA<ContactSyncRefused>()),
      );
      await expectLater(
        h.sync.answerCopies(
          c.synced,
          'no-such-copy',
          await versionOf(c.synced),
        ),
        throwsA(isA<ContactSyncRefused>()),
      );
      // Differences other than those listed: refused, so an answer never
      // lands on what Ron did not see.
      expect(await versionOf(c.synced), isNotEmpty);
      await expectLater(
        h.sync.answerCopies(c.synced, c.others.single, 'not this one'),
        throwsA(isA<ContactSyncRefused>()),
      );
      expect((await h.status()).copies.differing.single.answer, isNull);
    });

    test('Leave them takes the person off the list, and later merges pass '
        'it over until its copies change', () async {
      final cat = copiesOf('Cat', 'Fox', jobTitle: 'Buyer');
      await h.firstSync();
      final c = await hadcoOf(cat);
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Manager'});
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.refusing.add(Harness.hadco.id);
      await h.sync.answerCopies(c.synced, null, await versionOf(c.synced));
      await h.sync.syncNow();
      expect(
        (await h.status()).copies.differing.single.answer,
        ContactSyncCopiesPerson.leave,
      );
      h.refusing.clear();
      await h.sync.syncNow();
      var status = await h.status();
      expect(status.copies.differing, isEmpty);
      expect(status.copies.people, 0);
      expect(h.graph.contact(c.others.single), isNotNull);

      // Another person's copies to merge: Cat's are passed over.
      copiesOf('Ann', 'Cole');
      status = await h.later();
      expect(status.copies.people, 1);
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      status = await h.status();
      expect(status.copies.differing, isEmpty);
      expect(status.copies.last!.people, 1);
      expect(h.graph.contact(c.others.single), isNotNull);

      // Cat's copy changes: the next merge lists Cat again.
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Director'});
      copiesOf('Dan', 'Lee');
      await h.later();
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      status = await h.status();
      expect(status.copies.differing.single.title, 'Cat Fox');
      expect(h.graph.contact(c.others.single), isNotNull);
    });

    test('a merge stopped part way carries on at the next run, the ask kept '
        'until every person is dealt with', () async {
      for (var i = 0; i < 30; i++) {
        copiesOf('P$i', 'Fam$i');
      }
      await h.firstSync();
      expect((await h.status()).copies.people, 30);
      var stopped = false;
      h.before = (r) async {
        if (!stopped &&
            r.url.path.endsWith(r'$batch') &&
            r.body.contains('"method":"DELETE"')) {
          stopped = true;
          unawaited(h.sync.stop());
        }
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.before = null;
      var status = await h.status();
      expect(status.halt!.kind, ContactSyncHaltKind.putAway);
      expect(status.copies.asked, isTrue);
      expect(status.copies.last, isNull);
      // A batch of twenty went, and what was queued before the stop.
      expect(h.graph.count, inInclusiveRange(30, 40));
      expect(status.graphCount, h.graph.count);

      status = await h.later();
      expect(status.halt, isNull);
      expect(status.copies.asked, isFalse);
      expect(status.copies.last!.people, 30);
      expect(status.copies.last!.deleted, 30);
      expect(h.graph.count, 30);
      expect(status.copies.people, 0);
    });

    test('a write that is refused, or does not hold, fails that person: '
        'nothing of theirs is deleted, and the others go on', () async {
      final ann = copiesOf('Ann', 'Cole');
      final bob = copiesOf('Bob', 'Ray');
      final cat = copiesOf('Cat', 'Fox');
      await h.firstSync();
      final a = await hadcoOf(ann);
      final b = await hadcoOf(bob);
      final c = await hadcoOf(cat);
      h.graph.editFromOutlook(b.others.single, {'jobTitle': 'Chief'});
      h.graph.editFromOutlook(c.others.single, {'jobTitle': 'Clerk'});
      await h.later();
      // Bob's write refused; Cat's answered without what was written.
      h.answer = (r) => r.method == 'PATCH' &&
              r.url.pathSegments.last == b.synced
          ? http.Response(
              '{"error":{"code":"ErrorInvalidProperty","message":"x"}}',
              400,
              headers: {'content-type': 'application/json'},
            )
          : null;
      h.reshape = (r, response) {
        if (r.method != 'PATCH' || r.url.pathSegments.last != c.synced) {
          return null;
        }
        final json = jsonDecode(response.body) as Map<String, Object?>
          ..remove('jobTitle');
        return http.Response(
          jsonEncode(json),
          200,
          headers: {'content-type': 'application/json'},
        );
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.answer = null;
      h.reshape = null;
      final status = await h.status();
      expect(status.halt, isNull);
      expect(status.copies.asked, isFalse);
      expect(status.copies.last!.people, 1);
      expect(status.copies.last!.failed, 2);
      expect(h.graph.contact(a.others.single), isNull);
      expect(h.graph.contact(b.others.single), isNotNull);
      expect(h.graph.contact(b.synced)!['jobTitle'], isNull);
      expect(h.graph.contact(c.others.single), isNotNull);
      // Still to merge, for another try.
      expect(status.copies.people, 2);
    });

    test("the drop in Hadco's count does not trip the empty-answers guard "
        'at the next listing of Hadco whole', () async {
      for (var i = 0; i < 4; i++) {
        copiesOf('P$i', 'Fam$i', copies: 3);
      }
      await h.firstSync();
      expect(h.graph.count, 12);
      h.after = (r) {
        if (r.url.path.endsWith(r'$batch') &&
            r.body.contains('"method":"DELETE"')) {
          h.graph.expireDeltaLinks();
        }
      };
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      h.after = null;
      final status = await h.status();
      expect(status.halt, isNull);
      expect(h.graph.count, 4);
      expect(status.graphCount, 4);
      expect(status.copies.last!.deleted, 8);
    });

    test('Merge does nothing before the first sync is done, nor with nothing '
        'to merge', () async {
      copiesOf('Ann', 'Cole');
      await h.choose();
      // Even were copies counted already.
      await h.store.updatePair(
        (await h.pair()).pairId,
        (p) => p.copyWith(
          held: jsonEncode({
            'copies': {'people': 1, 'extras': 1},
          }),
        ),
      );
      await h.sync.mergeCopies();
      expect((await h.status()).copies.asked, isFalse);
      await h.sync.start();
      final hadco = h.graph.count;
      await h.sync.mergeCopies();
      await h.sync.syncNow();
      expect(h.graph.count, hadco - 1);
      // Nothing left to merge: nothing asked.
      await h.sync.mergeCopies();
      expect((await h.status()).copies.asked, isFalse);
    });
  });

  group('privacy', () {
    test('a run logs no name, address or number', () async {
      final logged = <String>[];
      final was = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) =>
          logged.add(message ?? '');
      addTearDown(() => debugPrint = was);

      final z = h.google.seed(
        person(
          'Zebulon',
          'Quixley',
          email: 'zq.private@example.org',
          mobile: '+1 202 555 0199',
          company: 'Velvetine Holdings',
          street: '742 Evergreen Terrace',
        ),
      );
      h.graph.seed(
        outlook(
          'Philippa',
          'Ostrander',
          email: 'pho.secret@example.net',
          mobile: '+1 303 555 0142',
          company: 'Marrowby Partners',
        ),
      );
      h.graph.seed(
        outlook('Refusa', 'Blockwell', email: 'rb.hidden@example.com'),
      );
      h.google.refuse = (p) => '${p['names']}'.contains('Refusa');
      await h.firstSync();
      h.google.editFromGmail(z, {
        'phoneNumbers': [
          {'value': '+1 202 555 0123', 'type': 'mobile'},
        ],
      });
      await h.later();
      h.google.deleteFromGmail(z);
      await h.later();

      expect(logged, isNotEmpty);
      final all = logged.join('\n');
      for (final secret in [
        'Zebulon',
        'Quixley',
        'zq.private',
        '555 0199',
        '5550199',
        '0123',
        'Velvetine',
        'Evergreen',
        'Philippa',
        'Ostrander',
        'pho.secret',
        '555 0142',
        'Marrowby',
        'Refusa',
        'Blockwell',
        'rb.hidden',
      ]) {
        expect(all, isNot(contains(secret)), reason: secret);
      }
    });
  });
}

extension on Harness {
  List<http.Request> contactWritesOf() => contactWrites;

  List<http.Request> requestsTo(String suffix) => [
    for (final r in requests)
      if (r.url.path.endsWith(suffix)) r,
  ];
}

extension on Account {
  Account copyWithAuth(AuthMethod method) => Account(
    id: id,
    displayName: displayName,
    emailAddress: emailAddress,
    provider: provider,
    authMethod: method,
    colorValue: colorValue,
  );
}

class _Refresher implements OAuthRefresher {
  Exception? refuse;

  @override
  Future<OAuthToken> refresh(OAuthToken token, {List<String>? scopes}) async {
    final refusal = refuse;
    if (refusal != null) throw refusal;
    return OAuthToken(
      accessToken: 'fresh',
      refreshToken: token.refreshToken,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
  }

  @override
  void close() {}
}
