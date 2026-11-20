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
    person: {'resourceName': name, 'etag': etag ?? 'etag-$name'},
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
      expect(byGraph(plan, 'H1')!.reason, ContactHeldReason.waiting);
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
      expect(byGraph(plan, 'H1')!.reason, ContactHeldReason.waiting);
      expect(byGraph(plan, 'H2')!.reason, ContactHeldReason.waiting);
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
      expect(copy.create!.tag, 'people/c1');
      expect(
        (copy.create!.body['singleValueExtendedProperties'] as List).single,
        {'id': graphLinkPropertyId, 'value': 'people/c1'},
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
      expect(pair.graphPatchFor({'displayName': 'Ann Cole'}), {
        'jobTitle': 'Director',
        'displayName': 'Ann Cole',
      });
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

    test('a pair neither feed mentions is left alone', () {
      final plan = run(links: [link(1, 'people/c1', 'H1', base: base)]);
      expect(plan.links, isEmpty);
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

    test('Apply them writes them, past the brake', () {
      final plan = run(
        google: renamed(11),
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
    });

    test('Copy them back writes the other side\'s values back', () {
      final plan = run(
        google: renamed(11),
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
}

extension on ContactLinkPlan {
  Map<String, Object?> graphPatchFor(Map<String, Object?> current) =>
      graphWrite!.graphPatch(current);
}
