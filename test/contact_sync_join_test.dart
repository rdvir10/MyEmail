import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/contacts/contact_mapping.dart';
import 'package:myemail/data/contacts/contact_sync_planner.dart';
import 'package:myemail/data/contacts/google_contacts_api.dart';
import 'package:myemail/data/graph/graph_contacts_api.dart';
import 'package:myemail/domain/synced_contact.dart';

import 'fakes/fake_google_people.dart';
import 'fakes/fake_graph_contacts.dart';

/// Where contact sync's parts meet: what the wire clients write and read,
/// through the fake servers, against what the mapping builds and reads.
/// Each part has its own tests; these are for the seams between them,
/// where each side can be right by itself and the two still miss.
void main() {
  late FakeGooglePeople google;
  late FakeGraphContacts graph;
  late GoogleContactsApi gmail;
  late GraphContactsApi outlook;

  setUp(() {
    google = FakeGooglePeople();
    graph = FakeGraphContacts();
    gmail = GoogleContactsApi(
      accessToken: ({bool force = false}) async => 'token',
      httpClient: google.client,
      sleep: (_) async {},
    );
    outlook = GraphContactsApi(
      accessToken: ({bool force = false}) async => 'token',
      httpClient: graph.client,
      sleep: (_) async {},
    );
  });

  final ann = SyncedContact({
    ContactField.name: ContactName.of(given: 'Ann', family: 'Lee'),
    ContactField.emails: ['ann@example.com'],
    ContactField.company: 'Acme',
  });

  Future<String?> outlookTag(String id) async =>
      GraphContact.fromJson((await outlook.get(id, withTag: true))!).tag;

  group('the hidden tag', () {
    test('an Outlook contact the client makes carries the tag the mapping '
        'reads', () async {
      // One property id, the mapping's: were the client to write the tag
      // under another, every contact the sync made would read as untagged
      // and could be copied back as new.
      final made = await outlook.create(graphCreateBody(ann), tag: 'people/c1');
      final one = made['id']! as String;
      expect(await outlookTag(one), 'people/c1');

      final batch = await outlook.createBatch([
        (contact: graphCreateBody(ann), tag: 'people/c2'),
      ]);
      final two = batch.single.contact!['id']! as String;
      expect(await outlookTag(two), 'people/c2');

      // After a Gmail re-key, the mapping's patch moves it, sent as an
      // update by the client.
      await outlook.update(one, graphTagPatch('people/c9'));
      expect(await outlookTag(one), 'people/c9');
      expect(graph.tagOf(one), 'people/c9');

      final found = await outlook.findByEmail('ann@example.com');
      expect({for (final c in found) GraphContact.fromJson(c).tag}, {
        'people/c9',
        'people/c2',
      });
    });

    test('a Gmail contact the client makes carries the tag the mapping '
        'reads', () async {
      final made = await gmail.create(googleCreateBody(ann), tag: 'AAMk-1');
      expect(GoogleContact.fromPerson(made).tag, 'AAMk-1');
      final name = made['resourceName']! as String;
      expect(GoogleContact.fromPerson((await gmail.get(name))!).tag, 'AAMk-1');
      expect(google.tagOf(name), 'AAMk-1');

      final batch = await gmail.createBatch([
        (person: googleCreateBody(ann), tag: 'AAMk-2'),
      ]);
      expect(GoogleContact.fromPerson(batch.single.contact!).tag, 'AAMk-2');
    });

    test('the mapping builds no tag: a create or a Restore carries the '
        "client's one alone", () async {
      expect(graphCreateBody(ann).containsKey('singleValueExtendedProperties'),
          isFalse);
      expect(googleCreateBody(ann).containsKey('clientData'), isFalse);

      final old = await outlook.create(graphCreateBody(ann), tag: 'people/c1');
      final whole = (await outlook.get(
        old['id']! as String,
        whole: true,
        withTag: true,
      ))!;
      final back = await outlook.create(
        graphRestoreBody(whole),
        tag: 'people/c5',
      );
      expect(await outlookTag(back['id']! as String), 'people/c5');
      expect(graph.tagOf(back['id']! as String), 'people/c5');

      final made = await gmail.create(googleCreateBody(ann), tag: 'AAMk-1');
      final read = (await gmail.get(
        made['resourceName']! as String,
        everyField: true,
      ))!;
      final again = await gmail.create(googleRestoreBody(read), tag: 'AAMk-5');
      expect([
        for (final e in again['clientData']! as List)
          if ((e as Map)['key'] == googleLinkKey) e['value'],
      ], ['AAMk-5']);
      expect(GoogleContact.fromPerson(again).tag, 'AAMk-5');
    });

    test('the device claim is written and read under the mapping\'s id',
        () async {
      final at = DateTime.utc(2026, 11, 21, 8);
      await outlook.writeClaim(
        FakeGraphContacts.mainFolderId,
        device: 'phone-1',
        at: at,
      );

      expect(graph.claim, isNotNull);
      expect(
        await outlook.readClaim(FakeGraphContacts.mainFolderId),
        GraphDeviceClaim(device: 'phone-1', at: at),
      );
    });
  });

  group('the field lists', () {
    test("Outlook's select holds every property the mapping reads", () {
      // A synced property missing from it would leave every contact read
      // as partial, passed over by the planner, never synced.
      final select = graphContactSelect.split(',').toSet();
      expect(select, containsAll(graphSyncedProperties));
      expect(select, containsAll(
          ['id', 'changeKey', 'parentFolderId', 'lastModifiedDateTime']));
    });

    test("Gmail's mask holds every Person field the mapping reads", () {
      final mask = googleContactFields.split(',').toSet();
      for (final f in ContactField.values) {
        expect(mask, contains(googlePersonField(f)), reason: f.name);
      }
      expect(mask, containsAll(['clientData', 'memberships', 'metadata']));
      expect(googleEveryField.split(',').toSet(), containsAll(mask));
    });

    test('a contact the delta lists reads whole, and its write is taken',
        () async {
      final id = graph.seed({
        'givenName': 'Ann',
        'surname': 'Lee',
        'emailAddresses': [
          {'address': 'ann@example.com', 'name': 'Ann Lee'},
        ],
      });
      final delta = await outlook.delta(
        folderId: FakeGraphContacts.mainFolderId,
      );
      final listed = GraphContact.fromJson(delta.contacts.single);
      expect(listed.readWhole, isTrue);

      final write = ContactWrite(
        side: ContactSide.graph,
        fields: {ContactField.company},
        target: listed.details.withValue(ContactField.company, 'Acme'),
        version: listed.changeKey,
        seen: listed.details,
      );
      final answer = await outlook.update(
        id,
        write.graphPatch((await outlook.get(id))!),
      );

      expect(syncedFromGraph(answer)[ContactField.company], 'Acme');
    });

    test('a Gmail write built from the read just before it is taken by '
        'updateContact', () async {
      // The update body is the Person as the client read it, rebuilt: it
      // carries metadata.sources with the contact source's etag, which is
      // what Google checks.
      final name = google.seed({
        'names': [
          {'givenName': 'Ann', 'familyName': 'Lee'},
        ],
        'emailAddresses': [
          {'value': 'ann@example.com'},
        ],
      });
      final listed = GoogleContact.fromPerson(
        (await gmail.listAll()).people.single,
      );

      final write = ContactWrite(
        side: ContactSide.google,
        fields: {ContactField.company},
        target: listed.details.withValue(ContactField.company, 'Acme'),
        version: listed.etag,
        seen: listed.details,
      );
      final update = write.googleUpdate(
        (await gmail.get(name))!,
        normaliser: ContactNormaliser(region: 'US'),
      );
      final answer = await gmail.update(
        name,
        update.person,
        fields: update.updatePersonFields,
      );

      expect(syncedFromPerson(answer)[ContactField.company], 'Acme');
    });
  });

  group('a re-key inside the JSON kept beside the rows', () {
    // The store's re-key runs rekeyContactJson over what the planner's
    // items wrote: these pin it to their keys.
    String review({
      ContactSide subject = ContactSide.graph,
      String? googleName,
      String? graphId = 'AAMk-9',
      List<String> candidates = const ['people/c1', 'people/c2'],
    }) => jsonEncode(ContactReviewItem(
      kind: ContactReviewKind.newContact,
      reason: ContactReviewReason.severalMatches,
      subjectSide: subject,
      googleName: googleName,
      graphId: graphId,
      candidates: candidates,
      candidateTitles: [for (final c in candidates) 'title of $c'],
      title: 'Ann Lee',
    ).toJson());

    test("reaches a review's subject and its candidates on the other side",
        () {
      final moved = jsonDecode(rekeyContactJson(
        review(),
        ContactSide.google,
        'people/c1',
        'people/c7',
      )!) as Map;
      expect(moved['candidates'], ['people/c7', 'people/c2']);
      expect(moved['candidateTitles'], [
        'title of people/c1',
        'title of people/c2',
      ]);

      final subject = jsonDecode(rekeyContactJson(
        review(subject: ContactSide.google, googleName: 'people/c1',
            graphId: null, candidates: ['AAMk-1']),
        ContactSide.google,
        'people/c1',
        'people/c7',
      )!) as Map;
      expect(subject['googleName'], 'people/c7');
      expect(subject['candidates'], ['AAMk-1']);
    });

    test('leaves the other side alone, and what names nothing as it was',
        () {
      // Candidates of a Gmail contact are Outlook ids: a Gmail re-key
      // never reaches them, even one spelt the same.
      final gmailSubject = review(
        subject: ContactSide.google,
        googleName: 'people/c5',
        graphId: null,
        candidates: ['people/c1'],
      );
      expect(
        rekeyContactJson(
            gmailSubject, ContactSide.google, 'people/c1', 'people/c7'),
        same(gmailSubject),
      );
      final graphNamed = review(graphId: 'people/c1');
      expect(
        jsonDecode(rekeyContactJson(
          graphNamed, ContactSide.google, 'people/c1', 'people/c7',
        )!)['graphId'],
        'people/c1',
      );
      expect(rekeyContactJson(null, ContactSide.google, 'a', 'b'), isNull);
      expect(
        rekeyContactJson('not json', ContactSide.google, 'a', 'b'),
        'not json',
      );
    });

    test("reaches a brake's items at any depth", () {
      final held = jsonEncode({
        'questions': [
          {
            'kind': 'deletions',
            'items': [
              const ContactBrakeItem(
                title: 'Ann Lee',
                side: ContactSide.google,
                graphId: 'AAMk-1',
              ).toJson(),
            ],
          },
        ],
      });

      final moved = rekeyContactJson(
        held,
        ContactSide.graph,
        'AAMk-1',
        'AAMk-2',
      )!;

      expect(moved, held.replaceAll('AAMk-1', 'AAMk-2'));
    });

    test('two candidates merged into one are one candidate', () {
      final moved = jsonDecode(rekeyContactJson(
        review(candidates: ['people/c1', 'people/c2', 'people/c3']),
        ContactSide.google,
        'people/c1',
        'people/c3',
      )!) as Map;

      expect(moved['candidates'], ['people/c3', 'people/c2']);
      expect(moved['candidateTitles'], [
        'title of people/c1',
        'title of people/c2',
      ]);
    });
  });

  group("the fake Graph's switch for empty properties", () {
    test('an entry it leaves them out of is not read whole', () async {
      // For the runner's tests: an entry Graph sends without a selected
      // property is passed over by the planner, never read as cleared.
      final id = graph.seed({
        'givenName': 'Ann',
        'surname': 'Lee',
        'emailAddresses': [
          {'address': 'ann@example.com', 'name': 'Ann Lee'},
        ],
      });
      expect(GraphContact.fromJson((await outlook.get(id))!).readWhole, isTrue);

      graph.leaveOutEmpty = true;
      final got = (await outlook.get(id))!;
      expect(got['givenName'], 'Ann');
      expect(got.keys, isNot(contains('nickName')));
      expect(got.keys, isNot(contains('homeAddress')));
      expect(got.keys, isNot(contains('homePhones')));
      final read = GraphContact.fromJson(got);
      expect(read.readWhole, isFalse);
      expect(
        read.missing,
        containsAll(['nickName', 'homeAddress', 'homePhones']),
      );
      expect(read.missing, isNot(contains('givenName')));

      final delta = await outlook.delta(
        folderId: FakeGraphContacts.mainFolderId,
      );
      expect(GraphContact.fromJson(delta.contacts.single).readWhole, isFalse);
      final listed = await outlook.listAll();
      expect(listed.single.keys, isNot(contains('nickName')));

      final whole = (await outlook.get(id, whole: true))!;
      expect(whole.keys, contains('nickName'),
          reason: 'a read of every property is as before');
    });
  });
}
