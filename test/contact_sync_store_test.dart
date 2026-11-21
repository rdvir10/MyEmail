import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/contacts/contact_sync_planner.dart'
    show
        ContactBrakeItem,
        ContactReviewItem,
        ContactReviewKind,
        ContactReviewReason;
import 'package:myemail/data/contacts/contact_sync_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';

/// What contact sync keeps between runs: the same promises from the store
/// the tests use and from the database the phone does.
///
/// The ones that matter most are those where losing a write, or half of
/// one, would have the sync act twice or forget what it did: a create
/// cleared with its link saved, a delete finished with its link gone, a
/// re-key reaching every row, and a removed account's pair kept for its
/// return and dropped only after thirty days.
void main() {
  final stores = <(String, ContactSyncStore Function(DateTime Function()))>[
    ('in memory', (clock) => MemoryContactSyncStore(clock: clock)),
    (
      'in the database',
      (clock) {
        final db = MailDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        return DriftContactSyncStore(db, clock: clock);
      }
    ),
  ];

  for (final (name, make) in stores) {
    group('contact sync records, $name', () {
      late DateTime now;
      late ContactSyncStore store;

      setUp(() {
        now = DateTime.utc(2026, 11, 20, 9, 30);
        store = make(() => now);
      });

      Future<ContactPair> pairOf({
        String google = 'g-acct',
        String graph = 'm-acct',
        String googleAddress = 'ron@gmail.com',
        String graphAddress = 'ron@hadco.com',
      }) =>
          store.ensurePair(
            googleAccountId: google,
            googleAddress: googleAddress,
            graphAccountId: graph,
            graphAddress: graphAddress,
          );

      ContactLink paired(int pairId, String google, String graph) =>
          ContactLink(
            pairId: pairId,
            googleName: google,
            graphId: graph,
            googleEtag: 'etag-$google',
            graphChangeKey: 'ck-$graph',
            googleBase: '{"names":"$google"}',
            graphBase: '{"givenName":"$graph"}',
            state: ContactLinkState.paired,
          );

      /// One of everything the pair can hold, for the tests that drop or
      /// move them.
      Future<void> fill(int pairId, {String google = 'people/c1'}) async {
        await store.saveLink(paired(pairId, google, 'AAMk-1'));
        await store.journalCreates(pairId, ContactSide.graph, [
          (sourceKey: google, tag: google),
        ]);
        await store.saveReview(ContactReview(
          pairId: pairId,
          kind: 'clash',
          googleName: google,
          graphId: 'AAMk-1',
          data: '{}',
        ));
        await store.addToBin(ContactBinEntry(
          pairId: pairId,
          side: ContactSide.google,
          contactId: google,
          partnerId: 'AAMk-1',
          raw: '{}',
          title: 'Dana',
        ));
      }

      group('pairs', () {
        test('are made once, their addresses lower-cased', () async {
          final made = await pairOf(graphAddress: 'Ron@Hadco.com');

          expect(made.googleAccountId, 'g-acct');
          expect(made.graphAddress, 'ron@hadco.com');
          expect(made.isDetached, isFalse);
          expect(await pairOf(), made, reason: 'the same two accounts');
          expect(
            await store.pairFor(
                googleAccountId: 'g-acct', graphAccountId: 'm-acct'),
            made,
          );
          expect(await store.pairs(), [made]);
          expect(await store.pair(made.pairId), made);
        });

        test('keep every field they are given, and clear one given null',
            () async {
          final made = await pairOf();
          final full = await store.updatePair(
            made.pairId,
            (p) => p.copyWith(
              graphFolderId: 'folder-1',
              phoneRegion: 'IL',
              googleSyncToken: 'sync-1',
              googleMask: 3,
              googleFullAt: DateTime.utc(2026, 11, 19, 8, 1, 2, 345),
              graphDeltaLink: 'https://graph.example/delta?token=1',
              graphMask: 2,
              normaliser: 1,
              googleCount: 412,
              graphCount: 388,
              firstStartedAt: DateTime.utc(2026, 11, 19, 8),
              firstDoneAt: DateTime.utc(2026, 11, 19, 9),
              lastAttemptAt: DateTime.utc(2026, 11, 20, 9),
              lastDoneAt: DateTime.utc(2026, 11, 20, 9, 1),
              lastResult: '{"added":2}',
              held: '{"deletions":[]}',
            ),
          );

          expect(await store.pair(made.pairId), full,
              reason: 'read back as it was written');
          expect(full!.googleFullAt, DateTime.utc(2026, 11, 19, 8, 1, 2, 345));
          expect(full.googleCount, 412);

          final cleared = await store.updatePair(
            made.pairId,
            (p) => p.copyWith(googleSyncToken: null, held: null),
          );
          expect(cleared!.googleSyncToken, isNull);
          expect(cleared.held, isNull);
          expect(cleared.graphDeltaLink, isNotNull,
              reason: 'a field left out keeps its value');
          expect(await store.pair(made.pairId), cleared);
        });

        test('keep times as UTC to the millisecond, whatever they were given',
            () async {
          final made = await pairOf();
          final local = DateTime(2026, 11, 20, 11, 30, 0, 0, 999);

          final after = await store.updatePair(
              made.pairId, (p) => p.copyWith(lastAttemptAt: local));

          expect(after!.lastAttemptAt!.isUtc, isTrue);
          expect(after.lastAttemptAt!.millisecondsSinceEpoch,
              local.millisecondsSinceEpoch);
          expect(await store.pair(made.pairId), after);
        });

        test('a pair that is not there is not changed', () async {
          expect(await store.updatePair(41, (p) => p), isNull);
        });

        test('an account removed detaches its pair and keeps all it holds',
            () async {
          final made = await pairOf();
          await fill(made.pairId);

          expect(await store.detachAccount('m-acct'), 1);

          final detached = (await store.pair(made.pairId))!;
          expect(detached.detachedAt, now);
          expect(
            await store.pairFor(
                googleAccountId: 'g-acct', graphAccountId: 'm-acct'),
            isNull,
            reason: 'a detached pair runs no more',
          );
          expect(await store.links(made.pairId), hasLength(1));
          expect(await store.ops(made.pairId), hasLength(1));
          expect(await store.reviews(made.pairId), hasLength(1));
          expect(await store.bin(made.pairId), hasLength(1));

          now = now.add(const Duration(days: 3));
          expect(await store.detachAccount('g-acct'), 0,
              reason: 'already detached');
          expect((await store.pair(made.pairId))!.detachedAt,
              detached.detachedAt,
              reason: 'the thirty days count from the first removal');
        });

        test('the account added again, under a new id, attaches it again',
            () async {
          final made = await pairOf();
          await fill(made.pairId);
          await store.detachAccount('m-acct');

          final back = await store.reattachAccount(
            side: ContactSide.graph,
            accountId: 'm-acct-2',
            address: 'RON@hadco.com',
            liveAccountIds: ['g-acct', 'm-acct-2'],
          );

          expect(back.single.pairId, made.pairId);
          expect(back.single.graphAccountId, 'm-acct-2');
          expect(back.single.isDetached, isFalse);
          expect(
            await store.pairFor(
                googleAccountId: 'g-acct', graphAccountId: 'm-acct-2'),
            back.single,
          );
          expect(await store.links(made.pairId), hasLength(1),
              reason: 'it carries on where it stopped');
        });

        test('but not while its other account is gone too', () async {
          final made = await pairOf();
          await store.detachAccount('m-acct');

          final first = await store.reattachAccount(
            side: ContactSide.graph,
            accountId: 'm-acct-2',
            address: 'ron@hadco.com',
            liveAccountIds: ['m-acct-2'],
          );
          expect(first.single.graphAccountId, 'm-acct-2');
          expect(first.single.isDetached, isTrue);

          final second = await store.reattachAccount(
            side: ContactSide.google,
            accountId: 'g-acct-2',
            address: 'ron@gmail.com',
            liveAccountIds: ['m-acct-2', 'g-acct-2'],
          );
          expect(second.single.pairId, made.pairId);
          expect(second.single.isDetached, isFalse);
        });

        test('another address attaches nothing', () async {
          await pairOf();
          await store.detachAccount('m-acct');

          expect(
            await store.reattachAccount(
              side: ContactSide.graph,
              accountId: 'm-acct-2',
              address: 'ron@myhomestudio.club',
              liveAccountIds: ['g-acct', 'm-acct-2'],
            ),
            isEmpty,
          );
        });

        test('switching on again with the same two addresses takes up the '
            'detached pair', () async {
          final made = await pairOf();
          await fill(made.pairId);
          await store.detachAccount('m-acct');

          final again = await pairOf(graph: 'm-acct-2');

          expect(again.pairId, made.pairId);
          expect(again.graphAccountId, 'm-acct-2');
          expect(again.isDetached, isFalse);
          expect(await store.pairs(), hasLength(1));
        });

        test('a pair detached for thirty days goes with everything in it',
            () async {
          final old = await pairOf();
          await fill(old.pairId);
          final kept = await pairOf(google: 'g-2', googleAddress: 'b@x.com');
          await fill(kept.pairId);
          await store.detachAccount('g-acct');
          now = now.add(const Duration(days: 2));
          await store.detachAccount('g-2');

          now = now.add(const Duration(days: 28));
          expect(await store.dropDetached(), 1);

          expect(await store.pair(old.pairId), isNull);
          expect(await store.links(old.pairId), isEmpty);
          expect(await store.ops(old.pairId), isEmpty);
          expect(await store.reviews(old.pairId), isEmpty);
          expect(await store.bin(old.pairId), isEmpty);
          expect(await store.pair(kept.pairId), isNotNull,
              reason: 'detached for 28 days');
          expect(await store.links(kept.pairId), hasLength(1));
        });

        test('an attached pair is never dropped for its age', () async {
          final made = await pairOf();
          now = now.add(const Duration(days: 400));
          expect(await store.dropDetached(), 0);
          expect(await store.pair(made.pairId), isNotNull);
        });

        test('dropping a pair leaves the others alone', () async {
          final one = await pairOf();
          await fill(one.pairId);
          final two = await pairOf(google: 'g-2', googleAddress: 'b@x.com');
          await fill(two.pairId);

          await store.dropPair(one.pairId);

          expect(await store.pairs(), [two]);
          expect(await store.links(one.pairId), isEmpty);
          expect(await store.bin(one.pairId), isEmpty);
          expect(await store.links(two.pairId), hasLength(1));
          expect(await store.ops(two.pairId), hasLength(1));
          expect(await store.reviews(two.pairId), hasLength(1));
          expect(await store.bin(two.pairId), hasLength(1));
        });
      });

      group('links', () {
        test('are saved with an id and the time, and found by either side',
            () async {
          final pair = await pairOf();
          final saved = await store.saveLink(
            paired(pair.pairId, 'people/c1', 'AAMk-1')
                .copyWith(googleWrittenAt: DateTime.utc(2026, 11, 20, 9)),
          );

          expect(saved.linkId, isNotNull);
          expect(saved.updatedAt, now);
          expect(saved.googleWrittenAt, DateTime.utc(2026, 11, 20, 9));
          expect(await store.links(pair.pairId), [saved]);
          expect(
            await store.linkFor(pair.pairId, ContactSide.google, 'people/c1'),
            saved,
          );
          expect(
            await store.linkFor(pair.pairId, ContactSide.graph, 'AAMk-1'),
            saved,
          );
          expect(
            await store.linkFor(pair.pairId, ContactSide.graph, 'people/c1'),
            isNull,
          );
        });

        test('saved again keep their id and take the new values', () async {
          final pair = await pairOf();
          final first =
              await store.saveLink(paired(pair.pairId, 'people/c1', 'AAMk-1'));
          now = now.add(const Duration(minutes: 5));

          final held = await store.saveLink(first.copyWith(
            state: ContactLinkState.held,
            reason: ContactHeldReason.kept,
            graphChangeKey: null,
          ));

          expect(held.linkId, first.linkId);
          expect(held.updatedAt, now);
          expect(held.reason, ContactHeldReason.kept);
          expect(held.graphChangeKey, isNull);
          expect(await store.links(pair.pairId), [held]);
        });

        test("every held reason, the planner's candidate among them, "
            'reads back as saved', () async {
          final pair = await pairOf();
          for (final (i, reason) in ContactHeldReason.values.indexed) {
            await store.saveLink(ContactLink(
              pairId: pair.pairId,
              googleName: 'people/c$i',
              state: ContactLinkState.held,
              reason: reason,
            ));
          }

          expect(
            [for (final l in await store.links(pair.pairId)) l.reason],
            ContactHeldReason.values,
          );
        });

        test('a held link may name one side only', () async {
          final pair = await pairOf();
          final held = await store.saveLink(ContactLink(
            pairId: pair.pairId,
            googleName: 'people/c9',
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ));
          final other = await store.saveLink(ContactLink(
            pairId: pair.pairId,
            graphId: 'AAMk-9',
            state: ContactLinkState.held,
            reason: ContactHeldReason.refused,
          ));

          expect(await store.links(pair.pairId), [held, other],
              reason: 'two links with no Google side do not clash');
        });

        test('that break the rules are refused', () async {
          final pair = await pairOf();
          for (final wrong in [
            ContactLink(
              pairId: pair.pairId,
              googleName: 'people/c1',
              state: ContactLinkState.paired,
            ),
            ContactLink(
              pairId: pair.pairId,
              googleName: 'people/c1',
              state: ContactLinkState.held,
            ),
            ContactLink(
              pairId: pair.pairId,
              state: ContactLinkState.held,
              reason: ContactHeldReason.waiting,
            ),
            paired(pair.pairId, 'people/c1', 'AAMk-1')
                .copyWith(reason: ContactHeldReason.deletionBrake),
          ]) {
            await expectLater(store.saveLink(wrong), throwsArgumentError);
          }
          expect(await store.links(pair.pairId), isEmpty);
        });

        test('two links of a pair never name one contact', () async {
          final pair = await pairOf();
          await store.saveLink(paired(pair.pairId, 'people/c1', 'AAMk-1'));

          await expectLater(
            store.saveLink(ContactLink(
              pairId: pair.pairId,
              googleName: 'people/c1',
              state: ContactLinkState.held,
              reason: ContactHeldReason.waiting,
            )),
            throwsStateError,
          );
          await expectLater(
            store.saveLink(paired(pair.pairId, 'people/c2', 'AAMk-1')),
            throwsStateError,
          );
          expect(await store.links(pair.pairId), hasLength(1));

          final other = await pairOf(google: 'g-2', googleAddress: 'b@x.com');
          await store.saveLink(paired(other.pairId, 'people/c1', 'AAMk-1'));
          expect(await store.links(other.pairId), hasLength(1),
              reason: 'another pair is another pair of address books');
        });

        test('saved together are saved all or not at all', () async {
          final pair = await pairOf();

          await expectLater(
            store.saveLinks([
              paired(pair.pairId, 'people/c1', 'AAMk-1'),
              paired(pair.pairId, 'people/c2', 'AAMk-2'),
              paired(pair.pairId, 'people/c3', 'AAMk-1'),
            ]),
            throwsStateError,
          );
          expect(await store.links(pair.pairId), isEmpty);

          final saved = await store.saveLinks([
            paired(pair.pairId, 'people/c1', 'AAMk-1'),
            paired(pair.pairId, 'people/c2', 'AAMk-2'),
          ]);
          expect(await store.links(pair.pairId), saved);
        });

        test('are deleted by id', () async {
          final pair = await pairOf();
          final saved = await store.saveLinks([
            paired(pair.pairId, 'people/c1', 'AAMk-1'),
            paired(pair.pairId, 'people/c2', 'AAMk-2'),
          ]);

          await store.deleteLinks([saved.first.linkId!]);

          expect(await store.links(pair.pairId), [saved.last]);
        });

        test('one whose row has gone is not brought back', () async {
          // A link read before its delete finished, or before its pair
          // was dropped, and saved again: it would come back with a new id,
          // a stray row naming contacts that are gone.
          final pair = await pairOf();
          final link =
              await store.saveLink(paired(pair.pairId, 'people/c1', 'AAMk-1'));
          final binned = await store.addToBin(ContactBinEntry(
            pairId: pair.pairId,
            side: ContactSide.graph,
            contactId: 'AAMk-1',
            raw: '{}',
            title: 'Dana',
          ));
          await store.markBinDone(binned.binId!, dropLinkId: link.linkId);

          await expectLater(
            store.saveLink(link.copyWith(googleEtag: 'later')),
            throwsStateError,
          );
          await expectLater(
            store.saveLinks([
              paired(pair.pairId, 'people/c2', 'AAMk-2'),
              link,
            ]),
            throwsStateError,
          );
          expect(await store.links(pair.pairId), isEmpty);

          final other = await pairOf(google: 'g-2', googleAddress: 'b@x.com');
          final kept =
              await store.saveLink(paired(other.pairId, 'people/c1', 'AAMk-1'));
          await store.dropPair(other.pairId);
          await expectLater(store.saveLink(kept), throwsStateError);
          expect(await store.links(other.pairId), isEmpty);
        });
      });

      group('creates in flight', () {
        test('are journalled with the time', () async {
          final pair = await pairOf();

          final ops = await store.journalCreates(
              pair.pairId, ContactSide.graph, [
            (sourceKey: 'people/c1', tag: 'people/c1'),
            (sourceKey: 'people/c2', tag: 'people/c2'),
          ]);

          expect(ops.map((o) => o.startedAt), [now, now]);
          expect(ops.first.side, ContactSide.graph);
          expect(await store.ops(pair.pairId), ops);
        });

        test('one sent again replaces the first', () async {
          final pair = await pairOf();
          await store.journalCreates(pair.pairId, ContactSide.graph, [
            (sourceKey: 'people/c1', tag: 'old'),
          ]);
          now = now.add(const Duration(hours: 2));

          final again = await store.journalCreates(
              pair.pairId, ContactSide.graph, [
            (sourceKey: 'people/c1', tag: 'new'),
          ]);

          expect(await store.ops(pair.pairId), again);
          expect(again.single.startedAt, now);
          expect(again.single.tag, 'new');
        });

        test('landed: the op cleared and its link saved together', () async {
          final pair = await pairOf();
          final ops = await store.journalCreates(
              pair.pairId, ContactSide.graph, [
            (sourceKey: 'people/c1', tag: 'people/c1'),
            (sourceKey: 'people/c2', tag: 'people/c2'),
          ]);

          final saved = await store.completeCreates({
            ops.first.opId: paired(pair.pairId, 'people/c1', 'AAMk-1'),
          });

          expect(await store.ops(pair.pairId), [ops.last]);
          expect(await store.links(pair.pairId), saved);
        });

        test('a link that cannot be saved leaves its op in place', () async {
          // The two land together or not at all. An op cleared with no
          // link saved would leave the contact made on the server and
          // nothing here to say so: the next run would copy it again.
          final pair = await pairOf();
          await store.saveLink(paired(pair.pairId, 'people/c9', 'AAMk-1'));
          final ops = await store.journalCreates(
              pair.pairId, ContactSide.graph, [
            (sourceKey: 'people/c1', tag: 'people/c1'),
            (sourceKey: 'people/c2', tag: 'people/c2'),
          ]);

          await expectLater(
            store.completeCreates({
              ops.first.opId: paired(pair.pairId, 'people/c1', 'AAMk-2'),
              ops.last.opId: paired(pair.pairId, 'people/c2', 'AAMk-1'),
            }),
            throwsStateError,
          );

          expect(await store.ops(pair.pairId), ops);
          expect(await store.links(pair.pairId), hasLength(1));
        });

        test('are dropped by id', () async {
          final pair = await pairOf();
          final ops = await store.journalCreates(
              pair.pairId, ContactSide.google, [
            (sourceKey: 'AAMk-1', tag: 'AAMk-1'),
          ]);

          await store.dropOps([ops.single.opId]);

          expect(await store.ops(pair.pairId), isEmpty);
        });
      });

      group('Needs a look', () {
        ContactReview review(int pairId, {String data = '{"n":1}'}) =>
            ContactReview(
              pairId: pairId,
              kind: 'clash',
              googleName: 'people/c1',
              graphId: 'AAMk-1',
              data: data,
            );

        test('is saved with the time', () async {
          final pair = await pairOf();

          final saved = await store.saveReview(review(pair.pairId));

          expect(saved.reviewId, isNotNull);
          expect(saved.createdAt, now);
          expect(saved.isAnswered, isFalse);
          expect(await store.reviews(pair.pairId), [saved]);
        });

        test('raised again replaces what it shows and keeps an answer',
            () async {
          final pair = await pairOf();
          final first = await store.saveReview(review(pair.pairId));
          await store.answerReview(first.reviewId!, 'useGoogle');
          now = now.add(const Duration(hours: 1));

          final again =
              await store.saveReview(review(pair.pairId, data: '{"n":2}'));

          expect(again.reviewId, first.reviewId);
          expect(again.data, '{"n":2}');
          expect(again.createdAt, first.createdAt);
          expect(again.answer, 'useGoogle',
              reason: 'Ron\'s answer waits for the next run');
          expect(await store.reviews(pair.pairId), [again]);
        });

        test('about other contacts is another review', () async {
          final pair = await pairOf();
          await store.saveReview(review(pair.pairId));
          await store.saveReview(ContactReview(
            pairId: pair.pairId,
            kind: 'clash',
            googleName: 'people/c1',
            data: '{}',
          ));
          await store.saveReview(ContactReview(
            pairId: pair.pairId,
            kind: 'samePerson',
            googleName: 'people/c1',
            graphId: 'AAMk-1',
            data: '{}',
          ));

          expect(await store.reviews(pair.pairId), hasLength(3));
        });

        test("Ron's answer is queued with the time", () async {
          final pair = await pairOf();
          final saved = await store.saveReview(review(pair.pairId));
          now = now.add(const Duration(minutes: 3));

          final answered =
              await store.answerReview(saved.reviewId!, 'leaveOut');

          expect(answered!.answer, 'leaveOut');
          expect(answered.answeredAt, now);
          expect(await store.reviews(pair.pairId), [answered]);
          expect(await store.answerReview(999, 'leaveOut'), isNull);
        });

        test('saved by id takes every value given', () async {
          final pair = await pairOf();
          final saved = await store.saveReview(review(pair.pairId));
          final answered =
              await store.answerReview(saved.reviewId!, 'useGraph');

          final cleared = await store.saveReview(
            answered!.copyWith(answer: null, data: '{"n":3}'),
          );

          expect(cleared.reviewId, saved.reviewId);
          expect(cleared.answer, isNull);
          expect(cleared.answeredAt, isNull);
          expect(cleared.data, '{"n":3}');
          expect(await store.reviews(pair.pairId), [cleared]);
        });

        test('is dropped by id', () async {
          final pair = await pairOf();
          final saved = await store.saveReview(review(pair.pairId));

          await store.dropReviews([saved.reviewId!]);

          expect(await store.reviews(pair.pairId), isEmpty);
        });
      });

      group('Recently deleted', () {
        ContactBinEntry entry(int pairId, {String id = 'AAMk-1'}) =>
            ContactBinEntry(
              pairId: pairId,
              side: ContactSide.graph,
              contactId: id,
              partnerId: 'people/c1',
              raw: '{"givenName":"Dana"}',
              partnerBase: '{"names":[]}',
              title: 'Dana Levi',
            );

        test('a contact is binned, pending, with the time, before it goes',
            () async {
          final pair = await pairOf();

          final binned = await store.addToBin(entry(pair.pairId));

          expect(binned.binId, isNotNull);
          expect(binned.state, ContactBinState.pending);
          expect(binned.deletedAt, now);
          expect(binned.restore, isFalse);
          expect(await store.bin(pair.pairId), [binned]);
          expect(
            await store.binEntry(pair.pairId, ContactSide.graph, 'AAMk-1'),
            binned,
          );
          expect(
            await store.binEntry(pair.pairId, ContactSide.google, 'AAMk-1'),
            isNull,
          );
        });

        test('binned again, it is one entry', () async {
          final pair = await pairOf();
          await store.addToBin(entry(pair.pairId));
          now = now.add(const Duration(hours: 1));

          final again = await store.addToBin(entry(pair.pairId));

          expect(await store.bin(pair.pairId), [again]);
          expect(again.deletedAt, now);
        });

        test('done, its link goes in the same step', () async {
          final pair = await pairOf();
          final link =
              await store.saveLink(paired(pair.pairId, 'people/c1', 'AAMk-1'));
          final binned = await store.addToBin(entry(pair.pairId));

          final done =
              await store.markBinDone(binned.binId!, dropLinkId: link.linkId);

          expect(done!.state, ContactBinState.done);
          expect(await store.bin(pair.pairId), [done]);
          expect(await store.links(pair.pairId), isEmpty);
        });

        test('back, and Restore asked for and taken back', () async {
          final pair = await pairOf();
          final binned = await store.addToBin(entry(pair.pairId));

          final asked = await store.askRestore(binned.binId!);
          expect(asked!.restore, isTrue);
          expect(await store.bin(pair.pairId), [asked]);

          final unasked = await store.askRestore(binned.binId!, restore: false);
          expect(unasked!.restore, isFalse);

          final back = await store.markBinBack(binned.binId!);
          expect(back!.state, ContactBinState.back);
          expect(await store.bin(pair.pairId), [back]);
          expect(await store.markBinBack(999), isNull);
        });

        test('keeps a contact thirty days', () async {
          final pair = await pairOf();
          final old = await store.addToBin(entry(pair.pairId, id: 'AAMk-old'));
          now = now.add(const Duration(days: 2));
          final young =
              await store.addToBin(entry(pair.pairId, id: 'AAMk-young'));
          final other = await pairOf(google: 'g-2', googleAddress: 'b@x.com');
          final elsewhere = await store.addToBin(entry(other.pairId));

          now = now.add(const Duration(days: 28, seconds: 1));
          expect(await store.pruneBin(pair.pairId), 1);

          expect(await store.bin(pair.pairId), [young]);
          expect(await store.bin(other.pairId), [elsewhere],
              reason: 'only the pair asked about');
          expect(await store.binEntry(pair.pairId, ContactSide.graph,
              old.contactId), isNull);
        });

        test('entries are dropped by id', () async {
          final pair = await pairOf();
          final binned = await store.addToBin(entry(pair.pairId));

          await store.dropBin([binned.binId!]);

          expect(await store.bin(pair.pairId), isEmpty);
        });
      });

      group('a re-key', () {
        test('reaches every row naming the old name, and nothing else',
            () async {
          final pair = await pairOf();
          await fill(pair.pairId);
          await store.addToBin(ContactBinEntry(
            pairId: pair.pairId,
            side: ContactSide.graph,
            contactId: 'AAMk-7',
            partnerId: 'people/c1',
            raw: '{}',
            title: 'Dana',
          ));
          final other = await pairOf(google: 'g-2', googleAddress: 'b@x.com');
          await fill(other.pairId);

          await store.rekey(
              pair.pairId, ContactSide.google, 'people/c1', 'people/c77');

          final link = (await store.links(pair.pairId)).single;
          expect(link.googleName, 'people/c77');
          expect(link.graphId, 'AAMk-1');
          expect((await store.reviews(pair.pairId)).single.googleName,
              'people/c77');
          final op = (await store.ops(pair.pairId)).single;
          expect(op.sourceKey, 'people/c77');
          expect(op.tag, 'people/c1',
              reason: 'the tag is what the server holds');
          final binned = await store.bin(pair.pairId);
          expect(binned.first.contactId, 'people/c77');
          expect(binned.last.partnerId, 'people/c77');
          expect(binned.last.contactId, 'AAMk-7');

          expect((await store.links(other.pairId)).single.googleName,
              'people/c1',
              reason: 'another pair is not touched');
          expect((await store.ops(other.pairId)).single.sourceKey,
              'people/c1');
        });

        test('reaches the ids a brake holds and an open review names, in '
            'the JSON beside the rows', () async {
          // Google re-keys a contact while the deletion brake holds it and
          // a Needs a look item offers it as a candidate. Left under the
          // old name, Ron's answer to either would name a contact that is
          // no longer there, and be dropped.
          final pair = await pairOf();
          await store.saveLink(ContactLink(
            pairId: pair.pairId,
            googleName: 'people/c1',
            state: ContactLinkState.held,
            reason: ContactHeldReason.deletionBrake,
          ));
          String brakes(String google) => jsonEncode({
                'deletions': [
                  ContactBrakeItem(
                    title: 'Ann Lee',
                    side: ContactSide.graph,
                    googleName: google,
                  ).toJson(),
                  const ContactBrakeItem(
                    title: 'Bo Ng',
                    side: ContactSide.graph,
                    googleName: 'people/c3',
                  ).toJson(),
                ],
              });
          await store.updatePair(
              pair.pairId, (p) => p.copyWith(held: brakes('people/c1')));
          final candidate = await store.saveReview(ContactReview(
            pairId: pair.pairId,
            kind: ContactReviewKind.newContact.name,
            graphId: 'AAMk-9',
            data: jsonEncode(const ContactReviewItem(
              kind: ContactReviewKind.newContact,
              reason: ContactReviewReason.sameName,
              subjectSide: ContactSide.graph,
              graphId: 'AAMk-9',
              candidates: ['people/c2', 'people/c1'],
              candidateTitles: ['Ann Lee', 'Ann Lee'],
              title: 'Ann Lee',
            ).toJson()),
          ));
          await store.answerReview(
            candidate.reviewId!,
            jsonEncode({
              'kind': 'samePerson',
              'googleName': 'people/c1',
              'graphId': 'AAMk-9',
            }),
          );
          final other = await pairOf(google: 'g-2', googleAddress: 'b@x.com');
          await store.updatePair(
              other.pairId, (p) => p.copyWith(held: brakes('people/c1')));

          // A re-key that clashes changes nothing, the JSON included.
          await store.saveLink(paired(pair.pairId, 'people/c8', 'AAMk-8'));
          final pairBefore = await store.pair(pair.pairId);
          final reviewsBefore = await store.reviews(pair.pairId);
          await expectLater(
            store.rekey(
                pair.pairId, ContactSide.google, 'people/c1', 'people/c8'),
            throwsStateError,
          );
          expect(await store.pair(pair.pairId), pairBefore);
          expect(await store.reviews(pair.pairId), reviewsBefore);

          await store.rekey(
              pair.pairId, ContactSide.google, 'people/c1', 'people/c77');

          final held = (await store.pair(pair.pairId))!.held!;
          expect(held, brakes('people/c77'));
          final review = (await store.reviews(pair.pairId)).single;
          final data = jsonDecode(review.data) as Map;
          expect(data['candidates'], ['people/c2', 'people/c77']);
          expect(data['graphId'], 'AAMk-9');
          expect((jsonDecode(review.answer!) as Map)['googleName'],
              'people/c77');
          expect(review.isAnswered, isTrue);
          expect(review.createdAt, candidate.createdAt);
          expect(
            (await store.links(pair.pairId)).first.googleName,
            'people/c77',
          );
          expect((await store.pair(other.pairId))!.held, brakes('people/c1'),
              reason: 'another pair is not touched');
        });

        test('of a Hadco contact moves its own rows', () async {
          final pair = await pairOf();
          await store.saveLink(paired(pair.pairId, 'people/c1', 'AAMk-1'));
          await store.journalCreates(pair.pairId, ContactSide.google, [
            (sourceKey: 'AAMk-1', tag: 'AAMk-1'),
          ]);

          await store.rekey(pair.pairId, ContactSide.graph, 'AAMk-1', 'AAMk-2');

          expect((await store.links(pair.pairId)).single.graphId, 'AAMk-2');
          expect((await store.ops(pair.pairId)).single.sourceKey, 'AAMk-2');
        });

        test('onto a contact the pair already has changes nothing', () async {
          final pair = await pairOf();
          await fill(pair.pairId);
          await store.saveLink(paired(pair.pairId, 'people/c2', 'AAMk-2'));

          await expectLater(
            store.rekey(
                pair.pairId, ContactSide.google, 'people/c1', 'people/c2'),
            throwsStateError,
          );

          expect(
            (await store.links(pair.pairId)).map((l) => l.googleName),
            ['people/c1', 'people/c2'],
          );
          expect((await store.reviews(pair.pairId)).single.googleName,
              'people/c1');
          expect((await store.bin(pair.pairId)).single.contactId, 'people/c1');
        });

        test('onto a contact a create in flight copies changes nothing',
            () async {
          // Two creates journalled and cut short, then Ron merges the two
          // sources in Gmail. Moved onto the other's, the ops would be two
          // for one source: in the database a broken index on every run,
          // since Google names the old one again and again.
          final pair = await pairOf();
          final ops = await store.journalCreates(
              pair.pairId, ContactSide.graph, [
            (sourceKey: 'people/c1', tag: 'people/c1'),
            (sourceKey: 'people/c2', tag: 'people/c2'),
          ]);
          await store.saveReview(ContactReview(
            pairId: pair.pairId,
            kind: 'clash',
            googleName: 'people/c1',
            data: '{}',
          ));

          await expectLater(
            store.rekey(
                pair.pairId, ContactSide.google, 'people/c1', 'people/c2'),
            throwsStateError,
          );

          expect(await store.ops(pair.pairId), ops);
          expect((await store.reviews(pair.pairId)).single.googleName,
              'people/c1');
        });

        test('onto a source journalled on the same side is no clash',
            () async {
          // A create on the Google side copies a Hadco contact; a Google
          // re-key does not touch it.
          final pair = await pairOf();
          await store.saveLink(ContactLink(
            pairId: pair.pairId,
            googleName: 'people/c1',
            state: ContactLinkState.held,
            reason: ContactHeldReason.waiting,
          ));
          await store.journalCreates(pair.pairId, ContactSide.google, [
            (sourceKey: 'people/c2', tag: 'people/c2'),
          ]);

          await store.rekey(
              pair.pairId, ContactSide.google, 'people/c1', 'people/c2');

          expect((await store.links(pair.pairId)).single.googleName,
              'people/c2');
        });
      });

      group('a transaction', () {
        test('that throws leaves everything as it was', () async {
          // The brake's case: the links held and the question on the pair
          // land together, or a crash between them leaves contacts held
          // with nothing on screen to say why.
          final pair = await pairOf();
          final link =
              await store.saveLink(paired(pair.pairId, 'people/c1', 'AAMk-1'));
          final review = await store.saveReview(ContactReview(
            pairId: pair.pairId,
            kind: 'clash',
            googleName: 'people/c1',
            data: '{}',
          ));
          final before = (
            await store.pairs(),
            await store.links(pair.pairId),
            await store.reviews(pair.pairId),
          );

          await expectLater(
            store.transaction(() async {
              await store.saveLinks([
                link.copyWith(
                  state: ContactLinkState.held,
                  reason: ContactHeldReason.deletionBrake,
                ),
                paired(pair.pairId, 'people/c2', 'AAMk-2'),
              ]);
              await store.updatePair(
                  pair.pairId, (p) => p.copyWith(held: '{"deletions":6}'));
              await store.dropReviews([review.reviewId!]);
              await store.journalCreates(pair.pairId, ContactSide.graph, [
                (sourceKey: 'people/c3', tag: 'people/c3'),
              ]);
              await store.addToBin(ContactBinEntry(
                pairId: pair.pairId,
                side: ContactSide.google,
                contactId: 'people/c4',
                raw: '{}',
                title: 'Noa',
              ));
              await pairOf(google: 'g-2', googleAddress: 'b@x.com');
              throw StateError('the app was put away');
            }),
            throwsStateError,
          );

          expect(await store.pairs(), before.$1);
          expect(await store.links(pair.pairId), before.$2);
          expect(await store.reviews(pair.pairId), before.$3);
          expect(await store.ops(pair.pairId), isEmpty);
          expect(await store.bin(pair.pairId), isEmpty);
        });

        test('that ends lands every write, the store\'s own steps among them',
            () async {
          final pair = await pairOf();
          final ops = await store.journalCreates(
              pair.pairId, ContactSide.graph, [
            (sourceKey: 'people/c1', tag: 'people/c1'),
          ]);

          final result = await store.transaction(() async {
            await store.completeCreates({
              ops.single.opId: paired(pair.pairId, 'people/c1', 'AAMk-1'),
            });
            await store.updatePair(
                pair.pairId, (p) => p.copyWith(graphCount: 1));
            // One inside that fails and is caught undoes only itself.
            try {
              await store.transaction(() async {
                await store.saveLink(
                    paired(pair.pairId, 'people/c2', 'AAMk-2'));
                throw StateError('refused');
              });
            } on StateError {
              // Passed by, as a refused contact is.
            }
            return 'done';
          });

          expect(result, 'done');
          expect(await store.ops(pair.pairId), isEmpty);
          expect(
            (await store.links(pair.pairId)).map((l) => l.googleName),
            ['people/c1'],
          );
          expect((await store.pair(pair.pairId))!.graphCount, 1);
        });
      });
    });
  }

  group('in the database', () {
    test('a link whose state a later build wrote reads as waiting', () async {
      // A downgrade, which Ron does not do, but a store that cannot read
      // its own rows would stop the sync for good.
      final db = MailDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = DriftContactSyncStore(db);
      final pair = await store.ensurePair(
        googleAccountId: 'g',
        googleAddress: 'a@gmail.com',
        graphAccountId: 'm',
        graphAddress: 'a@hadco.com',
      );
      await db.customStatement(
        'INSERT INTO contact_links (pair_id, google_name, graph_id, state, '
        "reason, updated_at) VALUES (?, 'people/c1', 'AAMk-1', 'linked', "
        "'pondering', 0)",
        [pair.pairId],
      );

      final link = (await store.links(pair.pairId)).single;

      expect(link.state, ContactLinkState.held);
      expect(link.reason, ContactHeldReason.waiting);
    });

    test("a held link's reason is kept as the planner's code", () async {
      // The planner reads the rows back through ContactHeldReason.fromCode:
      // a name kept instead (leftOut, not left_out) would read as unknown,
      // and every held contact would turn into one waiting under Needs a
      // look.
      final db = MailDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = DriftContactSyncStore(db);
      final pair = await store.ensurePair(
        googleAccountId: 'g',
        googleAddress: 'a@gmail.com',
        graphAccountId: 'm',
        graphAddress: 'a@hadco.com',
      );
      for (final (i, reason) in ContactHeldReason.values.indexed) {
        await store.saveLink(ContactLink(
          pairId: pair.pairId,
          graphId: 'AAMk-$i',
          state: ContactLinkState.held,
          reason: reason,
        ));
      }
      await store.saveLink(ContactLink(
        pairId: pair.pairId,
        googleName: 'people/c1',
        graphId: 'AAMk-p',
        state: ContactLinkState.paired,
      ));

      final rows = await db
          .customSelect(
            'SELECT state, reason FROM contact_links ORDER BY link_id',
          )
          .get();

      expect([for (final r in rows) r.read<String?>('reason')], [
        'left_out',
        'waiting',
        'candidate',
        'kept',
        'moved_out',
        'refused',
        'brake_delete',
        'brake_change',
        null,
      ]);
      expect({for (final r in rows) r.read<String>('state')}, {
        'held',
        'paired',
      });
    });

    test('a second connection sees what the first wrote', () async {
      // The store keeps nothing in memory between calls: the screen and
      // the runner may hold different instances on one file.
      final db = MailDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final first = DriftContactSyncStore(db);
      final second = DriftContactSyncStore(db);
      final pair = await first.ensurePair(
        googleAccountId: 'g',
        googleAddress: 'a@gmail.com',
        graphAccountId: 'm',
        graphAddress: 'a@hadco.com',
      );
      await first.updatePair(pair.pairId, (p) => p.copyWith(googleCount: 5));

      expect((await second.pair(pair.pairId))!.googleCount, 5);
    });
  });

  group('the engine', () {
    test('keeps the records it is given, and in memory otherwise', () {
      final db = MailDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final given = DriftContactSyncStore(db);
      CachedImapEngine engine({ContactSyncStore? contactSyncStore}) =>
          CachedImapEngine(
            accountStore: MemoryAccountStore(),
            credentialStore: MemoryCredentialStore(),
            cache: MemoryCacheStore(),
            contactSyncStore: contactSyncStore,
          );

      expect(engine(contactSyncStore: given).contactSyncStore, same(given));
      expect(engine().contactSyncStore, isA<MemoryContactSyncStore>());
    });

    test('is given the database by the app', () {
      // Without it every test passes, and the phone forgets every pair,
      // link and deletion at each restart: the next run would match
      // everything afresh and could copy what it had deleted.
      final main = File('lib/main.dart').readAsStringSync();
      expect(main,
          contains('contactSyncStore: DriftContactSyncStore(database)'));
    });
  });
}
