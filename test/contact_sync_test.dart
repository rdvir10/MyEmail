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
