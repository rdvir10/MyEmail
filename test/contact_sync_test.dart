import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart'
    show SignInNeedsConsent;
import 'package:myemail/data/contacts/contact_sync.dart';
import 'package:myemail/data/contacts/contact_sync_service.dart';
import 'package:myemail/data/contacts/contact_sync_store.dart';
import 'package:myemail/domain/account.dart';

import 'fakes/fake_google_people.dart';
import 'fakes/fake_graph_contacts.dart';

/// Contact sync end to end: the runner against both fake servers and the
/// Memory store, as the phone would run it, a run at a time.
class Harness {
  Harness({bool lagWrites = false}) {
    google.lagWrites = lagWrites;
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
  late final store = MemoryContactSyncStore(clock: () => _now);

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

  /// Every request, both servers.
  final requests = <http.Request>[];

  /// Called with each request before it is answered: a test's way to stop
  /// a run part way.
  Future<void> Function(http.Request request)? before;

  String device = 'phone';

  late ContactSync sync = make();

  ContactSync make({String? deviceName}) => ContactSync(
    store: store,
    accounts: () => accounts,
    accessToken: (String id, {bool force = false, List<String>? scopes}) async {
      if (refusing.contains(id)) {
        throw const SignInNeedsConsent('Contacts not allowed.');
      }
      return 'token-$id';
    },
    deviceId: () async => deviceName ?? device,
    region: () => 'US',
    httpClient: MockClient((request) async {
      requests.add(request);
      await before?.call(request);
      return request.url.host == 'people.googleapis.com'
          ? google.handle(request)
          : graph.handle(request);
    }),
    sleep: (_) async {},
    clock: () => _now,
  );

  Future<void> choose() => sync.choose(
    googleAccountId: gmail.id,
    graphAccountId: hadco.id,
  );

  /// Choose the accounts and run the first sync to its end.
  Future<void> firstSync() async {
    await choose();
    await sync.start();
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

  Future<ContactSyncHalt?> halt() async => (await status()).halt;

  /// Wait for the runs an answer started.
  Future<void> settle() async {
    for (var i = 0; i < 50 && sync.isRunning; i++) {
      await Future<void>.delayed(Duration.zero);
      await sync.syncNow();
    }
  }
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

String? firstEmail(Map<String, Object?>? contact) {
  final emails = contact?['emailAddresses'];
  if (emails is! List || emails.isEmpty) return null;
  final e = emails.first as Map;
  return (e['value'] ?? e['address']) as String?;
}

void main() {
  late Harness h;

  setUp(() => h = Harness());

  group('the first sync', () {
    test('copies each side to the other and pairs those in both', () async {
      h.google.seed(person('Ann', 'Lee', email: 'ann@example.com'));
      h.google.seed(person('Bob', 'Ray', email: 'bob@example.com'));
      h.graph.seed(outlook('Bob', 'Ray', email: 'bob@example.com'));
      h.graph.seed(outlook('Cy', 'Day', email: 'cy@example.com'));

      final preview = await (await (() async {
        await h.choose();
        return h.sync;
      })()).preview();
      expect(preview.addToGraph, 1);
      expect(preview.addToGoogle, 1);
      expect(preview.pairUp, 1);
      expect(preview.deletions, 0);
      // The preview writes nothing.
      expect(h.graph.count, 2);
      expect(h.google.count, 2);

      await h.sync.start();
      final status = await h.status();
      expect(status.halt, isNull);
      expect(status.firstDone, isTrue);
      expect(status.last!.addedToGraph, 1);
      expect(status.last!.addedToGoogle, 1);
      expect(h.graph.count, 3);
      expect(h.google.count, 3);
      expect(await h.paired(), hasLength(3));
      expect(h.graph.idWithEmail('ann@example.com'), isNotNull);
      expect(h.google.nameWithEmail('cy@example.com'), isNotNull);
      // Each copy carries the hidden tag naming its source.
      final ann = h.google.nameWithEmail('ann@example.com')!;
      expect(h.graph.tagOf(h.graph.idWithEmail('ann@example.com')!), ann);
      // The claim says this device syncs.
      expect(h.graph.claim, startsWith('phone '));
      expect(status.googleCount, 3);
      expect(status.graphCount, 3);
    });

    test('a second run finds nothing to do: its own writes are echoes',
        () async {
      h.google.seed(person('Ann', 'Lee', email: 'ann@example.com'));
      h.graph.seed(outlook('Cy', 'Day', email: 'cy@example.com'));
      await h.firstSync();
      h.pass(const Duration(hours: 2));
      h.requests.clear();
      await h.sync.syncNow();
      final status = await h.status();
      expect(status.halt, isNull);
      expect(status.last!.added + status.last!.changed, 0);
      expect(status.last!.deleted, 0);
      expect(status.needsALook, isEmpty);
      expect(
        h.requests.where((r) => r.method != 'GET' && !r.url.path.contains('contactFolders')),
        isEmpty,
      );
    });
  });
}
