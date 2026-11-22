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
        graph: [h('H1', person(given: 'Annie', family: 'Cole'))],
      );
      final pair = byGoogle(plan, 'people/c1')!;
      expect(pair.graphId, 'H1');
      expect(pair.state, ContactLinkState.paired);
      expect(pair.newPair, isTrue);
      expect(pair.create, isNull);
      expect(plan.counts.pairUp, 1);
      expect(plan.counts.addToGraph, 0);
      // Renamed since, but sharing an email: one person still.
      final renamed = run(
        google: [
          g(
            'people/c1',
            person(given: 'Ann', family: 'Cole', emails: ['ann@x.example']),
            tag: 'H1',
          ),
        ],
        graph: [
          h(
            'H1',
            person(given: 'Ann', family: 'Lee', emails: ['ann@x.example']),
          ),
        ],
      );
      expect(byGoogle(renamed, 'people/c1')!.graphId, 'H1');
      // Or a mobile.
      final byMobile = run(
        google: [
          g(
            'people/c1',
            person(given: 'Ann', family: 'Cole', mobile: '212 555 0100'),
            tag: 'H1',
          ),
        ],
        graph: [
          h(
            'H1',
            person(given: 'Ann', family: 'Lee', mobile: '+1 212 555 0100'),
          ),
        ],
      );
      expect(byGoogle(byMobile, 'people/c1')!.graphId, 'H1');
    });

    test('a tag between two people plainly different now is asked about',
        () {
      // A copy Ron typed another person over keeps MyEmail's link.
      final plan = run(
        google: [
          g('people/c1', person(given: 'Ann', family: 'Cole'), tag: 'H1'),
        ],
        graph: [h('H1', person(given: 'Bob', family: 'Roe'))],
      );
      expect(plan.links.where((l) => l.state == ContactLinkState.paired),
          isEmpty);
      final item = plan.reviews.single;
      expect(item.kind, ContactReviewKind.newContact);
      expect(item.reason, ContactReviewReason.namesDisagree);
      expect(item.googleName, 'people/c1');
      expect(item.candidates, ['H1']);
      expect(item.samePersonOffered, isTrue);
      expect(byGraph(plan, 'H1')!.reason, ContactHeldReason.candidate);
      // One due to be deleted is not offered: the usual rules follow.
      final orphan = run(
        google: [g('people/c5', ann)],
        graph: [
          h('H5', person(given: 'Bob', family: 'Roe'), tag: 'people/c5'),
        ],
        graphGone: {'X'},
        links: [link(1, 'people/c5', 'X', base: ann)],
      );
      expect(orphan.reviews, isEmpty);
      expect(byLink(orphan, 1)!.delete!.contactId, 'people/c5');
      expect(byGraph(orphan, 'H5')!.create!.side, ContactSide.google);
    });

    test('a hand copy typed over as Bob does not take Ann by its tag', () {
      // After a reinstall: Gmail Ann (ann@x); Outlook Ann, made by Ron
      // with her email and no tag; and Bob Roe, a hand copy of the sync's
      // Ann typed over, still tagged with Gmail Ann.
      final ann = person(given: 'Ann', family: 'Cole', emails: ['ann@x']);
      final bob = person(given: 'Bob', family: 'Roe', emails: ['bob@x']);
      final plan = run(
        google: [g('people/c1', ann)],
        graph: [h('H-bob', bob, tag: 'people/c1'), h('H-ann', ann)],
      );
      expect(byGoogle(plan, 'people/c1')!.graphId, 'H-ann');
      final item = plan.reviews.single;
      expect(item.graphId, 'H-bob');
      expect(item.reason, ContactReviewReason.taggedPaired);
      // The hand copy alone: no silent pair either.
      final alone = run(
        google: [g('people/c1', ann)],
        graph: [h('H-bob', bob, tag: 'people/c1')],
      );
      expect(
        alone.links.where(
          (l) => l.googleName == 'people/c1' && l.graphId == 'H-bob',
        ),
        isEmpty,
      );
      expect(alone.reviews.single.graphId, 'H-bob');
      // Nor one retyped as just "Bob", or as a company only: a missing
      // family name, or no name, is no agreement.
      for (final typedOver in [
        person(given: 'Bob', emails: ['bob@x']),
        SyncedContact({
          ContactField.company: 'Acme',
          ContactField.emails: ['info@acme.example'],
        }),
      ]) {
        final plan = run(
          google: [g('people/c1', ann)],
          graph: [h('H-x', typedOver, tag: 'people/c1')],
        );
        expect(
          plan.links.where(
            (l) => l.googleName == 'people/c1' && l.graphId == 'H-x',
          ),
          isEmpty,
        );
        expect(plan.reviews.single.graphId, 'H-x');
      }
      // A first name alone on both, the same, is one person.
      final first = person(given: 'Ann');
      final same = run(
        google: [g('people/c1', first)],
        graph: [h('H1', first, tag: 'people/c1')],
      );
      expect(byGoogle(same, 'people/c1')!.graphId, 'H1');
    });

    test('a tag naming an old name is moved on when it pairs', () {
      // A reinstall; Ron merged c5 into c6, and H5 is the sync's copy of
      // c5, tagged with it.
      GoogleContact merged() => GoogleContact(
        resourceName: 'people/c6',
        details: ann,
        etag: 'e6',
        previousNames: const ['people/c5'],
        person: const {'resourceName': 'people/c6'},
      );
      final plan = run(
        google: [merged()],
        graph: [h('H5', ann, tag: 'people/c5')],
      );
      expect(byGoogle(plan, 'people/c6')!.graphId, 'H5');
      expect(plan.graphTagMoves, {'H5': 'people/c6'});
      // Placed by its own tag (c6 due to be deleted, its partner gone).
      final own = run(
        google: [merged()],
        graph: [h('H5', ann, tag: 'people/c5')],
        graphGone: {'X'},
        links: [link(1, 'people/c5', 'X', base: ann, etag: 'e6')],
      );
      final pair = byLink(own, 1)!;
      expect(pair.googleName, 'people/c6');
      expect(pair.graphId, 'H5');
      expect(own.graphTagMoves, {'H5': 'people/c6'});
    });

    test('a tag the other side carries pairs them, whichever is placed first',
        () {
      // A reinstall: no rows. Each pair as the sync left it, its copy
      // tagged with the original; only a name and a landline, nothing
      // else to match by. Gmail's are placed first.
      SyncedContact landline(String given, String phone) => SyncedContact({
        ContactField.name: ContactName.of(given: given, family: 'Cole'),
        ContactField.homePhones: [phone],
      });
      final ann = landline('Ann', '212 555 0101');
      final bob = landline('Bob', '212 555 0102');
      final plan = run(
        google: [
          // Gmail's original, with its Outlook copy tagged with it.
          g('people/c1', ann),
          // Gmail's copy of an Outlook original, tagged with it.
          g('people/c2', bob, tag: 'H2'),
        ],
        graph: [h('H1', ann, tag: 'people/c1'), h('H2', bob)],
      );
      expect(byGoogle(plan, 'people/c1')!.graphId, 'H1');
      expect(byGoogle(plan, 'people/c2')!.graphId, 'H2');
      expect(plan.counts.pairUp, 2);
      expect(plan.links.where((l) => l.create != null), isEmpty);
      expect(plan.links.where((l) => l.state == ContactLinkState.held),
          isEmpty);
      expect(plan.reviews, isEmpty);
      // Not a tagged copy paired with another, nor one of two.
      final taken = run(
        google: [g('people/c1', ann), g('people/c9', ann)],
        graph: [h('H1', ann, tag: 'people/c1')],
        links: [link(9, 'people/c9', 'H1', base: ann)],
      );
      expect(byGoogle(taken, 'people/c1')?.graphId, isNot('H1'));
      final two = run(
        google: [g('people/c1', ann)],
        graph: [
          h('H1', ann, tag: 'people/c1'),
          h('H1b', ann, tag: 'people/c1'),
        ],
      );
      expect(
        two.links.where(
          (l) => l.googleName == 'people/c1' && l.graphId != null,
        ),
        isEmpty,
      );
    });

    test('a tag naming a contact already paired waits under Needs a look', () {
      // No email or mobile in common: not a copy of the paired Ann.
      final plan = run(
        google: [
          g('people/new', person(given: 'Ann', family: 'Cole'), tag: 'H1'),
        ],
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
      // Another full name on the address: not a copy of the paired Ann.
      final annie = person(
        given: 'Annie',
        family: 'Cole',
        emails: ['ann@x.example'],
      );
      final plan = run(
        google: [g('people/new', annie)],
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
      final annie = person(
        given: 'Annie',
        family: 'Cole',
        emails: ['ann@x.example'],
      );
      final plan = run(
        google: [g('people/new', annie)],
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

    test('an old address still shown is no name', () {
      // Outlook kept showing bob@x after Ron changed the address to
      // bob@y: a new pair does not give Gmail the name "bob@x".
      final paired = run(
        google: [
          g('people/c1', SyncedContact({
            ContactField.emails: ['bob@y.example'],
          })),
        ],
        graph: [
          outlook('H1', {
            'displayName': 'bob@x.example',
            'emailAddresses': [
              {'address': 'bob@y.example'},
            ],
          }),
        ],
      );
      final pair = paired.links.singleWhere(
        (l) => l.googleName == 'people/c1',
      );
      expect(pair.googleWrite, isNull);
      // A base left showing the old address (from before it was taken
      // in) is no name either: a name typed in Gmail goes to Outlook,
      // with no clash.
      final plan = run(
        google: [
          g(
            'people/c1',
            person(given: 'Ann', family: 'Lee', emails: ['ann@y.example']),
            at: later,
          ),
        ],
        graph: [
          outlook('H1', {
            'displayName': 'ann@y.example',
            'emailAddresses': [
              {'address': 'ann@y.example'},
            ],
          }, at: earlier),
        ],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: SyncedContact({
              ContactField.emails: ['ann@y.example'],
            }),
            graphBase: read({
              'displayName': 'ann@x.example',
              'emailAddresses': [
                {'address': 'ann@y.example'},
              ],
            }),
          ),
        ],
      );
      final p = byLink(plan, 1)!;
      expect(p.graphWrite!.fields, contains(ContactField.name));
      expect(p.removes, isFalse);
      expect(plan.reviews, isEmpty);
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
    test('a contact merged in Gmail into one of another name is asked about',
        () {
      // Ron merged Bob Roe into Robert Smith with Merge & fix: Google
      // reports Bob as deleted, and Robert, paired with his own Hadco
      // contact, now holds Bob's email.
      final bob = person(
        given: 'Bob',
        family: 'Roe',
        emails: ['bob@x.example'],
      );
      final robert = person(
        given: 'Robert',
        family: 'Smith',
        emails: ['rob@x.example'],
      );
      final merged = robert.withValue(ContactField.emails, [
        'rob@x.example',
        'bob@x.example',
      ]);
      final rows = [
        link(1, 'people/c1', 'H1', base: robert),
        link(2, 'people/c2', 'H2', base: bob),
      ];
      final plan = run(
        google: [gDeleted('people/c2'), g('people/c1', merged)],
        links: rows,
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      final held = byLink(plan, 2)!;
      expect(held.state, ContactLinkState.held);
      expect(held.reason, ContactHeldReason.waiting);
      expect((held.googleName, held.graphId), (null, 'H2'));
      expect(held.partnerId, 'people/c2', reason: 'for the bin, if deleted');
      expect(held.partnerBase, bob);
      final item = plan.reviews.singleWhere(
        (r) => r.kind == ContactReviewKind.mergedInGoogle,
      );
      expect((item.googleName, item.graphId), ('people/c1', 'H2'));
      // Robert's Hadco contact takes the email merged in, as any change.
      expect(byLink(plan, 1)!.graphWrite!.fields, {ContactField.emails});
      expect(plan.brakes, isEmpty);
      // The survivor known only from its row's base: the same.
      final fromBase = run(
        google: [gDeleted('people/c2')],
        links: [link(1, 'people/c1', 'H1', base: merged), rows[1]],
      );
      expect(fromBase.links.where((l) => l.delete != null), isEmpty);
      expect(byLink(fromBase, 2)!.reason, ContactHeldReason.waiting);
      // A copy of the same person held beside it is still moved to first.
      final copy = run(
        google: [gDeleted('people/c2')],
        links: [
          link(2, 'people/c2', 'H2', base: bob),
          link(
            3,
            'people/c3',
            null,
            base: bob,
            state: ContactLinkState.held,
            reason: ContactHeldReason.duplicate,
          ),
        ],
      );
      final moved = byLink(copy, 2)!;
      expect((moved.googleName, moved.graphId), ('people/c3', 'H2'));
      expect(
        copy.reviews.where((r) => r.kind == ContactReviewKind.mergedInGoogle),
        isEmpty,
      );
    });

    test('a held Hadco copy of a contact merged away is asked about with it',
        () {
      // Bob Smith, with a held Hadco copy, merged into Robert Smith.
      final bob = person(
        given: 'Bob',
        family: 'Smith',
        emails: ['bob@x.example'],
      );
      final robert = person(
        given: 'Robert',
        family: 'Smith',
        emails: ['rob@y.example'],
      );
      final merged = robert.withValue(ContactField.emails, [
        'rob@y.example',
        'bob@x.example',
      ]);
      final plan = run(
        google: [gDeleted('people/bob'), g('people/rob', merged)],
        links: [
          link(1, 'people/bob', 'H-bob', base: bob),
          link(
            2,
            null,
            'H-bob2',
            base: bob,
            state: ContactLinkState.held,
            reason: ContactHeldReason.duplicate,
          ),
          link(3, 'people/rob', 'H-rob', base: robert),
        ],
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      expect(plan.links.where((l) => l.create != null), isEmpty);
      // Not kept as the copy of a gone contact: Copy it back would make a
      // second Gmail Bob, of the one just merged.
      expect(
        plan.reviews.where((r) => r.kind == ContactReviewKind.kept),
        isEmpty,
      );
      expect(
        {
          for (final r in plan.reviews)
            if (r.kind == ContactReviewKind.mergedInGoogle)
              (r.googleName, r.graphId),
        },
        {('people/rob', 'H-bob'), ('people/rob', 'H-bob2')},
      );
      final copy = byLink(plan, 2)!;
      expect((copy.googleName, copy.graphId), (null, 'H-bob2'));
      expect(copy.state, ContactLinkState.held);
      expect(copy.reason, ContactHeldReason.waiting);
      expect(copy.partnerId, isNull);
      expect(byLink(plan, 1)!.reason, ContactHeldReason.waiting);
      // Delete it in Hadco too, on the copy: deleted there, nothing made.
      final deleted = run(
        links: [
          link(
            2,
            null,
            'H-bob2',
            base: bob,
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ),
        ],
        answers: const [
          ContactAnswer(ContactAnswerKind.deleteHereToo, graphId: 'H-bob2'),
        ],
      );
      final delete = byLink(deleted, 2)!.delete!;
      expect((delete.side, delete.contactId), (ContactSide.graph, 'H-bob2'));
      expect(deleted.links.where((l) => l.create != null), isEmpty);
    });

    test('held Hadco copies of one person merged away go with it', () {
      // Bob Smith merged into another Bob Smith Ron left out of the sync:
      // Bob's Hadco copies are copies of one person, one of them joined
      // only through the other (by a mobile), none sharing the pair's
      // email.
      final bob = person(
        given: 'Bob',
        family: 'Smith',
        emails: ['bob@x.example'],
      );
      final left = person(
        given: 'Bob',
        family: 'Smith',
        emails: ['bob@z.example'],
      );
      final plan = run(
        google: [
          gDeleted('people/bob'),
          g(
            'people/left',
            left.withValue(ContactField.emails, [
              'bob@z.example',
              'bob@x.example',
            ]),
          ),
        ],
        links: [
          link(1, 'people/bob', 'H-bob', base: bob),
          link(
            2,
            null,
            'H-bob2',
            base: bob.withValue(ContactField.mobile, '+1 212 555 0150'),
            state: ContactLinkState.held,
            reason: ContactHeldReason.duplicate,
          ),
          link(
            3,
            null,
            'H-bob3',
            base: person(
              given: 'Bob',
              family: 'Smith',
              emails: ['bob@w.example'],
              mobile: '+1 212 555 0150',
            ),
            state: ContactLinkState.held,
            reason: ContactHeldReason.duplicate,
          ),
          link(
            4,
            'people/left',
            null,
            base: left,
            state: ContactLinkState.held,
            reason: ContactHeldReason.leftOut,
          ),
        ],
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      expect(
        plan.reviews.where((r) => r.kind == ContactReviewKind.kept),
        isEmpty,
      );
      expect(
        {
          for (final r in plan.reviews)
            if (r.kind == ContactReviewKind.mergedInGoogle)
              (r.googleName, r.graphId),
        },
        {
          ('people/left', 'H-bob'),
          ('people/left', 'H-bob2'),
          ('people/left', 'H-bob3'),
        },
      );
      for (final id in [2, 3]) {
        expect(byLink(plan, id)!.reason, ContactHeldReason.waiting);
      }
    });

    test('a contact merged away but paired again keeps its copies held', () {
      // Bob merged into Robert, then brought back in Gmail as a new
      // contact carrying his Hadco contact's tag: paired with it again,
      // so his held Hadco copy, read this run, is held again as a copy.
      final bob = person(
        given: 'Bob',
        family: 'Smith',
        emails: ['bob@x.example'],
      );
      final robert = person(
        given: 'Robert',
        family: 'Smith',
        emails: ['rob@y.example'],
      );
      final plan = run(
        google: [
          gDeleted('people/bob'),
          g(
            'people/rob',
            robert.withValue(ContactField.emails, [
              'rob@y.example',
              'bob@x.example',
            ]),
          ),
          g('people/back', bob, tag: 'H-bob'),
        ],
        graph: [h('H-bob2', bob, key: 'key-new')],
        links: [
          link(1, 'people/bob', 'H-bob', base: bob),
          link(
            2,
            null,
            'H-bob2',
            base: bob,
            state: ContactLinkState.held,
            reason: ContactHeldReason.duplicate,
          ),
          link(3, 'people/rob', 'H-rob', base: robert),
        ],
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      final pair = byGraph(plan, 'H-bob')!;
      expect(pair.state, ContactLinkState.paired);
      expect(pair.googleName, 'people/back');
      expect(
        plan.reviews.where((r) => r.kind == ContactReviewKind.mergedInGoogle),
        isEmpty,
      );
      final copy = byLink(plan, 2)!;
      expect(copy.reason, ContactHeldReason.duplicate);
      expect(copy.graphChangeKey, 'key-new');
    });

    test('six merges at once make six questions and no deletion brake', () {
      SyncedContact gone(int i) =>
          person(given: 'P$i', family: 'Gone', emails: ['p$i@x.example']);
      SyncedContact survivor(int i) => person(
        given: 'S$i',
        family: 'Kept',
        emails: ['s$i@x.example', 'p$i@x.example'],
      );
      final plan = run(
        google: [
          for (var i = 0; i < 6; i++) ...[
            gDeleted('people/c$i'),
            g('people/s$i', survivor(i)),
          ],
        ],
        links: [
          for (var i = 0; i < 6; i++) ...[
            link(i, 'people/c$i', 'H$i', base: gone(i)),
            link(10 + i, 'people/s$i', 'T$i', base: survivor(i)),
          ],
        ],
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      expect(plan.brakes, isEmpty);
      expect(
        plan.reviews.where((r) => r.kind == ContactReviewKind.mergedInGoogle),
        hasLength(6),
      );
    });

    test('a contact new this run is never the one merged into', () {
      // Bob merged into Robert; the same run brings a new Gmail Bob, made
      // again by hand with Bob's mobile, which Bob's held Hadco copy also
      // has. Robert is the one merged into, and the new Bob is placed by
      // the new-contact rules: asked about, his mobile on two contacts.
      final bob = person(
        given: 'Bob',
        family: 'Smith',
        emails: ['bob@x.example'],
        mobile: '+1 212 555 0100',
      );
      final robert = person(
        given: 'Robert',
        family: 'Smith',
        emails: ['rob@y.example'],
      );
      final plan = run(
        google: [
          gDeleted('people/bob'),
          g(
            'people/rob',
            robert.withValue(ContactField.emails, [
              'rob@y.example',
              'bob@x.example',
            ]),
          ),
          g(
            'people/new',
            person(given: 'Bob', family: 'Smith', mobile: '+1 212 555 0100'),
          ),
        ],
        links: [
          link(1, 'people/bob', 'H-bob', base: bob),
          link(
            2,
            null,
            'H-bob2',
            base: bob,
            state: ContactLinkState.held,
            reason: ContactHeldReason.duplicate,
          ),
          link(3, 'people/rob', 'H-rob', base: robert),
        ],
      );
      expect(
        {
          for (final r in plan.reviews)
            if (r.kind == ContactReviewKind.mergedInGoogle)
              (r.googleName, r.graphId),
        },
        {('people/rob', 'H-bob'), ('people/rob', 'H-bob2')},
      );
      final asked = plan.reviews.singleWhere(
        (r) => r.kind == ContactReviewKind.newContact,
      );
      expect(asked.googleName, 'people/new');
    });

    test('a contact merged away sharing only a home or work phone is asked '
        'about', () {
      // Bob Roe's home phone, merged into Robert Smith; Cal Poe's work
      // phone, on Carl Moe; both read this run. Dee Fox shares only a
      // company: deleted.
      final bob = SyncedContact({
        ContactField.name: ContactName.of(given: 'Bob', family: 'Roe'),
        ContactField.homePhones: ['+1 212 555 0101'],
        ContactField.company: 'Roe Ltd',
      });
      final cal = SyncedContact({
        ContactField.name: ContactName.of(given: 'Cal', family: 'Poe'),
        ContactField.workPhones: ['+1 212 555 0202'],
      });
      final dee = SyncedContact({
        ContactField.name: ContactName.of(given: 'Dee', family: 'Fox'),
        ContactField.company: 'Roe Ltd',
      });
      final robert = person(
        given: 'Robert',
        family: 'Smith',
        emails: ['rob@y.example'],
        more: {
          ContactField.homePhones: ['+1 212 555 0101'],
          ContactField.company: 'Roe Ltd',
        },
      );
      final carl = person(
        given: 'Carl',
        family: 'Moe',
        emails: ['carl@y.example'],
        more: {
          ContactField.workPhones: ['+1 212 555 0202'],
        },
      );
      final plan = run(
        google: [
          gDeleted('people/bob'),
          gDeleted('people/cal'),
          gDeleted('people/dee'),
          g('people/rob', robert, etag: 'etag-2'),
          g('people/carl', carl, etag: 'etag-2'),
        ],
        links: [
          link(1, 'people/bob', 'H-bob', base: bob),
          link(2, 'people/cal', 'H-cal', base: cal),
          link(3, 'people/dee', 'H-dee', base: dee),
          link(
            4,
            'people/rob',
            'H-rob',
            base: robert.withValue(ContactField.homePhones, null),
          ),
          link(5, 'people/carl', 'H-carl', base: carl),
        ],
      );
      expect(
        {
          for (final r in plan.reviews)
            if (r.kind == ContactReviewKind.mergedInGoogle)
              (r.googleName, r.graphId),
        },
        {('people/rob', 'H-bob'), ('people/carl', 'H-cal')},
      );
      expect(
        [for (final l in plan.links) ?l.delete?.contactId],
        ['H-dee'],
      );
    });

    test('a contact deleted on a shared office line is deleted', () {
      // Old Roe, Amy Roe and Ben Roe share the office's line; Old Roe is
      // deleted, and neither of the others was changed.
      SyncedContact at(String given, {String? mobile}) => SyncedContact({
        ContactField.name: ContactName.of(given: given, family: 'Roe'),
        ContactField.emails: ['${given.toLowerCase()}@roe.example'],
        ContactField.mobile: mobile,
        ContactField.workPhones: ['+1 312 555 0000'],
        ContactField.company: 'Roe Steel',
      });
      final rows = [
        link(1, 'people/old', 'H-old', base: at('Old')),
        link(2, 'people/amy', 'H-amy', base: at('Amy')),
        link(3, 'people/ben', 'H-ben', base: at('Ben')),
      ];
      final plan = run(google: [gDeleted('people/old')], links: rows);
      expect(byLink(plan, 1)!.delete!.contactId, 'H-old');
      expect(plan.reviews, isEmpty);
      // Amy changed this run: the line is a sign of a merge into her.
      final changed = run(
        google: [
          gDeleted('people/old'),
          g('people/amy', at('Amy'), etag: 'etag-2'),
        ],
        links: rows,
      );
      expect(byLink(changed, 1)!.delete, isNull);
      expect(changed.reviews.single.googleName, 'people/amy');
      // A mobile is no shared line: on Ben, unchanged, it is a sign.
      final mobile = run(
        google: [gDeleted('people/old')],
        links: [
          link(
            1,
            'people/old',
            'H-old',
            base: at('Old', mobile: '+1 312 555 0101'),
          ),
          rows[1],
          link(
            3,
            'people/ben',
            'H-ben',
            base: at('Ben', mobile: '+1 312 555 0101'),
          ),
        ],
      );
      expect(byLink(mobile, 1)!.delete, isNull);
      expect(mobile.reviews.single.googleName, 'people/ben');
    });

    test('a number on two of a contact\'s lists counts once', () {
      // Bob's email went to Rob Ames, his mobile to Rob Zee, both read
      // this run: one each (the mobile is a phone too), so by id.
      final bob = person(
        given: 'Bob',
        family: 'Smith',
        emails: ['bob@x.example'],
        mobile: '+1 212 555 0100',
      );
      final ames = person(
        given: 'Rob',
        family: 'Ames',
        emails: ['ames@y.example'],
      );
      final zee = person(
        given: 'Rob',
        family: 'Zee',
        emails: ['zee@y.example'],
      );
      final plan = run(
        google: [
          gDeleted('people/bob'),
          g(
            'people/a',
            ames.withValue(ContactField.emails, [
              'ames@y.example',
              'bob@x.example',
            ]),
          ),
          g('people/z', zee.withValue(ContactField.mobile, '+1 212 555 0100')),
        ],
        links: [
          link(1, 'people/bob', 'H-bob', base: bob),
          link(2, 'people/a', 'H-a', base: ames),
          link(3, 'people/z', 'H-z', base: zee),
        ],
      );
      expect(
        plan.reviews
            .singleWhere((r) => r.kind == ContactReviewKind.mergedInGoogle)
            .googleName,
        'people/a',
      );
    });

    test('a contact merged into one of its full name read this run is asked '
        'about', () {
      // Bob Smith shares nothing with the other Bob Smith but the name.
      final bob = person(
        given: 'Bob',
        family: 'Smith',
        emails: ['bob@x.example'],
      );
      final other = person(
        given: 'Bob',
        family: 'Smith',
        emails: ['bob@y.example'],
      );
      List<ContactLinkInput> rows() => [
        link(1, 'people/bob', 'H-bob', base: bob),
        link(2, 'people/other', 'H-other', base: other),
      ];
      final plan = run(
        google: [
          gDeleted('people/bob'),
          g(
            'people/other',
            other.withValue(ContactField.jobTitle, 'Buyer'),
            etag: 'etag-2',
          ),
        ],
        links: rows(),
      );
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      final item = plan.reviews.singleWhere(
        (r) => r.kind == ContactReviewKind.mergedInGoogle,
      );
      expect((item.googleName, item.graphId), ('people/other', 'H-bob'));
      // Not read this run, it is no sign: deleted.
      final unread = run(google: [gDeleted('people/bob')], links: rows());
      expect(byLink(unread, 1)!.delete!.contactId, 'H-bob');
      // Of two read this run that share his email, the one of his name.
      final two = run(
        google: [
          gDeleted('people/bob'),
          g(
            'people/a',
            person(
              given: 'Robert',
              family: 'Smith',
              emails: ['rob@y.example', 'bob@x.example'],
            ),
          ),
          g(
            'people/z',
            person(
              given: 'Bob',
              family: 'Smith',
              emails: ['bob@z.example', 'bob@x.example'],
            ),
          ),
        ],
        links: [
          rows().first,
          link(
            2,
            'people/a',
            'H-a',
            base: person(
              given: 'Robert',
              family: 'Smith',
              emails: ['rob@y.example'],
            ),
          ),
          link(
            3,
            'people/z',
            'H-z',
            base: person(
              given: 'Bob',
              family: 'Smith',
              emails: ['bob@z.example'],
            ),
          ),
        ],
      );
      expect(
        two.reviews
            .singleWhere((r) => r.kind == ContactReviewKind.mergedInGoogle)
            .googleName,
        'people/z',
      );
    });

    test('a contact deleted in Gmail is deleted in Outlook', () {
      // Its email is on no other Gmail contact: a deletion, not a merge.
      final plan = run(
        google: [
          gDeleted('people/c1'),
          g('people/c9', person(given: 'Ann', family: 'Lee', emails: ['l@x'])),
        ],
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
      expect(kept.partnerId, 'people/c1', reason: 'for a delete after all');
      expect(kept.partnerBase, pair.delete!.partnerBase);
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
      // Nor the one it was merged into, new this run: deleted.
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
      // The losing row's old items are dropped, not moved onto people/m.
      expect(plan.mergedAway, [(googleName: 'people/a', graphId: 'H-a')]);
    });

    test('a held Gmail contact merged away loses its row, and nothing else',
        () {
      // j2, a second Gmail copy of Ann, waits under Needs a look; Ron
      // merges it into j1, which is paired.
      final plan = run(
        google: [
          g('people/j1', ann, previous: ['people/j2']),
          gDeleted('people/j2'),
        ],
        graph: [h('H1', ann)],
        links: [
          link(1, 'people/j1', 'H1', base: ann),
          link(
            2,
            'people/j2',
            null,
            base: ann,
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ),
        ],
      );
      final gone = byLink(plan, 2)!;
      expect(gone.removeRow, isTrue);
      expect(gone.writes, isFalse);
      // The store refuses a row that names no contact.
      expect(
        plan.links.where(
          (l) => !l.removeRow && l.googleName == null && l.graphId == null,
        ),
        isEmpty,
      );
      expect(plan.reviews, isEmpty);
      expect(byLink(plan, 1)!.googleName, 'people/j1');
      expect(plan.googleGone, isEmpty);
      // j2's own Needs a look item goes with it, not onto j1.
      expect(plan.mergedAway, [(googleName: 'people/j2', graphId: null)]);
      expect(plan.reKeys, {'people/j2': 'people/j1'});
      // The row held with no Outlook contact never wins over a pair, even
      // when the merged contact shares nothing with its Outlook partner.
      final heldWins = run(
        google: [
          g('people/j1', person(given: 'Zed', family: 'Quorn'),
              previous: ['people/j2']),
          gDeleted('people/j2'),
        ],
        links: [
          link(
            1,
            'people/j1',
            null,
            base: ann,
            state: ContactLinkState.held,
            reason: ContactHeldReason.leftOut,
          ),
          link(2, 'people/j2', 'H2', base: ann),
        ],
      );
      expect(byLink(heldWins, 1)!.removeRow, isTrue);
      final pair = byLink(heldWins, 2)!;
      expect(pair.googleName, 'people/j1');
      expect(pair.graphId, 'H2');
      expect(pair.state, ContactLinkState.paired);
      expect(
        heldWins.reviews.where(
          (r) => r.kind == ContactReviewKind.mergedInGoogle,
        ),
        isEmpty,
      );
    });

    test('a chain of re-keys maps each old name to the last', () {
      // getBatchGet found a re-keyed to b; the listing says c was b.
      final plan = run(
        googleReKeys: {'people/a': 'people/b'},
        google: [g('people/c', ann, previous: ['people/b'])],
        links: [link(1, 'people/a', 'H1', base: ann)],
      );
      expect(plan.reKeys, {'people/a': 'people/c', 'people/b': 'people/c'});
      expect(byLink(plan, 1)!.googleName, 'people/c');
    });

    test('no tag is moved on an Outlook contact that loses its row', () {
      // c1 was re-keyed to c9, and its Outlook partner H1 is gone: c9 is
      // deleted, the row with it, and H1 has no tag left to move.
      final plan = run(
        googleReKeys: {'people/c1': 'people/c9'},
        google: [g('people/c9', ann)],
        graphGone: {'H1'},
        links: [
          link(1, 'people/c1', 'H1', base: ann, etag: 'etag-people/c9'),
        ],
      );
      expect(byLink(plan, 1)!.delete!.contactId, 'people/c9');
      expect(plan.reKeys, {'people/c1': 'people/c9'});
      expect(plan.graphTagMoves, isEmpty);
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
      expect(plan.binToMarkBack, [4]);
      expect(plan.binToDrop, isEmpty);
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
      expect(copied.binToMarkBack, [4]);
    });

    test('a Restore found back is dropped, not marked back', () {
      // Ron brought both back himself (Outlook's Recover deleted items,
      // Gmail's Trash) and pressed Restore: the run pairs them, and the
      // bin row is a Restore found already back.
      final plan = run(
        google: [g('people/c1', ann)],
        graph: [h('H1', ann)],
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
      expect(byGoogle(plan, 'people/c1')!.graphId, 'H1');
      expect(plan.binToDrop, [9]);
      expect(plan.binToMarkBack, isEmpty);
    });

    test('a bin row marked back is left out, so a later deletion counts', () {
      final links = [link(1, 'people/c1', 'H1', base: ann)];
      // Passed in, H1's id reads as the sync's own deletion: ignored.
      final passed = run(
        google: [g('people/c1', ann)],
        graphGone: {'H1'},
        links: links,
        bin: [
          const ContactBinInput(
            binId: 4,
            side: ContactSide.graph,
            contactId: 'H1',
          ),
        ],
      );
      expect(passed.links.where((l) => l.delete != null), isEmpty);
      // Left out, as the runner must once the row is marked back: Ron's
      // deleting H1 again deletes its Gmail partner.
      final leftOut = run(
        google: [g('people/c1', ann)],
        graphGone: {'H1'},
        links: links,
      );
      expect(byLink(leftOut, 1)!.delete!.contactId, 'people/c1');
    });
  });

  group('the deletion brake', () {
    List<ContactLinkInput> pairs(int n) => [
      for (var i = 0; i < n; i++)
        link(i, 'people/c$i', 'H$i', base: person(given: 'P$i', family: 'X')),
    ];

    test('each item tells its contact apart by its email, else mobile', () {
      SyncedContact who(int i) => person(
        given: 'P$i',
        family: 'X',
        emails: i == 0 ? null : ['p$i@x.example', 'other$i@x.example'],
        mobile: '+1 212 555 010$i',
      );
      final plan = run(
        google: [for (var i = 0; i < 6; i++) g('people/c$i', who(i))],
        graphGone: {for (var i = 0; i < 6; i++) 'H$i'},
        links: [
          for (var i = 0; i < 6; i++)
            link(i, 'people/c$i', 'H$i', base: who(i)),
        ],
      );
      final items = plan.brakes.single.items;
      expect(items.first.hint, '+1 212 555 0100', reason: 'no email');
      expect(items[1].hint, 'p1@x.example');
      expect(items.every((i) => i.changes.isEmpty), isTrue);
      final back = ContactBrakeItem.fromJson(items[1].toJson())!;
      expect(back.hint, 'p1@x.example');
      expect(back.googleName, 'people/c1');
    });

    test('Delete them keeps the partner for the bin, and Restore makes both',
        () {
      // Run one: Ron deleted six Outlook contacts; the brake holds their
      // Gmail partners.
      final held = run(
        google: [for (var i = 0; i < 6; i++) g('people/c$i', ann)],
        graphGone: {for (var i = 0; i < 6; i++) 'H$i'},
        links: [
          for (var i = 0; i < 6; i++) link(i, 'people/c$i', 'H$i', base: ann),
        ],
      );
      final row = byLink(held, 0)!;
      expect(row.reason, ContactHeldReason.deletionBrake);
      expect(row.graphId, isNull);
      expect(row.partnerId, 'H0');
      expect(row.partnerBase, ann);
      // Saved as the runner saves it, and passed back.
      ContactLinkInput saved(ContactLinkPlan p) => ContactLinkInput(
        linkId: p.linkId!,
        googleName: p.googleName,
        graphId: p.graphId,
        googleEtag: p.googleEtag,
        googleBase: p.googleBase?.toJson(),
        state: p.state,
        reason: p.reason,
        partnerId: p.partnerId,
        partnerBase: p.partnerBase?.toJson(),
      );
      // Run two: Delete them.
      final deleted = run(
        google: [g('people/c0', ann)],
        links: [saved(row)],
        answers: const [ContactAnswer(ContactAnswerKind.deleteHeld)],
      );
      final delete = byLink(deleted, 0)!.delete!;
      expect(delete.contactId, 'people/c0');
      expect(delete.partnerId, 'H0');
      expect(delete.partnerBase, ann);
      // Run three: Restore on the bin row the delete made remakes both
      // sides, to be paired.
      final restored = run(
        bin: [
          ContactBinInput(
            binId: 9,
            side: ContactSide.google,
            contactId: delete.contactId,
            partnerId: delete.partnerId,
            raw: const {
              'resourceName': 'people/c0',
              'names': [
                {'givenName': 'Ann', 'familyName': 'Cole'},
              ],
              'emailAddresses': [
                {'value': 'ann@x.example'},
              ],
            },
            partnerBase: delete.partnerBase!.toJson(),
            restore: true,
          ),
        ],
      );
      final restore = restored.restores.single;
      expect(restore.alreadyBack, isFalse);
      expect(restore.googleRaw, isNotNull);
      expect(restore.graphDetails, ann, reason: 'the Outlook side too');
      // Don't delete them, then Delete it here too, keeps it as well.
      final kept = run(
        google: [g('people/c0', ann)],
        links: [saved(row)],
        answers: const [ContactAnswer(ContactAnswerKind.keepHeld)],
      );
      final keptRow = byLink(kept, 0)!;
      expect(keptRow.reason, ContactHeldReason.kept);
      expect(keptRow.partnerId, 'H0');
      final again = run(
        google: [g('people/c0', ann)],
        links: [saved(keptRow)],
        answers: const [
          ContactAnswer(
            ContactAnswerKind.deleteHereToo,
            googleName: 'people/c0',
          ),
        ],
      );
      expect(byLink(again, 0)!.delete!.partnerId, 'H0');
      expect(byLink(again, 0)!.delete!.partnerBase, ann);
    });

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

    test('each item says what Apply them would do, detail by detail', () {
      final note = ContactNotes('Met at the trade fair.\nKeeps two dogs.');
      final address = ContactAddress.of(
        street: '1200 Industrial Parkway, Building 7, Loading Dock Entrance B',
        city: 'Springfield',
      );
      final full = person(
        given: 'P',
        family: 'X',
        emails: ['a@x.example', 'b@x.example'],
        mobile: '+1 212 555 0100',
        more: {
          ContactField.company: 'Old',
          ContactField.jobTitle: 'Sales manager',
          ContactField.notes: note,
          ContactField.workAddress: address,
          ContactField.birthday: const ContactBirthday(month: 7, day: 4),
        },
      );
      // Gmail lost, or changed, many of them at once (an Undo changes).
      final changed = SyncedContact({
        ...full.values,
        ContactField.emails: ['a@x.example', 'c@x.example'],
        ContactField.mobile: null,
        ContactField.jobTitle: 'Purchasing manager',
        ContactField.company: 'New',
        ContactField.notes: ContactNotes('Moved to Ohio.\nStill two dogs.'),
        ContactField.workAddress: ContactAddress.of(city: 'Springfield'),
        ContactField.birthday: const ContactBirthday(
          year: 1980,
          month: 7,
          day: 4,
        ),
      });
      final plan = run(
        google: [
          g('people/c0', changed),
          // An email only added is no loss.
          g(
            'people/c1',
            full
                .withValue(ContactField.company, 'New')
                .withValue(ContactField.emails, [
                  'a@x.example',
                  'b@x.example',
                  'c@x.example',
                ]),
          ),
          for (var i = 2; i < 11; i++)
            g('people/c$i', full.withValue(ContactField.company, 'New')),
        ],
        links: [
          for (var i = 0; i < 11; i++) link(i, 'people/c$i', 'H$i', base: full),
        ],
      );
      final item = plan.brakes.single.items.first;
      expect(item.side, ContactSide.graph, reason: 'Hadco would lose them');
      expect(item.changes, [
        const ContactDetailChange(
          field: ContactField.emails,
          side: ContactSide.graph,
          before: 'b@x.example',
        ),
        const ContactDetailChange(
          field: ContactField.mobile,
          side: ContactSide.graph,
          before: '+1 212 555 0100',
        ),
        const ContactDetailChange(
          field: ContactField.workAddress,
          side: ContactSide.graph,
          before:
              '1200 Industrial Parkway, Building 7, Loading Dock '
              'Entrance\u2026',
          after: 'Springfield',
        ),
        const ContactDetailChange(
          field: ContactField.company,
          side: ContactSide.graph,
          before: 'Old',
          after: 'New',
        ),
        const ContactDetailChange(
          field: ContactField.jobTitle,
          side: ContactSide.graph,
          before: 'Sales manager',
          after: 'Purchasing manager',
        ),
        const ContactDetailChange(
          field: ContactField.notes,
          side: ContactSide.graph,
          after: 'changed',
        ),
      ], reason: 'a year added to the birthday is no loss');
      // Kept with the question, and never in a log.
      final back = ContactBrakeItem.fromJson(item.toJson())!;
      expect(back.changes, item.changes);
      expect(back.side, ContactSide.graph);
      expect('${item.changes[3]}', 'ContactDetailChange(graph company)');
      expect(
        plan.brakes.single.items[1].changes,
        [
          const ContactDetailChange(
            field: ContactField.company,
            side: ContactSide.graph,
            before: 'Old',
            after: 'New',
          ),
        ],
      );
    });

    test('a list shows only the values it would lose, each on its own', () {
      const long =
          'ann.cole.purchasing.department.second.floor.office@hadcometals'
          '.example';
      final emails = SyncedContact({
        ContactField.name: ContactName.of(given: 'Ann', family: 'Cole'),
        ContactField.emails: [
          'ann.cole@hadcometals.example',
          'ann.cole.personal@gmail.example',
          long,
        ],
        ContactField.homePhones: ['+1 212 555 0101', '+1 212 555 0102'],
      });
      // Hadco lost its last email, and changed its second home phone in
      // its slot: Gmail's is changed in place.
      final hadco = emails
          .withValue(ContactField.emails, [
            'ann.cole@hadcometals.example',
            'ann.cole.personal@gmail.example',
          ])
          .withValue(ContactField.homePhones, [
            '+1 212 555 0101',
            '+1 212 555 0199',
          ]);
      final plan = run(
        google: [for (var i = 0; i < 11; i++) g('people/c$i', emails)],
        graph: [for (var i = 0; i < 11; i++) h('H$i', hadco)],
        links: [
          for (var i = 0; i < 11; i++)
            link(
              i,
              'people/c$i',
              'H$i',
              base: emails,
              state: ContactLinkState.held,
              reason: ContactHeldReason.changeBrake,
            ),
        ],
      );
      expect(plan.heldBrakes.single.items.first.changes, [
        const ContactDetailChange(
          field: ContactField.emails,
          side: ContactSide.google,
          before:
              'ann.cole.purchasing.department.second.floor.office@hadcomet'
              '\u2026',
        ),
        const ContactDetailChange(
          field: ContactField.homePhones,
          side: ContactSide.google,
          before: '+1 212 555 0102',
          after: '+1 212 555 0199',
        ),
      ]);
    });

    test('a value is shown replaced only by the one put in its place', () {
      // Hadco put d in b's slot and removed a, c moving up into a's slot:
      // Apply them removes a from Gmail and changes b to d there, though
      // d stands where a stood.
      final base = person(
        given: 'Ann',
        family: 'Cole',
        emails: ['a@x.example', 'b@x.example', 'c@x.example'],
      );
      final hadco = base.withValue(ContactField.emails, [
        'c@x.example',
        'd@x.example',
      ]);
      final row = link(
        1,
        'people/c1',
        'H1',
        base: base,
        state: ContactLinkState.held,
        reason: ContactHeldReason.changeBrake,
      );
      final plan = run(
        google: [g('people/c1', base)],
        graph: [h('H1', hadco)],
        links: [row],
      );
      final item = plan.heldBrakes.single.items.single;
      expect(item.changes, [
        const ContactDetailChange(
          field: ContactField.emails,
          side: ContactSide.google,
          before: 'a@x.example',
        ),
        const ContactDetailChange(
          field: ContactField.emails,
          side: ContactSide.google,
          before: 'b@x.example',
          after: 'd@x.example',
        ),
      ]);
      final applied = run(
        google: [g('people/c1', base)],
        graph: [h('H1', hadco)],
        links: [row],
        answers: [
          ContactAnswer(ContactAnswerKind.applyHeld, held: [item]),
        ],
      );
      final write = byLink(applied, 1)!.googleWrite!;
      expect(write.replaced[ContactField.emails], {
        'b@x.example': 'd@x.example',
      });
      expect(write.target.list(ContactField.emails), [
        'd@x.example',
        'c@x.example',
      ]);
    });

    test('a detail changed on both sides is flagged as a clash', () {
      // Both sides changed the job title, Gmail's the newer edit; Gmail
      // alone changed the company.
      final start = person(
        given: 'Ann',
        family: 'Cole',
        more: {ContactField.company: 'Acme', ContactField.jobTitle: 'Buyer'},
      );
      final gmail = start
          .withValue(ContactField.jobTitle, 'Manager')
          .withValue(ContactField.company, 'Acme Corp');
      final hadco = start.withValue(ContactField.jobTitle, 'Lead buyer');
      List<ContactLinkInput> rows({required bool held}) => [
        for (var i = 0; i < 11; i++)
          link(
            i,
            'people/c$i',
            'H$i',
            base: start,
            state: held ? ContactLinkState.held : ContactLinkState.paired,
            reason: held ? ContactHeldReason.changeBrake : null,
          ),
      ];
      final expected = [
        const ContactDetailChange(
          field: ContactField.company,
          side: ContactSide.graph,
          before: 'Acme',
          after: 'Acme Corp',
        ),
        const ContactDetailChange(
          field: ContactField.jobTitle,
          side: ContactSide.graph,
          before: 'Lead buyer',
          after: 'Manager',
          clash: true,
        ),
      ];
      // Raised this run, and rebuilt for a question held before.
      for (final held in [false, true]) {
        final plan = run(
          google: [
            for (var i = 0; i < 11; i++) g('people/c$i', gmail, at: later),
          ],
          graph: [for (var i = 0; i < 11; i++) h('H$i', hadco, at: earlier)],
          links: rows(held: held),
        );
        final item = plan.heldBrakes.single.items.first;
        expect(item.changes, expected, reason: held ? 'held' : 'raised');
        expect(ContactBrakeItem.fromJson(item.toJson())!.changes, expected);
      }
      // Copy them back puts the company back, but not the job title.
      final back = run(
        google: [g('people/c0', gmail, at: later)],
        graph: [h('H0', hadco, at: earlier)],
        links: [rows(held: true).first],
        answers: const [ContactAnswer(ContactAnswerKind.copyHeldBack)],
      );
      final pair = byLink(back, 0)!;
      expect(pair.googleWrite!.target.text(ContactField.company), 'Acme');
      expect(pair.graphWrite!.target.text(ContactField.jobTitle), 'Manager');
    });

    test('an item lists the details lost on both sides', () {
      // Gmail changed the company (Hadco would lose Acme); Hadco removed
      // the mobile and an email (Gmail would lose them).
      final both = person(
        given: 'Ann',
        family: 'Cole',
        emails: ['ann@x.example', 'a2@x.example'],
        mobile: '+1 212 555 0100',
        more: {ContactField.company: 'Acme'},
      );
      final rows = [
        for (var i = 0; i < 11; i++)
          link(
            i,
            'people/c$i',
            'H$i',
            base: both,
            state: ContactLinkState.held,
            reason: ContactHeldReason.changeBrake,
          ),
      ];
      final gmail = both.withValue(ContactField.company, 'Acme Corp');
      final hadco = both
          .withValue(ContactField.mobile, null)
          .withValue(ContactField.emails, ['ann@x.example']);
      final plan = run(
        google: [for (var i = 0; i < 11; i++) g('people/c$i', gmail)],
        graph: [for (var i = 0; i < 11; i++) h('H$i', hadco)],
        links: rows,
      );
      final item = plan.heldBrakes.single.items.first;
      expect(item.side, ContactSide.google, reason: 'Gmail loses more');
      expect(
        {for (final c in item.changes) (c.side, c.field)},
        {
          (ContactSide.google, ContactField.emails),
          (ContactSide.google, ContactField.mobile),
          (ContactSide.graph, ContactField.company),
        },
      );
      expect(
        item.changes.singleWhere((c) => c.side == ContactSide.graph),
        const ContactDetailChange(
          field: ContactField.company,
          side: ContactSide.graph,
          before: 'Acme',
          after: 'Acme Corp',
        ),
      );
      // Exactly what Apply them would write.
      final applied = run(
        google: [g('people/c0', gmail)],
        graph: [h('H0', hadco)],
        links: [rows.first],
        answers: [
          ContactAnswer(ContactAnswerKind.applyHeld, held: [item]),
        ],
      );
      final pair = byLink(applied, 0)!;
      expect(
        {
          for (final f in pair.googleWrite!.fields) (ContactSide.google, f),
          for (final f in pair.graphWrite!.fields) (ContactSide.graph, f),
        },
        {for (final c in item.changes) (c.side, c.field)},
      );
      // Each change keeps its side through toJson/fromJson; one kept
      // without a side takes its item's.
      final back = ContactBrakeItem.fromJson(item.toJson())!;
      expect(back.changes, item.changes);
      final older = ContactBrakeItem.fromJson({
        'title': 'Ann Cole',
        'side': 'graph',
        'changes': [
          {'field': 'company', 'before': 'Acme', 'after': 'Acme Corp'},
        ],
      })!;
      expect(older.changes.single.side, ContactSide.graph);
    });

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

    test('a change held before shows its details at the next run', () {
      // Held before details were kept (the tablet's 58): every run the
      // question's items are rebuilt from the pairs' reads.
      final heldRows = [
        for (var i = 0; i < 11; i++)
          link(
            i,
            'people/c$i',
            'H$i',
            base: base,
            state: ContactLinkState.held,
            reason: ContactHeldReason.changeBrake,
          ),
      ];
      final reads = contactsToRead(links: heldRows);
      expect(reads.google, hasLength(11), reason: 'read every run');
      expect(reads.graph, hasLength(11));
      final plan = run(
        // Pair 10 read on its Gmail side only: left out.
        google: renamed(11),
        graph: unchanged(10),
        links: heldRows,
      );
      expect(plan.brakes, isEmpty, reason: 'nothing raised anew');
      expect(plan.links, isEmpty, reason: 'still held');
      final items = plan.heldBrakes.single.items;
      expect(plan.heldBrakes.single.kind, ContactBrakeKind.changes);
      expect(items, hasLength(10));
      expect(items.first.googleName, 'people/c0');
      expect(items.first.side, ContactSide.graph);
      expect(items.first.changes, [
        const ContactDetailChange(
          field: ContactField.company,
          side: ContactSide.graph,
          before: 'Old',
          after: 'New',
        ),
      ]);
      // A deletion held before keeps its hint, read or not.
      final deletion = run(
        links: [
          link(
            20,
            'people/c20',
            null,
            base: person(given: 'P', family: 'X', emails: ['p@x.example']),
            state: ContactLinkState.held,
            reason: ContactHeldReason.deletionBrake,
          ),
        ],
      );
      final held = deletion.heldBrakes.single;
      expect(held.kind, ContactBrakeKind.deletions);
      expect(held.items.single.hint, 'p@x.example');
      expect(held.items.single.side, ContactSide.graph);
      // A question raised this run is there too.
      final raised = run(google: renamed(11), links: pairs(11));
      expect(
        raised.heldBrakes.single.items.map((i) => i.googleName),
        raised.brakes.single.items.map((i) => i.googleName),
      );
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

    test('each of the four answers given to one item acts on it alone', () {
      ContactBrakeItem one(int i) => ContactBrakeItem(
        title: 'P X',
        side: ContactSide.graph,
        googleName: 'people/c$i',
        graphId: 'H$i',
      );
      final changeRows = [
        for (var i = 0; i < 3; i++)
          link(
            i,
            'people/c$i',
            'H$i',
            base: base,
            state: ContactLinkState.held,
            reason: ContactHeldReason.changeBrake,
          ),
      ];
      for (final kind in [
        ContactAnswerKind.applyHeld,
        ContactAnswerKind.copyHeldBack,
      ]) {
        final plan = run(
          google: renamed(3),
          graph: unchanged(3),
          links: changeRows,
          answers: [
            ContactAnswer(kind, held: [one(1)]),
          ],
        );
        expect(plan.answers, [ContactAnswerOutcome.applied], reason: '$kind');
        final answered = byLink(plan, 1)!;
        expect(answered.state, ContactLinkState.paired, reason: '$kind');
        expect(
          kind == ContactAnswerKind.applyHeld
              ? answered.graphWrite?.target.text(ContactField.company)
              : answered.googleWrite?.target.text(ContactField.company),
          kind == ContactAnswerKind.applyHeld ? 'New' : 'Old',
        );
        expect(byLink(plan, 0), isNull, reason: '$kind: still held');
        expect(byLink(plan, 2), isNull, reason: '$kind: still held');
        // The rest of the question stands, with its details.
        expect(
          plan.heldBrakes.single.items.map((i) => i.googleName),
          ['people/c0', 'people/c2'],
        );
      }
      final deletionRows = [
        for (var i = 0; i < 3; i++)
          link(
            i,
            'people/c$i',
            null,
            base: base,
            state: ContactLinkState.held,
            reason: ContactHeldReason.deletionBrake,
          ),
      ];
      for (final kind in [
        ContactAnswerKind.deleteHeld,
        ContactAnswerKind.keepHeld,
      ]) {
        final plan = run(
          google: renamed(3),
          graphGone: {'H0', 'H1', 'H2'},
          links: deletionRows,
          answers: [
            ContactAnswer(
              kind,
              held: [
                const ContactBrakeItem(
                  title: 'P X',
                  side: ContactSide.graph,
                  googleName: 'people/c1',
                ),
              ],
            ),
          ],
        );
        expect(plan.answers, [ContactAnswerOutcome.applied], reason: '$kind');
        final answered = byLink(plan, 1)!;
        if (kind == ContactAnswerKind.deleteHeld) {
          expect(answered.delete!.contactId, 'people/c1');
        } else {
          expect(answered.reason, ContactHeldReason.kept);
        }
        expect(byLink(plan, 0), isNull, reason: '$kind: still held');
        expect(byLink(plan, 2), isNull, reason: '$kind: still held');
        expect(
          plan.heldBrakes.single.items.map((i) => i.googleName),
          ['people/c0', 'people/c2'],
        );
      }
    });

    test('an answer acts only on the rows its question listed', () {
      // Rows 0 and 1 were held by the brake Ron answered; row 2 by a later
      // one, after his answer was queued.
      final rows = [
        for (var i = 0; i < 3; i++)
          link(
            i,
            'people/c$i',
            'H$i',
            base: base,
            state: ContactLinkState.held,
            reason: ContactHeldReason.changeBrake,
          ),
      ];
      final asked = [
        for (var i = 0; i < 2; i++)
          ContactBrakeItem(
            title: 'P X',
            side: ContactSide.graph,
            googleName: 'people/c$i',
            graphId: 'H$i',
          ),
      ];
      final plan = run(
        google: renamed(3),
        graph: unchanged(3),
        links: rows,
        answers: [ContactAnswer(ContactAnswerKind.applyHeld, held: asked)],
      );
      expect(plan.answers, [ContactAnswerOutcome.applied]);
      expect(byLink(plan, 0)!.graphWrite, isNotNull);
      expect(byLink(plan, 1)!.graphWrite, isNotNull);
      expect(byLink(plan, 2), isNull, reason: 'still held, its own question');
      // The same for the deletion brake's Delete them.
      final deletions = run(
        graphGone: {'H3', 'H4'},
        links: [
          for (final i in [3, 4])
            link(
              i,
              'people/c$i',
              null,
              base: base,
              state: ContactLinkState.held,
              reason: ContactHeldReason.deletionBrake,
            ),
        ],
        answers: [
          ContactAnswer(
            ContactAnswerKind.deleteHeld,
            held: [
              ContactBrakeItem.fromJson(
                const ContactBrakeItem(
                  title: 'P X',
                  side: ContactSide.graph,
                  googleName: 'people/c3',
                ).toJson(),
              )!,
            ],
          ),
        ],
      );
      expect(byLink(deletions, 3)!.delete!.contactId, 'people/c3');
      expect(byLink(deletions, 4), isNull);
      // And Don't delete them.
      final kept = run(
        google: [g('people/c3', base), g('people/c4', base)],
        graphGone: {'H3', 'H4'},
        links: [
          for (final i in [3, 4])
            link(
              i,
              'people/c$i',
              null,
              base: base,
              state: ContactLinkState.held,
              reason: ContactHeldReason.deletionBrake,
            ),
        ],
        answers: [
          const ContactAnswer(
            ContactAnswerKind.keepHeld,
            held: [
              ContactBrakeItem(
                title: 'P X',
                side: ContactSide.graph,
                googleName: 'people/c3',
              ),
            ],
          ),
        ],
      );
      expect(byLink(kept, 3)!.reason, ContactHeldReason.kept);
      expect(byLink(kept, 4), isNull);
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

    test('found by the tag it was written with, after a re-key', () {
      // Journalled under people/c1 with tag people/c1; the store then
      // re-keyed the source to people/c9, and Google no longer reports
      // the re-key. The Outlook copy still carries people/c1.
      final plan = run(
        google: [g('people/c9', ann)],
        graph: [
          h('H9', person(given: 'Ann', family: 'Cole'), tag: 'people/c1'),
        ],
        journal: [
          ContactJournalEntry(
            opId: 3,
            side: ContactSide.graph,
            sourceId: 'people/c9',
            tag: 'people/c1',
            startedAt: now.subtract(const Duration(hours: 3)),
          ),
        ],
      );
      expect(plan.journalSettled, [3]);
      expect(byGoogle(plan, 'people/c9')!.graphId, 'H9');
      expect(plan.links.where((l) => l.create != null), isEmpty);
      expect(plan.reviews, isEmpty);
      expect(plan.graphTagMoves, {'H9': 'people/c9'});
    });

    test('a copy whose source was merged into a pair keeps out of its row',
        () {
      // people/a is paired with H-a. people/c is new, and its copy Z was
      // cut short. Ron merges a into c in Gmail.
      final plan = run(
        google: [
          g('people/c', ann, previous: ['people/a']),
          gDeleted('people/a'),
        ],
        graph: [h('H-a', ann), h('Z', ann, tag: 'people/c')],
        links: [link(1, 'people/a', 'H-a', base: ann)],
        journal: [
          ContactJournalEntry(
            opId: 7,
            side: ContactSide.graph,
            sourceId: 'people/c',
            startedAt: now.subtract(const Duration(hours: 3)),
          ),
        ],
      );
      expect(plan.journalSettled, [7]);
      final row = byLink(plan, 1)!;
      expect(row.googleName, 'people/c');
      expect(row.graphId, 'H-a', reason: 'H-a keeps its pair');
      final copy = byGraph(plan, 'Z')!;
      expect(copy.linkId, isNull);
      expect(copy.state, ContactLinkState.held);
      expect(copy.reason, ContactHeldReason.waiting);
      final item = plan.reviews.single;
      expect(item.kind, ContactReviewKind.mergedInGoogle);
      expect(item.googleName, 'people/c');
      expect(item.graphId, 'Z');
      expect(plan.graphTagMoves, {'H-a': 'people/c'});
      expect(plan.links.where((l) => l.create != null), isEmpty);
    });

    test('two copies settling onto one source: one pair, one held', () {
      // Copies of new Gmail contacts a and b were both being made in
      // Outlook, the answers lost; Ron merges b into a in Gmail. The op
      // for b is the older, and comes first.
      final plan = run(
        google: [
          g('people/a', ann, previous: ['people/b']),
          gDeleted('people/b'),
        ],
        graph: [
          h('copy-a', ann, tag: 'people/a'),
          h('copy-b', ann, tag: 'people/b'),
        ],
        journal: [
          ContactJournalEntry(
            opId: 1,
            side: ContactSide.graph,
            sourceId: 'people/b',
            startedAt: now.subtract(const Duration(hours: 4)),
          ),
          ContactJournalEntry(
            opId: 2,
            side: ContactSide.graph,
            sourceId: 'people/a',
            startedAt: now.subtract(const Duration(hours: 3)),
          ),
        ],
      );
      expect(plan.journalSettled, unorderedEquals([1, 2]));
      final pair = byGoogle(plan, 'people/a')!;
      expect(pair.graphId, 'copy-a', reason: 'tagged with the surviving name');
      expect(pair.state, ContactLinkState.paired);
      final held = byGraph(plan, 'copy-b')!;
      expect(held.googleName, isNull);
      expect(held.reason, ContactHeldReason.waiting);
      expect(plan.reviews.single.kind, ContactReviewKind.mergedInGoogle);
      expect(plan.links.where((l) => l.create != null), isEmpty);
      // Every row saves: none names nothing, no contact is named twice.
      final kept = plan.links.where((l) => !l.removeRow);
      expect(
        kept.where((l) => l.googleName == null && l.graphId == null),
        isEmpty,
      );
      final googleNames = [for (final l in kept) ?l.googleName];
      final graphIds = [for (final l in kept) ?l.graphId];
      expect(googleNames.toSet(), hasLength(googleNames.length));
      expect(graphIds.toSet(), hasLength(graphIds.length));

      // Both merged into a third contact c: the oldest op's copy is the
      // one paired.
      final third = run(
        google: [
          g('people/c', ann, previous: ['people/a', 'people/b']),
          gDeleted('people/a'),
          gDeleted('people/b'),
        ],
        graph: [
          h('copy-a', ann, tag: 'people/a'),
          h('copy-b', ann, tag: 'people/b'),
        ],
        journal: [
          ContactJournalEntry(
            opId: 5,
            side: ContactSide.graph,
            sourceId: 'people/a',
            startedAt: now.subtract(const Duration(hours: 4)),
          ),
          ContactJournalEntry(
            opId: 6,
            side: ContactSide.graph,
            sourceId: 'people/b',
            startedAt: now.subtract(const Duration(hours: 5)),
          ),
        ],
      );
      expect(byGoogle(third, 'people/c')!.graphId, 'copy-b');
      expect(byGraph(third, 'copy-a')!.reason, ContactHeldReason.waiting);
    });

    test('a copy keeps out of a row its source holds with another', () {
      // people/c's row holds it with H-a, which is in another folder (the
      // row moved out); people/c's interrupted copy Z is found.
      final plan = run(
        google: [g('people/c', ann)],
        graph: [h('Z', ann, tag: 'people/c')],
        graphMovedOut: {'H-a'},
        links: [
          link(
            1,
            'people/c',
            'H-a',
            base: ann,
            state: ContactLinkState.held,
            reason: ContactHeldReason.movedOut,
          ),
        ],
        journal: [
          ContactJournalEntry(
            opId: 7,
            side: ContactSide.graph,
            sourceId: 'people/c',
            startedAt: now.subtract(const Duration(hours: 3)),
          ),
        ],
      );
      expect(plan.journalSettled, [7]);
      expect(byLink(plan, 1), isNull, reason: 'held with H-a, as it was');
      expect(byGraph(plan, 'Z')!.reason, ContactHeldReason.waiting);
      expect(plan.reviews.single.kind, ContactReviewKind.mergedInGoogle);
    });

    test('a Gmail copy whose source is paired goes through the rules', () {
      // Outlook H5 is paired with Gmail c7 by the time its interrupted
      // Gmail copy c9 is found.
      final plan = run(
        google: [g('people/c7', ann), g('people/c9', ann, tag: 'H5')],
        graph: [h('H5', ann)],
        links: [link(5, 'people/c7', 'H5', base: ann)],
        journal: [
          ContactJournalEntry(
            opId: 8,
            side: ContactSide.google,
            sourceId: 'H5',
            startedAt: now.subtract(const Duration(hours: 3)),
          ),
        ],
      );
      expect(plan.journalSettled, [8]);
      expect(byLink(plan, 5)!.googleName, 'people/c7');
      // A copy of the person c7 is: held as a duplicate, asked about
      // nowhere.
      expect(byGoogle(plan, 'people/c9')!.reason, ContactHeldReason.duplicate);
      expect(plan.reviews, isEmpty);
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
      // H2 is not paired: its item went with the answer, and it is held
      // as a candidate, to be placed again once it is back and read.
      final away = byLink(plan, 2)!;
      expect(away.reason, ContactHeldReason.candidate);
      expect(away.graphId, 'H2');
      expect(away.writes, isFalse);
    });

    test('Copy it anyway waits while its contact is away', () {
      final waiting = [
        link(
          1,
          null,
          'H2',
          base: ann,
          state: ContactLinkState.held,
          reason: ContactHeldReason.waiting,
        ),
      ];
      const copy = [
        ContactAnswer(ContactAnswerKind.copyAnyway, graphId: 'H2'),
      ];
      final away = run(
        graphMovedOut: {'H2'},
        links: waiting,
        answers: copy,
      );
      expect(away.answers, [ContactAnswerOutcome.waiting]);
      expect(byLink(away, 1), isNull, reason: 'held as it was');
      // Back in Contacts: Ron's choice is done.
      final back = run(graph: [h('H2', ann)], links: waiting, answers: copy);
      expect(back.answers, [ContactAnswerOutcome.applied]);
      expect(byLink(back, 1)!.create!.side, ContactSide.google);
    });

    test('a contact whose answer is dropped is placed again', () {
      final annCole = person(given: 'Ann', family: 'Cole', emails: ['a@x']);
      final annLee = person(given: 'Ann', family: 'Lee', emails: ['a@x']);
      // Gmail c2 waits under "names disagree", Outlook H2 is its candidate.
      final rows = [
        link(
          1,
          'people/c2',
          null,
          base: annCole,
          state: ContactLinkState.held,
          reason: ContactHeldReason.waiting,
        ),
        link(
          2,
          null,
          'H2',
          base: annLee,
          state: ContactLinkState.held,
          reason: ContactHeldReason.candidate,
        ),
      ];
      const same = [
        ContactAnswer(
          ContactAnswerKind.samePerson,
          googleName: 'people/c2',
          graphId: 'H2',
        ),
      ];
      // Same person while H2 is in another folder: dropped, and c2, read
      // this run, comes back under Needs a look at once.
      final away = run(
        google: [g('people/c2', annCole)],
        graphMovedOut: {'H2'},
        links: rows,
        answers: same,
      );
      expect(away.answers, [ContactAnswerOutcome.dropped]);
      final item = away.reviews.single;
      expect(item.googleName, 'people/c2');
      expect(item.candidates, ['H2']);
      expect(byLink(away, 1)!.reason, ContactHeldReason.waiting);
      // H2 deleted, and c2 not read this run: c2 is held as a candidate,
      // which the next run reads and places.
      final gone = run(graphGone: {'H2'}, links: rows, answers: same);
      expect(gone.answers, [ContactAnswerOutcome.dropped]);
      expect(byLink(gone, 1)!.reason, ContactHeldReason.candidate);
      expect(contactsToRead(links: [
        link(
          1,
          'people/c2',
          null,
          base: annCole,
          state: ContactLinkState.held,
          reason: ContactHeldReason.candidate,
        ),
      ]).google, ['people/c2']);
      // Copy it back on a kept contact away waits for its return.
      final kept = run(
        graphMovedOut: {'H1'},
        links: [
          link(
            1,
            null,
            'H1',
            base: ann,
            state: ContactLinkState.held,
            reason: ContactHeldReason.kept,
          ),
        ],
        answers: const [
          ContactAnswer(ContactAnswerKind.copyBack, graphId: 'H1'),
        ],
      );
      expect(kept.answers, [ContactAnswerOutcome.waiting]);
      expect(byLink(kept, 1), isNull);
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

    test('Copy them back waits for a pair moved out of Contacts', () {
      // Google's Undo changes took the company off both Gmail contacts and
      // the change brake held them; H2 is in another folder when Ron
      // answers Copy them back.
      final base = ann.withValue(ContactField.company, 'Hadco');
      final lost = ann;
      List<ContactLinkInput> held(Iterable<int> ids) => [
        for (final i in ids)
          link(
            i,
            'people/c$i',
            'H$i',
            base: base,
            state: ContactLinkState.held,
            reason: ContactHeldReason.changeBrake,
          ),
      ];
      const copyBack = [ContactAnswer(ContactAnswerKind.copyHeldBack)];
      final away = run(
        google: [g('people/c1', lost), g('people/c2', lost)],
        graph: [h('H1', base)],
        graphMovedOut: {'H2'},
        links: held([1, 2]),
        answers: copyBack,
      );
      expect(away.answers, [ContactAnswerOutcome.waiting]);
      expect(byLink(away, 1)!.googleWrite!.fields, {ContactField.company});
      expect(byLink(away, 2), isNull, reason: 'still held by the brake');
      // H2 is back: the queued answer copies it back too.
      final back = run(
        google: [g('people/c2', lost)],
        graph: [h('H2', base)],
        links: held([2]),
        answers: copyBack,
      );
      expect(back.answers, [ContactAnswerOutcome.applied]);
      final pair = byLink(back, 2)!;
      expect(pair.googleWrite!.target.text(ContactField.company), 'Hadco');
      expect(pair.graphWrite, isNull, reason: 'Hadco keeps its company');
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
      expect(plan.binToDrop, isEmpty);
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
      expect(plan.binToDrop, [9]);
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
      expect(plan.binToDrop, [9]);
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
      expect(apart.binToDrop, isEmpty);

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
      expect(family.binToDrop, isEmpty);

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
      expect(plan.binToDrop, [9]);
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

    test('never takes the sync\'s own write for Ron\'s', () {
      final start = base.withValue(ContactField.company, 'A');
      // Outlook changed the company to B, Gmail added a nickname.
      final plan = run(
        google: [
          g(
            'people/c1',
            start.withValue(ContactField.nickname, 'Annie'),
            etag: 'e1',
            at: earlier,
          ),
        ],
        graph: [
          h('H1', start.withValue(ContactField.company, 'B'), key: 'k1'),
        ],
        links: [
          link(1, 'people/c1', 'H1', base: start, etag: 'e0', key: 'k0'),
        ],
      );
      final first = byLink(plan, 1)!;
      expect(first.googleWrite!.fields, {ContactField.company});
      expect(first.graphWrite!.fields, {ContactField.nickname});
      // The Gmail write went through (etag e2). Outlook's read before the
      // PATCH finds Ron changed the company to C meanwhile.
      final written = g(
        'people/c1',
        start
            .withValue(ContactField.nickname, 'Annie')
            .withValue(ContactField.company, 'B'),
        etag: 'e2',
        at: now,
      );
      final again = first.replan(
        graph: h('H1', start.withValue(ContactField.company, 'C'), key: 'k2'),
        googleWritten: written,
      );
      expect(again.plan.googleWrite!.fields, {ContactField.company});
      expect(
        again.plan.googleWrite!.target.text(ContactField.company),
        'C',
        reason: 'Ron\'s newest value, one-sided: no clash',
      );
      expect(again.plan.googleWrite!.version, 'e2');
      expect(again.plan.graphWrite!.fields, {ContactField.nickname});
      expect(again.plan.graphWrite!.version, 'k2');
      expect(again.reviews, isEmpty);
      // The Gmail write of C meets a newer etag in turn (Ron set an
      // office): planned again from that read, the sync's B is still not
      // Ron's, and C still wins.
      final third = again.plan.replan(
        google: g(
          'people/c1',
          written.details.withValue(ContactField.office, 'B2'),
          etag: 'e3',
          at: now,
        ),
      );
      expect(third.plan.googleWrite!.target.text(ContactField.company), 'C');
      expect(third.plan.graphWrite!.fields, {
        ContactField.nickname,
        ContactField.office,
      });
      expect(third.reviews, isEmpty);
      expect(
        () => first.replan(google: written, googleWritten: written),
        throwsArgumentError,
      );
    });
  });
  group('copies of one person', () {
    // Ann as the tablet holds her: an email and a mobile.
    SyncedContact annCopy({
      List<String>? emails = const ['ann@x.example'],
      String? mobile = '+1 212 555 0100',
      Map<ContactField, Object?> more = const {},
    }) => person(
      given: 'Ann',
      family: 'Cole',
      emails: emails,
      mobile: mobile,
      more: more,
    );
    List<ContactLinkPlan> held(ContactSyncPlan plan) => [
      for (final l in plan.links)
        if (l.reason == ContactHeldReason.duplicate) l,
    ];

    test('twice in Hadco, once in Gmail: one pair, one held, no item', () {
      final plan = run(
        firstSync: true,
        google: [g('people/c1', annCopy())],
        graph: [
          h('H1', annCopy()),
          h('H2', annCopy(more: {ContactField.office: 'B2'})),
        ],
      );
      final pair = byGoogle(plan, 'people/c1')!;
      expect(pair.graphId, 'H2', reason: 'the most complete Hadco copy');
      expect(pair.state, ContactLinkState.paired);
      expect(pair.googleWrite!.fields, {ContactField.office});
      final copy = byGraph(plan, 'H1')!;
      expect(copy.state, ContactLinkState.held);
      expect(copy.reason, ContactHeldReason.duplicate);
      expect(copy.googleName, isNull);
      expect(copy.graphBase, annCopy(), reason: 'its read kept');
      expect(copy.writes, isFalse);
      expect(plan.reviews, isEmpty);
      expect(plan.links.where((l) => l.create != null), isEmpty);
      expect(plan.brakes, isEmpty);
    });

    test('twice on both sides: one pair, one held on each side', () {
      final plan = run(
        google: [g('people/c1', annCopy()), g('people/c2', annCopy())],
        graph: [h('H1', annCopy()), h('H2', annCopy())],
      );
      final pair = plan.links.singleWhere(
        (l) => l.state == ContactLinkState.paired,
      );
      expect((pair.googleName, pair.graphId), ('people/c1', 'H1'));
      expect(
        [for (final l in held(plan)) l.googleName ?? l.graphId],
        unorderedEquals(['people/c2', 'H2']),
      );
      expect(plan.reviews, isEmpty);
      expect(plan.links.where((l) => l.create != null), isEmpty);
      // What the screen lists.
      final group = plan.duplicates.single;
      expect(group.title, 'Ann Cole');
      expect((group.googleSynced, group.graphSynced), ('people/c1', 'H1'));
      expect(group.googleCopies, ['people/c2']);
      expect(group.graphCopies, ['H2']);
      expect(plan.counts.duplicateCopies, 2);
      expect(plan.counts.toJson()['duplicateCopies'], 2);
    });

    test('three copies, one with no mobile and one with no email', () {
      final plan = run(
        google: [g('people/c1', annCopy())],
        graph: [
          h('H1', annCopy()),
          h('H2', annCopy(emails: null)),
          h('H3', annCopy(mobile: null)),
        ],
      );
      expect(byGoogle(plan, 'people/c1')!.graphId, 'H1');
      expect(
        [for (final l in held(plan)) l.graphId],
        unorderedEquals(['H2', 'H3']),
      );
      expect(plan.reviews, isEmpty);
    });

    test('copies on one side only: the most complete is copied', () {
      final plan = run(
        google: [
          g('people/c1', annCopy()),
          g('people/c2', annCopy(more: {ContactField.office: 'B2'})),
        ],
      );
      expect(byGoogle(plan, 'people/c2')!.create!.side, ContactSide.graph);
      expect(byGoogle(plan, 'people/c1')!.reason, ContactHeldReason.duplicate);
      expect(plan.reviews, isEmpty);
      // Listed with the copy being made as its side's synced copy, so the
      // screen counts it before the next run pairs it.
      final group = plan.duplicates.single;
      expect(group.googleSynced, 'people/c2');
      expect(group.graphSynced, isNull);
      expect(group.googleCopies, ['people/c1']);
      // Facing a Hadco copy Ron left out, the most complete is asked about
      // as matching a held contact, its own copies no other person.
      final leftOut = run(
        google: [
          g('people/c1', annCopy()),
          g('people/c2', annCopy(more: {ContactField.office: 'B2'})),
        ],
        links: [
          link(
            1,
            null,
            'H1',
            base: annCopy(),
            state: ContactLinkState.held,
            reason: ContactHeldReason.leftOut,
          ),
        ],
      );
      final item = leftOut.reviews.single;
      expect(item.googleName, 'people/c2');
      expect(item.reason, ContactReviewReason.matchHeld);
      expect(item.candidates, ['H1']);
      expect(byGoogle(leftOut, 'people/c1')!.reason,
          ContactHeldReason.duplicate);
    });

    test('a family on one address is still asked about', () {
      final fam = ['fam@x.example'];
      final plan = run(
        google: [
          g('people/ann', person(given: 'Ann', family: 'Cole', emails: fam)),
          g('people/bob', person(given: 'Bob', family: 'Cole', emails: fam)),
        ],
        graph: [
          h('H-ann1', person(given: 'Ann', family: 'Cole', emails: fam)),
          h('H-ann2', person(given: 'Ann', family: 'Cole', emails: fam)),
          h('H-bob', person(given: 'Bob', family: 'Cole', emails: fam)),
        ],
      );
      expect(held(plan), isEmpty);
      expect(
        plan.reviews.map((r) => r.reason),
        everyElement(ContactReviewReason.sharedAddress),
      );
      expect(plan.reviews, hasLength(2));
    });

    test('a copy with a slightly different name is not grouped', () {
      final plan = run(
        google: [g('people/c1', annCopy())],
        graph: [
          h('H1', annCopy()),
          h(
            'H2',
            person(
              given: 'Anne',
              family: 'Cole',
              emails: ['ann@x.example'],
              mobile: '+1 212 555 0100',
            ),
          ),
        ],
      );
      expect(held(plan), isEmpty);
      expect(plan.reviews.single.reason, ContactReviewReason.sharedAddress);
    });

    test('John Roe Sr. and Jr. on one family address are two people', () {
      SyncedContact roe(
        String suffix, [
        Map<ContactField, Object?> more = const {},
      ]) => SyncedContact({
            ContactField.name: ContactName.of(
              given: 'John',
              family: 'Roe',
              suffix: suffix,
            ),
            ContactField.emails: ['roes@x.example'],
            ...more,
          });
      final plan = run(
        google: [
          g('people/sr', roe('Sr.')),
          g('people/jr', roe('Jr.', {ContactField.jobTitle: 'Student'})),
        ],
        graph: [
          h('H-sr', roe('Sr.', {ContactField.jobTitle: 'Owner'})),
          h('H-jr', roe('Jr.')),
        ],
      );
      expect(held(plan), isEmpty);
      expect(plan.links.where((l) => l.state == ContactLinkState.paired),
          isEmpty);
      expect(
        plan.reviews.map((r) => r.reason),
        [ContactReviewReason.sharedAddress, ContactReviewReason.sharedAddress],
      );
      // A title is no other person: "Dr." Ann is a copy of Ann.
      final dr = run(
        google: [g('people/c1', annCopy())],
        graph: [
          h('H1', annCopy()),
          h(
            'H2',
            SyncedContact({
              ContactField.name: ContactName.of(
                prefix: 'Dr.',
                given: 'Ann',
                family: 'Cole',
              ),
              ContactField.emails: ['ann@x.example'],
            }),
          ),
        ],
      );
      expect(held(dr), hasLength(1));
      expect(dr.reviews, isEmpty);
    });

    test('a new copy of a paired person, linked through the pair, is held',
        () {
      // Gmail Ann is paired with Outlook H1, which has no email; a second
      // Outlook Ann shares Gmail Ann's address.
      final plan = run(
        graph: [h('H2', annCopy())],
        links: [
          link(
            1,
            'people/c1',
            'H1',
            googleBase: annCopy(),
            graphBase: annCopy(emails: null, mobile: null),
          ),
        ],
      );
      expect(byGraph(plan, 'H2')!.reason, ContactHeldReason.duplicate);
      expect(plan.reviews, isEmpty);
    });

    test('Ron\'s own link chooses which copies pair', () {
      // A reinstall: the sync's Outlook copy of c2 carries c2's tag,
      // though c1 is the more complete Gmail copy.
      final plan = run(
        google: [
          g('people/c1', annCopy(more: {ContactField.office: 'B2'})),
          g('people/c2', annCopy()),
        ],
        graph: [h('H1', annCopy(), tag: 'people/c2')],
      );
      expect(byGoogle(plan, 'people/c2')!.graphId, 'H1');
      expect(byGoogle(plan, 'people/c1')!.reason, ContactHeldReason.duplicate);
    });

    test('a copy due to be deleted is paired first, and so kept', () {
      // Gmail c0 was deleted; its partner H1 would go. Gmail has two new
      // copies of Ann, and Outlook a second copy H2.
      final plan = run(
        google: [g('people/c1', annCopy()), g('people/c2', annCopy())],
        graph: [h('H1', annCopy()), h('H2', annCopy())],
        googleGone: {'people/c0'},
        links: [link(1, 'people/c0', 'H1', base: annCopy())],
      );
      final pair = byLink(plan, 1)!;
      expect(pair.graphId, 'H1');
      expect(pair.googleName, 'people/c1');
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      expect(
        [for (final l in held(plan)) l.googleName ?? l.graphId],
        unorderedEquals(['people/c2', 'H2']),
      );
    });

    // Ann as a run after the first leaves her: c1 with H1 paired, H2 held.
    List<ContactLinkInput> synced() => [
      link(1, 'people/c1', 'H1', base: annCopy()),
      link(
        2,
        null,
        'H2',
        base: annCopy(),
        state: ContactLinkState.held,
        reason: ContactHeldReason.duplicate,
      ),
    ];

    test('a later run: a new copy is held, not copied', () {
      final plan = run(graph: [h('H3', annCopy())], links: synced());
      final copy = byGraph(plan, 'H3')!;
      expect(copy.reason, ContactHeldReason.duplicate);
      expect(copy.linkId, isNull);
      expect(plan.links.where((l) => l.create != null), isEmpty);
      expect(plan.reviews, isEmpty);
      // In Gmail too.
      final gmail = run(google: [g('people/c3', annCopy())], links: synced());
      expect(byGoogle(gmail, 'people/c3')!.reason, ContactHeldReason.duplicate);
      expect(gmail.reviews, isEmpty);
    });

    test('a held copy read again is held again, its read kept', () {
      final edited = annCopy(more: {ContactField.office: 'B2'});
      final plan = run(graph: [h('H2', edited)], links: synced());
      final copy = byLink(plan, 2)!;
      expect(copy.reason, ContactHeldReason.duplicate);
      expect(copy.graphBase, edited);
      expect(copy.writes, isFalse);
      expect(byLink(plan, 1), isNull, reason: 'the pair as it was');
      // Given another name by Ron, it is no copy: the usual rules.
      final bob = person(given: 'Bob', family: 'Roe', emails: ['bob@x']);
      final renamed = run(graph: [h('H2', bob)], links: synced());
      expect(byLink(renamed, 2)!.create!.side, ContactSide.google);
    });

    test('Ron deleting a held copy: its row goes, and nothing else', () {
      final plan = run(graphGone: {'H2'}, links: synced());
      expect(byLink(plan, 2)!.removeRow, isTrue);
      expect(byLink(plan, 2)!.delete, isNull);
      expect(plan.links, hasLength(1));
      expect(plan.reviews, isEmpty);
    });

    test('a copy of a person no longer synced is kept, never copied back',
        () {
      // Ron deletes Ann in Gmail: the sync deletes Hadco's synced copy,
      // and the copy held beside it becomes a kept item at once.
      final plan = run(googleGone: {'people/c1'}, links: synced());
      expect(byLink(plan, 1)!.delete!.contactId, 'H1');
      final copy = byLink(plan, 2)!;
      expect(copy.state, ContactLinkState.held);
      expect(copy.reason, ContactHeldReason.kept);
      expect(copy.graphId, 'H2');
      final item = plan.reviews.single;
      expect(item.kind, ContactReviewKind.kept);
      expect(item.reason, ContactReviewReason.copyOfGone);
      expect(item.graphId, 'H2');
      expect(item.goneSide, ContactSide.google);
      expect(plan.duplicates, isEmpty);
      // Read later, it stays as it is: no second Ann in Gmail.
      final keptRow = link(
        2,
        null,
        'H2',
        base: annCopy(),
        state: ContactLinkState.held,
        reason: ContactHeldReason.kept,
      );
      final later = run(
        graph: [h('H2', annCopy(more: {ContactField.nickname: 'Annie'}))],
        links: [keptRow],
      );
      expect(later.links.where((l) => l.create != null), isEmpty);
      // A copy left held with no pair at all (from before), read or not,
      // is kept with an item too, not placed by the usual rules.
      final lone = link(
        2,
        null,
        'H2',
        base: annCopy(),
        state: ContactLinkState.held,
        reason: ContactHeldReason.duplicate,
      );
      for (final plan in [
        run(graph: [h('H2', annCopy())], links: [lone]),
        run(links: [lone]),
      ]) {
        expect(plan.links.where((l) => l.create != null), isEmpty);
        expect(byLink(plan, 2)!.reason, ContactHeldReason.kept);
        expect(plan.reviews.single.reason, ContactReviewReason.copyOfGone);
      }
      // Held copies on both sides with no pair left are not paired with
      // each other either: each is kept with an item.
      ContactLinkInput copyRow(int id, String? g, String? h) => link(
        id,
        g,
        h,
        base: annCopy(),
        state: ContactLinkState.held,
        reason: ContactHeldReason.duplicate,
      );
      final orphaned = run(
        google: [g('people/c2', annCopy()), g('people/c3', annCopy())],
        graph: [h('H2', annCopy())],
        links: [
          copyRow(2, 'people/c2', null),
          copyRow(3, 'people/c3', null),
          copyRow(4, null, 'H2'),
        ],
      );
      expect(orphaned.links.where((l) => l.state == ContactLinkState.paired),
          isEmpty);
      expect(
        orphaned.links.map((l) => l.reason),
        everyElement(ContactHeldReason.kept),
      );
      expect(orphaned.reviews, hasLength(3));
    });

    test('copies of a person still synced stay held, never kept', () {
      ContactLinkInput copyRow(int id, String? g, String? h, SyncedContact b) =>
          link(
            id,
            g,
            h,
            base: b,
            state: ContactLinkState.held,
            reason: ContactHeldReason.duplicate,
          );
      // Ron changed Ann's email and mobile on the pair; two Hadco copies
      // still share only the old email: a group of their own, Ann synced.
      final moved = annCopy(
        emails: ['ann@new.example'],
        mobile: '+1 212 555 0199',
      );
      final oldOnly = annCopy(mobile: null);
      final changed = run(
        google: [g('people/c1', moved)],
        graph: [h('H2', oldOnly), h('H3', oldOnly)],
        links: [
          link(1, 'people/c1', 'H1', base: moved),
          copyRow(2, null, 'H2', oldOnly),
          copyRow(3, null, 'H3', oldOnly),
        ],
      );
      expect(changed.reviews, isEmpty);
      expect(
        [for (final i in [2, 3]) byLink(changed, i)?.reason],
        everyElement(ContactHeldReason.duplicate),
      );
      // Listed with Ann's pair, by her name.
      final listed = changed.duplicates.single;
      expect((listed.googleSynced, listed.graphSynced), ('people/c1', 'H1'));
      expect(listed.graphCopies, ['H2', 'H3']);
      // The pair held as moved out, or by the change brake: its copies
      // stay held, and a new copy is held too.
      for (final reason in [
        ContactHeldReason.movedOut,
        ContactHeldReason.changeBrake,
      ]) {
        final plan = run(
          google: [g('people/c2', annCopy()), g('people/c3', annCopy())],
          graphMovedOut: {if (reason == ContactHeldReason.movedOut) 'H1'},
          links: [
            link(
              1,
              'people/c1',
              'H1',
              base: annCopy(),
              state: ContactLinkState.held,
              reason: reason,
            ),
            copyRow(2, 'people/c2', null, annCopy()),
          ],
        );
        expect(plan.reviews, isEmpty, reason: '$reason');
        expect(byLink(plan, 2)!.reason, ContactHeldReason.duplicate);
        final group = plan.duplicates.single;
        expect((group.googleSynced, group.graphSynced), ('people/c1', 'H1'));
        expect(byGoogle(plan, 'people/c3')!.reason,
            ContactHeldReason.duplicate);
      }
      // But when its own pair has just gone, a copy is kept even while
      // another person of the same name is synced.
      final other = annCopy(
        emails: ['annb@y.example'],
        mobile: '+1 312 555 0000',
      );
      final gone = run(
        googleGone: {'people/c1'},
        links: [
          link(1, 'people/c1', 'H1', base: annCopy()),
          copyRow(2, null, 'H2', annCopy()),
          link(5, 'people/c5', 'H5', base: other),
        ],
      );
      expect(byLink(gone, 2)!.reason, ContactHeldReason.kept);
      expect(gone.reviews.single.reason, ContactReviewReason.copyOfGone);
      // A copy joined to nobody by its address is kept when the contact
      // of its name that was synced has gone, not held for it.
      final stray = run(
        googleGone: {'people/c1'},
        links: [
          link(1, 'people/c1', 'H1', base: annCopy()),
          copyRow(
            2,
            null,
            'H2',
            annCopy(emails: ['ann@old.example'], mobile: null),
          ),
        ],
      );
      expect(byLink(stray, 2)!.reason, ContactHeldReason.kept);
    });

    test('kept after a Gmail delete: whatever Ron answers, no second Ann',
        () {
      // Ron deletes Ann in Gmail; Hadco's synced copy changed since, so it
      // is kept; the copy held beside it is kept too, each with an item.
      final changed = annCopy(more: {ContactField.office: 'B3'});
      final kept = run(
        googleGone: {'people/c1'},
        graph: [h('H1', changed, key: 'k2')],
        links: synced(),
      );
      expect(byLink(kept, 1)!.reason, ContactHeldReason.kept);
      expect(byLink(kept, 2)!.reason, ContactHeldReason.kept);
      expect(
        kept.reviews.map((r) => r.reason),
        unorderedEquals([
          ContactReviewReason.changedSince,
          ContactReviewReason.copyOfGone,
        ]),
      );
      final rows = [
        link(
          1,
          null,
          'H1',
          base: changed,
          state: ContactLinkState.held,
          reason: ContactHeldReason.kept,
        ),
        link(
          2,
          null,
          'H2',
          base: annCopy(),
          state: ContactLinkState.held,
          reason: ContactHeldReason.kept,
        ),
      ];
      for (final answer in [
        ContactAnswerKind.copyBack,
        ContactAnswerKind.deleteHereToo,
        ContactAnswerKind.keepOnlyHere,
      ]) {
        final plan = run(
          graph: [
            h('H1', changed, key: 'k2'),
            h('H2', annCopy(more: {ContactField.nickname: 'Annie'})),
          ],
          links: rows,
          answers: [ContactAnswer(answer, graphId: 'H1')],
        );
        expect(
          plan.counts.addToGoogle,
          answer == ContactAnswerKind.copyBack ? 1 : 0,
          reason: '$answer: only H1, and only when asked',
        );
        expect(byGraph(plan, 'H2'), isNull, reason: '$answer: H2 left alone');
      }
    });

    test('Ron deleting the synced copy in Hadco: the pair moves to a copy',
        () {
      final plan = run(
        google: [g('people/c1', annCopy())],
        graphGone: {'H1'},
        links: synced(),
      );
      final pair = byLink(plan, 1)!;
      expect((pair.googleName, pair.graphId), ('people/c1', 'H2'));
      expect(pair.state, ContactLinkState.paired);
      expect(pair.newPair, isTrue, reason: 'nothing overwritten');
      expect(pair.alsoRemove, [2]);
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      expect(plan.brakes, isEmpty);
      expect(plan.reviews, isEmpty);
      expect(plan.duplicates, isEmpty, reason: 'the copy is synced now');
      // A held copy of another person is not taken: the partner goes as
      // usual.
      final other = run(
        google: [g('people/c1', annCopy())],
        graphGone: {'H1'},
        links: [
          link(1, 'people/c1', 'H1', base: annCopy()),
          link(
            2,
            null,
            'H2',
            base: person(given: 'Bob', family: 'Roe', emails: ['bob@x']),
            state: ContactLinkState.held,
            reason: ContactHeldReason.duplicate,
          ),
        ],
      );
      expect(byLink(other, 1)!.delete!.contactId, 'people/c1');
    });

    test('the synced copy deleted in Gmail, or moved out of Contacts', () {
      final rows = [
        link(1, 'people/c1', 'H1', base: annCopy()),
        link(
          2,
          'people/c2',
          null,
          base: annCopy(),
          state: ContactLinkState.held,
          reason: ContactHeldReason.duplicate,
        ),
      ];
      final deleted = run(google: [gDeleted('people/c1')], links: rows);
      final pair = byLink(deleted, 1)!;
      expect((pair.googleName, pair.graphId), ('people/c2', 'H1'));
      expect(deleted.links.where((l) => l.delete != null), isEmpty);
      // Hadco's side renamed since (Ann married): the Gmail copy left
      // still carries the gone copy's name, and is taken.
      final renamed = run(
        google: [gDeleted('people/c1')],
        graph: [
          h(
            'H1',
            person(
              given: 'Ann',
              family: 'Smith',
              emails: ['ann@x.example'],
              mobile: '+1 212 555 0100',
            ),
          ),
        ],
        links: rows,
      );
      final moved = byLink(renamed, 1)!;
      expect((moved.googleName, moved.graphId), ('people/c2', 'H1'));
      expect(renamed.links.where((l) => l.delete != null), isEmpty);
      // Outlook's synced copy moved to another folder, a copy left.
      final away = run(graphMovedOut: {'H1'}, links: synced());
      final now = byLink(away, 1)!;
      expect((now.googleName, now.graphId), ('people/c1', 'H2'));
      expect(now.state, ContactLinkState.paired);
    });

    test("Gmail's Merge & fix folding a copy into the synced one", () {
      final rows = [
        link(1, 'people/c1', 'H1', base: annCopy()),
        link(
          2,
          'people/c2',
          null,
          base: annCopy(),
          state: ContactLinkState.held,
          reason: ContactHeldReason.duplicate,
        ),
      ];
      final plan = run(
        google: [
          g('people/c1', annCopy(), previous: ['people/c2']),
          gDeleted('people/c2'),
        ],
        links: rows,
      );
      expect(byLink(plan, 2)!.removeRow, isTrue);
      final pair = byLink(plan, 1);
      expect(pair == null || (pair.googleName, pair.graphId) ==
          ('people/c1', 'H1'), isTrue, reason: 'the pair untouched');
      expect(plan.links.where((l) => l.delete != null), isEmpty);
      expect(plan.mergedAway, [(googleName: 'people/c2', graphId: null)]);
      // The other way round: the synced copy merged into the held one.
      final into = run(
        google: [
          g('people/c2', annCopy(), previous: ['people/c1']),
          gDeleted('people/c1'),
        ],
        links: rows,
      );
      final kept = byLink(into, 1)!;
      expect((kept.googleName, kept.graphId), ('people/c2', 'H1'));
      expect(byLink(into, 2)!.removeRow, isTrue);
      expect(into.links.where((l) => l.delete != null), isEmpty);
    });

    test('listed on a run that read none of the copies', () {
      final rows = [
        ...synced(),
        link(
          3,
          'people/c2',
          null,
          base: annCopy(),
          state: ContactLinkState.held,
          reason: ContactHeldReason.duplicate,
        ),
      ];
      final plan = run(links: rows);
      expect(plan.links, isEmpty);
      final group = plan.duplicates.single;
      expect(group.title, 'Ann Cole');
      expect((group.googleSynced, group.graphSynced), ('people/c1', 'H1'));
      expect(group.googleCopies, ['people/c2']);
      expect(group.graphCopies, ['H2']);
      expect(plan.counts.duplicateCopies, 2);
      // A held copy whose address has changed since it was read is still
      // held while Ann is synced, and listed with her pair.
      final apart = run(
        links: [
          link(1, 'people/c1', 'H1', base: annCopy()),
          link(
            2,
            null,
            'H2',
            base: annCopy(emails: ['ann@old.example'], mobile: null),
            state: ContactLinkState.held,
            reason: ContactHeldReason.duplicate,
          ),
        ],
      );
      final alone = apart.duplicates.single;
      expect(alone.title, 'Ann Cole');
      expect(alone.graphCopies, ['H2']);
      expect((alone.googleSynced, alone.graphSynced), ('people/c1', 'H1'));
      expect(apart.reviews, isEmpty);
    });

    test('a first sync shaped like the tablet asks only about families and '
        'same names', () {
      // About 2000 contacts as Ron's tablet holds them: most people twice
      // in Hadco and once in Gmail, some twice in Gmail, a copy with only
      // an email or only a mobile; families on one address; and people
      // with the same name and nothing else in common.
      String mobile(int i) => '+1 212 555 ${i.toString().padLeft(4, '0')}';
      SyncedContact someone(
        int i, {
        bool email = true,
        bool phone = true,
      }) => person(
        given: 'P$i',
        family: 'Fam$i',
        emails: email ? ['p$i@x.example'] : null,
        mobile: phone ? mobile(i) : null,
      );
      final google = <GoogleContact>[];
      final graph = <GraphContact>[];
      for (var i = 0; i < 650; i++) {
        google.add(g('people/p$i', someone(i)));
        if (i % 10 == 0) {
          google.add(g('people/p$i-2', someone(i, email: false)));
        }
        graph.add(h('H$i', someone(i)));
        if (i % 5 != 0) {
          graph.add(h('H$i-2', someone(i, email: i.isEven, phone: i.isOdd)));
        }
      }
      for (var f = 0; f < 30; f++) {
        for (final given in ['Ann', 'Bob']) {
          final member = person(
            given: given,
            family: 'Home$f',
            emails: ['home$f@x.example'],
          );
          google.add(g('people/$given$f', member));
          graph.add(h('H-$given$f', member));
        }
      }
      SyncedContact sam(int k, String email) =>
          person(given: 'Sam$k', family: 'Same', emails: [email]);
      for (var k = 0; k < 20; k++) {
        google.add(g('people/s$k', sam(k, 'g$k@x')));
        graph.add(h('H-s$k', sam(k, 'h$k@x')));
      }
      expect(google.length + graph.length, greaterThan(2000));
      final plan = run(
        firstSync: true,
        google: google,
        graph: graph,
        googleComplete: true,
        graphComplete: true,
      );
      final reasons = <ContactReviewReason?, int>{};
      for (final r in plan.reviews) {
        reasons[r.reason] = (reasons[r.reason] ?? 0) + 1;
      }
      expect(reasons, {
        ContactReviewReason.sharedAddress: 60,
        ContactReviewReason.sameName: 20,
      });
      expect(plan.counts.pairUp, 650);
      expect(plan.counts.addToGoogle + plan.counts.addToGraph, 0);
      expect(plan.counts.duplicateCopies, 585);
      expect(plan.duplicates, hasLength(585));
      expect(plan.brakes, isEmpty);
      expect(plan.stop, isNull);
    });

    test('holding copies is no deletion and no change for the brakes', () {
      SyncedContact someone(int i) =>
          person(given: 'P$i', family: 'X', emails: ['p$i@x']);
      final plan = run(
        google: [
          for (var i = 0; i < 12; i++) g('people/c$i', someone(i)),
        ],
        graph: [
          for (var i = 0; i < 12; i++)
            for (final copy in ['a', 'b']) h('H$i$copy', someone(i)),
        ],
      );
      expect(held(plan), hasLength(12));
      expect(plan.brakes, isEmpty);
      expect(plan.counts.heldDeletions, 0);
      expect(plan.counts.heldChanges, 0);
    });
  });

}

extension on ContactLinkPlan {
  Map<String, Object?> graphPatchFor(Map<String, Object?> current) =>
      graphWrite!.graphPatch(current);
}
