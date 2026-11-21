import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/contacts/contact_mapping.dart';
import 'package:myemail/data/contacts/contact_sync_planner.dart';
import 'package:myemail/domain/synced_contact.dart';

/// The contact sync's planner: matching, merging, clashes, deletions and
/// the brakes, as the plan's "Pairing contacts" to "The brakes" set out.
void main() {
  final now = DateTime.utc(2026, 11, 20, 12);
  final earlier = now.subtract(const Duration(hours: 3));
  final later = now.subtract(const Duration(hours: 1));
  final norm = ContactNormaliser(region: 'US');

  SyncedContact person({
    String? given,
    String? family,
    List<String>? emails,
    String? mobile,
    Map<ContactField, Object?> more = const {},
  }) => SyncedContact({
    ContactField.name: ContactName.of(given: given, family: family),
    ContactField.emails: emails,
    ContactField.mobile: mobile,
    ...more,
  });

  GoogleContact g(
    String name,
    SyncedContact details, {
    String? etag,
    DateTime? at,
    String? tag,
    List<String> previous = const [],
  }) => GoogleContact(
    resourceName: name,
    details: details,
    etag: etag ?? 'etag-$name',
    updatedAt: at,
    tag: tag,
    previousNames: previous,
    person: {
      'resourceName': name,
      'metadata': {
        'sources': [
          {'type': 'CONTACT', 'id': name, 'etag': etag ?? 'etag-$name'},
        ],
      },
    },
  );

  GoogleContact gDeleted(String name) => GoogleContact(
    resourceName: name,
    details: SyncedContact.empty,
    deleted: true,
  );

  GraphContact h(
    String id,
    SyncedContact details, {
    String? key,
    DateTime? at,
    String? tag,
  }) => GraphContact(
    id: id,
    details: details,
    changeKey: key ?? 'key-$id',
    updatedAt: at,
    tag: tag,
    json: {'id': id},
  );

  ContactLinkInput link(
    int id,
    String? googleName,
    String? graphId, {
    SyncedContact? base,
    SyncedContact? googleBase,
    SyncedContact? graphBase,
    String? etag,
    String? key,
    ContactLinkState state = ContactLinkState.paired,
    ContactHeldReason? reason,
    DateTime? writtenAt,
  }) => ContactLinkInput(
    linkId: id,
    googleName: googleName,
    graphId: graphId,
    googleEtag: googleName == null ? null : etag ?? 'etag-$googleName',
    graphChangeKey: graphId == null ? null : key ?? 'key-$graphId',
    googleBase: googleName == null ? null : (googleBase ?? base)?.toJson(),
    graphBase: graphId == null ? null : (graphBase ?? base)?.toJson(),
    state: state,
    reason: reason,
    googleWrittenAt: writtenAt,
  );

  ContactSyncPlan run({
    List<GoogleContact> google = const [],
    List<GraphContact> graph = const [],
    bool googleComplete = false,
    bool graphComplete = false,
    List<ContactLinkInput> links = const [],
    bool firstSync = false,
    Set<String> googleGone = const {},
    Set<String> graphGone = const {},
    Set<String> graphMovedOut = const {},
    Map<String, String> googleReKeys = const {},
    List<ContactJournalEntry> journal = const [],
    List<ContactBinInput> bin = const [],
    List<ContactAnswer> answers = const [],
    int? expectedGoogle,
    int? expectedGraph,
  }) => planContactSync(
    ContactSyncInput(
      google: google,
      graph: graph,
      googleComplete: googleComplete,
      graphComplete: graphComplete,
      links: links,
      firstSync: firstSync,
      googleGone: googleGone,
      graphGone: graphGone,
      graphMovedOut: graphMovedOut,
      googleReKeys: googleReKeys,
      journal: journal,
      bin: bin,
      answers: answers,
      expectedGoogle: expectedGoogle,
      expectedGraph: expectedGraph,
      phoneRegion: 'US',
      now: now,
    ),
  );

  ContactLinkPlan? byGoogle(ContactSyncPlan plan, String name) =>
      plan.links.where((l) => l.googleName == name).firstOrNull;
  ContactLinkPlan? byGraph(ContactSyncPlan plan, String id) =>
      plan.links.where((l) => l.graphId == id).firstOrNull;
  ContactLinkPlan? byLink(ContactSyncPlan plan, int id) =>
      plan.links.where((l) => l.linkId == id).firstOrNull;

  final ann = person(given: 'Ann', family: 'Cole', emails: ['ann@x.example']);

  group('matching new contacts', () {
    test('a tag naming a contact on the other side pairs them', () {
      final plan = run(
        google: [
          g('people/c1', person(given: 'Ann', family: 'Cole'), tag: 'H1'),
        ],
        graph: [h('H1', person(given: 'Annie', family: 'Smith'))],
      );
      final pair = byGoogle(plan, 'people/c1')!;
      expect(pair.graphId, 'H1');
      expect(pair.state, ContactLinkState.paired);
      expect(pair.newPair, isTrue);
      expect(pair.create, isNull);
      expect(plan.counts.pairUp, 1);
      expect(plan.counts.addToGraph, 0);
    });

    test('a tag naming a contact already paired waits under Needs a look', () {
      final plan = run(
        google: [g('people/new', ann, tag: 'H1')],
        links: [link(1, 'people/c1', 'H1', base: ann)],
      );
      final held = byGoogle(plan, 'people/new')!;
      expect(held.state, ContactLinkState.held);
      expect(held.reason, ContactHeldReason.waiting);
      expect(held.create, isNull);
      final review = plan.reviews.single;
      expect(review.kind, ContactReviewKind.newContact);
      expect(review.reason, ContactReviewReason.taggedPaired);
      expect(review.candidates, ['H1']);
      expect(review.samePersonOffered, isFalse, reason: 'only Copy or Leave');
    });

    test('a unique email with agreeing names pairs, without case', () {
      final plan = run(
        google: [
          g(
            'people/c1',
            person(given: 'Ann', family: 'Cole', emails: ['Ann@X.example']),
          ),
        ],
        graph: [
          h(
            'H1',
            person(given: 'Annie', family: 'COLE', emails: ['ann@x.example']),
          ),
        ],
      );
      expect(byGoogle(plan, 'people/c1')!.graphId, 'H1');
      expect(
        plan.reviews.where((r) => r.kind == ContactReviewKind.newContact),
        isEmpty,
      );
    });

    test('a unique email whose family names disagree waits', () {
      final plan = run(
        google: [g('people/c1', ann)],
        graph: [
          h(
            'H1',
            person(given: 'Ann', family: 'Smith', emails: ['ann@x.example']),
          ),
        ],
      );
      expect(plan.links.where((l) => l.create != null), isEmpty);
      final review = plan.reviews.single;
      expect(review.reason, ContactReviewReason.namesDisagree);
      expect(review.samePersonOffered, isTrue);
      expect(byGoogle(plan, 'people/c1')!.reason, ContactHeldReason.waiting);
      expect(byGraph(plan, 'H1')!.reason, ContactHeldReason.candidate);
      expect(plan.reviews, hasLength(1), reason: 'one item for the two');
    });

    test('a side with no family name agrees', () {
      final plan = run(
        google: [
          g('people/c1', person(given: 'Ann', emails: ['ann@x.example'])),
        ],
        graph: [h('H1', ann)],
      );
      expect(byGoogle(plan, 'people/c1')!.graphId, 'H1');
    });

    test('else a unique mobile, as an E.164 key', () {
      final plan = run(
        google: [
          g(
            'people/c1',
            person(given: 'Ann', family: 'Cole', mobile: '(212) 555-0100'),
          ),
        ],
        graph: [
          h(
            'H1',
            person(given: 'Ann', family: 'Cole', mobile: '+1 212 555 0100'),
          ),
        ],
      );
      expect(byGoogle(plan, 'people/c1')!.graphId, 'H1');
    });

    test('an address several contacts share (a family email) waits', () {
      final family = ['home@x.example'];
      final plan = run(
        google: [
          g('people/c1', person(given: 'Ann', family: 'Cole', emails: family)),
        ],
        graph: [
          h('H1', person(given: 'Ann', family: 'Cole', emails: family)),
          h('H2', person(given: 'Bob', family: 'Cole', emails: family)),
        ],
      );
      expect(plan.links.where((l) => l.create != null), isEmpty);
      final review = plan.reviews.single;
      expect(review.reason, ContactReviewReason.sharedAddress);
      expect(review.candidates, unorderedEquals(['H1', 'H2']));
      expect(byGraph(plan, 'H1')!.reason, ContactHeldReason.candidate);
      expect(byGraph(plan, 'H2')!.reason, ContactHeldReason.candidate);
    });

    test('an address two Gmail contacts share pairs with neither', () {
      final family = ['home@x.example'];
      final plan = run(
        google: [
          g('people/c1', person(given: 'Ann', family: 'Cole', emails: family)),
          g('people/c2', person(given: 'Bob', family: 'Cole', emails: family)),
        ],
        graph: [h('H1', person(given: 'Ann', family: 'Cole', emails: family))],
      );
      expect(plan.links.where((l) => l.newPair), isEmpty);
      expect(byGoogle(plan, 'people/c1')!.reason, ContactHeldReason.waiting);
      expect(
        plan.reviews.first.reason,
        ContactReviewReason.sharedAddress,
      );
    });

    test('the same full name and nothing else in common waits', () {
      final plan = run(
        google: [
          g('people/c1', person(given: 'Ann', family: 'Cole', emails: ['a@x'])),
        ],
        graph: [h('H1', person(given: 'ann', family: 'cole', emails: ['b@x']))],
      );
      expect(plan.links.where((l) => l.create != null), isEmpty);
      expect(plan.reviews.single.reason, ContactReviewReason.sameName);
      expect(plan.counts.needsALook, 1);
    });

    test('a match naming a paired contact offers only Copy or Leave', () {
      final plan = run(
        google: [g('people/new', ann)],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            base: person(
              given: 'Ann',
              family: 'Cole',
              emails: ['ann@x.example'],
            ),
          ),
        ],
      );
      // The email is on two Gmail contacts, the old one paired: shared.
      expect(plan.reviews.single.kind, ContactReviewKind.newContact);
      expect(plan.links.where((l) => l.create != null), isEmpty);
    });

    test('a unique match with a paired contact on the other side waits', () {
      final plan = run(
        google: [g('people/new', ann)],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: person(given: 'Ann', family: 'Cole'),
            graphBase: ann,
          ),
        ],
      );
      final review = plan.reviews.single;
      expect(review.reason, ContactReviewReason.matchPaired);
      expect(review.samePersonOffered, isFalse);
    });

    test('a unique match with a held contact waits', () {
      final plan = run(
        google: [g('people/new', ann)],
        links: [
          link(
            1,
            null,
            'H1',
            base: ann,
            state: ContactLinkState.held,
            reason: ContactHeldReason.leftOut,
          ),
        ],
      );
      final review = plan.reviews.single;
      expect(review.reason, ContactReviewReason.matchHeld);
      expect(review.samePersonOffered, isTrue);
    });

    test('a contact with no possible partner is copied, with its tag', () {
      final plan = run(google: [g('people/c1', ann)]);
      final copy = byGoogle(plan, 'people/c1')!;
      expect(copy.create!.side, ContactSide.graph);
      expect(copy.create!.tag, 'people/c1', reason: 'for the wire client');
      expect(
        copy.create!.body.containsKey('singleValueExtendedProperties'),
        isFalse,
      );
      expect(copy.googleBase, ann, reason: 'the source taken in');
      expect(plan.counts.addToGraph, 1);
      final back = run(graph: [h('H1', ann)]);
      expect(byGraph(back, 'H1')!.create!.side, ContactSide.google);
      expect(back.counts.addToGoogle, 1);
    });

    test('the same person added on both sides is paired, not copied twice', () {
      final plan = run(
        google: [g('people/c1', ann)],
        graph: [h('H1', ann)],
      );
      expect(plan.links, hasLength(1));
      expect(plan.links.single.googleName, 'people/c1');
      expect(plan.links.single.graphId, 'H1');
      expect(plan.counts.addToGraph + plan.counts.addToGoogle, 0);
      expect(plan.counts.pairUp, 1);
    });
  });

  group('a new pair is merged without overwriting', () {
    test('empty details filled, lists joined, a differing one left', () {
      final plan = run(
        google: [
          g(
            'people/c1',
            person(
              given: 'Ann',
              family: 'Cole',
              emails: ['ann@x.example'],
              mobile: '212 555 0100',
              more: {
                ContactField.company: 'Hadco',
                ContactField.homePhones: ['212 555 0101'],
              },
            ),
          ),
        ],
        graph: [
          h(
            'H1',
            person(
              given: 'Ann',
              family: 'Cole',
              emails: ['ann@x.example', 'ann@work.example'],
              more: {
                ContactField.company: 'Hadco Ltd',
                ContactField.jobTitle: 'Lead',
                ContactField.homePhones: ['212 555 0102'],
              },
            ),
          ),
        ],
      );
      final pair = plan.links.single;
      expect(pair.newPair, isTrue);
      expect(
        pair.graphWrite!.fields,
        {ContactField.mobile, ContactField.homePhones},
      );
      expect(pair.graphWrite!.target.text(ContactField.mobile), '212 555 0100');
      expect(pair.googleWrite!.fields, {
        ContactField.emails,
        ContactField.jobTitle,
        ContactField.homePhones,
      });
      expect(pair.googleWrite!.target.list(ContactField.emails), [
        'ann@x.example',
        'ann@work.example',
      ]);
      expect(pair.graphWrite!.fields.contains(ContactField.company), isFalse);
      expect(pair.googleWrite!.fields.contains(ContactField.company), isFalse);
      expect(pair.removes, isFalse);
      final review = plan.reviews.single;
      expect(review.kind, ContactReviewKind.differing);
      expect(review.fields, [ContactField.company]);
      expect(review.googleValues!.text(ContactField.company), 'Hadco');
      expect(review.graphValues!.text(ContactField.company), 'Hadco Ltd');
      expect(plan.counts.differingPairs, 1);
      // Left as it is on both sides, and not synced until one side
      // changes it: each base takes its own side's value.
      expect(pair.googleBase!.text(ContactField.company), 'Hadco');
      expect(pair.graphBase!.text(ContactField.company), 'Hadco Ltd');
    });

    SyncedContact born(ContactBirthday? birthday) => person(
      given: 'Ann',
      family: 'Cole',
      emails: ['a@x'],
      more: {ContactField.birthday: birthday},
    );
    const fourth = ContactBirthday(month: 7, day: 4);
    const fifth = ContactBirthday(month: 7, day: 5);
    const fourth1980 = ContactBirthday(year: 1980, month: 7, day: 4);

    test('Outlook\'s year goes to a year-less birthday on the same day', () {
      final plan = run(
        google: [g('people/c1', born(fourth))],
        graph: [h('H1', born(fourth1980))],
      );
      final pair = plan.links.single;
      expect(pair.googleWrite!.fields, {ContactField.birthday});
      expect(pair.googleWrite!.target.birthday, fourth1980);
      expect(pair.graphWrite, isNull);
    });

    test('a year-less birthday on another day waits, nothing written', () {
      final plan = run(
        google: [g('people/c1', born(fifth))],
        graph: [h('H1', born(fourth1980))],
      );
      expect(plan.links.single.writes, isFalse);
      expect(plan.reviews.single.fields, [ContactField.birthday]);
    });

    test('a year-less birthday is never copied to Outlook', () {
      final plan = run(
        google: [g('people/c1', born(fifth))],
        graph: [h('H1', born(null))],
      );
      expect(plan.links.single.graphWrite, isNull);
      expect(plan.reviews, isEmpty);
    });
  });

  group('a pair already made', () {
    final base = person(
      given: 'Ann',
      family: 'Cole',
      emails: ['ann@x.example'],
      mobile: '212 555 0100',
      more: {
        ContactField.jobTitle: 'Lead',
        ContactField.company: 'Hadco',
        ContactField.homePhones: ['212 555 0101'],
      },
    );

    test('a change on one side is written to the other, the base kept', () {
      final changed = base.withValue(ContactField.jobTitle, 'Director');
      final plan = run(
        google: [g('people/c1', changed, etag: 'etag-2')],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.googleWrite, isNull);
      expect(pair.graphWrite!.fields, {ContactField.jobTitle});
      expect(pair.graphWrite!.target.text(ContactField.jobTitle), 'Director');
      expect(
        pair.graphPatchFor({'displayName': 'Ann Cole', 'changeKey': 'key-H1'}),
        {'jobTitle': 'Director', 'displayName': 'Ann Cole'},
      );
      expect(pair.removes, isTrue, reason: 'a detail replaced');
      expect(pair.googleEtag, 'etag-2');
      // Until the write is answered, Gmail's base for the job title stays
      // as it was, so a failed write is tried again next time.
      expect(pair.googleBase!.text(ContactField.jobTitle), 'Lead');
      final after = pair.basesAfter(
        graphAnswer: base.withValue(ContactField.jobTitle, 'Director'),
      );
      expect(after.google.text(ContactField.jobTitle), 'Director');
      expect(after.graph.text(ContactField.jobTitle), 'Director');
      expect(plan.counts.changeGraph, 1);
    });

    test('a fix to capitals is a change; a phone reformatted is not', () {
      final plan = run(
        graph: [
          h(
            'H1',
            base
                .withValue(ContactField.company, 'HADCO')
                .withValue(ContactField.mobile, '(212) 555-0100'),
            key: 'key-2',
          ),
        ],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.googleWrite!.fields, {ContactField.company});
      expect(pair.graphBase!.text(ContactField.mobile), '(212) 555-0100');
    });

    test('lists merge: an addition on each side keeps both', () {
      final plan = run(
        google: [
          g(
            'people/c1',
            base.withValue(
              ContactField.homePhones,
              ['212 555 0101', '212 555 0102'],
            ),
          ),
        ],
        graph: [
          h(
            'H1',
            base.withValue(
              ContactField.homePhones,
              ['212 555 0101', '212 555 0103'],
            ),
          ),
        ],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.googleWrite!.target.list(ContactField.homePhones), [
        '212 555 0101',
        '212 555 0102',
        '212 555 0103',
      ]);
      expect(
        pair.graphWrite,
        isNull,
        reason: 'Outlook\'s two slots are full: the third stays in Gmail',
      );
      expect(plan.reviews, isEmpty, reason: 'lists do not clash');
      expect(pair.removes, isFalse);
    });

    test('a clash: the newer edit wins, and the losing value is kept', () {
      final plan = run(
        google: [
          g(
            'people/c1',
            base.withValue(ContactField.company, 'Acme'),
            at: earlier,
          ),
        ],
        graph: [
          h('H1', base.withValue(ContactField.company, 'Hadco Ltd'), at: later),
        ],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.googleWrite!.target.text(ContactField.company), 'Hadco Ltd');
      expect(pair.graphWrite, isNull);
      final review = plan.reviews.single;
      expect(review.kind, ContactReviewKind.clash);
      expect(review.losingSide, ContactSide.google);
      expect(review.losing!.text(ContactField.company), 'Acme');

      final other = run(
        google: [
          g(
            'people/c1',
            base.withValue(ContactField.company, 'Acme'),
            at: later,
          ),
        ],
        graph: [
          h(
            'H1',
            base.withValue(ContactField.company, 'Hadco Ltd'),
            at: earlier,
          ),
        ],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      expect(
        byLink(other, 1)!.graphWrite!.target.text(ContactField.company),
        'Acme',
      );
      expect(other.reviews.single.losingSide, ContactSide.graph);
    });

    test('the app\'s own write coming back is a no-op', () {
      // Run one: Gmail changed the job title; Outlook is written.
      final changed = base.withValue(ContactField.jobTitle, 'Director');
      final first = byLink(
        run(
          google: [g('people/c1', changed, etag: 'etag-2')],
          links: [link(1, 'people/c1', 'H1', base: base)],
        ),
        1,
      )!;
      final answered = changed;
      final bases = first.basesAfter(graphAnswer: answered);
      // Run two: both feeds report the contact as written.
      final second = run(
        google: [g('people/c1', changed, etag: 'etag-2')],
        graph: [h('H1', answered, key: 'key-2')],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: bases.google,
            graphBase: bases.graph,
            etag: 'etag-2',
            key: 'key-2',
          ),
        ],
      );
      final pair = byLink(second, 1)!;
      expect(pair.writes, isFalse);
      expect(second.reviews, isEmpty);
    });

    test('an edit made while the run was going survives the write', () {
      final changed = base.withValue(ContactField.jobTitle, 'Director');
      final first = byLink(
        run(
          google: [g('people/c1', changed)],
          links: [link(1, 'people/c1', 'H1', base: base)],
        ),
        1,
      )!;
      // Between the read and the PATCH, Ron changed the office in Outlook:
      // the PATCH's answer carries it.
      final answer = changed.withValue(ContactField.office, 'B2');
      final bases = first.basesAfter(graphAnswer: answer);
      expect(bases.graph.text(ContactField.office), isNull);
      final second = run(
        graph: [h('H1', answer, key: 'key-3')],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: bases.google,
            graphBase: bases.graph,
          ),
        ],
      );
      final pair = byLink(second, 1)!;
      expect(pair.googleWrite!.fields, {ContactField.office});
      expect(pair.googleWrite!.target.text(ContactField.office), 'B2');
    });

    test('a list merged both ways moves on only when both writes went', () {
      final plan = run(
        google: [
          g(
            'people/c1',
            base.withValue(ContactField.emails, ['ann@x.example', 'g@x']),
          ),
        ],
        graph: [
          h(
            'H1',
            base.withValue(ContactField.emails, ['ann@x.example', 'h@x']),
          ),
        ],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      final pair = byLink(plan, 1)!;
      final merged = base.withValue(ContactField.emails, [
        'ann@x.example',
        'g@x',
        'h@x',
      ]);
      final half = pair.basesAfter(googleAnswer: merged);
      expect(half.google.list(ContactField.emails), ['ann@x.example']);
      final otherHalf = pair.basesAfter(graphAnswer: merged);
      expect(otherHalf.graph.list(ContactField.emails), ['ann@x.example']);
      final both = pair.basesAfter(googleAnswer: merged, graphAnswer: merged);
      expect(both.google.list(ContactField.emails), hasLength(3));
      expect(both.graph.list(ContactField.emails), hasLength(3));
    });

    test('a write is built only on the version the plan read', () {
      // The feed did not bring the Gmail side: the plan is made from the
      // base, so from the row's etag.
      final plan = run(
        graph: [
          h('H1', base.withValue(ContactField.emails, [
            'ann@x.example',
            'e5@x',
          ]), key: 'key-2'),
        ],
        links: [link(1, 'people/c1', 'H1', base: base, etag: 'etag-1')],
      );
      final write = byLink(plan, 1)!.googleWrite!;
      expect(write.version, 'etag-1');
      // Read with other fields than the listing: the Person's own etag
      // differs, the contact source's is the version.
      Map<String, Object?> person(String etag) => {
        'resourceName': 'people/c1',
        'etag': '%person-etag-of-another-read',
        'metadata': {
          'sources': [
            {'type': 'CONTACT', 'id': 'c1', 'etag': etag},
          ],
        },
        'emailAddresses': [
          {'value': 'ann@x.example'},
          {'value': 'e4@x'},
        ],
      };
      expect(
        () => write.googleUpdate(person('etag-9'), normaliser: norm),
        throwsA(isA<ContactReadStale>()),
      );
      final update = write.googleUpdate(person('etag-1'), normaliser: norm);
      expect(update.person['metadata'], {
        'sources': [
          {'type': 'CONTACT', 'id': 'c1', 'etag': 'etag-1'},
        ],
      }, reason: 'the version updateContact checks');
      expect(update.person.containsKey('etag'), isFalse);
      expect(
        (update.person['emailAddresses'] as List).map(
          (e) => (e as Map)['value'],
        ),
        ['ann@x.example', 'e4@x', 'e5@x'],
        reason: 'a value the plan never saw survives',
      );
      final graph = byLink(
        run(
          google: [g('people/c1', base.withValue(ContactField.office, 'B2'))],
          links: [link(1, 'people/c1', 'H1', base: base, key: 'key-1')],
        ),
        1,
      )!.graphWrite!;
      expect(
        () => graph.graphPatch({'changeKey': 'key-2'}),
        throwsA(isA<ContactReadStale>()),
      );
      expect(
        graph.graphPatch({'changeKey': 'key-1'}),
        contains('officeLocation'),
      );
    });

    test('Gmail\'s version is its contact source\'s etag, whatever was read',
        () {
      // The Person's own etag is the answer's entity tag, and differs
      // between a listing and a full read; the contact source's does not.
      Map<String, Object?> read(String personEtag) => {
        'resourceName': 'people/c1',
        'etag': personEtag,
        'metadata': {
          'sources': [
            {'type': 'CONTACT', 'id': 'c1', 'etag': 'src-1'},
          ],
        },
        'names': [
          {'givenName': 'Ann', 'familyName': 'Cole'},
        ],
        'emailAddresses': [
          {'value': 'ann@x.example'},
        ],
      };
      final listed = GoogleContact.fromPerson(read('%listing'));
      expect(listed.etag, 'src-1');
      // Outlook's copy went: the Gmail contact, unchanged since the row
      // was saved, is deleted rather than kept as changed.
      final plan = run(
        google: [listed],
        graphGone: {'H1'},
        links: [link(1, 'people/c1', 'H1', base: ann, etag: 'src-1')],
      );
      final delete = byLink(plan, 1)!.delete!;
      expect(delete.side, ContactSide.google);
      expect(delete.expectedVersion, 'src-1');
      // The full read just before the delete has another Person etag but
      // the same version.
      expect(googleContactEtag(read('%full-read')), delete.expectedVersion);
    });

    test('a removed, sparse or empty Outlook entry is never read as cleared',
        () {
      for (final entry in [
        GraphContact(
          id: 'H1',
          details: SyncedContact({ContactField.company: 'X'}),
          removed: true,
        ),
        GraphContact(
          id: 'H1',
          details: SyncedContact({ContactField.company: 'X'}),
          missing: const {'surname', 'emailAddresses'},
        ),
        GraphContact(id: 'H1', details: SyncedContact.empty),
      ]) {
        final plan = run(
          graph: [entry],
          links: [link(1, 'people/c1', 'H1', base: base)],
        );
        expect(plan.links.where((l) => l.writes), isEmpty);
      }
      final emptyGmail = run(
        google: [g('people/c1', SyncedContact.empty)],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      expect(emptyGmail.links.where((l) => l.writes), isEmpty);
    });

    test('a sparse Outlook entry passed over is counted, for a read by id',
        () {
      GraphContact sparse(String id) => GraphContact(
        id: id,
        details: SyncedContact({ContactField.company: 'X'}),
        missing: const {'nickName'},
      );
      final plan = run(
        graph: [
          GraphContact(
            id: 'H0',
            details: SyncedContact.empty,
            removed: true,
          ),
          sparse('H1'),
          // Sparse in the delta, then read whole by id: not passed over.
          sparse('H3'),
          h('H3', person(given: 'Cy', family: 'Roe')),
        ],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      expect(plan.graphPassedOver, {'H1'});
      expect(plan.counts.passedOver, 1);
      expect(plan.counts.toJson()['passedOver'], 1);
      expect(plan.links.where((l) => l.writes && l.graphId == 'H1'), isEmpty);
      expect(plan.counts.addToGoogle, 1, reason: 'H3 was read whole');
      // A run the empty-answers brake stops says so too.
      final stopped = run(
        graph: [sparse('H1')],
        graphComplete: true,
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      expect(stopped.stop, isNotNull);
      expect(stopped.graphPassedOver, {'H1'});
      expect(stopped.counts.passedOver, 1);
    });

    test('Outlook\'s year reaches a year-less Gmail birthday after pairing',
        () {
      const yearless = ContactBirthday(month: 7, day: 4);
      const full = ContactBirthday(year: 1980, month: 7, day: 4);
      final gmail = base.withValue(ContactField.birthday, yearless);
      final plan = run(
        graph: [h('H1', base.withValue(ContactField.birthday, full))],
        links: [
          link(1, 'people/c1', 'H1', googleBase: gmail, graphBase: base),
        ],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.googleWrite!.target.birthday, full);
      expect(pair.removes, isFalse, reason: 'a year added, nothing lost');
    });

    test('a pair neither feed mentions is left alone', () {
      final plan = run(links: [link(1, 'people/c1', 'H1', base: base)]);
      expect(plan.links, isEmpty);
    });
  });

  group('a display name that is no name', () {
    // Outlook contacts as a whole read returns them: every synced
    // property there, null when empty.
    GraphContact outlook(
      String id,
      Map<String, Object?> values, {
      DateTime? at,
    }) => GraphContact.fromJson({
      'id': id,
      'changeKey': 'key-$id-2',
      'lastModifiedDateTime': ?at?.toIso8601String(),
      for (final p in graphSyncedProperties) p: null,
      ...values,
    });
    SyncedContact read(Map<String, Object?> values) =>
        outlook('H1', values).details;
    SyncedContact gmail(Map<String, Object?> person) =>
        syncedFromPerson(person);

    test('an edit to the company never clears the Gmail name', () {
      // Outlook shows "Acme Corp" with no name parts, company "Acme";
      // Ron changes the company to "Acme Corp".
      final gmailNow = gmail({
        'names': [
          {'unstructuredName': 'Acme Corp'},
        ],
        'organizations': [
          {'name': 'Acme'},
        ],
      });
      final plan = run(
        graph: [
          outlook('H1', {
            'displayName': 'Acme Corp',
            'companyName': 'Acme Corp',
          }),
        ],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: gmailNow,
            graphBase: read({'displayName': 'Acme Corp', 'companyName': 'Acme'}),
          ),
        ],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.googleWrite!.fields, {ContactField.company});
      expect(
        pair.googleWrite!.target.text(ContactField.company),
        'Acme Corp',
      );
      expect(pair.graphWrite, isNull);
    });

    test('an email edit never makes the old address a Gmail name', () {
      // Outlook shows the address for want of a name, and keeps showing
      // the old one after Ron changes the address.
      final plan = run(
        graph: [
          outlook('H1', {
            'displayName': 'bob@x.example',
            'emailAddresses': [
              {'address': 'bob@y.example'},
            ],
          }),
        ],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: SyncedContact({
              ContactField.emails: ['bob@x.example'],
            }),
            graphBase: read({
              'displayName': 'bob@x.example',
              'emailAddresses': [
                {'address': 'bob@x.example'},
              ],
            }),
          ),
        ],
      );
      final write = byLink(plan, 1)!.googleWrite!;
      expect(write.fields, {ContactField.emails});
      expect(write.target.list(ContactField.emails), ['bob@y.example']);
    });

    test('one no-name display remade as another is no change', () {
      // Outlook remakes the shown address with the address itself, while
      // Gmail has a name: the name is not cleared.
      final bob = person(given: 'Bob', family: 'Smith', emails: ['bob@x']);
      final plan = run(
        graph: [
          outlook('H1', {
            'displayName': 'bob@y',
            'emailAddresses': [
              {'address': 'bob@y'},
            ],
          }),
        ],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: bob,
            graphBase: read({
              'displayName': 'bob@x',
              'emailAddresses': [
                {'address': 'bob@x'},
              ],
            }),
          ),
        ],
      );
      final write = byLink(plan, 1)!.googleWrite!;
      expect(write.fields, {ContactField.emails});
    });

    test('a new pair is never filled with one, and keeps it raw', () {
      final plan = run(
        google: [
          g('people/c1', SyncedContact({
            ContactField.emails: ['bob@x.example'],
          })),
        ],
        graph: [
          outlook('H1', {
            'displayName': 'bob@x.example',
            'emailAddresses': [
              {'address': 'bob@x.example'},
            ],
          }),
        ],
      );
      final pair = byGoogle(plan, 'people/c1')!;
      expect(pair.graphId, 'H1');
      expect(pair.googleWrite, isNull, reason: 'no name copied to Gmail');
      expect(
        pair.graphBase!.name,
        ContactName.of(display: 'bob@x.example'),
        reason: 'the base keeps the raw value',
      );
    });

    test('one remade from a new company is taken into the base', () {
      // Outlook shows the company for want of a name; Ron renames the
      // company and Outlook remakes the shown name with it.
      final first = run(
        graph: [
          outlook('H1', {
            'displayName': 'Acme Inc',
            'companyName': 'Acme Inc',
          }),
        ],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: SyncedContact({ContactField.company: 'Acme'}),
            graphBase: read({'displayName': 'Acme', 'companyName': 'Acme'}),
          ),
        ],
      );
      final pair = byLink(first, 1)!;
      expect(pair.googleWrite!.fields, {ContactField.company});
      final bases = pair.basesAfter(
        googleAnswer: SyncedContact({ContactField.company: 'Acme Inc'}),
      );
      expect(bases.graph.name, ContactName.of(display: 'Acme Inc'));
      // Later Ron types a name in Gmail, then edits the mobile in Outlook
      // (the newer edit): the name goes to Outlook, with no clash.
      final second = run(
        google: [
          g(
            'people/c1',
            person(
              given: 'Ann',
              family: 'Lee',
              more: {ContactField.company: 'Acme Inc'},
            ),
            at: earlier,
          ),
        ],
        graph: [
          outlook('H1', {
            'displayName': 'Acme Inc',
            'companyName': 'Acme Inc',
            'mobilePhone': '+1 212 555 0100',
          }, at: later),
        ],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: bases.google,
            graphBase: bases.graph,
          ),
        ],
      );
      final now2 = byLink(second, 1)!;
      expect(now2.graphWrite!.fields, contains(ContactField.name));
      expect(
        now2.googleWrite?.fields.contains(ContactField.name) ?? false,
        isFalse,
        reason: 'Gmail\'s new name is not cleared',
      );
      expect(second.reviews, isEmpty);
    });

    test('two contacts showing only their company are no same name', () {
      final plan = run(
        google: [
          g('people/c1', SyncedContact({
            ContactField.name: ContactName.of(display: 'Acme'),
            ContactField.company: 'Acme',
            ContactField.emails: ['info@acme.example'],
          })),
        ],
        graph: [
          outlook('H1', {
            'displayName': 'Acme',
            'companyName': 'Acme',
            'emailAddresses': [
              {'address': 'sales@acme.example'},
            ],
          }),
        ],
      );
      expect(plan.reviews, isEmpty);
      expect(plan.counts.addToGoogle, 1);
      expect(plan.counts.addToGraph, 1);
    });
  });

  group('deletions', () {
    test('a contact deleted in Gmail is deleted in Outlook', () {
      final plan = run(
        google: [gDeleted('people/c1')],
        links: [link(1, 'people/c1', 'H1', base: ann, key: 'key-1')],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.removeRow, isTrue);
      final delete = pair.delete!;
      expect(delete.side, ContactSide.graph);
      expect(delete.contactId, 'H1');
      expect(delete.cause, ContactDeleteCause.deletedInGoogle);
      expect(delete.expectedVersion, 'key-1');
      expect(delete.partnerId, 'people/c1');
      expect(delete.partnerBase, ann);
      expect(plan.counts.deleteGraph, 1);
    });

    test('one gone from Outlook is deleted in Gmail', () {
      final plan = run(
        graphGone: {'H1'},
        links: [link(1, 'people/c1', 'H1', base: ann)],
      );
      expect(byLink(plan, 1)!.delete!.side, ContactSide.google);
      expect(plan.counts.deleteGoogle, 1);
    });

    test('a deletion whose partner has changed since is kept', () {
      final plan = run(
        google: [gDeleted('people/c1')],
        graph: [
          h('H1', ann.withValue(ContactField.jobTitle, 'New'), key: 'key-2'),
        ],
        links: [link(1, 'people/c1', 'H1', base: ann, key: 'key-1')],
      );
      final kept = byLink(plan, 1)!;
      expect(kept.delete, isNull);
      expect(kept.state, ContactLinkState.held);
      expect(kept.reason, ContactHeldReason.kept);
      expect(kept.googleName, isNull, reason: 'the gone id cleared');
      expect(kept.graphId, 'H1');
      final review = plan.reviews.single;
      expect(review.kind, ContactReviewKind.kept);
      expect(review.reason, ContactReviewReason.changedSince);
      expect(review.goneSide, ContactSide.google);
    });

    test('the read just before deleting can still keep it', () {
      final pair = byLink(
        run(
          google: [gDeleted('people/c1')],
          links: [link(1, 'people/c1', 'H1', base: ann)],
        ),
        1,
      )!;
      final kept = pair.keptInstead();
      expect(kept.reason, ContactHeldReason.kept);
      expect(kept.graphId, 'H1');
      expect(kept.googleName, isNull);
      expect(pair.keptReview().goneSide, ContactSide.google);
    });

    test('deleted and made again: the partner is paired with the new one', () {
      final plan = run(
        google: [
          gDeleted('people/c1'),
          g('people/c2', ann.withValue(ContactField.jobTitle, 'Lead')),
        ],
        links: [link(1, 'people/c1', 'H1', base: ann)],
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      final pair = byLink(plan, 1)!;
      expect(pair.googleName, 'people/c2');
      expect(pair.graphId, 'H1');
      expect(pair.newPair, isTrue);
      expect(pair.graphWrite!.fields, {ContactField.jobTitle});
      expect(plan.counts.addToGraph, 0);
    });

    test('a contact due to be deleted is never matched', () {
      // H1 was deleted in Outlook; its old address on a new Gmail contact
      // must not pair with it.
      final plan = run(
        google: [g('people/c2', ann)],
        graphGone: {'H1'},
        links: [link(1, 'people/c1', 'H1', base: ann)],
      );
      expect(byGoogle(plan, 'people/c2')!.create!.side, ContactSide.graph);
      expect(byLink(plan, 1)!.delete!.contactId, 'people/c1');
    });

    test('the sync\'s own deletes, in the bin, are ignored', () {
      final plan = run(
        graphGone: {'H1'},
        links: [link(1, 'people/c1', 'H1', base: ann)],
        bin: [
          const ContactBinInput(
            binId: 7,
            side: ContactSide.graph,
            contactId: 'H1',
          ),
        ],
      );
      expect(plan.links, isEmpty);
    });

    test('Gmail\'s deleted entries for the sync\'s own deletes are ignored',
        () {
      final plan = run(
        google: [gDeleted('people/c1')],
        links: [link(1, 'people/c1', 'H1', base: ann)],
        bin: [
          const ContactBinInput(
            binId: 7,
            side: ContactSide.google,
            contactId: 'people/c1',
          ),
        ],
      );
      expect(plan.links, isEmpty);
    });

    test('a moved-out copy is never deleted: only its row goes', () {
      final plan = run(
        google: [for (var i = 0; i < 6; i++) gDeleted('people/c$i')],
        links: [
          for (var i = 0; i < 6; i++)
            link(
              i,
              'people/c$i',
              'H$i',
              base: ann,
              state: ContactLinkState.held,
              reason: ContactHeldReason.movedOut,
            ),
        ],
      );
      expect(plan.links, hasLength(6));
      expect(plan.links.map((l) => l.removeRow), everyElement(isTrue));
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      expect(plan.brakes, isEmpty);
    });

    test('an orphan is never a same-name candidate', () {
      final plan = run(
        google: [
          gDeleted('people/c1'),
          g('people/c2', person(given: 'Ann', family: 'Cole', emails: ['a@g'])),
        ],
        graph: [h('H1', person(given: 'Ann', family: 'Cole', emails: ['a@h']))],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            base: person(given: 'Ann', family: 'Cole', emails: ['a@h']),
          ),
        ],
      );
      expect(byGoogle(plan, 'people/c2')!.create!.side, ContactSide.graph);
      expect(byLink(plan, 1)!.delete!.contactId, 'H1');
      expect(plan.reviews, isEmpty);
    });

    test('merged in Gmail: the closer row stays, the other is asked about', () {
      final cole = person(
        given: 'Ann',
        family: 'Cole',
        emails: ['ann@x.example', 'ann@work.example'],
        mobile: '212 555 0100',
      );
      final plan = run(
        google: [
          gDeleted('people/a'),
          gDeleted('people/b'),
          g('people/m', cole, previous: ['people/a', 'people/b']),
        ],
        graph: [
          h(
            'H-a',
            person(given: 'Ann', family: 'Cole', emails: ['ann@x.example']),
          ),
          h(
            'H-b',
            person(
              given: 'Ann',
              family: 'Cole',
              emails: ['ann@work.example'],
              mobile: '212 555 0100',
            ),
          ),
        ],
        links: [
          link(
            1,
            'people/a',
            'H-a',
            base: person(
              given: 'Ann',
              family: 'Cole',
              emails: ['ann@x.example'],
            ),
          ),
          link(
            2,
            'people/b',
            'H-b',
            base: person(
              given: 'Ann',
              family: 'Cole',
              emails: ['ann@work.example'],
              mobile: '212 555 0100',
            ),
          ),
        ],
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      final stays = byLink(plan, 2)!;
      expect(stays.googleName, 'people/m');
      expect(stays.state, ContactLinkState.paired);
      final other = byLink(plan, 1)!;
      expect(other.googleName, isNull);
      expect(other.state, ContactLinkState.held);
      final review = plan.reviews.firstWhere(
        (r) => r.kind == ContactReviewKind.mergedInGoogle,
      );
      expect(review.graphId, 'H-a');
      expect(review.googleName, 'people/m');
      expect(plan.reKeys, {'people/a': 'people/m', 'people/b': 'people/m'});
      expect(plan.googleGone, isEmpty, reason: 'merged, not deleted');
      expect(plan.graphTagMoves, {'H-b': 'people/m'});
    });

    test('a re-key renames the row and moves the partner\'s tag', () {
      final plan = run(
        googleReKeys: {'people/c1': 'people/c9'},
        google: [g('people/c9', ann.withValue(ContactField.office, 'B2'))],
        links: [link(1, 'people/c1', 'H1', base: ann)],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.googleName, 'people/c9');
      expect(pair.graphWrite!.fields, {ContactField.office});
      expect(plan.graphTagMoves, {'H1': 'people/c9'});
    });

    test('a move out of Contacts holds the pair; its return resumes it', () {
      final moved = run(
        graphMovedOut: {'H1'},
        links: [link(1, 'people/c1', 'H1', base: ann)],
      );
      final held = byLink(moved, 1)!;
      expect(held.state, ContactLinkState.held);
      expect(held.reason, ContactHeldReason.movedOut);
      expect(held.googleName, 'people/c1');
      expect(held.graphId, 'H1');
      expect(held.delete, isNull);
      expect(moved.counts.deleteGoogle, 0);

      // Back in Contacts, with a change made in Gmail meanwhile.
      final back = run(
        google: [g('people/c1', ann.withValue(ContactField.office, 'B2'))],
        graph: [h('H1', ann)],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            base: ann,
            state: ContactLinkState.held,
            reason: ContactHeldReason.movedOut,
          ),
        ],
      );
      final pair = byLink(back, 1)!;
      expect(pair.state, ContactLinkState.paired);
      expect(pair.graphWrite!.fields, {ContactField.office});
      expect(back.links.where((l) => l.create != null), isEmpty);
    });

    test('absences: checked after the hour of grace, never judged before', () {
      final links = [
        link(
          1,
          'people/fresh',
          'H1',
          base: ann,
          writtenAt: now.subtract(const Duration(minutes: 10)),
        ),
        link(
          2,
          'people/old',
          'H2',
          base: ann,
          writtenAt: now.subtract(const Duration(hours: 2)),
        ),
        link(3, 'people/seen', 'H3', base: ann),
      ];
      final checks = contactsToConfirm(
        google: [g('people/seen', ann)],
        googleComplete: true,
        graph: [h('H1', ann), h('H2', ann), h('H3', ann)],
        graphComplete: true,
        graphRemoved: ['H3'],
        links: links,
        now: now,
      );
      expect(checks.google, ['people/old']);
      expect(checks.graph, ['H3']);
      // Missing from a complete listing but not confirmed: nothing goes.
      final plan = run(
        google: [g('people/seen', ann)],
        googleComplete: true,
        links: links,
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
    });

    test('a pair made with a contact in the bin: Already back', () {
      final plan = run(
        google: [g('people/c1', ann)],
        graph: [h('H1', ann)],
        bin: [
          const ContactBinInput(
            binId: 4,
            side: ContactSide.graph,
            contactId: 'H1',
          ),
          const ContactBinInput(
            binId: 5,
            side: ContactSide.graph,
            contactId: 'H9',
            done: false,
          ),
        ],
      );
      expect(plan.binAlreadyBack, [4]);
      expect(plan.binNotDue, [5]);
      // Brought back with no partner left: copied, and back all the same.
      final copied = run(
        graph: [h('H1', ann)],
        bin: [
          const ContactBinInput(
            binId: 4,
            side: ContactSide.graph,
            contactId: 'H1',
          ),
        ],
      );
      expect(byGraph(copied, 'H1')!.create, isNotNull);
      expect(copied.binAlreadyBack, [4]);
    });
  });

  group('the deletion brake', () {
    List<ContactLinkInput> pairs(int n) => [
      for (var i = 0; i < n; i++)
        link(i, 'people/c$i', 'H$i', base: person(given: 'P$i', family: 'X')),
    ];

    test('five deletions go ahead', () {
      final plan = run(
        google: [for (var i = 0; i < 5; i++) gDeleted('people/c$i')],
        links: pairs(5),
      );
      expect(plan.links.where((l) => l.delete != null), hasLength(5));
      expect(plan.brakes, isEmpty);
    });

    test('six are held and asked about, everything else carries on', () {
      final plan = run(
        google: [
          for (var i = 0; i < 4; i++) gDeleted('people/c$i'),
          g('people/new', ann),
        ],
        graphGone: {'H4', 'H5'},
        links: pairs(6),
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      final held = [for (var i = 0; i < 6; i++) byLink(plan, i)!];
      expect(
        held.map((l) => l.reason),
        everyElement(ContactHeldReason.deletionBrake),
      );
      expect(held[0].graphId, 'H0', reason: 'the copy that would go');
      expect(held[0].googleName, isNull);
      expect(held[5].googleName, 'people/c5');
      final brake = plan.brakes.single;
      expect(brake.kind, ContactBrakeKind.deletions);
      expect(brake.items, hasLength(6));
      expect(
        brake.items.first.side,
        ContactSide.google,
        reason: 'deleted in Gmail',
      );
      expect(
        brake.items.last.side,
        ContactSide.graph,
        reason: 'gone from Hadco',
      );
      expect(byGoogle(plan, 'people/new')!.create, isNotNull);
      expect(plan.counts.heldDeletions, 6);
    });

    test('Delete them deletes those still due, past the brake', () {
      final plan = run(
        links: [
          for (var i = 0; i < 7; i++)
            link(
              i,
              null,
              'H$i',
              base: person(given: 'P$i'),
              state: ContactLinkState.held,
              reason: ContactHeldReason.deletionBrake,
            ),
        ],
        graphGone: {'H6'},
        answers: [const ContactAnswer(ContactAnswerKind.deleteHeld)],
      );
      expect(plan.links.where((l) => l.delete != null), hasLength(6));
      expect(byLink(plan, 6)!.removeRow, isTrue);
      expect(plan.brakes, isEmpty);
    });

    test('Don\'t delete them keeps the copies, unpaired, to look at', () {
      final plan = run(
        links: [
          for (var i = 0; i < 6; i++)
            link(
              i,
              'people/c$i',
              null,
              base: person(given: 'P$i'),
              state: ContactLinkState.held,
              reason: ContactHeldReason.deletionBrake,
            ),
        ],
        answers: [const ContactAnswer(ContactAnswerKind.keepHeld)],
      );
      expect(
        plan.links.map((l) => l.reason),
        everyElement(ContactHeldReason.kept),
      );
      expect(plan.reviews, hasLength(6));
      expect(plan.reviews.first.reason, ContactReviewReason.notDeleted);
      expect(plan.reviews.first.goneSide, ContactSide.graph);
    });

    test('held deletions stay held whatever the count later', () {
      final plan = run(
        links: [
          link(
            1,
            null,
            'H1',
            base: ann,
            state: ContactLinkState.held,
            reason: ContactHeldReason.deletionBrake,
          ),
        ],
        graph: [h('H1', ann)],
      );
      expect(plan.links, isEmpty);
    });
  });

  group('the change brake', () {
    final base = person(
      given: 'P',
      family: 'X',
      more: {ContactField.company: 'Old'},
    );
    List<ContactLinkInput> pairs(int n) => [
      for (var i = 0; i < n; i++) link(i, 'people/c$i', 'H$i', base: base),
    ];
    List<GoogleContact> renamed(int n) => [
      for (var i = 0; i < n; i++)
        g('people/c$i', base.withValue(ContactField.company, 'New')),
    ];

    test('ten contacts losing details go ahead', () {
      final plan = run(google: renamed(10), links: pairs(10));
      expect(plan.links.where((l) => l.graphWrite != null), hasLength(10));
      expect(plan.brakes, isEmpty);
    });

    test('eleven are held; fills and copies carry on', () {
      final plan = run(
        google: [
          ...renamed(11),
          g('people/c11', base.withValue(ContactField.office, 'B2')),
          g('people/new', ann),
        ],
        links: pairs(12),
      );
      final held = [for (var i = 0; i < 11; i++) byLink(plan, i)!];
      expect(
        held.map((l) => l.reason),
        everyElement(ContactHeldReason.changeBrake),
      );
      expect(held.where((l) => l.writes), isEmpty);
      expect(held.first.googleBase, base, reason: 'old bases kept');
      expect(byLink(plan, 11)!.graphWrite!.fields, {ContactField.office});
      expect(byGoogle(plan, 'people/new')!.create, isNotNull);
      expect(plan.brakes.single.kind, ContactBrakeKind.changes);
      expect(plan.brakes.single.items, hasLength(11));
      expect(plan.counts.heldChanges, 11);
    });

    test('also when Outlook\'s side removes them', () {
      final plan = run(
        graph: [
          for (var i = 0; i < 11; i++)
            h('H$i', base.withValue(ContactField.company, null)),
        ],
        links: pairs(11),
      );
      expect(plan.brakes.single.items.first.side, ContactSide.google);
    });

    List<GraphContact> unchanged(int n) => [
      for (var i = 0; i < n; i++) h('H$i', base),
    ];

    test('Apply them writes them, past the brake', () {
      final plan = run(
        google: renamed(11),
        graph: unchanged(11),
        links: [
          for (var i = 0; i < 11; i++)
            link(
              i,
              'people/c$i',
              'H$i',
              base: base,
              state: ContactLinkState.held,
              reason: ContactHeldReason.changeBrake,
            ),
        ],
        answers: [const ContactAnswer(ContactAnswerKind.applyHeld)],
      );
      expect(plan.brakes, isEmpty);
      final writes = plan.links.where((l) => l.graphWrite != null).toList();
      expect(writes, hasLength(11));
      expect(writes.first.graphWrite!.target.text(ContactField.company), 'New');
      expect(writes.first.state, ContactLinkState.paired);
      expect(plan.answers, [ContactAnswerOutcome.applied]);
    });

    test('Apply them waits for the contacts to be read', () {
      // A feed that brought only Gmail's side: planned from Outlook's base
      // the change would be written, but the answer waits instead, and the
      // pairs stay held.
      final plan = run(
        google: renamed(11).sublist(1),
        graph: unchanged(11).sublist(1),
        links: [
          for (var i = 0; i < 11; i++)
            link(
              i,
              'people/c$i',
              'H$i',
              base: base,
              state: ContactLinkState.held,
              reason: ContactHeldReason.changeBrake,
            ),
        ],
        answers: [const ContactAnswer(ContactAnswerKind.applyHeld)],
      );
      expect(plan.answers, [ContactAnswerOutcome.waiting]);
      expect(byLink(plan, 0), isNull, reason: 'held as it was');
      expect(plan.links.where((l) => l.graphWrite != null), hasLength(10));
    });

    test('Copy them back writes the other side\'s values back', () {
      final plan = run(
        google: renamed(11),
        graph: unchanged(11),
        links: [
          for (var i = 0; i < 11; i++)
            link(
              i,
              'people/c$i',
              'H$i',
              base: base,
              state: ContactLinkState.held,
              reason: ContactHeldReason.changeBrake,
            ),
        ],
        answers: [const ContactAnswer(ContactAnswerKind.copyHeldBack)],
      );
      final first = byLink(plan, 0)!;
      expect(first.graphWrite, isNull);
      expect(first.googleWrite!.target.text(ContactField.company), 'Old');
    });
  });

  group('the empty-answers brake', () {
    test('a complete listing with under half those expected stops the run', () {
      final plan = run(
        google: [for (var i = 0; i < 4; i++) g('people/c$i', ann)],
        googleComplete: true,
        expectedGoogle: 20,
        links: [link(1, 'people/c1', 'H1', base: ann)],
      );
      expect(plan.stop!.side, ContactSide.google);
      expect(plan.stop!.listed, 4);
      expect(plan.stop!.expected, 20);
      expect(plan.links, isEmpty);
    });

    test('none while contacts are paired stops it, on either side', () {
      final plan = run(
        graphComplete: true,
        expectedGraph: 3,
        links: [link(1, 'people/c1', 'H1', base: ann)],
      );
      expect(plan.stop!.side, ContactSide.graph);
    });

    test('with no count stored, the rows naming that side stand in', () {
      final plan = run(
        google: [for (var i = 0; i < 4; i++) g('people/c$i', ann)],
        googleComplete: true,
        links: [
          for (var i = 0; i < 20; i++) link(i, 'people/c$i', 'H$i', base: ann),
        ],
      );
      expect(plan.stop!.side, ContactSide.google);
      expect(plan.stop!.expected, 20);
    });

    test('exactly half is not under half', () {
      ContactSyncPlan listing(int n) => run(
        google: [for (var i = 0; i < n; i++) g('people/c$i', ann)],
        googleComplete: true,
        expectedGoogle: 20,
      );
      expect(listing(10).stop, isNull);
      expect(listing(9).stop, isNotNull);
    });

    test('a small address book is not stopped', () {
      final plan = run(
        google: [g('people/c1', ann)],
        googleComplete: true,
        expectedGoogle: 8,
        links: [link(1, 'people/c1', 'H1', base: ann)],
      );
      expect(plan.stop, isNull);
    });

    test('That\'s right, carry on accepts the new count', () {
      final plan = run(
        google: [for (var i = 0; i < 4; i++) g('people/c$i', ann)],
        googleComplete: true,
        expectedGoogle: 20,
        answers: [
          const ContactAnswer(
            ContactAnswerKind.carryOn,
            side: ContactSide.google,
          ),
        ],
      );
      expect(plan.stop, isNull);
      expect(plan.googleCount, 4);
    });
  });

  group('the first sync', () {
    test('deletes nothing: a deletion seen waits under Needs a look', () {
      final plan = run(
        firstSync: true,
        google: [gDeleted('people/c1')],
        links: [link(1, 'people/c1', 'H1', base: ann)],
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      expect(byLink(plan, 1)!.reason, ContactHeldReason.kept);
      expect(plan.reviews.single.reason, ContactReviewReason.firstSync);
    });

    test('never overwrites a detail that differs', () {
      final base = person(
        given: 'Ann',
        family: 'Cole',
        more: {ContactField.company: 'Hadco'},
      );
      final plan = run(
        firstSync: true,
        google: [g('people/c1', base.withValue(ContactField.company, 'Acme'))],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.writes, isFalse);
      expect(plan.reviews.single.kind, ContactReviewKind.differing);
    });

    test('a resumed first sync neither removes nor puts back', () {
      final base = person(
        given: 'Ann',
        family: 'Cole',
        emails: ['a1@x', 'a2@x'],
      );
      final plan = run(
        firstSync: true,
        google: [g('people/c1', base.withValue(ContactField.emails, ['a1@x']))],
        graph: [h('H1', base)],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.writes, isFalse);
      expect(
        pair.googleBase!.list(ContactField.emails),
        ['a1@x', 'a2@x'],
        reason: 'left for after the first sync',
      );
    });

    test('a resumed first sync lists a clash rather than settle it', () {
      final base = person(
        given: 'Ann',
        family: 'Cole',
        more: {ContactField.company: 'Hadco'},
      );
      final plan = run(
        firstSync: true,
        google: [
          g(
            'people/c1',
            base.withValue(ContactField.company, 'Acme'),
            at: later,
          ),
        ],
        graph: [
          h('H1', base.withValue(ContactField.company, 'Beta'), at: earlier),
        ],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      expect(byLink(plan, 1)!.writes, isFalse);
      expect(plan.reviews.single.kind, ContactReviewKind.differing);
    });

    test('the preview counts what it would do', () {
      final plan = run(
        firstSync: true,
        googleComplete: true,
        graphComplete: true,
        google: [
          g('people/c1', ann),
          g(
            'people/c2',
            person(given: 'Bob', family: 'Day', emails: ['bob@x']),
          ),
          g(
            'people/c3',
            person(
              given: 'Cy',
              family: 'Eve',
              emails: ['cy@x'],
              more: {ContactField.company: 'A'},
            ),
          ),
          g('people/c4', person(given: 'Ed', family: 'Gee', emails: ['ed@x'])),
        ],
        graph: [
          h('H1', ann),
          h(
            'H3',
            person(
              given: 'Cy',
              family: 'Eve',
              emails: ['cy@x'],
              more: {ContactField.company: 'B'},
            ),
          ),
          h('H4', person(given: 'Di', family: 'Fay', emails: ['di@x'])),
          h('H5', person(given: 'Ed', family: 'Gee')),
        ],
      );
      final c = plan.counts;
      expect(c.addToGraph, 1, reason: 'Bob');
      expect(c.addToGoogle, 1, reason: 'Di; the two Eds wait');
      expect(c.pairUp, 2);
      expect(c.differingPairs, 1);
      expect(c.deleteGoogle + c.deleteGraph, 0);
      expect(c.needsALook, 2);
      expect(plan.googleCount, 4);
      expect(plan.graphCount, 4);
    });
  });

  group('interrupted creates', () {
    final entry = ContactJournalEntry(
      opId: 3,
      side: ContactSide.graph,
      sourceId: 'people/c1',
      startedAt: now.subtract(const Duration(minutes: 20)),
    );

    test('found by its tag: paired, not made again', () {
      final plan = run(
        google: [g('people/c1', ann)],
        graph: [h('H1', ann, tag: 'people/c1')],
        journal: [entry],
      );
      expect(plan.journalSettled, [3]);
      expect(byGoogle(plan, 'people/c1')!.graphId, 'H1');
      expect(plan.links.where((l) => l.create != null), isEmpty);
    });

    test('a copy found while its source was not read is left alone', () {
      final notRead = run(
        graph: [h('H1', ann, tag: 'people/c1')],
        journal: [entry],
      );
      expect(notRead.links, isEmpty);
      expect(notRead.journalSettled, isEmpty);
      final gone = run(
        graph: [h('H1', ann, tag: 'people/c1')],
        googleGone: {'people/c1'},
        journal: [entry],
      );
      expect(gone.journalSettled, [3]);
      expect(gone.links.single.delete!.contactId, 'H1');
    });

    test('not found within the hour: the source waits', () {
      final plan = run(google: [g('people/c1', ann)], journal: [entry]);
      expect(plan.links, isEmpty);
      expect(plan.journalSettled, isEmpty);
    });

    test('not found an hour later: made again', () {
      final plan = run(
        google: [g('people/c1', ann)],
        journal: [
          ContactJournalEntry(
            opId: 3,
            side: ContactSide.graph,
            sourceId: 'people/c1',
            startedAt: now.subtract(const Duration(minutes: 61)),
          ),
        ],
      );
      expect(plan.journalSettled, [3]);
      expect(byGoogle(plan, 'people/c1')!.create!.side, ContactSide.graph);
    });
  });

  group('Ron\'s answers', () {
    test('Same person pairs two waiting contacts into one row', () {
      final plan = run(
        google: [g('people/c1', ann)],
        graph: [h('H1', person(given: 'Ann', family: 'Smith'))],
        links: [
          link(
            1,
            'people/c1',
            null,
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ),
          link(
            2,
            null,
            'H1',
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ),
        ],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.samePerson,
            googleName: 'people/c1',
            graphId: 'H1',
          ),
        ],
      );
      final pair = plan.links.single;
      expect(pair.linkId, 1);
      expect(pair.alsoRemove, [2]);
      expect(pair.state, ContactLinkState.paired);
      expect(pair.fromAnswer, isTrue);
      expect(pair.graphWrite!.fields, {ContactField.emails});
      expect(plan.reviews.single.kind, ContactReviewKind.differing);
    });

    test('Copy it anyway copies; Leave it out holds', () {
      final copied = run(
        google: [g('people/c1', ann)],
        links: [
          link(
            1,
            'people/c1',
            null,
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ),
        ],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.copyAnyway,
            googleName: 'people/c1',
          ),
        ],
      );
      expect(byLink(copied, 1)!.create!.side, ContactSide.graph);
      final left = run(
        google: [g('people/c1', ann)],
        links: [
          link(
            1,
            'people/c1',
            null,
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ),
        ],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.leaveOut,
            googleName: 'people/c1',
          ),
        ],
      );
      expect(byLink(left, 1)!.reason, ContactHeldReason.leftOut);
    });

    test('Use Gmail\'s writes Gmail\'s value; a losing value goes to both', () {
      final base = person(
        given: 'Ann',
        family: 'Cole',
        more: {ContactField.company: 'A'},
      );
      final differing = run(
        google: [g('people/c1', base)],
        graph: [h('H1', base.withValue(ContactField.company, 'B'))],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: base,
            graphBase: base.withValue(ContactField.company, 'B'),
          ),
        ],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.useGoogle,
            googleName: 'people/c1',
            graphId: 'H1',
          ),
        ],
      );
      final pair = byLink(differing, 1)!;
      expect(pair.graphWrite!.target.text(ContactField.company), 'A');
      expect(pair.fromAnswer, isTrue);

      final losing = run(
        google: [g('people/c1', base)],
        graph: [h('H1', base)],
        links: [link(1, 'people/c1', 'H1', base: base)],
        answers: [
          ContactAnswer(
            ContactAnswerKind.useValue,
            googleName: 'people/c1',
            graphId: 'H1',
            value: SyncedContact({ContactField.company: 'Lost'}).toJson(),
          ),
        ],
      );
      final both = byLink(losing, 1)!;
      expect(both.googleWrite!.target.text(ContactField.company), 'Lost');
      expect(both.graphWrite!.target.text(ContactField.company), 'Lost');
    });

    test('Use Hadco\'s never drops what Outlook cannot hold', () {
      final google = person(
        given: 'Ann',
        family: 'Cole',
        emails: ['a1@x', 'a2@x', 'a3@x', 'a4@x'],
        more: {
          ContactField.company: 'A',
          ContactField.nickname: 'Annie',
          ContactField.birthday: const ContactBirthday(month: 7, day: 4),
        },
      );
      final graph = person(
        given: 'Ann',
        family: 'Cole',
        emails: ['a1@x', 'a2@x', 'a3@x'],
        more: {ContactField.company: 'B'},
      );
      ContactSyncPlan answer(
        Set<ContactField> fields, {
        ContactAnswerKind kind = ContactAnswerKind.useGraph,
      }) => run(
        google: [g('people/c1', google)],
        graph: [h('H1', graph)],
        links: [
          link(1, 'people/c1', 'H1', googleBase: google, graphBase: graph),
        ],
        answers: [
          ContactAnswer(
            kind,
            googleName: 'people/c1',
            graphId: 'H1',
            fields: fields,
          ),
        ],
      );
      // With no details named: only those the item listed, never one
      // that is on one side only.
      final plan = byLink(answer(const {}), 1)!;
      expect(plan.googleWrite!.fields, {ContactField.company});
      expect(plan.graphWrite, isNull);
      final gmails = byLink(
        answer(const {}, kind: ContactAnswerKind.useGoogle),
        1,
      )!;
      expect(
        gmails.graphWrite!.fields,
        {ContactField.company},
        reason: 'no nickname filled',
      );
      expect(gmails.googleWrite, isNull);
      // Named, a list or an empty value still never applies.
      final named = byLink(
        answer({
          ContactField.emails,
          ContactField.birthday,
          ContactField.company,
        }),
        1,
      )!.googleWrite!;
      expect(named.fields, {ContactField.company});
    });

    test('an answer acts only on contacts read this run', () {
      final waitingRow = link(
        1,
        'people/c1',
        null,
        state: ContactLinkState.held,
        reason: ContactHeldReason.waiting,
      );
      final candidateRow = link(
        2,
        null,
        'H1',
        state: ContactLinkState.held,
        reason: ContactHeldReason.candidate,
      );
      final same = run(
        links: [waitingRow, candidateRow],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.samePerson,
            googleName: 'people/c1',
            graphId: 'H1',
          ),
        ],
      );
      expect(same.answers, [ContactAnswerOutcome.waiting]);
      expect(same.links.where((l) => l.writes), isEmpty);
      final copy = run(
        links: [waitingRow],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.copyAnyway,
            googleName: 'people/c1',
          ),
        ],
      );
      expect(copy.answers, [ContactAnswerOutcome.waiting]);
      expect(copy.links.where((l) => l.create != null), isEmpty);
      // What to read for them.
      final reads = contactsToRead(
        links: [
          waitingRow,
          link(
            3,
            'people/c3',
            'H3',
            state: ContactLinkState.held,
            reason: ContactHeldReason.changeBrake,
          ),
          link(4, 'people/c4', 'H4'),
          link(
            7,
            null,
            'H7',
            state: ContactLinkState.held,
            reason: ContactHeldReason.candidate,
          ),
        ],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.samePerson,
            googleName: 'people/c1',
            graphId: 'H1',
          ),
          const ContactAnswer(ContactAnswerKind.applyHeld),
          const ContactAnswer(ContactAnswerKind.useGoogle, graphId: 'H4'),
        ],
        journal: [
          ContactJournalEntry(
            opId: 1,
            side: ContactSide.graph,
            sourceId: 'people/c5',
            startedAt: now,
          ),
        ],
        bin: [
          const ContactBinInput(
            binId: 1,
            side: ContactSide.graph,
            contactId: 'H6',
            partnerId: 'people/c6',
            restore: true,
          ),
        ],
      );
      expect(
        reads.google,
        unorderedEquals([
          'people/c1',
          'people/c3',
          'people/c4',
          'people/c5',
          'people/c6',
        ]),
      );
      expect(reads.graph, unorderedEquals(['H1', 'H3', 'H4', 'H6', 'H7']));
    });

    test('a candidate is placed once its item is answered or dropped', () {
      // Case a: they share only a name, and Gmail Ann is then deleted.
      final annG = person(given: 'Ann', family: 'Cole', emails: ['a@g']);
      final annH = person(given: 'Ann', family: 'Cole', emails: ['a@h']);
      final first = run(
        google: [g('people/ann', annG)],
        graph: [h('H-ann', annH)],
      );
      expect(byGraph(first, 'H-ann')!.reason, ContactHeldReason.candidate);
      expect(
        byGoogle(first, 'people/ann')!.googleBase,
        annG,
        reason: 'what was read, for later runs that do not read it',
      );
      final rows = [
        link(
          1,
          'people/ann',
          null,
          base: annG,
          state: ContactLinkState.held,
          reason: ContactHeldReason.waiting,
        ),
        link(
          2,
          null,
          'H-ann',
          base: annH,
          state: ContactLinkState.held,
          reason: ContactHeldReason.candidate,
        ),
      ];
      // While Gmail Ann still waits, Outlook Ann stays as it is.
      final meanwhile = run(graph: [h('H-ann', annH)], links: rows);
      expect(byLink(meanwhile, 2), isNull);
      expect(meanwhile.reviews, isEmpty);
      final deleted = run(
        googleGone: {'people/ann'},
        graph: [h('H-ann', annH)],
        links: rows,
      );
      expect(byLink(deleted, 1)!.removeRow, isTrue);
      expect(byLink(deleted, 2)!.create!.side, ContactSide.google);

      // Case b: Ann shares a family address with Bob and Cy; Leave it out
      // on Ann sends Bob and Cy back through the rules, each to an item
      // of its own.
      final family = ['family@x'];
      final bob = person(given: 'Bob', family: 'Cole', emails: family);
      final cy = person(given: 'Cy', family: 'Cole', emails: family);
      final left = run(
        google: [
          g('people/ann', person(given: 'Ann', family: 'Cole', emails: family)),
        ],
        graph: [h('H-bob', bob), h('H-cy', cy)],
        links: [
          link(
            1,
            'people/ann',
            null,
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ),
          link(
            2,
            null,
            'H-bob',
            state: ContactLinkState.held,
            reason: ContactHeldReason.candidate,
          ),
          link(
            3,
            null,
            'H-cy',
            state: ContactLinkState.held,
            reason: ContactHeldReason.candidate,
          ),
        ],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.leaveOut,
            googleName: 'people/ann',
          ),
        ],
      );
      expect(byLink(left, 1)!.reason, ContactHeldReason.leftOut);
      expect(byLink(left, 2)!.reason, ContactHeldReason.waiting);
      expect(byLink(left, 3)!.reason, ContactHeldReason.waiting);
      expect(
        left.reviews.map((r) => r.graphId),
        unorderedEquals(['H-bob', 'H-cy']),
      );
    });

    test('an answer whose contact has gone since is dropped', () {
      final plan = run(
        googleGone: {'people/c1'},
        links: [
          link(
            1,
            'people/c1',
            null,
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ),
        ],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.copyAnyway,
            googleName: 'people/c1',
          ),
        ],
      );
      expect(plan.links.where((l) => l.create != null), isEmpty);
      expect(byLink(plan, 1)!.removeRow, isTrue);
      expect(plan.answers, [ContactAnswerOutcome.dropped]);
    });

    test('an answer about a contact moved out of Contacts is dropped', () {
      // Outlook H1 was moved to another folder: no run reads it while it
      // is away, so a waiting answer would wait for ever.
      final differs = ann.withValue(ContactField.company, 'Hadco');
      final plan = run(
        google: [g('people/c1', differs), g('people/c2', ann)],
        graphMovedOut: {'H1', 'H2'},
        links: [
          link(1, 'people/c1', 'H1', base: ann),
          link(
            2,
            null,
            'H2',
            base: ann,
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ),
        ],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.useGoogle,
            googleName: 'people/c1',
            graphId: 'H1',
          ),
          const ContactAnswer(
            ContactAnswerKind.samePerson,
            googleName: 'people/c2',
            graphId: 'H2',
          ),
        ],
      );
      expect(plan.answers, [
        ContactAnswerOutcome.dropped,
        ContactAnswerOutcome.dropped,
      ]);
      // The pair is held as moved out, both ids kept, nothing written.
      final pair = byLink(plan, 1)!;
      expect(pair.reason, ContactHeldReason.movedOut);
      expect(pair.graphId, 'H1');
      expect(pair.writes, isFalse);
      expect(byLink(plan, 2), isNull, reason: 'H2 is not paired');
    });

    test('Apply them holds a pair moved out of Contacts as moved out', () {
      final held = [
        for (final i in [1, 2])
          link(
            i,
            'people/c$i',
            'H$i',
            base: ann,
            state: ContactLinkState.held,
            reason: ContactHeldReason.changeBrake,
          ),
      ];
      final changed = ann.withValue(ContactField.company, 'New');
      final plan = run(
        google: [g('people/c1', changed), g('people/c2', changed)],
        graph: [h('H1', ann)],
        graphMovedOut: {'H2'},
        links: held,
        answers: const [ContactAnswer(ContactAnswerKind.applyHeld)],
      );
      expect(plan.answers, [ContactAnswerOutcome.applied]);
      expect(byLink(plan, 1)!.graphWrite!.fields, {ContactField.company});
      final away = byLink(plan, 2)!;
      expect(away.reason, ContactHeldReason.movedOut);
      expect(away.googleName, 'people/c2');
      expect(away.graphId, 'H2');
      expect(away.writes, isFalse);
    });

    test('a kept contact copied back, or deleted here too', () {
      final kept = link(
        1,
        null,
        'H1',
        base: ann,
        state: ContactLinkState.held,
        reason: ContactHeldReason.kept,
      );
      final back = run(
        graph: [h('H1', ann)],
        links: [kept],
        answers: [
          const ContactAnswer(ContactAnswerKind.copyBack, graphId: 'H1'),
        ],
      );
      expect(byLink(back, 1)!.create!.side, ContactSide.google);
      final gone = run(
        links: [kept],
        answers: [
          const ContactAnswer(ContactAnswerKind.deleteHereToo, graphId: 'H1'),
        ],
      );
      final delete = byLink(gone, 1)!.delete!;
      expect(delete.contactId, 'H1');
      expect(delete.cause, ContactDeleteCause.answered);
    });

    test('a refused contact is tried again when it changes', () {
      final refused = link(
        1,
        'people/c1',
        null,
        state: ContactLinkState.held,
        reason: ContactHeldReason.refused,
      );
      final unchanged = run(google: [g('people/c1', ann)], links: [refused]);
      expect(unchanged.links, isEmpty);
      final changed = run(
        google: [g('people/c1', ann, etag: 'etag-new')],
        links: [refused],
      );
      expect(byLink(changed, 1)!.create!.side, ContactSide.graph);
    });
  });

  group('Restore', () {
    test('made again on both sides from the bin', () {
      final plan = run(
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.graph,
            contactId: 'H1',
            partnerId: 'people/c1',
            raw: const {
              'id': 'H1',
              'givenName': 'Ann',
              'surname': 'Cole',
              'fileAs': 'Cole, Ann',
            },
            partnerBase: ann.toJson(),
            title: 'Ann Cole',
            restore: true,
          ),
        ],
      );
      final restore = plan.restores.single;
      expect(restore.alreadyBack, isFalse);
      expect(restore.graphRaw!['fileAs'], 'Cole, Ann');
      expect(restore.googleDetails, ann);
      expect(plan.counts.restores, 1);
    });

    test('an address someone else has is not the contact back', () {
      final john = person(
        given: 'John',
        family: 'Roe',
        emails: ['info@acme.example', 'john@x'],
      );
      final plan = run(
        google: [g('people/john', john)],
        graph: [h('H-john', john)],
        links: [link(1, 'people/john', 'H-john', base: john)],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.google,
            contactId: 'people/info',
            partnerId: 'H-info',
            raw: const {
              'resourceName': 'people/info',
              'names': [
                {'unstructuredName': 'Info Desk'},
              ],
              'emailAddresses': [
                {'value': 'info@acme.example'},
              ],
            },
            partnerBase: SyncedContact({
              ContactField.name: ContactName.of(display: 'Info Desk'),
              ContactField.emails: ['info@acme.example'],
            }).toJson(),
            restore: true,
          ),
        ],
      );
      final restore = plan.restores.single;
      expect(restore.alreadyBack, isFalse);
      expect(restore.googleRaw, isNotNull, reason: 'made again');
      expect(restore.graphDetails, isNotNull);
      expect(plan.binAlreadyBack, isEmpty);
    });

    test('an address two contacts share finds neither back', () {
      final family = ['fam@x'];
      final plan = run(
        google: [
          g('people/a', person(given: 'Ann', family: 'Cole', emails: family)),
          g('people/b', person(given: 'Bob', family: 'Cole', emails: family)),
        ],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.google,
            contactId: 'people/x',
            raw: const {
              'resourceName': 'people/x',
              'names': [
                {'givenName': 'Cy', 'familyName': 'Cole'},
              ],
              'emailAddresses': [
                {'value': 'fam@x'},
              ],
            },
            restore: true,
          ),
        ],
      );
      final restore = plan.restores.single;
      expect(restore.googleName, isNull);
      expect(restore.googleRaw, isNotNull, reason: 'made again');
    });

    test('an address two contacts share on the other side finds none back',
        () {
      final family = ['fam@x'];
      final cy = person(given: 'Cy', family: 'Cole', emails: family);
      final plan = run(
        // One Gmail contact has the address, as the deleted one did, but
        // two Outlook contacts share it: a family email, not Cy's own.
        google: [g('people/y', cy)],
        graph: [
          h('H-a', person(given: 'Ann', family: 'Cole', emails: family)),
          h('H-b', person(given: 'Bob', family: 'Cole', emails: family)),
        ],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.google,
            contactId: 'people/x',
            partnerId: 'H-x',
            raw: const {
              'resourceName': 'people/x',
              'names': [
                {'givenName': 'Cy', 'familyName': 'Cole'},
              ],
              'emailAddresses': [
                {'value': 'fam@x'},
              ],
            },
            partnerBase: cy.toJson(),
            restore: true,
          ),
        ],
      );
      final restore = plan.restores.single;
      expect(restore.googleName, isNull, reason: 'people/y is not Cy back');
      expect(restore.googleRaw, isNotNull, reason: 'made again');
      expect(restore.graphDetails, cy);
    });

    test('another\'s held contact on the address is not used', () {
      // Ann and Bob Cole share fam@x. Bob is only in Gmail, left out.
      // Restoring Ann's Outlook copy must make her Gmail copy again, not
      // take Bob's contact and row and fill him with Ann.
      final annFam = person(given: 'Ann', family: 'Cole', emails: ['fam@x']);
      final bob = person(given: 'Bob', family: 'Cole', emails: ['fam@x']);
      final plan = run(
        google: [g('people/c5', bob)],
        links: [
          link(
            5,
            'people/c5',
            null,
            base: bob,
            state: ContactLinkState.held,
            reason: ContactHeldReason.leftOut,
          ),
        ],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.graph,
            contactId: 'H9',
            partnerId: 'people/c9',
            raw: const {
              'id': 'H9',
              'givenName': 'Ann',
              'surname': 'Cole',
              'emailAddresses': [
                {'address': 'fam@x'},
              ],
            },
            partnerBase: annFam.toJson(),
            restore: true,
          ),
        ],
      );
      final restore = plan.restores.single;
      expect(restore.googleName, isNull);
      expect(restore.linkId, isNull, reason: 'Bob keeps his row');
      expect(restore.googleDetails, annFam, reason: 'Ann made again');
      expect(restore.graphRaw, isNotNull);
      expect(byLink(plan, 5), isNull, reason: 'Bob left as he was');
    });

    test('a contact back but held is used, its row carried', () {
      final heldC9 = link(
        5,
        'people/c9',
        null,
        base: ann,
        state: ContactLinkState.held,
        reason: ContactHeldReason.waiting,
      );
      // Case a: the bin row is Gmail c9's own.
      final own = run(
        google: [g('people/c9', ann)],
        links: [heldC9],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.google,
            contactId: 'people/c9',
            partnerId: 'H9',
            partnerBase: ann.toJson(),
            restore: true,
          ),
        ],
      );
      final a = own.restores.single;
      expect(a.googleName, 'people/c9');
      expect(a.linkId, 5, reason: 'no second row naming c9');
      expect(a.googleRaw, isNull);
      expect(a.graphDetails, ann);
      // Case b: Outlook H9's partner c9 is back, held.
      final partner = run(
        google: [g('people/c9', ann)],
        links: [heldC9],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.graph,
            contactId: 'H9',
            partnerId: 'people/c9',
            raw: const {'id': 'H9', 'givenName': 'Ann', 'surname': 'Cole'},
            partnerBase: ann.toJson(),
            restore: true,
          ),
        ],
      );
      final b = partner.restores.single;
      expect(b.googleName, 'people/c9');
      expect(b.linkId, 5);
      expect(b.googleDetails, isNull, reason: 'Ann is not made twice');
      expect(b.graphRaw, isNotNull);
    });

    test('already back and paired: the bin row is dropped', () {
      final plan = run(
        links: [link(1, 'people/c1', 'H1', base: ann)],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.graph,
            contactId: 'H1',
            partnerId: 'people/c1',
            partnerBase: ann.toJson(),
            restore: true,
          ),
        ],
      );
      expect(plan.restores.single.alreadyBack, isTrue);
      expect(plan.binAlreadyBack, [9]);
    });

    test('made again by Ron and copied by the sync, it is Already back', () {
      // The sync deleted Outlook H9 because Ron deleted Gmail c9. Ron then
      // made Ann again as c9b, which the sync copied to H9b and paired.
      // Restore on H9 must not make a second Ann on each side.
      final plan = run(
        google: [g('people/c9b', ann)],
        graph: [h('H9b', ann, tag: 'people/c9b')],
        links: [link(3, 'people/c9b', 'H9b', base: ann)],
        googleGone: {'people/c9'},
        graphGone: {'H9'},
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.graph,
            contactId: 'H9',
            partnerId: 'people/c9',
            raw: const {
              'id': 'H9',
              'givenName': 'Ann',
              'surname': 'Cole',
              'emailAddresses': [
                {'address': 'ann@x.example', 'name': 'Ann Cole'},
              ],
            },
            partnerBase: ann.toJson(),
            title: 'Ann Cole',
            restore: true,
          ),
        ],
      );
      final restore = plan.restores.single;
      expect(restore.alreadyBack, isTrue);
      expect(restore.graphRaw, isNull);
      expect(restore.googleDetails, isNull);
      expect(plan.binAlreadyBack, [9]);
      expect(plan.counts.restores, 0);
      expect(plan.links.where((l) => l.create != null), isEmpty);

      // Matches each paired with someone else are not it back.
      final annOnly = person(given: 'Ann', family: 'Cole');
      final apart = run(
        google: [g('people/c9b', ann), g('people/c7', annOnly)],
        graph: [h('H9b', ann), h('H7', annOnly)],
        links: [
          link(3, 'people/c9b', 'H7', base: ann),
          link(4, 'people/c7', 'H9b', base: ann),
        ],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.graph,
            contactId: 'H9',
            partnerId: 'people/c9',
            raw: const {
              'id': 'H9',
              'givenName': 'Ann',
              'surname': 'Cole',
              'emailAddresses': [
                {'address': 'ann@x.example'},
              ],
            },
            partnerBase: ann.toJson(),
            restore: true,
          ),
        ],
      );
      expect(apart.restores.single.alreadyBack, isFalse);
      expect(apart.binAlreadyBack, isEmpty);

      // Paired earlier in the same run, by Ron's Same person.
      final answered = run(
        google: [g('people/c9b', ann)],
        graph: [h('H9b', ann)],
        links: [
          link(
            3,
            'people/c9b',
            null,
            base: ann,
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ),
        ],
        answers: const [
          ContactAnswer(
            ContactAnswerKind.samePerson,
            googleName: 'people/c9b',
            graphId: 'H9b',
          ),
        ],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.graph,
            contactId: 'H9',
            partnerId: 'people/c9',
            raw: const {
              'id': 'H9',
              'givenName': 'Ann',
              'surname': 'Cole',
              'emailAddresses': [
                {'address': 'ann@x.example'},
              ],
            },
            partnerBase: ann.toJson(),
            restore: true,
          ),
        ],
      );
      expect(answered.answers, [ContactAnswerOutcome.applied]);
      expect(answered.restores.single.alreadyBack, isTrue);
    });

    test('a family member or namesake on the address is not it back', () {
      ContactBinInput binOf(Map<String, Object?> raw, SyncedContact partner) =>
          ContactBinInput(
            binId: 9,
            side: ContactSide.graph,
            contactId: 'H9',
            partnerId: 'people/c9',
            raw: raw,
            partnerBase: partner.toJson(),
            restore: true,
          );
      // Ann and Bob Cole shared fam@x; Ron deleted Ann in Gmail and the
      // sync deleted Outlook H9. Only Bob, paired, has fam@x now.
      final annFam = person(given: 'Ann', family: 'Cole', emails: ['fam@x']);
      final bob = person(given: 'Bob', family: 'Cole', emails: ['fam@x']);
      final family = run(
        google: [g('people/c5', bob)],
        graph: [h('H5', bob)],
        links: [link(5, 'people/c5', 'H5', base: bob)],
        bin: [
          binOf(const {
            'id': 'H9',
            'givenName': 'Ann',
            'surname': 'Cole',
            'emailAddresses': [
              {'address': 'fam@x'},
            ],
          }, annFam),
        ],
      );
      final restore = family.restores.single;
      expect(restore.alreadyBack, isFalse, reason: 'the bin holds Ann');
      expect(restore.graphRaw, isNotNull);
      expect(restore.googleDetails, annFam);
      expect(family.binAlreadyBack, isEmpty);

      // John Roe Jr. is not John Roe Sr. back.
      SyncedContact roe(String suffix) => SyncedContact({
        ContactField.name: ContactName.of(
          given: 'John',
          family: 'Roe',
          suffix: suffix,
        ),
        ContactField.emails: ['roe@x'],
      });
      final namesake = run(
        google: [g('people/c5', roe('Jr.'))],
        graph: [h('H5', roe('Jr.'))],
        links: [link(5, 'people/c5', 'H5', base: roe('Jr.'))],
        bin: [
          binOf(const {
            'id': 'H9',
            'givenName': 'John',
            'surname': 'Roe',
            'generation': 'Sr.',
            'emailAddresses': [
              {'address': 'roe@x'},
            ],
          }, roe('Sr.')),
        ],
      );
      expect(namesake.restores.single.alreadyBack, isFalse);
    });

    test('a nameless contact made again and copied is Already back', () {
      // info@acme, no name but the company shown. Ron made it again as
      // c9b, which the sync copied to H9b and paired.
      final info = SyncedContact({
        ContactField.name: ContactName.of(display: 'Acme'),
        ContactField.emails: ['info@acme.example'],
        ContactField.company: 'Acme',
      });
      final plan = run(
        google: [g('people/c9b', info)],
        graph: [h('H9b', info, tag: 'people/c9b')],
        links: [link(3, 'people/c9b', 'H9b', base: info)],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.graph,
            contactId: 'H9',
            partnerId: 'people/c9',
            raw: const {
              'id': 'H9',
              'displayName': 'Acme',
              'companyName': 'Acme',
              'emailAddresses': [
                {'address': 'info@acme.example'},
              ],
            },
            partnerBase: info.toJson(),
            restore: true,
          ),
        ],
      );
      expect(plan.restores.single.alreadyBack, isTrue);
      expect(plan.binAlreadyBack, [9]);
      // Another company on the address is another contact.
      final other = info
          .withValue(ContactField.company, 'Beta')
          .withValue(ContactField.name, ContactName.of(display: 'Beta'));
      final beta = run(
        google: [g('people/c9b', other)],
        graph: [h('H9b', other, tag: 'people/c9b')],
        links: [link(3, 'people/c9b', 'H9b', base: other)],
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.graph,
            contactId: 'H9',
            partnerId: 'people/c9',
            raw: const {
              'id': 'H9',
              'displayName': 'Acme',
              'companyName': 'Acme',
              'emailAddresses': [
                {'address': 'info@acme.example'},
              ],
            },
            partnerBase: info.toJson(),
            restore: true,
          ),
        ],
      );
      expect(beta.restores.single.alreadyBack, isFalse);
    });
  });

  test('one pair compared directly, as the runner re-plans a moved one', () {
    final base = person(
      given: 'Ann',
      family: 'Cole',
      more: {ContactField.office: 'A'},
    );
    final pair = planPairedContact(
      googleNow: base.withValue(ContactField.office, 'B'),
      googleBase: base,
      graphNow: base,
      graphBase: base,
      normaliser: norm,
    );
    expect(pair.toGraph, {ContactField.office});
    expect(pair.toGoogle, isEmpty);
    expect(pair.removes, isTrue);
  });

  group('a pair planned again after a stale read', () {
    final base = person(
      given: 'Ann',
      family: 'Cole',
      more: {ContactField.office: 'A'},
    );

    test('keeps the first sync\'s rules', () {
      // First sync: Gmail changed the office (Outlook has one, so it is
      // listed, not overwritten) and added a nickname (copied).
      final plan = run(
        firstSync: true,
        google: [
          g(
            'people/c1',
            base
                .withValue(ContactField.office, 'B')
                .withValue(ContactField.nickname, 'Annie'),
          ),
        ],
        links: [link(1, 'people/c1', 'H1', base: base)],
      );
      final first = byLink(plan, 1)!;
      expect(first.graphWrite!.fields, {ContactField.nickname});
      // The PATCH met a newer changeKey: Ron added a job title in Outlook
      // meanwhile. Planned again, the office is still only listed.
      final again = first.replan(
        graph: h(
          'H1',
          base.withValue(ContactField.jobTitle, 'Lead'),
          key: 'key-H1-2',
        ),
      );
      expect(again.plan.graphWrite!.fields, {ContactField.nickname});
      expect(again.plan.graphWrite!.version, 'key-H1-2');
      expect(again.plan.googleWrite!.fields, {ContactField.jobTitle});
      expect(again.plan.googleWrite!.version, first.googleEtag);
      expect(again.plan.linkId, 1);
      expect(again.reviews.single.kind, ContactReviewKind.differing);
      expect(again.reviews.single.fields, [ContactField.office]);
      expect(again.plan.settings!.firstSync, isTrue);
    });

    test('keeps a new pair\'s rules, and refuses what it cannot plan', () {
      final plan = run(
        google: [
          g('people/c1', ann.withValue(ContactField.company, 'Hadco')),
        ],
        graph: [h('H1', ann.withValue(ContactField.company, 'Hadco Ltd'))],
      );
      final first = byGoogle(plan, 'people/c1')!;
      expect(first.newPair, isTrue);
      final again = first.replan(
        graph: h(
          'H1',
          ann
              .withValue(ContactField.company, 'Hadco Ltd')
              .withValue(ContactField.office, 'B2'),
          key: 'key-H1-2',
        ),
      );
      // Still merged without overwriting: the company is listed, the
      // office filled in.
      expect(again.plan.newPair, isTrue);
      expect(again.plan.graphWrite, isNull);
      expect(again.plan.googleWrite!.fields, {ContactField.office});
      expect(again.reviews.single.fields, [ContactField.company]);
      expect(
        () => first.replan(
          graph: GraphContact(
            id: 'H1',
            details: ann,
            missing: const {'surname'},
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => const ContactLinkPlan(linkId: 1, removeRow: true).replan(),
        throwsStateError,
      );
    });
  });
}

extension on ContactLinkPlan {
  Map<String, Object?> graphPatchFor(Map<String, Object?> current) =>
      graphWrite!.graphPatch(current);
}
