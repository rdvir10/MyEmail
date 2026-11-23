import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui show PlatformDispatcher;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../../domain/account.dart';
import '../../domain/error_report.dart';
import '../../domain/synced_contact.dart';
import '../auth/google_oauth.dart' show GoogleOAuth;
import '../auth/microsoft_oauth.dart'
    show MicrosoftOAuth, SignInExpired, SignInNeedsConsent;
import '../graph/graph_contacts_api.dart';
import '../mail_engine.dart' show AuthenticationFailed, ConnectionFailed;
import '../ui_state_store.dart';
import 'account_people.dart' show AccountPeople;
import 'contact_backup.dart';
import 'contact_copies.dart' as cp;
import 'contact_mapping.dart';
import 'contact_sync_planner.dart';
import 'contact_sync_service.dart';
import 'contact_sync_store.dart';
import 'contact_wire_errors.dart';
import 'google_contacts_api.dart';

/// An account's token for [scopes]: `OAuthTokenRepository.accessToken`.
typedef ContactSyncToken =
    Future<String> Function(
      String accountId, {
      bool force,
      List<String>? scopes,
    });

/// The contact sync runner: reads both address books, plans with
/// [planContactSync], carries the plan out one write at a time, and keeps
/// what it did in the [ContactSyncStore]. Owned by the engine, never by a
/// screen, because settings screens close when the app is put away.
///
/// One run at a time: the running one is shared, Sync now joins it, and an
/// answer asks for a second straight after it. A run, in order: the claim
/// and access; both feeds; contacts looked up by id (what looks deleted,
/// what the queued answers and Restores name, what a listing left out);
/// the plan (the empty-answers check, interrupted creates, answers and
/// Restores, the brakes); the rows that need no write, with the plan's
/// re-keys, Needs a look and the brakes' questions; then the writes, each
/// row saved as its write comes back; and only then the feeds' new
/// positions, the counts, the result and the claim. A run stopped part way
/// (the app put away, a failure) leaves the positions where they were, so
/// the next reads the same changes again and finds them done.
///
/// No request is made inside a store transaction, and the log has counts,
/// timings and HTTP statuses only: no name, address, number or note.
class ContactSync implements ContactSyncService {
  ContactSync({
    required this.store,
    required this.accounts,
    required this.accessToken,
    Future<String> Function()? deviceId,
    String? Function()? region,
    http.Client? httpClient,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
  }) : _deviceIdOf = deviceId,
       _region = region ?? _phoneRegion,
       _client = httpClient,
       _sleepFor = sleep,
       _clock = clock ?? DateTime.now;

  final ContactSyncStore store;

  /// Every account in the app, as it stands.
  final Iterable<Account> Function() accounts;
  final ContactSyncToken accessToken;

  /// This device's own random id, kept where the app keeps it.
  final Future<String> Function()? _deviceIdOf;
  final String? Function() _region;

  /// Tests' way in to the fake servers; the app's clients make their own.
  final http.Client? _client;
  final Future<void> Function(Duration)? _sleepFor;
  final DateTime Function() _clock;

  /// Another device's claim younger than this stops a run.
  static const claimLasts = Duration(days: 7);

  /// Google's sync tokens expire a week after the full listing that
  /// started them: a full listing is taken after six days.
  static const fullListingAfter = Duration(days: 6);

  /// A Google batch create costs 200 of the day's contact writes however
  /// few it holds: fewer contacts than this go one at a time.
  static const googleBatchFloor = 100;

  /// Outlook creates in the first sync go twenty to a `$batch` when there
  /// are at least this many.
  static const graphBatchFloor = 2;

  DateTime _now() => _clock().toUtc();

  // --- runs ------------------------------------------------------------------

  Future<void>? _running;
  bool _again = false;
  bool _stopAsked = false;
  bool _takeClaim = false;

  /// Set by [forget]: an account signed in again may allow what it did not,
  /// so the pause after a failed run does not hold the next one back.
  bool _pauseLifted = false;
  ContactSyncProgress? _progress;
  String? _device;

  /// Outlook contacts' hidden tags as last read, by id, with the
  /// `changeKey` they were read at: a contact without a row is read by id
  /// for its tag once per change, not once per run (the preview and Start
  /// read the same contacts within minutes).
  final Map<String, ({String? changeKey, String? tag})> _tags = {};

  final _changes = StreamController<void>.broadcast();

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Stream<void> get changed => _changes.stream;

  /// Run now, or join the run going. With [again], a run is wanted after
  /// the one going too: an answer queued while it reads.
  Future<void> _go({bool again = false}) {
    final running = _running;
    if (running != null) {
      if (again) _again = true;
      return running;
    }
    _stopAsked = false;
    final run = _runLoop();
    _running = run;
    return run;
  }

  Future<void> _runLoop() async {
    try {
      do {
        _again = false;
        await _runOnce();
      } while (_again && !_stopAsked);
    } catch (e) {
      // _Run records its own failures; this is a mistake of the runner's,
      // and the shell must not see it.
      debugPrint('[myemail] contacts: run failed unexpectedly '
          '(${e.runtimeType})');
    } finally {
      _running = null;
      _progress = null;
      _changed();
    }
  }

  Future<void> _runOnce() async {
    final pair = await _attachedPair();
    if (pair == null || pair.firstStartedAt == null) return;
    _pauseLifted = false;
    // Sync here holds until a run completes: one stopped part way takes
    // the claim over again when it carries on.
    if (await _Run(this, pair, takeClaim: _takeClaim).go()) {
      _takeClaim = false;
    }
  }

  /// When [changed] last told of progress: a first sync of a thousand
  /// contacts would otherwise have the screen read the status a thousand
  /// times.
  final _sinceProgress = Stopwatch();

  void _progressTo(ContactSyncProgress? progress) {
    final before = _progress;
    _progress = progress;
    final moved =
        before == null ||
        progress == null ||
        before.step != progress.step ||
        progress.done >= progress.total;
    if (moved || _sinceProgress.elapsedMilliseconds >= 250) {
      _sinceProgress
        ..reset()
        ..start();
      _changed();
    }
  }

  @override
  Future<void> start() async {
    final pair = await _attachedPair();
    if (pair == null) return;
    if (pair.firstStartedAt == null) {
      final region = pair.phoneRegion ?? _regionNow();
      await store.updatePair(
        pair.pairId,
        (p) => p.copyWith(
          firstStartedAt: p.firstStartedAt ?? _now(),
          phoneRegion: p.phoneRegion ?? region,
        ),
      );
      debugPrint('[myemail] contacts: first sync started');
    }
    await _go();
  }

  @override
  Future<void> syncNow() => _go();

  @override
  Future<bool> startIfDue() async {
    try {
      if (_running != null) return false;
      final pair = await _attachedPair();
      if (pair == null || pair.firstStartedAt == null) return false;
      final now = _now();
      final held = _Held.parse(pair.held);
      if (held.quotaUntil case final until? when now.isBefore(until)) {
        return false;
      }
      final last = _LastResult.parse(pair.lastResult);
      final halt = last.halt;
      if (!_pauseLifted &&
          halt != null &&
          halt.pausesRuns &&
          now.difference(halt.at) < ContactSyncStatus.failedPause) {
        return false;
      }
      final done = pair.lastDoneAt;
      final firstUnfinished = pair.firstDoneAt == null;
      // A merge of Hadco's copies asked, or an answer to one waiting, is
      // carried on the next time MyEmail is open, as a first sync is.
      if (!firstUnfinished &&
          !held.copies.dueNow &&
          done != null &&
          now.difference(done) < ContactSyncStatus.dueAfter) {
        return false;
      }
      unawaited(_go());
      return true;
    } catch (e) {
      debugPrint('[myemail] contacts: could not check for a due run '
          '(${e.runtimeType})');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    final running = _running;
    if (running == null) return;
    _stopAsked = true;
    _again = false;
    await running;
  }

  /// A test's way to see whether a run is going.
  bool get isRunning => _running != null;

  // --- the engine's hooks ----------------------------------------------------

  /// [accountId] signed in again: what it would not allow before, it may
  /// allow now, so the pause after a refused run is lifted.
  void forget(String accountId) {
    _pauseLifted = true;
    _changed();
  }

  /// [accountId] is being removed: the run going stops and is waited for,
  /// then every pair naming it is detached, keeping all it holds, so that
  /// adding the same address again carries on where it stopped.
  Future<void> accountRemoved(String accountId) async {
    await stop();
    final detached = await store.detachAccount(accountId);
    if (detached > 0) {
      debugPrint('[myemail] contacts: $detached pair(s) detached');
    }
    _changed();
  }

  /// [account] was added: a pair detached when an account of the same
  /// address was removed takes it, and is attached again when its other
  /// account is there. Not where that would leave an account in two
  /// attached pairs: an account syncs with one other, the one chosen last.
  Future<void> accountAdded(Account account) async {
    if (account.isShared) return;
    final side = account.provider == MailProvider.gmail
        ? ContactSide.google
        : ContactSide.graph;
    final back = await store.reattachAccount(
      side: side,
      accountId: account.id,
      address: account.emailAddress,
      liveAccountIds: accounts().map((a) => a.id),
    );
    for (final pair in back) {
      if (pair.isDetached) continue;
      final others = await store.pairs();
      final clash = others.any(
        (p) =>
            p.pairId != pair.pairId &&
            !p.isDetached &&
            (p.googleAccountId == pair.googleAccountId ||
                p.graphAccountId == pair.graphAccountId),
      );
      if (clash) {
        await store.updatePair(
          pair.pairId,
          (p) => p.copyWith(detachedAt: _now()),
        );
      } else {
        debugPrint('[myemail] contacts: a pair was attached again');
      }
    }
    _changed();
  }

  /// Let go: the run going is stopped.
  Future<void> close() async {
    await stop();
    await _changes.close();
  }

  // --- the pair --------------------------------------------------------------

  /// The pair this device syncs: the attached one, the latest if there
  /// were ever two.
  Future<ContactPair?> _attachedPair() async {
    final pairs = await store.pairs();
    return pairs.where((p) => !p.isDetached).lastOrNull;
  }

  Account? _account(String id) =>
      accounts().firstWhereOrNull((a) => a.id == id);

  @override
  Future<void> choose({
    required String googleAccountId,
    required String graphAccountId,
  }) async {
    // The screen chooses again whenever it is about to act: the same two
    // accounts change nothing, whatever is going on.
    final current = await _attachedPair();
    if (current != null &&
        current.googleAccountId == googleAccountId &&
        current.graphAccountId == graphAccountId) {
      return;
    }
    if (_running != null) {
      throw const ContactSyncRefused(
        'Contact sync is running. Choose the accounts once it has stopped.',
      );
    }
    final google = _account(googleAccountId);
    final graph = _account(graphAccountId);
    if (google == null ||
        google.provider != MailProvider.gmail ||
        !AccountPeople.canSearch(google)) {
      throw const ContactSyncRefused(
        'Contact sync needs a Gmail account signed in with Google.',
      );
    }
    if (graph == null ||
        graph.provider != MailProvider.outlook ||
        !AccountPeople.canSearch(graph)) {
      throw const ContactSyncRefused(
        "Contact sync needs a Microsoft account's own mailbox.",
      );
    }
    final pair = await store.ensurePair(
      googleAccountId: google.id,
      googleAddress: google.emailAddress,
      graphAccountId: graph.id,
      graphAddress: graph.emailAddress,
    );
    for (final other in await store.pairs()) {
      if (other.pairId == pair.pairId || other.isDetached) continue;
      if (other.googleAccountId == google.id ||
          other.graphAccountId == graph.id) {
        await store.updatePair(
          other.pairId,
          (p) => p.copyWith(detachedAt: _now()),
        );
      }
    }
    _changed();
  }

  // --- access ----------------------------------------------------------------

  static List<String> _scopesOf(ContactSide side) => side == ContactSide.google
      ? GoogleOAuth.contactSyncScopes
      : MicrosoftOAuth.contactSyncScopes;

  @override
  Future<ContactSyncAccess> access(String accountId) async {
    final account = _account(accountId);
    if (account == null || !AccountPeople.canSearch(account)) {
      return const ContactSyncAccess(ContactSyncAccessState.notPossible);
    }
    final side = account.provider == MailProvider.gmail
        ? ContactSide.google
        : ContactSide.graph;
    try {
      await accessToken(accountId, scopes: _scopesOf(side));
      return const ContactSyncAccess(ContactSyncAccessState.allowed);
    } on SignInNeedsConsent catch (e) {
      return ContactSyncAccess(
        e.needsAdministrator
            ? ContactSyncAccessState.needsAdministrator
            : ContactSyncAccessState.needsSignIn,
        e.message,
      );
    } on SignInExpired catch (e) {
      return ContactSyncAccess(ContactSyncAccessState.unknown, e.message);
    } catch (e) {
      return ContactSyncAccess(
        ContactSyncAccessState.unknown,
        e is ReadableError ? e.message : 'Could not ask (${e.runtimeType}).',
      );
    }
  }

  // --- status ----------------------------------------------------------------

  @override
  Future<ContactSyncStatus> status() async {
    final pair = await _attachedPair();
    if (pair == null) return ContactSyncStatus(running: _progress);
    final held = _Held.parse(pair.held);
    final last = _LastResult.parse(pair.lastResult);
    final reviews = await store.reviews(pair.pairId);
    final bin = await store.bin(pair.pairId);
    return ContactSyncStatus(
      googleAccountId: pair.googleAccountId,
      graphAccountId: pair.graphAccountId,
      firstStartedAt: pair.firstStartedAt,
      firstDoneAt: pair.firstDoneAt,
      lastAttemptAt: pair.lastAttemptAt,
      lastDoneAt: pair.lastDoneAt,
      running: _progress,
      last: last.tally,
      halt: last.halt,
      questions: [
        for (final q in held.questions)
          if (q.items.isNotEmpty || q.kind == ContactSyncQuestionKind.emptyAnswer)
            q.shown(),
      ],
      needsALook: [
        for (final r in reviews)
          ?_Look.of(r),
      ],
      recentlyDeleted: [
        for (final b in bin)
          if (b.binId != null)
            ContactSyncDeleted(
              id: b.binId!,
              title: b.title,
              side: b.side,
              state: switch (b.state) {
                ContactBinState.pending => ContactSyncDeletedState.deleting,
                ContactBinState.done => ContactSyncDeletedState.deleted,
                ContactBinState.back => ContactSyncDeletedState.back,
              },
              deletedAt: b.deletedAt,
              restoreAsked: b.restore,
              restoreProblem: held.restoreProblems[b.binId],
            ),
      ],
      googleCount: pair.googleCount,
      graphCount: pair.graphCount,
      notice: _noticeOf(held, last),
      duplicates: [
        for (final d in held.duplicates) d.shown(),
      ],
      copies: held.copies.shown(),
    );
  }

  /// The one-line message: the last stop, or questions raised, since the
  /// shell last showed one.
  static ContactSyncNotice? _noticeOf(_Held held, _LastResult last) {
    final seen = held.noticeSeenAt;
    bool fresh(DateTime at) => seen == null || at.isAfter(seen);
    final halt = last.halt;
    final stopped = halt != null &&
            halt.kind != ContactSyncHaltKind.putAway &&
            fresh(halt.at)
        ? halt
        : null;
    var deletions = 0;
    var changes = 0;
    DateTime? at = stopped?.at;
    for (final q in held.questions) {
      if (q.answer != null || !fresh(q.at)) continue;
      // Items answered on their own wait for a run, not for Ron.
      final open = q.items.where((i) => _Question.answerOf(i) == null).length;
      if (open == 0) continue;
      if (q.kind == ContactSyncQuestionKind.deletions) {
        deletions += open;
      } else if (q.kind == ContactSyncQuestionKind.changes) {
        changes += open;
      } else {
        continue;
      }
      if (at == null || q.at.isAfter(at)) at = q.at;
    }
    if (at == null) return null;
    return ContactSyncNotice(
      at: at,
      halt: stopped,
      heldDeletions: deletions,
      heldChanges: changes,
    );
  }

  // --- the copies on the Microsoft side --------------------------------------

  @override
  Future<void> mergeCopies() async {
    final pair = await _attachedPair();
    if (pair == null || pair.firstDoneAt == null) return;
    var asked = false;
    await store.updatePair(pair.pairId, (p) {
      final held = _Held.parse(p.held);
      if (held.copies.people == 0) return p;
      if (held.copies.asked == null) {
        held.copies
          ..asked = _now()
          ..shortStops = 0;
      }
      asked = true;
      return p.copyWith(held: held.encode());
    });
    if (!asked) return;
    debugPrint('[myemail] contacts: a merge of copies asked');
    _changed();
    unawaited(_go(again: true));
  }

  @override
  Future<void> answerCopies(
    String person,
    String? keep,
    String version,
  ) async {
    final pair = await _attachedPair();
    if (pair == null) return;
    await store.updatePair(pair.pairId, (p) {
      final held = _Held.parse(p.held);
      final listed = held.copies.listed(person);
      if (listed == null ||
          _Copies.versionOf(listed) != version ||
          (keep != null && !_Copies.copyKeys(listed).contains(keep))) {
        throw const ContactSyncRefused(
          "That person's copies have changed since they were shown. Look "
          'at them again.',
        );
      }
      listed['answer'] = keep ?? ContactSyncCopiesPerson.leave;
      return p.copyWith(held: held.encode());
    });
    _changed();
    unawaited(_go(again: true));
  }

  @override
  Future<void> answerAllCopies(Map<String, String> people) async {
    final pair = await _attachedPair();
    if (pair == null) return;
    await store.updatePair(pair.pairId, (p) {
      final held = _Held.parse(p.held);
      var any = false;
      for (final listed in held.copies.differing) {
        // Only one shown, at the differences shown, with no answer yet: a
        // person listed since the screen was drawn is never answered by
        // it, nor one whose copies have changed.
        final key = listed['key']! as String;
        if (listed['answer'] != null ||
            people[key] != _Copies.versionOf(listed)) {
          continue;
        }
        // The person is named by its synced copy.
        listed['answer'] = key;
        any = true;
      }
      if (!any) {
        throw const ContactSyncRefused(
          "Those people's copies have changed since they were shown. Look "
          'at them again.',
        );
      }
      return p.copyWith(held: held.encode());
    });
    _changed();
    unawaited(_go(again: true));
  }

  @override
  Future<void> noticeSeen(DateTime at) async {
    final pair = await _attachedPair();
    if (pair == null) return;
    await store.updatePair(pair.pairId, (p) {
      final held = _Held.parse(p.held);
      final seen = held.noticeSeenAt;
      if (seen != null && !at.isAfter(seen)) return p;
      return p.copyWith(held: (held..noticeSeenAt = at.toUtc()).encode());
    });
    _changed();
  }

  // --- answers ---------------------------------------------------------------

  @override
  Future<void> answerQuestion(
    ContactSyncQuestionKind kind,
    ContactSyncChoice choice, {
    Set<String>? items,
  }) async {
    if (choice == ContactSyncChoice.keepWaiting) return;
    if (!ContactSyncQuestion(kind: kind).choices.contains(choice)) {
      throw ArgumentError.value(choice, 'choice', 'not an answer to $kind');
    }
    final pair = await _attachedPair();
    if (pair == null) return;
    final whole = items == null || kind == ContactSyncQuestionKind.emptyAnswer;
    await store.updatePair(pair.pairId, (p) {
      final held = _Held.parse(p.held);
      final questions = [
        for (final q in held.questions)
          if (q.kind == kind) q,
      ];
      if (!whole) {
        // All or nothing: a key the question no longer has (its contact
        // gone, or the question answered since) means the screen shows
        // what is no longer so, and Ron should look again.
        final known = {
          for (final q in questions)
            for (final item in q.items) _Question.keyOf(item),
        };
        if (!known.containsAll(items)) {
          throw const ContactSyncRefused(
            'That question has changed since it was shown. Look at it '
            'again.',
          );
        }
      }
      // An item answered anew no longer says why its last answer waited
      // ([_Held.waits]): no run has tried this one.
      for (final q in questions) {
        if (whole) {
          // Every item not answered on its own.
          if (q.answer != null) continue;
          q.answer = choice;
          for (final item in q.items) {
            if (_Question.answerOf(item) == null) item.remove(_Held.waits);
          }
          continue;
        }
        for (final item in q.items) {
          if (!items.contains(_Question.keyOf(item))) continue;
          // Named with others (the screen's "for all"), one answered on its
          // own meanwhile keeps its answer; named alone, it takes this one.
          if (items.length > 1 && _Question.answerOf(item) != null) continue;
          item['answer'] = choice.name;
          item.remove(_Held.waits);
        }
      }
      return p.copyWith(held: held.encode());
    });
    _changed();
    unawaited(_go(again: true));
  }

  @override
  Future<void> answerLook(
    int lookId,
    ContactSyncChoice choice, {
    String? candidateId,
  }) async {
    if (await _queueLook(lookId, choice, candidateId: candidateId)) {
      unawaited(_go(again: true));
    }
    _changed();
  }

  @override
  Future<void> answerAllDiffering(ContactSyncChoice choice) async {
    final pair = await _attachedPair();
    if (pair == null) return;
    var run = false;
    for (final r in await store.reviews(pair.pairId)) {
      // Only those not answered yet: an answer given item by item stands.
      if (r.kind != ContactReviewKind.differing.name ||
          r.reviewId == null ||
          r.isAnswered) {
        continue;
      }
      if (await _queueLook(r.reviewId!, choice)) run = true;
    }
    _changed();
    if (run) unawaited(_go(again: true));
  }

  /// Queue [choice] on the review [lookId]; true when a run must carry it
  /// out, false when it was done here (an item that just goes).
  Future<bool> _queueLook(
    int lookId,
    ContactSyncChoice choice, {
    String? candidateId,
  }) async {
    final pair = await _attachedPair();
    if (pair == null) return false;
    final review = (await store.reviews(
      pair.pairId,
    )).firstWhereOrNull((r) => r.reviewId == lookId);
    if (review == null) return false;
    final look = _Look.of(review);
    if (look == null || !look.choices.contains(choice)) {
      throw ArgumentError.value(choice, 'choice', 'not offered here');
    }
    final data = _Look.dataOf(review);
    final g = review.googleName;
    final h = review.graphId;
    Map<String, Object?> answer(ContactAnswerKind kind, {
      String? googleName,
      String? graphId,
      Object? fields,
      Object? value,
    }) => {
      'kind': kind.name,
      'googleName': ?googleName,
      'graphId': ?graphId,
      'fields': ?fields,
      'value': ?value,
    };

    final Map<String, Object?>? queued;
    switch (choice) {
      case ContactSyncChoice.leaveAsTheyAre || ContactSyncChoice.keepNewer:
        await store.dropReviews([lookId]);
        return false;
      case ContactSyncChoice.samePerson:
        final candidates = look.candidates.map((c) => c.id).toList();
        final candidate = candidateId ??
            (candidates.length == 1 ? candidates.single : null);
        if (candidate == null || !candidates.contains(candidate)) {
          throw ArgumentError.value(candidateId, 'candidateId');
        }
        final subjectGoogle = look.side == ContactSide.google;
        queued = answer(
          ContactAnswerKind.samePerson,
          googleName: subjectGoogle ? g : candidate,
          graphId: subjectGoogle ? candidate : h,
        );
      case ContactSyncChoice.copyAnyway:
        // Only the subject: a candidate copied too would be a second copy
        // of the same person when Ron meant this one.
        queued = answer(
          ContactAnswerKind.copyAnyway,
          googleName: look.side == ContactSide.google ? g : null,
          graphId: look.side == ContactSide.graph ? h : null,
        );
      case ContactSyncChoice.leaveOut:
        queued = answer(
          ContactAnswerKind.leaveOut,
          googleName: look.side == ContactSide.google ? g : null,
          graphId: look.side == ContactSide.graph ? h : null,
        );
      case ContactSyncChoice.useGoogle || ContactSyncChoice.useGraph:
        queued = answer(
          choice == ContactSyncChoice.useGoogle
              ? ContactAnswerKind.useGoogle
              : ContactAnswerKind.useGraph,
          googleName: g,
          graphId: h,
          fields: data['fields'],
        );
      case ContactSyncChoice.useOther:
        queued = answer(
          ContactAnswerKind.useValue,
          googleName: g,
          graphId: h,
          value: data['losing'],
        );
      case ContactSyncChoice.copyBack:
        queued = answer(ContactAnswerKind.copyBack, googleName: g, graphId: h);
      case ContactSyncChoice.deleteHereToo:
        queued = answer(
          ContactAnswerKind.deleteHereToo,
          // A merge in Gmail names the Gmail contact it went into, which
          // is not the one to delete.
          googleName: review.kind == ContactReviewKind.mergedInGoogle.name
              ? null
              : g,
          graphId: h,
        );
      case ContactSyncChoice.keepOnlyHere:
        queued = answer(
          ContactAnswerKind.keepOnlyHere,
          googleName: review.kind == ContactReviewKind.mergedInGoogle.name
              ? null
              : g,
          graphId: h,
        );
      case ContactSyncChoice.retry:
        queued = answer(ContactAnswerKind.retry, googleName: g, graphId: h);
      case ContactSyncChoice.deleteThem ||
          ContactSyncChoice.dontDelete ||
          ContactSyncChoice.applyThem ||
          ContactSyncChoice.copyThemBack ||
          ContactSyncChoice.carryOn ||
          ContactSyncChoice.keepWaiting:
        throw ArgumentError.value(choice, 'choice', 'a question\'s answer');
    }
    await store.answerReview(lookId, jsonEncode(queued));
    return true;
  }

  @override
  Future<void> restore(int deletedId) async {
    final entry = await store.askRestore(deletedId);
    if (entry != null) {
      await store.updatePair(entry.pairId, (p) {
        final h = _Held.parse(p.held);
        if (h.restoreProblems.remove(deletedId) == null) return p;
        return p.copyWith(held: h.encode());
      });
    }
    _changed();
    if (entry != null) unawaited(_go(again: true));
  }

  @override
  Future<void> syncHere() async {
    // Only a pair whose first sync was started: the first sync starts
    // from Start alone, after the preview and the backup.
    final pair = await _attachedPair();
    if (pair == null || pair.firstStartedAt == null) return;
    _takeClaim = true;
    _changed();
    unawaited(_go(again: true));
  }

  // --- the preview and the backup --------------------------------------------

  Future<ContactPair> _chosenPair() async {
    final pair = await _attachedPair();
    if (pair == null) {
      throw const ContactSyncRefused(
        'Choose the Gmail and Microsoft accounts to sync first.',
      );
    }
    return pair;
  }

  @override
  Future<ContactSyncPreview> preview() async {
    final pair = await _chosenPair();
    final run = _Run(this, pair, preview: true);
    try {
      final plan = await run.previewPlan();
      final c = plan.counts;
      return ContactSyncPreview(
        googleListed: plan.googleCount,
        graphListed: plan.graphCount,
        addToGoogle: c.addToGoogle,
        addToGraph: c.addToGraph,
        pairUp: c.pairUp,
        needsALook: c.needsALook,
        differingPairs: c.differingPairs,
        duplicateCopies: c.duplicateCopies,
      );
    } catch (e) {
      throw run.readable(e);
    } finally {
      run.close();
    }
  }

  @override
  Future<List<ContactSyncBackupFile>> backup({ContactSide? only}) async {
    final pair = await _chosenPair();
    final run = _Run(this, pair, preview: true);
    try {
      final watch = Stopwatch()..start();
      final google = only == null || only == ContactSide.google
          ? (
              people: (await run.google(
                (a) => a.listAll(everyField: true),
              )).people,
              labels: await run.google((a) => a.labels()),
            )
          : null;
      List<Map<String, Object?>>? contacts;
      if (only == null || only == ContactSide.graph) {
        final folder =
            pair.graphFolderId ?? await run.graph((a) => a.mainFolderId());
        contacts = await run.graph(
          (a) => a.listAll(folderId: folder, whole: true),
        );
      }
      final at = _now();
      debugPrint('[myemail] contacts: backup of '
          '${google?.people.length ?? '-'} + ${contacts?.length ?? '-'} '
          'contacts, ${watch.elapsedMilliseconds} ms');
      return [
        if (google != null)
          ContactSyncBackupFile(
            side: ContactSide.google,
            fileName: ContactBackup.vCardName(at),
            mimeType: ContactBackup.vCardType,
            contents: ContactBackup.vCard(
              google.people,
              labelNames: google.labels,
            ),
            count: google.people.length,
          ),
        if (contacts != null)
          ContactSyncBackupFile(
            side: ContactSide.graph,
            fileName: ContactBackup.csvName(at),
            mimeType: ContactBackup.csvType,
            contents: ContactBackup.outlookCsv(contacts),
            count: contacts.length,
          ),
      ];
    } catch (e) {
      throw run.readable(e);
    } finally {
      run.close();
    }
  }

  // --- this device -----------------------------------------------------------

  /// This device's own id, kept in [store] under
  /// [UiStateKeys.contactSyncDeviceId], made the first time it is asked
  /// for: what the engine is given in the app. Left out of Backup, so a
  /// restored backup never makes a second device the same one.
  static Future<String> deviceIdIn(UiStateStore store) async {
    final known = store.readString(UiStateKeys.contactSyncDeviceId);
    if (known != null && known.isNotEmpty) return known;
    final made = _randomId();
    await store.writeString(UiStateKeys.contactSyncDeviceId, made);
    return made;
  }

  Future<String> _thisDevice() async {
    final known = _device;
    if (known != null) return known;
    final given = _deviceIdOf;
    final id = given == null ? _randomId() : await given();
    return _device = id;
  }

  /// A random id for a device that is given none: one per runner.
  static String _randomId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(16).toRadixString(16),
    ].join();
  }

  String _regionNow() {
    final region = _region()?.toUpperCase();
    if (region != null && ContactNormaliser.isRegion(region)) return region;
    return 'US';
  }

  static String? _phoneRegion() =>
      ui.PlatformDispatcher.instance.locale.countryCode;
}

/// The run was asked to stop: the app was put away.
class _Stopped implements Exception {
  const _Stopped();
}

/// One run, or the preview's reading.
class _Run {
  _Run(this.sync, ContactPair pair, {this.preview = false, this.takeClaim = false})
    : pair = pair,
      pairId = pair.pairId,
      now = sync._now() {
    final googleId = pair.googleAccountId;
    final graphId = pair.graphAccountId;
    _google = GoogleContactsApi(
      accessToken: ({bool force = false}) => sync.accessToken(
        googleId,
        force: force,
        scopes: GoogleOAuth.contactSyncScopes,
      ),
      httpClient: sync._client,
      sleep: sync._sleepFor,
      clock: sync._clock,
    );
    _graph = GraphContactsApi(
      accessToken: ({bool force = false}) => sync.accessToken(
        graphId,
        force: force,
        scopes: MicrosoftOAuth.contactSyncScopes,
      ),
      mailAccessToken: ({bool force = false}) =>
          sync.accessToken(graphId, force: force),
      httpClient: sync._client,
      sleep: sync._sleepFor,
    );
  }

  final ContactSync sync;
  final bool preview;
  final bool takeClaim;
  final int pairId;
  final DateTime now;
  ContactPair pair;

  late final GoogleContactsApi _google;
  late final GraphContactsApi _graph;

  ContactSyncStore get store => sync.store;

  /// The side of the request in hand, for a failure that reaches the top.
  ContactSide? _side;

  Future<T> google<T>(Future<T> Function(GoogleContactsApi api) call) {
    _side = ContactSide.google;
    return call(_google);
  }

  Future<T> graph<T>(Future<T> Function(GraphContactsApi api) call) {
    _side = ContactSide.graph;
    return call(_graph);
  }

  void close() {
    _google.close();
    _graph.close();
  }

  /// The app was put away: the run stops between writes. Not a preview,
  /// which the screen waits for.
  void _checkStop() {
    if (!preview && sync._stopAsked) throw const _Stopped();
  }

  // --- what was read ---------------------------------------------------------

  String? folderId;
  String? _deletedItems;

  final googleRead = <String, Map<String, Object?>>{};
  final googleGone = <String>{};
  final googleReKeys = <String, String>{};
  bool googleComplete = false;
  bool googleFull = false;
  String? googleToken;

  final graphRead = <String, Map<String, Object?>>{};
  final graphGone = <String>{};
  final graphMovedOut = <String>{};
  final graphRemoved = <String>{};
  bool graphComplete = false;
  String? deltaLink;

  late List<ContactLink> links;
  late Map<int, ContactLink> linkById;
  late List<ContactSyncOp> ops;
  late List<ContactBinEntry> bin;
  late List<ContactReview> reviews;
  late _Held held;

  /// The queued answers given to the planner, and where each came from.
  final answers = <ContactAnswer>[];
  final answerSources = <_AnswerSource>[];

  // --- reading ---------------------------------------------------------------

  Future<String> _token(ContactSide side) => sync.accessToken(
    pair.accountIdOn(side),
    scopes: ContactSync._scopesOf(side),
  );

  /// Both address books and what the plan needs read by id, into the
  /// fields above.
  Future<void> read() async {
    final normaliserMoved =
        pair.normaliser != null && pair.normaliser != contactNormaliserVersion;

    // Access first, so a lapsed permission shows as which account.
    for (final side in ContactSide.values) {
      _side = side;
      await _token(side);
    }
    _side = null;

    links = await store.links(pairId);
    linkById = {for (final l in links) l.linkId!: l};
    ops = await store.ops(pairId);
    bin = await store.bin(pairId);
    reviews = await store.reviews(pairId);
    held = _Held.parse(pair.held);
    _answers();

    folderId = pair.graphFolderId ?? await graph((a) => a.mainFolderId());

    if (!preview && folderId != null) await _claim();
    _checkStop();

    await _readGoogle(full: normaliserMoved || preview);
    _checkStop();
    await _readGraph(fresh: normaliserMoved || preview);
    _checkStop();
    await _readMore();
    if (!preview) await _settleRestores();
    _checkStop();
  }

  /// Restores held back this run: a create of theirs whose answer was
  /// lost has not shown yet, and may only be Google's lag. Still planned,
  /// so that what they made is not placed as a new contact meanwhile, but
  /// not carried out.
  final restoreWaiting = <int>{};

  /// A Restore's creates noted but not answered (the run stopped, or the
  /// answer was lost): the contact made is looked for by its tag among
  /// those read, and taken as made; not found, the Restore waits out the
  /// hour Google's listings may lag, then the create counts as not made.
  Future<void> _settleRestores() async {
    if (held.restoring.isEmpty) return;
    final rowGoogle = {for (final l in links) ?l.googleName};
    final rowGraph = {for (final l in links) ?l.graphId};
    final binIds = {for (final b in bin) b.binId};
    final kept = <Map<String, Object?>>[];
    final givenUp = <Map<String, Object?>>[];
    var changed = false;
    for (final note in held.restoring) {
      final binId = note['binId'];
      final side = _sideOf(note['side']);
      if (binId is! int || side == null || !binIds.contains(binId)) {
        // Its bin row has gone (kept past its 30 days): the Restore with it.
        givenUp.add(note);
        changed = true;
        continue;
      }
      if (_Held.madeBy(note) != null) {
        kept.add(note);
        continue;
      }
      final tag = note['tag'];
      String? found;
      if (tag is String) {
        found = side == ContactSide.google
            ? googleRead.entries
                  .firstWhereOrNull(
                    (e) =>
                        !rowGoogle.contains(e.key) && googleTag(e.value) == tag,
                  )
                  ?.key
            : graphRead.entries
                  .firstWhereOrNull(
                    (e) => !rowGraph.contains(e.key) && _tagOf(e.value) == tag,
                  )
                  ?.key;
      }
      if (found != null) {
        kept.add({
          ...note,
          side == ContactSide.google ? 'googleName' : 'graphId': found,
        });
        changed = true;
        continue;
      }
      final at = _time(note['at']);
      if (at != null && now.difference(at) < contactGrace) {
        restoreWaiting.add(binId);
        kept.add(note);
        continue;
      }
      changed = true;
    }
    if (!changed) return;
    held.restoring
      ..clear()
      ..addAll(kept);
    final rows = await store.transaction(() async {
      final saved = await _keepMade(givenUp);
      await store.updatePair(pairId, (p) {
        final h = _Held.parse(p.held);
        h.restoring
          ..clear()
          ..addAll(kept);
        return p.copyWith(held: h.encode());
      });
      return saved;
    });
    if (rows > 0) {
      // The plan is made from the rows as they now are, and from the
      // contacts kept read: a candidate's row holds no details, and one
      // not read would be placed as a contact with none (no name to agree
      // with a tag naming it, no email to match).
      links = await store.links(pairId);
      linkById = {for (final l in links) l.linkId!: l};
      final google = <String>[];
      for (final note in givenUp) {
        final made = _Held.madeBy(note);
        if (made == null) continue;
        if (_sideOf(note['side']) == ContactSide.google) {
          if (!googleRead.containsKey(made)) google.add(made);
        } else if (!graphRead.containsKey(made)) {
          _checkStop();
          await _confirmGraph(made);
        }
      }
      await _confirmGoogle(google);
    }
  }

  /// Contacts a Restore made before it was given up (refused, its bin row
  /// gone, only one side to bring back), each kept as a row held as a
  /// candidate where no row names it yet. A feed that has moved past one
  /// never shows it again, and with no row nothing would read it; a
  /// candidate is read and placed every run (paired, copied or under
  /// Needs a look), and a Restore pressed again finds it, not makes it.
  /// How many rows it saved.
  Future<int> _keepMade(Iterable<Map<String, Object?>> notes) async {
    var saved = 0;
    for (final note in [...notes]) {
      final made = _Held.madeBy(note);
      final side = _sideOf(note['side']);
      if (made == null || side == null) continue;
      if (await store.linkFor(pairId, side, made) != null) continue;
      saved++;
      await store.saveLink(
        ContactLink(
          pairId: pairId,
          googleName: side == ContactSide.google ? made : null,
          graphId: side == ContactSide.graph ? made : null,
          state: ContactLinkState.held,
          reason: ContactHeldReason.candidate,
        ),
      );
    }
    return saved;
  }

  /// The device claim: another device's, younger than a week, stops the
  /// run unless this one was told to take it over.
  ///
  /// A folder that will not give its claim (a refusal, or not found) is
  /// taken as having none: the claim only warns a second device, and must
  /// not stop the one that syncs. A sign-in, a consent or a connection
  /// lost still stops the run, as any request's would.
  Future<void> _claim() async {
    final GraphDeviceClaim? claim;
    try {
      claim = await graph((a) => a.readClaim(folderId!));
    } on ContactRefused catch (e) {
      debugPrint('[myemail] contacts: the device claim was not read '
          '(HTTP ${e.status})');
      return;
    } on ContactGone {
      debugPrint('[myemail] contacts: the device claim was not read '
          '(HTTP 404)');
      return;
    }
    final me = await sync._thisDevice();
    if (takeClaim && claim?.device != me) {
      // Sync here: the claim is this device's from the start of the run,
      // so the other stops at its next run, even if this one does not
      // complete.
      await _writeClaim(now);
      return;
    }
    if (claim == null || claim.device == me) return;
    if (now.difference(claim.at) < ContactSync.claimLasts) {
      throw _OtherDevice(claim.at);
    }
  }

  Future<void> _readGoogle({required bool full}) async {
    final token = pair.googleSyncToken;
    final fullAt = pair.googleFullAt;
    var fullDue =
        full ||
        token == null ||
        pair.googleMask != googleContactFieldsVersion ||
        fullAt == null ||
        now.difference(fullAt) >= ContactSync.fullListingAfter;
    GoogleContactsRead? changes;
    if (!fullDue) {
      try {
        changes = await google((a) => a.listChanges(token));
      } on ContactFeedExpired {
        fullDue = true;
      }
    }
    final GoogleContactsRead read =
        changes ?? await google((a) => a.listAll());
    googleFull = fullDue;
    googleComplete = read.complete;
    googleToken = read.syncToken;
    for (final person in read.people) {
      if (person['resourceName'] case final String name) {
        googleRead[name] = person;
      }
    }
    googleGone.addAll(read.deleted);
  }

  Future<void> _readGraph({required bool fresh}) async {
    final folder = folderId;
    if (folder == null) {
      // No contact in the main folder yet, so no folder to take a delta
      // of: the listing of /me/contacts is the whole of it.
      final all = await graph((a) => a.listAll());
      for (final c in all) {
        if (c['id'] case final String id) graphRead[id] = c;
      }
      graphComplete = true;
      return;
    }
    final link = pair.graphDeltaLink;
    var start =
        fresh || link == null || pair.graphMask != graphContactSelectVersion;
    GraphContactsDelta? changes;
    if (!start) {
      try {
        changes = await graph(
          (a) => a.delta(folderId: folder, deltaLink: link),
        );
      } on ContactFeedExpired {
        start = true;
      }
    }
    final GraphContactsDelta delta;
    if (changes != null) {
      delta = changes;
    } else {
      try {
        delta = await graph((a) => a.delta(folderId: folder));
      } on ContactFeedExpired catch (e) {
        // A fresh delta is started once a run: one refused as well is
        // Microsoft in trouble, not an old link.
        throw ConnectionFailed(
          'Microsoft would not start listing the contacts '
          '(HTTP ${e.status}). Try again shortly.',
        );
      }
    }
    for (final c in delta.contacts) {
      if (c['id'] case final String id) graphRead[id] = c;
    }
    graphRemoved.addAll(delta.removed);
    graphComplete = delta.complete;
    deltaLink = delta.deltaLink;
  }

  /// What the listings left to be read by id.
  Future<void> _readMore() async {
    // Outlook: an entry that lacks a synced property is read whole, and a
    // contact with no row is read with its hidden tag (once per change),
    // as are those passed over last run.
    final rowGraph = {for (final l in links) ?l.graphId};
    final wanted = <String>{
      for (final MapEntry(key: id, value: c) in graphRead.entries)
        if (!GraphContact.fromJson(c).readWhole) id,
      for (final id in held.passedOver)
        if (!graphRemoved.contains(id)) id,
    };
    final tagged = <String>{
      for (final MapEntry(key: id, value: c) in graphRead.entries)
        if (!rowGraph.contains(id) &&
            sync._tags[id]?.changeKey != c['changeKey'])
          id,
    };
    for (final id in {...wanted, ...tagged}) {
      _checkStop();
      await _readGraphId(id, withTag: tagged.contains(id));
    }

    // Gmail: a listing lags behind writes by minutes, so a contact the
    // sync wrote in the last hour, listed with another version than the
    // row's, may be listed as it was before: read again by name, which
    // sees the write. And a contact the sync deleted that a listing still
    // shows is asked about, so it is not copied back as new.
    final binGoogle = {
      for (final b in bin)
        if (b.side == ContactSide.google && b.state != ContactBinState.back)
          b.contactId,
    };
    final again = <String>{
      for (final l in links)
        if (l.googleName case final String name
            when googleRead.containsKey(name) &&
                l.googleWrittenAt != null &&
                now.difference(l.googleWrittenAt!) < contactGrace &&
                googleContactEtag(googleRead[name]!) != l.googleEtag)
          name,
      for (final name in googleRead.keys)
        if (binGoogle.contains(name)) name,
    };
    if (again.isNotEmpty) {
      final r = await google((a) => a.getBatch(again));
      for (final name in again) {
        final person = r.found[name];
        if (person == null) {
          if (r.notFound.contains(name)) googleRead.remove(name);
          continue;
        }
        final now = person['resourceName'];
        if (now is String && now != name) {
          googleRead.remove(name);
          googleReKeys[name] = now;
          googleRead[now] = person;
        } else {
          googleRead[name] = person;
        }
      }
    }
    // Likewise an Outlook contact the sync deleted, should a listing show
    // it: one Ron put back in Contacts is back, and stays.
    for (final b in bin) {
      if (b.side != ContactSide.graph || b.state == ContactBinState.back) {
        continue;
      }
      if (!graphRead.containsKey(b.contactId)) continue;
      _checkStop();
      final c = await graph((a) => a.get(b.contactId));
      if (c == null || !_inContacts(c)) graphRead.remove(b.contactId);
    }

    final inputs = [for (final l in links) _linkInput(l)];
    final confirm = contactsToConfirm(
      google: [
        for (final p in googleRead.values) GoogleContact.fromPerson(p),
      ],
      googleComplete: googleComplete,
      graph: [
        for (final c in graphRead.values) GraphContact.fromJson(c),
      ],
      graphComplete: graphComplete,
      graphRemoved: graphRemoved,
      links: inputs,
      now: now,
    );
    await _confirmGoogle(confirm.google);
    for (final id in confirm.graph) {
      _checkStop();
      await _confirmGraph(id);
    }

    final toRead = contactsToRead(
      links: inputs,
      answers: answers,
      journal: [for (final o in ops) _journalEntry(o)],
      bin: _binInputs(),
    );
    // Among them, both sides of every pair the change brake holds, read at
    // every run for what its question shows: read apart, so that one of
    // those reads failing never stops the run ([_readHeldPairs]).
    final heldGoogle = <String>{};
    final heldGraph = <String>{};
    for (final l in links) {
      if (l.reason != ContactHeldReason.changeBrake) continue;
      if (l.googleName case final name?) heldGoogle.add(name);
      if (l.graphId case final id?) heldGraph.add(id);
    }
    bool unreadGoogle(String name) =>
        !googleRead.containsKey(name) && !googleGone.contains(name);
    bool unreadGraph(String id) =>
        !graphRead.containsKey(id) && !graphGone.contains(id);
    await _confirmGoogle(
      toRead.google.where((n) => !heldGoogle.contains(n) && unreadGoogle(n)),
    );
    for (final id in toRead.graph) {
      if (heldGraph.contains(id) || !unreadGraph(id)) continue;
      _checkStop();
      await _confirmGraph(id);
    }
    await _readHeldPairs(
      [
        for (final n in toRead.google)
          if (heldGoogle.contains(n) && unreadGoogle(n)) n,
      ],
      [
        for (final id in toRead.graph)
          if (heldGraph.contains(id) && unreadGraph(id)) id,
      ],
    );

    // An interrupted Outlook create whose copy no listing showed: looked
    // for by its source's first email, among the contacts that carry tags.
    for (final op in ops) {
      if (op.side != ContactSide.graph) continue;
      if (graphRead.values.any(
        (c) => _tagOf(c) == op.tag || _tagOf(c) == op.sourceKey,
      )) {
        continue;
      }
      final source = googleRead[op.sourceKey];
      final email = source == null
          ? null
          : syncedFromPerson(source).list(ContactField.emails).firstOrNull;
      if (email == null) continue;
      _checkStop();
      for (final c in await graph((a) => a.findByEmail(email))) {
        final id = c['id'];
        if (id is! String || !_inContacts(c)) continue;
        graphRead[id] = c;
        sync._tags[id] = (
          changeKey: c['changeKey'] as String?,
          tag: GraphContactsApi.tagOf(c),
        );
      }
    }
  }

  String? _tagOf(Map<String, Object?> c) {
    final id = c['id'];
    return GraphContactsApi.tagOf(c) ??
        (id is String ? sync._tags[id]?.tag : null);
  }

  bool _inContacts(Map<String, Object?> c) {
    final folder = c['parentFolderId'];
    return folderId == null || folder == null || folder == folderId;
  }

  /// Gmail contacts asked about by name: there (perhaps re-keyed), or gone.
  Future<void> _confirmGoogle(Iterable<String> names) async {
    final asked = names.toSet();
    if (asked.isEmpty) return;
    _checkStop();
    final r = await google((a) => a.getBatch(asked));
    for (final MapEntry(key: name, value: person) in r.found.entries) {
      _placeGoogle(name, person);
    }
    googleGone.addAll(r.notFound);
  }

  /// A Gmail contact read alone by name: there (perhaps re-keyed), or gone.
  Future<void> _readGoogleAlone(String name) async {
    final person = await google((a) => a.get(name));
    if (person == null) {
      googleGone.add(name);
      return;
    }
    _placeGoogle(name, person);
  }

  /// [person], read by [name]: under the name Google gives it now.
  void _placeGoogle(String name, Map<String, Object?> person) {
    final now = person['resourceName'];
    if (now is String && now != name) {
      googleReKeys[name] = now;
      googleRead[now] = person;
    } else {
      googleRead[name] = person;
    }
  }

  /// An Outlook contact asked about by id: there, gone (not found, or in
  /// Deleted Items, where Outlook's own delete puts it), or moved to
  /// another folder.
  Future<void> _confirmGraph(String id) async {
    final c = await graph((a) => a.get(id));
    if (c == null) {
      graphRead.remove(id);
      graphGone.add(id);
      return;
    }
    await _placeGraph(id, c);
  }

  /// Why the answer given to [item], a held change, waits: its Outlook
  /// contact is out of Contacts, or a contact of its pair was not read
  /// this run. Null when both were read.
  String? _waitsOn(Map<String, Object?> item) {
    final g = item['googleName'];
    final h = item['graphId'];
    if (h is String && graphMovedOut.contains(h)) return 'movedOut';
    if ((g is String && !googleRead.containsKey(g)) ||
        (h is String && !graphRead.containsKey(h))) {
      return 'unread';
    }
    return null;
  }

  /// [c], the Outlook contact [id] as read by id: in Contacts, read; in
  /// Deleted Items, gone; elsewhere, moved out.
  Future<void> _placeGraph(String id, Map<String, Object?> c) async {
    if (_inContacts(c)) {
      graphRead[id] = c;
      return;
    }
    graphRead.remove(id);
    _deletedItems ??= await graph((a) => a.deletedItemsFolderId());
    if (c['parentFolderId'] == _deletedItems) {
      graphGone.add(id);
    } else {
      graphMovedOut.add(id);
    }
  }

  /// The contacts of the pairs the change brake holds, Gmail's [names] and
  /// Hadco's [ids], read by id at every run for what its question shows
  /// ([ContactSyncPlan.heldBrakes]): reads that never stop a run. One
  /// that fails leaves its contacts unread, so the plan leaves their item
  /// out and it stays as it was: held, with the details it showed, and any
  /// answer given to it waiting for a run that reads them (the item says
  /// so: [_Held.waits]). Gmail's go in one request (Google's batch read),
  /// Hadco's [GraphContactsApi.batchLimit] to a `$batch`, each batch
  /// failing on its own; a batch refused as a whole (one bad name spoils
  /// Google's for all) is read again a contact at a time, each failing on
  /// its own. A failure every request would meet (a sign-in, Google's
  /// daily quota) is the run's as anywhere, and so is a stop.
  Future<void> _readHeldPairs(List<String> names, List<String> ids) async {
    var unread = 0;
    var alone = 0;
    Future<void> eachAlone(
      List<String> asking,
      Future<void> Function(String) read,
    ) async {
      alone += asking.length;
      for (final id in asking) {
        _checkStop();
        try {
          await read(id);
        } on Exception catch (e) {
          if (!_failsAlone(e)) rethrow;
          unread++;
        }
      }
    }

    if (names.isNotEmpty) {
      try {
        await _confirmGoogle(names);
      } on ContactRefused {
        await eachAlone(names, _readGoogleAlone);
      } on Exception catch (e) {
        if (!_failsAlone(e)) rethrow;
        unread += names.length;
      }
    }
    const most = GraphContactsApi.batchLimit;
    for (var start = 0; start < ids.length; start += most) {
      final asking = ids.sublist(start, min(start + most, ids.length));
      _checkStop();
      try {
        final r = await graph((a) => a.getBatch(asking));
        for (final id in r.notFound) {
          graphRead.remove(id);
          graphGone.add(id);
        }
        for (final MapEntry(key: id, value: c) in r.found.entries) {
          await _placeGraph(id, c);
        }
        unread += r.unknown.length;
      } on ContactRefused {
        await eachAlone(asking, _confirmGraph);
      } on Exception catch (e) {
        if (!_failsAlone(e)) rethrow;
        unread += asking.length;
      }
    }
    if (alone > 0) {
      debugPrint('[myemail] contacts: a batch read refused, $alone held '
          'contacts read one at a time');
    }
    if (unread > 0) {
      debugPrint('[myemail] contacts: $unread contacts of held changes not '
          'read this run');
    }
  }

  /// A failure of the one request, which the run outlives: no connection,
  /// a server in trouble or throttling, a refusal of what was asked.
  static bool _failsAlone(Exception e) =>
      e is ConnectionFailed || e is ContactRefused || e is ContactGone;

  /// An Outlook contact read whole by id, with its tag where asked.
  Future<void> _readGraphId(String id, {required bool withTag}) async {
    final c = await graph((a) => a.get(id, withTag: withTag));
    if (c == null || !_inContacts(c)) {
      // Gone or moved since the listing: left to the next listing, which
      // says so.
      graphRead.remove(id);
      return;
    }
    graphRead[id] = c;
    if (withTag) {
      sync._tags[id] = (
        changeKey: c['changeKey'] as String?,
        tag: GraphContactsApi.tagOf(c),
      );
    }
  }

  // --- the planner's inputs --------------------------------------------------

  static Map<String, Object?>? _decode(String? json) {
    if (json == null) return null;
    try {
      final v = jsonDecode(json);
      return v is Map ? v.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  static String? _encode(SyncedContact? details) =>
      details == null ? null : jsonEncode(details.toJson());

  ContactLinkInput _linkInput(ContactLink l) => ContactLinkInput(
    linkId: l.linkId!,
    googleName: l.googleName,
    graphId: l.graphId,
    googleEtag: l.googleEtag,
    graphChangeKey: l.graphChangeKey,
    googleBase: _decode(l.googleBase),
    graphBase: _decode(l.graphBase),
    state: l.state,
    reason: l.reason,
    googleWrittenAt: l.googleWrittenAt,
    partnerId: l.partnerId,
    partnerBase: _decode(l.partnerBase),
  );

  ContactJournalEntry _journalEntry(ContactSyncOp op) => ContactJournalEntry(
    opId: op.opId,
    side: op.side,
    sourceId: op.sourceKey,
    startedAt: op.startedAt,
    tag: op.tag,
  );

  /// The bin as the planner reads it. Not the rows Ron brought back
  /// himself: the planner takes every id in its bin input for the sync's
  /// own deletion, and would ignore Ron deleting such a contact again.
  ///
  /// A Restore part made has the contacts it made in place of those the
  /// row names (see [_Held.restoring]), so the planner finds them back by
  /// id rather than make them again.
  List<ContactBinInput> _binInputs() => [
    for (final b in bin)
      if (b.binId != null && b.state != ContactBinState.back) _binInput(b),
  ];

  ContactBinInput _binInput(ContactBinEntry b) {
    var contactId = b.contactId;
    var partnerId = b.partnerId;
    for (final note in held.restoring) {
      if (note['binId'] != b.binId) continue;
      final made = _Held.madeBy(note);
      if (made == null) continue;
      if (_sideOf(note['side']) == b.side) {
        contactId = made;
      } else {
        partnerId = made;
      }
    }
    return ContactBinInput(
      binId: b.binId!,
      side: b.side,
      contactId: contactId,
      partnerId: partnerId,
      done: b.state == ContactBinState.done,
      raw: _decode(b.raw),
      partnerBase: _decode(b.partnerBase),
      title: b.title,
      restore: b.restore,
    );
  }

  /// Every answer queued: on Needs a look items, on the brakes' questions,
  /// and those planned by a run that stopped before it finished.
  void _answers() {
    void add(Map<String, Object?>? json, _AnswerSource source) {
      final answer = _answerOf(json);
      if (answer == null) return;
      answers.add(answer);
      answerSources.add(source);
    }

    for (final r in reviews) {
      if (r.answer == null || r.reviewId == null) continue;
      add(_decode(r.answer), _AnswerSource.review(r.reviewId!));
    }
    for (final (i, a) in held.pending.indexed) {
      add(a, _AnswerSource.pending(i));
    }
    for (final q in held.questions) {
      if (q.kind == ContactSyncQuestionKind.emptyAnswer) {
        if (q.answer == ContactSyncChoice.carryOn) {
          answers.add(ContactAnswer(ContactAnswerKind.carryOn, side: q.side));
          answerSources.add(
            _AnswerSource.question(q.id, q.answer!, const {}, whole: true),
          );
        }
        continue;
      }
      // Each choice given, the whole question's or an item's own, acts
      // only on the contacts it was given for: never a sweep of every
      // row the brake holds (held is never null), nor of the items
      // answered otherwise, nor of a later brake's, held under a question
      // of its own.
      final byChoice = <ContactSyncChoice, List<Map<String, Object?>>>{};
      final wholeFor = <ContactSyncChoice>{};
      for (final item in q.items) {
        final own = _Question.answerOf(item);
        final choice = own ?? q.answer;
        if (choice == null) continue;
        if (own == null) wholeFor.add(choice);
        byChoice.putIfAbsent(choice, () => []).add(item);
      }
      for (final MapEntry(key: choice, value: items) in byChoice.entries) {
        final kind = switch (choice) {
          ContactSyncChoice.deleteThem => ContactAnswerKind.deleteHeld,
          ContactSyncChoice.dontDelete => ContactAnswerKind.keepHeld,
          ContactSyncChoice.applyThem => ContactAnswerKind.applyHeld,
          ContactSyncChoice.copyThemBack => ContactAnswerKind.copyHeldBack,
          _ => null,
        };
        if (kind == null) continue;
        answers.add(
          ContactAnswer(
            kind,
            held: [for (final i in items) ?ContactBrakeItem.fromJson(i)],
          ),
        );
        answerSources.add(
          _AnswerSource.question(
            q.id,
            choice,
            {for (final i in items) _Question.keyOf(i)},
            whole: wholeFor.contains(choice),
          ),
        );
      }
    }
  }

  /// A merge's Use Hadco's answer ([_CopiesStep._write]) is the merge's
  /// on the Gmail contact as it was when the write was made (its
  /// `googleEtag`). Should Gmail have changed since (Ron edited it while
  /// the answer waited), the answer is dropped, from the pair too: the
  /// usual rules then decide between his edit and the merge's, the newer
  /// winning and the other listed, never his edit written over unasked.
  void _dropStale() {
    for (var i = answers.length - 1; i >= 0; i--) {
      final at = answerSources[i].pendingIndex;
      if (at == null || at >= held.pending.length) continue;
      final etag = held.pending[at]['googleEtag'];
      final name = answers[i].googleName;
      if (etag is! String || name == null) continue;
      final person = googleRead[googleReKeys[name] ?? name];
      if (person == null || googleContactEtag(person) == etag) continue;
      answers.removeAt(i);
      answerSources.removeAt(i);
      debugPrint('[myemail] contacts: a merge answer dropped, Gmail changed '
          'since');
    }
  }

  static ContactAnswer? _answerOf(Map<String, Object?>? json) {
    if (json == null) return null;
    final kind = ContactAnswerKind.values.firstWhereOrNull(
      (k) => k.name == json['kind'],
    );
    if (kind == null) return null;
    final fields = json['fields'];
    final value = json['value'];
    return ContactAnswer(
      kind,
      googleName: json['googleName'] as String?,
      graphId: json['graphId'] as String?,
      fields: {
        if (fields is List)
          for (final f in fields)
            if (f is String) ?ContactField.byName(f),
      },
      value: value is Map ? value.cast<String, Object?>() : null,
    );
  }

  ContactSyncInput input() => ContactSyncInput(
    google: [
      for (final p in googleRead.values) GoogleContact.fromPerson(p),
    ],
    graph: [
      for (final c in graphRead.values) _graphContact(c),
    ],
    googleComplete: googleComplete,
    graphComplete: graphComplete,
    links: [for (final l in links) _linkInput(l)],
    firstSync: pair.firstDoneAt == null,
    googleGone: googleGone,
    graphGone: graphGone,
    graphMovedOut: graphMovedOut,
    googleReKeys: googleReKeys,
    journal: [for (final o in ops) _journalEntry(o)],
    bin: _binInputs(),
    answers: answers,
    expectedGoogle: pair.googleCount,
    expectedGraph: pair.graphCount,
    phoneRegion: pair.phoneRegion ?? sync._regionNow(),
    now: now,
  );

  /// An Outlook contact as read, with the tag the last read of it by id
  /// found where this read did not ask for it.
  GraphContact _graphContact(Map<String, Object?> json) {
    final c = GraphContact.fromJson(json);
    if (c.tag != null) return c;
    final cached = sync._tags[c.id];
    if (cached == null ||
        cached.tag == null ||
        cached.changeKey != c.changeKey) {
      return c;
    }
    return GraphContact(
      id: c.id,
      details: c.details,
      changeKey: c.changeKey,
      updatedAt: c.updatedAt,
      folderId: c.folderId,
      tag: cached.tag,
      json: c.json,
      removed: c.removed,
      missing: c.missing,
    );
  }

  // --- the preview -----------------------------------------------------------

  Future<ContactSyncPlan> previewPlan() async {
    await read();
    final input = this.input();
    final plan = planContactSync(
      ContactSyncInput(
        google: input.google,
        graph: input.graph,
        googleComplete: input.googleComplete,
        graphComplete: input.graphComplete,
        links: input.links,
        firstSync: true,
        googleGone: input.googleGone,
        graphGone: input.graphGone,
        graphMovedOut: input.graphMovedOut,
        googleReKeys: input.googleReKeys,
        journal: input.journal,
        bin: input.bin,
        expectedGoogle: input.expectedGoogle,
        expectedGraph: input.expectedGraph,
        phoneRegion: input.phoneRegion,
        now: input.now,
      ),
    );
    _logShape(input, plan);
    return plan;
  }

  // --- the run ---------------------------------------------------------------

  late ContactNormaliser norm;
  late ContactSyncPlan plan;
  final tally = _Tally();
  final watch = Stopwatch();

  /// The contacts copied to the other side this run, by their source.
  final copiedFrom = <(ContactSide, String)>{};

  /// Contacts made and deleted this run, per side, for the counts.
  var googleMade = 0;
  var graphMade = 0;
  var googleDeleted = 0;
  var graphDeleted = 0;

  /// Reviews saved this run, by what names them, so a pair planned again
  /// can replace its own.
  final savedReviews = <(String, String?, String?), int>{};

  /// The answers kept on the pair for their writes ([_saveFirst]), by the
  /// plan whose writes carry each out, and for each answer ([_Held.writing])
  /// those of its plans whose results are not saved yet.
  final _answersOf = Map<ContactLinkPlan, Set<int>>.identity();
  final _writesLeft = <int, Set<ContactLinkPlan>>{};

  /// True when the run completed.
  Future<bool> go() async {
    watch.start();
    try {
      pair = await store.updatePair(
            pairId,
            (p) => p.copyWith(lastAttemptAt: now),
          ) ??
          pair;
      await store.pruneBin(pairId);
      await store.dropDetached();
      final quota = _Held.parse(pair.held).quotaUntil;
      if (quota != null && now.isBefore(quota)) {
        throw ContactQuotaSpent(quota);
      }
      sync._progressTo(
        ContactSyncProgress(
          step: ContactSyncStep.reading,
          firstSync: pair.firstDoneAt == null,
        ),
      );
      await read();
      _dropStale();
      norm = ContactNormaliser(
        region: pair.phoneRegion ?? sync._regionNow(),
      );
      final planned = input();
      plan = planContactSync(planned);
      _logShape(planned, plan);
      if (plan.stop case final stop?) {
        await _emptyAnswer(stop);
        return false;
      }
      tally
        ..firstSync = pair.firstDoneAt == null
        ..passedOver = plan.counts.passedOver
        ..paired = plan.counts.pairUp
        ..heldDeletions = plan.counts.heldDeletions
        ..heldChanges = plan.counts.heldChanges;
      await _saveFirst();
      await _write();
      // The sync's own end is recorded before the merge of Hadco's copies,
      // which can take minutes: a merge cut short (MyEmail put away, a
      // sign-in) leaves the feeds' positions, the counts and the answers
      // carried out as they are, not read and planned again next time.
      await _finish();
      await _copies();
      await _countCopies();
      return true;
    } catch (e) {
      await _halted(e);
      return false;
    } finally {
      close();
    }
  }

  // --- the rows that need no write -------------------------------------------

  /// One transaction, in this order: the rows the plan removes; the rows
  /// that need no write, in plan order (a merge's losers before its
  /// winner); the items of answers planned and of contacts gone; the
  /// plan's re-keys; then new Needs a look items, the brakes' questions,
  /// the journal entries settled and the bin rows found back. Answered
  /// items go before the re-key, which folds two items that come to name
  /// one contact into the older, taking a queued answer along: one dropped
  /// after it would leave its answer on the other, done again next run.
  /// Rows with writes are saved as each write comes back.
  Future<void> _saveFirst() async {
    final reKeys = plan.reKeys;
    final noWrite = [
      for (final p in plan.links)
        if (!p.writes) p,
    ];
    final outcomes = plan.answers;

    // Answers planned: their items go, and each answer whose plan writes
    // is kept on the pair, marked, until those writes come back
    // ([_carriedOut]): a run stopped before them plans it again, and one
    // stopped after them does not, for planned again it would write the
    // side Ron chose over an edit he made since. Its plans are those that
    // write a contact it names. One with nothing to write is carried out
    // by this transaction, and not kept.
    final pending = <Map<String, Object?>>[];
    final dropReviews = <int>{};
    final writing = [
      for (final p in plan.links)
        if (p.writes) p,
    ];
    void keep(Map<String, Object?> answer) {
      final g = answer['googleName'];
      final h = answer['graphId'];
      final name = g is String ? plan.reKeys[g] ?? g : null;
      final by = [
        for (final p in writing)
          if ((name != null && p.googleName == name) ||
              (h is String && p.graphId == h))
            p,
      ];
      if (by.isEmpty) return;
      final mark = _writesLeft.length;
      _writesLeft[mark] = Set.identity()..addAll(by);
      for (final p in by) {
        (_answersOf[p] ??= {}).add(mark);
      }
      pending.add({...answer, _Held.writing: mark});
    }

    for (final (i, source) in answerSources.indexed) {
      final outcome = i < outcomes.length ? outcomes[i] : null;
      if (outcome == null) continue;
      if (source.reviewId case final id?) {
        if (outcome == ContactAnswerOutcome.waiting) continue;
        dropReviews.add(id);
        if (outcome == ContactAnswerOutcome.applied) {
          final r = reviews.firstWhereOrNull((r) => r.reviewId == id);
          if (_decode(r?.answer) case final answer?) keep(answer);
        }
      }
      if (source.pendingIndex case final at? when at < held.pending.length) {
        final answer = held.pending[at];
        switch (outcome) {
          case ContactAnswerOutcome.applied:
            keep(answer);
          case ContactAnswerOutcome.waiting:
            // Kept for a run that reads its contacts, with no mark: a mark
            // is the run's that made it.
            pending.add({...answer}..remove(_Held.writing));
          case ContactAnswerOutcome.dropped:
            break;
        }
      }
    }
    // Items about contacts gone this run go too, and those of rows a merge
    // in Gmail folded away, which the re-key would move onto the merged
    // contact.
    for (final r in reviews) {
      if ((r.googleName != null && plan.googleGone.contains(r.googleName)) ||
          (r.graphId != null && plan.graphGone.contains(r.graphId))) {
        dropReviews.add(r.reviewId!);
      }
      for (final away in plan.mergedAway) {
        if (r.googleName == away.googleName &&
            (away.graphId == null || r.graphId == away.graphId)) {
          dropReviews.add(r.reviewId!);
        }
      }
    }

    await store.transaction(() async {
      final remove = <int>{
        for (final p in noWrite) ...p.alsoRemove,
        for (final p in noWrite)
          if (p.linkId != null &&
              (p.removeRow || (p.googleName == null && p.graphId == null)))
            p.linkId!,
      };
      await store.deleteLinks(remove);
      for (final p in noWrite) {
        if (p.removeRow || (p.googleName == null && p.graphId == null)) {
          continue;
        }
        await store.saveLink(_linkOf(p));
      }

      await store.dropReviews(dropReviews);
      // Kept with their ids where the re-key below reaches them.
      await store.updatePair(pairId, (p) {
        final h = _Held.parse(p.held);
        h.pending
          ..clear()
          ..addAll(pending);
        return p.copyWith(held: h.encode());
      });

      await store.dropOps(plan.journalSettled);
      for (final MapEntry(key: old, value: name) in reKeys.entries) {
        // Two creates in flight whose sources Ron then merged: the store
        // will not leave two copying one contact, so the merged-away
        // source's goes, and its copy, if made, is found by its tag.
        final copying = await store.ops(pairId);
        bool copies(String id) => copying.any(
          (o) => o.side == ContactSide.graph && o.sourceKey == id,
        );
        if (copies(old) && copies(name)) {
          await store.dropOps([
            for (final o in copying)
              if (o.side == ContactSide.graph && o.sourceKey == old) o.opId,
          ]);
        }
        await store.rekey(pairId, ContactSide.google, old, name);
      }

      for (final item in plan.reviews) {
        await _saveReview(item);
      }
      await store.dropBin(plan.binToDrop);
      for (final id in plan.binToMarkBack) {
        await store.markBinBack(id);
      }
      // The brakes' questions (new items added, every item's details as
      // this run read them), and the copies of one person as this plan
      // groups them: with the rows that hold them, so the screen lists
      // them from what this device keeps, after a restart too. Held
      // copies are not deletions and raise no question (the planner keeps
      // them out of the brakes); only their groups are kept here.
      await store.updatePair(pairId, (p) {
        final h = _Held.parse(p.held);
        for (final brake in plan.brakes) {
          h.raise(brake, now);
        }
        h.refresh(plan.heldBrakes);
        h.duplicates
          ..clear()
          ..addAll(plan.duplicates.map(_Duplicates.of));
        return p.copyWith(held: h.encode());
      });
    });
    final rekeyed = reKeys.length;
    if (rekeyed > 0) debugPrint('[myemail] contacts: $rekeyed Gmail re-keys');
  }

  /// The answers kept on the pair for [p]'s writes ([_saveFirst]) are
  /// done once [p]'s result is saved: taken off the pair in the same
  /// transaction, so that a run stopped later never plans them again. One
  /// that waits on another plan's writes as well stays until those are
  /// saved too.
  Future<void> _carriedOut(ContactLinkPlan p) async {
    final marks = _answersOf.remove(p);
    if (marks == null) return;
    final done = {
      for (final mark in marks)
        if ((_writesLeft[mark]?..remove(p))?.isEmpty ?? false) mark,
    };
    if (done.isEmpty) return;
    await store.updatePair(pairId, (pair) {
      final h = _Held.parse(pair.held);
      h.pending.removeWhere((a) => done.contains(a[_Held.writing]));
      return pair.copyWith(held: h.encode());
    });
  }

  /// [item] saved, replacing one of the same kind about the same contacts.
  Future<void> _saveReview(ContactReviewItem item) async {
    final kind = _Look.kindOf(item);
    final saved = await store.saveReview(
      ContactReview(
        pairId: pairId,
        kind: kind,
        googleName: item.googleName,
        graphId: item.graphId,
        data: jsonEncode(item.toJson()),
      ),
    );
    savedReviews[(kind, item.googleName, item.graphId)] = saved.reviewId!;
    tally.needsALook++;
  }

  ContactLink _linkOf(
    ContactLinkPlan p, {
    SyncedContact? googleBase,
    SyncedContact? graphBase,
    String? googleEtag,
    String? graphChangeKey,
    bool googleWritten = false,
  }) {
    final stored = p.linkId == null ? null : linkById[p.linkId];
    final paired = p.state == ContactLinkState.paired;
    return ContactLink(
      linkId: p.linkId,
      pairId: pairId,
      googleName: p.googleName,
      graphId: p.graphId,
      googleEtag: googleEtag ?? p.googleEtag,
      graphChangeKey: graphChangeKey ?? p.graphChangeKey,
      googleBase: _encode(googleBase ?? p.googleBase),
      graphBase: _encode(graphBase ?? p.graphBase),
      state: p.state,
      reason: paired ? null : p.reason,
      googleWrittenAt: googleWritten ? now : stored?.googleWrittenAt,
      // A row held with one id after its partner went keeps that partner,
      // so a delete of its contact after all can bin both for Restore.
      partnerId: paired ? null : p.partnerId,
      partnerBase: paired ? null : _encode(p.partnerBase),
    );
  }

  // --- writes ----------------------------------------------------------------

  int _total = 0;
  int _done = 0;

  void _stepDone() {
    _done++;
    tally.done = _done;
    sync._progressTo(
      ContactSyncProgress(
        step: ContactSyncStep.writing,
        done: _done,
        total: _total,
        firstSync: tally.firstSync,
      ),
    );
  }

  Future<void> _write() async {
    final restores = [
      for (final r in plan.restores)
        if (!r.alreadyBack) r,
    ];
    final creates = [
      for (final p in plan.links)
        if (p.create != null) p,
    ];
    final updates = [
      for (final p in plan.links)
        if (p.create == null &&
            p.delete == null &&
            (p.googleWrite != null || p.graphWrite != null))
          p,
    ];
    final deletes = [
      for (final p in plan.links)
        if (p.delete != null) p,
    ];
    _total =
        restores.length +
        creates.length +
        updates.length +
        deletes.length +
        plan.graphTagMoves.length +
        plan.binNotDue.length;
    tally.planned = _total;
    sync._progressTo(
      ContactSyncProgress(
        step: ContactSyncStep.writing,
        total: _total,
        firstSync: tally.firstSync,
      ),
    );

    Set<String>? labels;
    for (final r in restores) {
      _checkStop();
      if (r.googleRaw != null) {
        labels ??= (await google((a) => a.labels())).keys.toSet();
      }
      await _restore(r, labels ?? const {});
      _stepDone();
    }
    await _creates(
      [
        for (final p in creates)
          if (p.create!.side == ContactSide.google) p,
      ],
      ContactSide.google,
    );
    await _creates(
      [
        for (final p in creates)
          if (p.create!.side == ContactSide.graph) p,
      ],
      ContactSide.graph,
    );
    for (final p in updates) {
      _checkStop();
      await _update(p);
      _stepDone();
    }
    for (final p in deletes) {
      _checkStop();
      await _delete(p);
      _stepDone();
    }
    for (final MapEntry(key: id, value: name) in plan.graphTagMoves.entries) {
      _checkStop();
      await _moveTag(id, name);
      _stepDone();
    }
    for (final binId in plan.binNotDue) {
      _checkStop();
      await _notDue(binId);
      _stepDone();
    }
  }

  // Creates.

  /// The creates on [side], journalled before they are sent. In the first
  /// sync many go together; otherwise, and for a small remainder, one at a
  /// time.
  Future<void> _creates(List<ContactLinkPlan> creates, ContactSide side) async {
    if (creates.isEmpty) return;
    final first = tally.firstSync;
    final size = side == ContactSide.google
        ? GoogleContactsApi.batchLimit
        : GraphContactsApi.batchLimit;
    final floor = side == ContactSide.google
        ? ContactSync.googleBatchFloor
        : ContactSync.graphBatchFloor;
    var at = 0;
    while (at < creates.length) {
      _checkStop();
      final left = creates.length - at;
      final take = left < size ? left : size;
      if (first && take >= floor) {
        await _createBatch(creates.sublist(at, at + take), side);
        at += take;
      } else {
        await _createOne(creates[at]);
        at++;
      }
    }
  }

  Future<void> _createOne(ContactLinkPlan p) async {
    final create = p.create!;
    final op = (await store.journalCreates(pairId, create.side, [
      (sourceKey: create.sourceId, tag: create.tag),
    ])).single;
    try {
      final made = create.side == ContactSide.google
          ? await google((a) => a.create(create.body, tag: create.tag))
          : await graph((a) => a.create(create.body, tag: create.tag));
      await _created(p, op, made);
    } on ContactRefused {
      await _refusedCreate(p, op);
    } on Exception catch (e) {
      if (_notMade(e)) await store.dropOps([op.opId]);
      rethrow;
    }
    _stepDone();
  }

  /// Failures that say the contact was not made, so its journal entry can
  /// go; any other leaves it for its tag to settle.
  static bool _notMade(Object e) =>
      e is SignInNeedsConsent ||
      e is AuthenticationFailed ||
      e is ContactQuotaSpent ||
      e is ContactsSwitchedOff ||
      e is ContactRefused ||
      e is ContactBatchRefused;

  Future<void> _createBatch(
    List<ContactLinkPlan> plans,
    ContactSide side,
  ) async {
    final journalled = await store.journalCreates(pairId, side, [
      for (final p in plans) (sourceKey: p.create!.sourceId, tag: p.create!.tag),
    ]);
    final List<ContactCreateAnswer> made;
    if (side == ContactSide.google) {
      made = await google(
        (a) => a.createBatch([
          for (final p in plans) (person: p.create!.body, tag: p.create!.tag),
        ]),
      );
    } else {
      made = await graph(
        (a) => a.createBatch([
          for (final p in plans) (contact: p.create!.body, tag: p.create!.tag),
        ]),
      );
    }
    Exception? stop;
    final alone = <ContactLinkPlan>[];
    for (final (i, p) in plans.indexed) {
      final op = journalled[i];
      final answer = made[i];
      final contact = answer.contact;
      if (contact != null) {
        await _created(p, op, contact);
        _stepDone();
        continue;
      }
      final failure = answer.failure;
      switch (failure) {
        case ContactBatchRefused():
          // The whole batch, and none made: each is sent alone, which
          // finds the one it would not take.
          await store.dropOps([op.opId]);
          alone.add(p);
        case ContactRefused():
          await _refusedCreate(p, op);
          _stepDone();
        case final Exception e:
          if (_notMade(e)) await store.dropOps([op.opId]);
          stop ??= e;
        case null:
          stop ??= const ConnectionFailed('A contact was not answered for.');
      }
    }
    // A sign-in, a quota or a connection lost stops the run once what was
    // made is saved; contacts whose fate is not known are left journalled.
    if (stop != null) throw stop;
    for (final p in alone) {
      _checkStop();
      await _createOne(p);
    }
  }

  /// A create landed: its row saved, its journal entry cleared and the
  /// answers it carries out done with, in one.
  Future<void> _created(
    ContactLinkPlan p,
    ContactSyncOp op,
    Map<String, Object?> made,
  ) async {
    final create = p.create!;
    final onGoogle = create.side == ContactSide.google;
    final details = onGoogle ? syncedFromPerson(made) : syncedFromGraph(made);
    final id = (onGoogle ? made['resourceName'] : made['id']) as String?;
    if (id == null) {
      throw const ConnectionFailed('A contact was made without an id.');
    }
    final bases = p.basesAfter(created: details);
    final link = ContactLink(
      linkId: p.linkId,
      pairId: pairId,
      googleName: onGoogle ? id : p.googleName,
      graphId: onGoogle ? p.graphId : id,
      googleEtag: onGoogle ? googleContactEtag(made) : p.googleEtag,
      graphChangeKey: onGoogle ? p.graphChangeKey : made['changeKey'] as String?,
      googleBase: _encode(bases.google),
      graphBase: _encode(bases.graph),
      state: ContactLinkState.paired,
      googleWrittenAt: onGoogle
          ? now
          : (p.linkId == null ? null : linkById[p.linkId]?.googleWrittenAt),
    );
    await store.transaction(() async {
      await store.completeCreates({op.opId: link});
      await _carriedOut(p);
    });
    copiedFrom.add((create.side.other, create.sourceId));
    if (onGoogle) {
      googleMade++;
      tally.addedToGoogle++;
    } else {
      graphMade++;
      tally.addedToGraph++;
      if (!_tagsKnown(id)) {
        sync._tags[id] = (
          changeKey: made['changeKey'] as String?,
          tag: create.tag,
        );
      }
      // The first contact made in an empty mailbox names the folder.
      if (folderId == null && made['parentFolderId'] is String) {
        folderId = made['parentFolderId'] as String;
        await store.updatePair(
          pairId,
          (p) => p.copyWith(graphFolderId: p.graphFolderId ?? folderId),
        );
      }
    }
  }

  bool _tagsKnown(String id) => sync._tags.containsKey(id);

  /// A server would not take the new contact: its source is held as
  /// refused, under Needs a look, and the run carries on.
  Future<void> _refusedCreate(ContactLinkPlan p, ContactSyncOp op) async {
    final create = p.create!;
    final sourceGoogle = create.side == ContactSide.graph;
    final held = ContactLinkPlan(
      linkId: p.linkId,
      googleName: sourceGoogle ? create.sourceId : null,
      graphId: sourceGoogle ? null : create.sourceId,
      state: ContactLinkState.held,
      reason: ContactHeldReason.refused,
      googleEtag: sourceGoogle ? p.googleEtag : null,
      graphChangeKey: sourceGoogle ? null : p.graphChangeKey,
      googleBase: sourceGoogle ? p.googleBase : null,
      graphBase: sourceGoogle ? null : p.graphBase,
      title: p.title,
    );
    await store.transaction(() async {
      await store.dropOps([op.opId]);
      await store.saveLink(_linkOf(held));
      await _saveReview(
        ContactReviewItem(
          kind: ContactReviewKind.refused,
          subjectSide: create.side,
          googleName: held.googleName,
          graphId: held.graphId,
          title: p.title,
        ),
      );
      await _carriedOut(p);
    });
    tally.refused++;
    debugPrint('[myemail] contacts: a new contact was refused by '
        '${create.side == ContactSide.google ? 'Google' : 'Microsoft'}');
  }

  // Changes to pairs.

  /// A pair's writes, Outlook's first: each side read just before it is
  /// written. A version moved since the plan read it means that side is
  /// read again and the pair planned again with the run's settings, told
  /// of a write already made to the other side; once, then the rest waits
  /// for the next run, which reads the change.
  Future<void> _update(ContactLinkPlan planned) async {
    var p = planned;
    Map<String, Object?>? gAnswer;
    Map<String, Object?>? hAnswer;
    var googleWritten = false;
    var graphWritten = false;
    String? googleName = p.googleName;
    for (var attempt = 0; ; attempt++) {
      ContactSide? stale;
      try {
        if (p.graphWrite case final write?) {
          final contact = await graph((a) => a.get(p.graphId!));
          if (contact == null || !_inContacts(contact)) break;
          final body = write.graphPatch(contact);
          hAnswer = await graph((a) => a.update(p.graphId!, body));
          graphWritten = true;
        }
        if (p.googleWrite case final write?) {
          final person = await google((a) => a.get(p.googleName!));
          if (person == null) break;
          final u = write.googleUpdate(person, normaliser: norm);
          final name = person['resourceName'] as String;
          gAnswer = await google(
            (a) => a.update(name, u.person, fields: u.updatePersonFields),
          );
          googleName = name;
          googleWritten = true;
        }
        break;
      } on ContactReadStale catch (e) {
        stale = e.side;
      } on ContactChangedMeanwhile {
        stale = ContactSide.google;
      } on ContactGone {
        // Deleted while the run went: the next run's feed says so. What
        // was written to the other side is kept.
        break;
      } on ContactRefused {
        await _refusedPair(
          p,
          gAnswer: gAnswer,
          hAnswer: hAnswer,
          planned: planned,
        );
        return;
      }
      if (attempt > 0) break;
      final again = await _replanned(p, stale, gAnswer: gAnswer, hAnswer: hAnswer);
      if (again == null) break;
      await _replaceReviews(p, again.reviews);
      p = again.plan;
      gAnswer = null;
      hAnswer = null;
      if (p.googleWrite == null && p.graphWrite == null) break;
    }
    final bases = p.basesAfter(
      googleAnswer: gAnswer == null ? null : syncedFromPerson(gAnswer),
      graphAnswer: hAnswer == null ? null : syncedFromGraph(hAnswer),
    );
    if (googleName != null && googleName != p.googleName) {
      // Google re-keyed it while the run went.
      await store.rekey(pairId, ContactSide.google, p.googleName!, googleName);
    }
    final link = _linkOf(
      p,
      googleBase: bases.google,
      graphBase: bases.graph,
      googleEtag: gAnswer == null ? null : googleContactEtag(gAnswer),
      graphChangeKey: hAnswer?['changeKey'] as String?,
      googleWritten: googleWritten,
    );
    await store.transaction(() async {
      await store.deleteLinks(p.alsoRemove);
      await store.saveLink(
        googleName == p.googleName
            ? link
            : link.copyWith(googleName: googleName),
      );
      await _carriedOut(planned);
    });
    if (googleWritten) tally.changedGoogle++;
    if (graphWritten) tally.changedGraph++;
  }

  /// [p] planned again after [stale]'s version moved: that side read again,
  /// the other's write made this run, if any, passed as written, so that
  /// a value it has just been given is not read as Ron's change. Null when
  /// the side is gone, moved or not read whole: left for the next run.
  Future<({ContactLinkPlan plan, List<ContactReviewItem> reviews})?>
  _replanned(
    ContactLinkPlan p,
    ContactSide? stale, {
    Map<String, Object?>? gAnswer,
    Map<String, Object?>? hAnswer,
  }) async {
    GoogleContact? google;
    GraphContact? graph;
    if (stale == ContactSide.google) {
      final fresh = await this.google((a) => a.get(p.googleName!));
      if (fresh == null) return null;
      google = GoogleContact.fromPerson(fresh);
      if (google.details.isEmpty) return null;
    } else {
      final fresh = await this.graph((a) => a.get(p.graphId!));
      if (fresh == null || !_inContacts(fresh)) return null;
      graph = GraphContact.fromJson(fresh);
      if (!graph.readWhole || graph.details.isEmpty) return null;
    }
    final writtenG = gAnswer == null ? null : GoogleContact.fromPerson(gAnswer);
    var writtenH = hAnswer == null ? null : GraphContact.fromJson(hAnswer);
    if (writtenH != null && (!writtenH.readWhole || writtenH.details.isEmpty)) {
      // A write's answer that lacks a property cannot stand for the
      // contact: read it whole, and take that as what was written only
      // while it is still the version the write made. Read as Ron's, the
      // sync's own write would win a clash against his edit in Gmail.
      final fresh = await this.graph((a) => a.get(p.graphId!));
      if (fresh == null || !_inContacts(fresh)) return null;
      final whole = GraphContact.fromJson(fresh);
      if (!whole.readWhole ||
          whole.details.isEmpty ||
          whole.changeKey == null ||
          whole.changeKey != writtenH.changeKey) {
        return null;
      }
      writtenH = whole;
    }
    return p.replan(
      google: google,
      graph: graph,
      googleWritten: writtenG,
      graphWritten: writtenH,
    );
  }

  /// A pair planned again: the items the run's plan gave it are replaced.
  Future<void> _replaceReviews(
    ContactLinkPlan p,
    List<ContactReviewItem> items,
  ) async {
    final mine = [
      for (final MapEntry(key: k, value: id) in savedReviews.entries)
        if (k.$2 == p.googleName &&
            k.$3 == p.graphId &&
            (k.$1 == ContactReviewKind.differing.name ||
                k.$1.startsWith('${ContactReviewKind.clash.name}:')))
          (k, id),
    ];
    await store.transaction(() async {
      await store.dropReviews([for (final (_, id) in mine) id]);
      for (final (k, _) in mine) {
        savedReviews.remove(k);
      }
      for (final item in items) {
        await _saveReview(item);
      }
    });
  }

  /// A server would not take a pair's change: the pair is held as refused
  /// with both ids, under Needs a look, and is tried again when it changes.
  /// [planned] is the pair's plan as the run made it, before any plan made
  /// again ([_update]): the answers it carries out are done with.
  Future<void> _refusedPair(
    ContactLinkPlan p, {
    Map<String, Object?>? gAnswer,
    Map<String, Object?>? hAnswer,
    required ContactLinkPlan planned,
  }) async {
    final bases = p.basesAfter(
      googleAnswer: gAnswer == null ? null : syncedFromPerson(gAnswer),
      graphAnswer: hAnswer == null ? null : syncedFromGraph(hAnswer),
    );
    final refusing = hAnswer == null && p.graphWrite != null
        ? ContactSide.graph
        : ContactSide.google;
    final held = ContactLinkPlan(
      linkId: p.linkId,
      googleName: p.googleName,
      graphId: p.graphId,
      state: ContactLinkState.held,
      reason: ContactHeldReason.refused,
      googleEtag: gAnswer == null ? p.googleEtag : googleContactEtag(gAnswer),
      graphChangeKey: hAnswer == null
          ? p.graphChangeKey
          : hAnswer['changeKey'] as String?,
      googleBase: bases.google,
      graphBase: bases.graph,
      title: p.title,
    );
    await store.transaction(() async {
      await store.deleteLinks(p.alsoRemove);
      await store.saveLink(_linkOf(held, googleWritten: gAnswer != null));
      await _saveReview(
        ContactReviewItem(
          kind: ContactReviewKind.refused,
          subjectSide: refusing,
          googleName: p.googleName,
          graphId: p.graphId,
          title: p.title,
        ),
      );
      await _carriedOut(planned);
    });
    tally.refused++;
    debugPrint('[myemail] contacts: a change was refused by '
        '${refusing == ContactSide.google ? 'Google' : 'Microsoft'}');
  }

  // Deletions.

  /// A delete: the contact read again in full first. Changed since, or no
  /// longer in Contacts, it is kept instead; otherwise the full copy goes
  /// into the bin, pending, before the delete is sent, and is marked done
  /// when the server answers.
  ///
  /// An Outlook contact out of Contacts that the bin holds as the sync's
  /// own delete (pending: a delete whose answer was lost; or done) is not
  /// one Ron moved: it is where Microsoft keeps what it deleted (Deleted
  /// Items, as for Outlook's own deletes, where a read by its id still
  /// finds it), and is gone, as a 404 would say. Kept instead, its item
  /// would come back at every Delete it here too, and a Restore would pair
  /// Gmail with it.
  Future<void> _delete(ContactLinkPlan p) async {
    final d = p.delete!;
    final onGoogle = d.side == ContactSide.google;
    final full = onGoogle
        ? await google((a) => a.get(d.contactId, everyField: true))
        : await graph((a) => a.get(d.contactId, whole: true));
    final already = await store.binEntry(pairId, d.side, d.contactId);
    final deletedBefore =
        full != null &&
        !onGoogle &&
        !_inContacts(full) &&
        already != null &&
        already.state != ContactBinState.back;
    if (full == null || deletedBefore) {
      // Gone already: the delete before a crash, or by someone else.
      await store.transaction(() async {
        if (already != null && already.state == ContactBinState.pending) {
          await store.markBinDone(
            already.binId!,
            dropLinkId: p.removeRow ? p.linkId : null,
          );
        } else if (p.removeRow && p.linkId != null) {
          await store.deleteLinks([p.linkId!]);
        }
        await store.deleteLinks(p.alsoRemove);
        await _carriedOut(p);
      });
      return;
    }
    final version = onGoogle
        ? googleContactEtag(full)
        : full['changeKey'] as String?;
    final expected = d.expectedVersion;
    final moved = !onGoogle && !_inContacts(full);
    // A version not known is no proof the contact is unchanged: only Ron's
    // own answer deletes it then.
    final unknown = expected == null && !p.fromAnswer;
    if ((expected != null && version != expected) || moved || unknown) {
      // Changed since it was last synced: kept, and Ron is asked. Kept as
      // it is now, its version and details from the read in hand, so a
      // later Delete it here too with nothing changed since goes through,
      // and one with a change since keeps it again.
      final details = onGoogle ? syncedFromPerson(full) : syncedFromGraph(full);
      await store.transaction(() async {
        await store.saveLink(
          _linkOf(
            p.keptInstead(),
            googleEtag: onGoogle ? version : null,
            graphChangeKey: onGoogle ? null : version,
            googleBase: onGoogle ? details : null,
            graphBase: onGoogle ? null : details,
          ),
        );
        await _saveReview(p.keptReview());
        await _carriedOut(p);
      });
      debugPrint('[myemail] contacts: a contact due to be deleted had '
          'changed and was kept');
      return;
    }
    final entry = await store.addToBin(
      ContactBinEntry(
        pairId: pairId,
        side: d.side,
        contactId: d.contactId,
        partnerId: d.partnerId,
        raw: jsonEncode(full),
        partnerBase: _encode(d.partnerBase),
        title: d.title,
      ),
    );
    if (onGoogle) {
      // By the name the read just before returned: an old one would be
      // answered as not there while the contact lived on.
      final name = full['resourceName'] as String? ?? d.contactId;
      await google((a) => a.delete(name));
      googleDeleted++;
      tally.deletedGoogle++;
    } else {
      await graph((a) => a.delete(d.contactId));
      graphDeleted++;
      tally.deletedGraph++;
    }
    await store.transaction(() async {
      await store.markBinDone(
        entry.binId!,
        dropLinkId: p.removeRow ? p.linkId : null,
      );
      await store.deleteLinks(p.alsoRemove);
      await _carriedOut(p);
    });
  }

  /// A pending bin row whose contact is no longer due to be deleted: dropped
  /// if the contact is still there, marked done if it is not.
  Future<void> _notDue(int binId) async {
    final entry = bin.firstWhereOrNull((b) => b.binId == binId);
    if (entry == null) return;
    final there = entry.side == ContactSide.google
        ? await google((a) => a.get(entry.contactId)) != null
        : await graph((a) => a.get(entry.contactId)).then(
            (c) => c != null && _inContacts(c),
          );
    if (there) {
      await store.dropBin([binId]);
    } else {
      await store.markBinDone(binId);
    }
  }

  /// A Gmail contact re-keyed: its Outlook partner's tag, where it has
  /// one (a contact the sync made), names it anew. One without a tag is
  /// left without: Ron's own contact is not given one.
  Future<void> _moveTag(String id, String name) async {
    try {
      final read = await graph((a) => a.get(id, withTag: true));
      if (read == null) return;
      final tag = GraphContactsApi.tagOf(read);
      if (tag == null || tag == name) return;
      final answer = await graph((a) => a.update(id, graphTagPatch(name)));
      sync._tags[id] = (changeKey: answer['changeKey'] as String?, tag: name);
      final link = await store.linkFor(pairId, ContactSide.graph, id);
      // The patch moved its changeKey: kept, so a later delete does not read
      // the sync's own write as a change. Only where the contact was, just
      // before it, at the version the row holds: an edit Ron made since the
      // listing must still read as one.
      if (link != null &&
          read['changeKey'] == link.graphChangeKey &&
          answer['changeKey'] is String) {
        await store.saveLink(
          link.copyWith(graphChangeKey: answer['changeKey'] as String),
        );
      }
    } on ContactGone {
      return;
    } on ContactRefused {
      debugPrint('[myemail] contacts: a hidden tag was not moved');
    }
  }

  // Restores.

  /// A Restore: the contacts the plan says to make, Outlook's first, each
  /// noted on the pair before it is sent and its contact noted when it
  /// comes back, so that a run stopped in between, a lost answer or a
  /// lagging listing never makes one twice; then the two paired as a new
  /// pair is, merged without overwriting. A server's refusal is this
  /// Restore's alone: it is taken back, says why in Recently deleted, and
  /// the run carries on.
  Future<void> _restore(ContactRestorePlan r, Set<String> labels) async {
    final stored = bin.firstWhereOrNull((b) => b.binId == r.binId);
    if (stored == null || restoreWaiting.contains(r.binId)) return;
    // The ids the row names, with any contact made already in its place:
    // read again before each create, so the second carries the first's.
    ContactBinInput entry() => _binInput(stored);
    String? g = r.googleName;
    String? h = r.graphId;
    Map<String, Object?>? gMade;
    Map<String, Object?>? hMade;
    try {
      // Tagged with the ids the bin row names (the contacts made so far
      // standing in for them), which is how a later run finds them back.
      if (r.graphRaw case final raw?) {
        hMade = await _restoreCreate(
          r.binId,
          ContactSide.graph,
          graphRestoreBody(raw),
          entry().partnerId,
        );
        h = hMade['id'] as String?;
      } else if (r.graphDetails case final details? when h == null) {
        hMade = await _restoreCreate(
          r.binId,
          ContactSide.graph,
          graphCreateBody(details),
          entry().contactId,
        );
        h = hMade['id'] as String?;
      }
      // Put away between the two: the next run makes only the other.
      if (hMade != null) _checkStop();
      if (r.googleRaw case final raw?) {
        gMade = await _restoreCreate(
          r.binId,
          ContactSide.google,
          googleRestoreBody(raw, labelsThatExist: labels),
          entry().partnerId,
        );
        g = gMade['resourceName'] as String?;
      } else if (r.googleDetails case final details? when g == null) {
        gMade = await _restoreCreate(
          r.binId,
          ContactSide.google,
          googleCreateBody(details),
          entry().contactId,
        );
        g = gMade['resourceName'] as String?;
      }
    } on ContactRefused catch (e) {
      await _restoreRefused(r.binId, e);
      return;
    }
    tally.restored++;
    // One found back rather than made is paired as it is now.
    var googleNow = gMade ?? (g == null ? null : googleRead[g]);
    var graphNow = hMade ?? (h == null ? null : graphRead[h]);
    if (googleNow == null && g != null) {
      googleNow = await google((a) => a.get(g!));
    }
    if (graphNow == null && h != null) {
      // Only one in Contacts is paired: one read in Deleted Items, or in
      // another folder, is not back, and a pair with it would never sync.
      final read = await graph((a) => a.get(h!));
      graphNow = read != null && _inContacts(read) ? read : null;
    }
    final googleName = g;
    final graphId = h;
    final googleOne = googleNow == null
        ? null
        : GoogleContact.fromPerson(googleNow);
    final graphOne = graphNow == null ? null : GraphContact.fromJson(graphNow);
    if (googleName == null ||
        graphId == null ||
        googleOne == null ||
        graphOne == null) {
      // Only one side to bring back: it is back, and placed by the next
      // run as any contact is.
      await store.transaction(() async {
        await store.dropBin([r.binId]);
        await _keepMade(held.restoring.where((n) => n['binId'] == r.binId));
        await _forgetRestore(r.binId);
      });
      return;
    }
    // Paired as a new pair is: a detail left differing between the two is
    // listed under Needs a look, not passed over for ever.
    final pairPlan = planPairedContact(
      googleNow: googleOne.details,
      graphNow: graphOne.details,
      googleUpdatedAt: googleOne.updatedAt,
      graphUpdatedAt: graphOne.updatedAt,
      normaliser: norm,
      newPair: true,
    );
    final saved = await store.transaction(() async {
      await store.dropBin([r.binId]);
      await _forgetRestore(r.binId);
      await store.deleteLinks(r.alsoRemove);
      final link = await store.saveLink(
        ContactLink(
          linkId: r.linkId,
          pairId: pairId,
          googleName: googleName,
          graphId: graphId,
          googleEtag: googleOne.etag,
          graphChangeKey: graphOne.changeKey,
          googleBase: _encode(pairPlan.googleBase),
          graphBase: _encode(pairPlan.graphBase),
          state: ContactLinkState.paired,
          googleWrittenAt: gMade != null ? now : null,
        ),
      );
      if (pairPlan.differing.isNotEmpty) {
        final same = [
          for (final f in ContactField.values)
            if (!pairPlan.differing.contains(f)) f,
        ];
        await _saveReview(
          ContactReviewItem(
            kind: ContactReviewKind.differing,
            googleName: googleName,
            graphId: graphId,
            fields: pairPlan.differing,
            googleValues: googleOne.details.withFieldsFrom(
              SyncedContact.empty,
              same,
            ),
            graphValues: graphOne.details.withFieldsFrom(
              SyncedContact.empty,
              same,
            ),
            title: r.title,
          ),
        );
      }
      return link;
    });
    if (!pairPlan.writes) return;
    await _update(
      ContactLinkPlan(
        linkId: saved.linkId,
        googleName: googleName,
        graphId: graphId,
        googleEtag: googleOne.etag,
        graphChangeKey: graphOne.changeKey,
        googleBase: pairPlan.googleBase,
        graphBase: pairPlan.graphBase,
        googleNow: googleOne.details,
        graphNow: graphOne.details,
        googleWrite: pairPlan.googleWrite(version: googleOne.etag),
        graphWrite: pairPlan.graphWrite(version: graphOne.changeKey),
        newPair: true,
        fromAnswer: true,
        title: r.title,
        settings: ContactPairSettings(
          normaliser: norm,
          googleUpdatedAt: googleOne.updatedAt,
          graphUpdatedAt: graphOne.updatedAt,
          newPair: true,
        ),
      ),
    );
  }

  /// One of a Restore's creates, noted on the pair before it goes and
  /// with what it made once it comes back.
  Future<Map<String, Object?>> _restoreCreate(
    int binId,
    ContactSide side,
    Map<String, Object?> body,
    String? tag,
  ) async {
    final note = <String, Object?>{
      'binId': binId,
      'side': side.name,
      'tag': ?tag,
      'at': _ms(now),
    };
    await _noteRestore(binId, side, note);
    final made = side == ContactSide.google
        ? await google<Map<String, Object?>>((a) => a.create(body, tag: tag))
        : await graph<Map<String, Object?>>((a) => a.create(body, tag: tag));
    final id = side == ContactSide.google ? made['resourceName'] : made['id'];
    if (id is! String) {
      throw const ConnectionFailed('A contact was made without an id.');
    }
    await _noteRestore(binId, side, {
      ...note,
      side == ContactSide.google ? 'googleName' : 'graphId': id,
    });
    if (side == ContactSide.google) {
      googleMade++;
    } else {
      graphMade++;
      if (folderId == null && made['parentFolderId'] is String) {
        folderId = made['parentFolderId'] as String;
      }
    }
    return made;
  }

  /// [note] in place of any note of the same Restore and side.
  Future<void> _noteRestore(
    int binId,
    ContactSide side,
    Map<String, Object?> note,
  ) async {
    bool same(Map<String, Object?> n) =>
        n['binId'] == binId && n['side'] == side.name;
    held.restoring
      ..removeWhere(same)
      ..add(note);
    await store.updatePair(pairId, (p) {
      final h = _Held.parse(p.held);
      h.restoring
        ..removeWhere(same)
        ..add(note);
      return p.copyWith(held: h.encode());
    });
  }

  /// A Restore done with, or given up: its notes go.
  Future<void> _forgetRestore(int binId) async {
    held.restoring.removeWhere((n) => n['binId'] == binId);
    await store.updatePair(pairId, (p) {
      final h = _Held.parse(p.held);
      h.restoring.removeWhere((n) => n['binId'] == binId);
      h.restoreProblems.remove(binId);
      return p.copyWith(held: h.encode());
    });
  }

  /// A server would not take a contact a Restore made: the Restore is
  /// taken back and says why in Recently deleted. A contact it made
  /// before the refusal stays, kept as a candidate ([_keepMade]).
  Future<void> _restoreRefused(int binId, ContactRefused refused) async {
    await store.transaction(() async {
      await store.askRestore(binId, restore: false);
      await _keepMade(held.restoring.where((n) => n['binId'] == binId));
      held.restoring.removeWhere((n) => n['binId'] == binId);
      await store.updatePair(pairId, (p) {
        final h = _Held.parse(p.held);
        h.restoring.removeWhere((n) => n['binId'] == binId);
        h.restoreProblems[binId] = 'Could not restore. ${refused.message}';
        return p.copyWith(held: h.encode());
      });
    });
    tally.refused++;
    debugPrint('[myemail] contacts: a Restore was refused '
        '(HTTP ${refused.status})');
  }

  // --- the copies on the Microsoft side --------------------------------------

  /// Copies the merge deleted this run (gone too where a delete found one
  /// gone): the pair's Microsoft count is lowered by them, so the
  /// empty-answers guard measures against what is left.
  var copiesGone = 0;

  /// People the merge merged this run, by their synced copy: the count of
  /// people to merge leaves them out.
  final copiesMerged = <String>{};

  /// Ron's choices of another copy's details, as answers for the next
  /// run (Use Hadco's, for the details they replaced): his, so never held
  /// by the change brake.
  final copiesAnswers = <Map<String, Object?>>[];

  /// The merge of the Microsoft side's copies of one person
  /// ([ContactSyncService.mergeCopies]), when one is asked or Ron has
  /// answered a person whose copies differ: after the plan's writes, so
  /// the copies are read as they now are, and before the end, which
  /// counts what is left.
  ///
  /// For each person whose synced Microsoft copy is paired and has held
  /// copies beside it (this plan's duplicates), every copy is read whole,
  /// with its photo, and the rules ([cp.mergeCopies]) say what to do:
  /// nothing to add, the others deleted; details to add, written to the
  /// synced copy and checked there first; details that differ, listed
  /// for Ron, and done his way once he has answered on those very
  /// differences. A failed write deletes nothing. The others go with an
  /// ordinary delete, twenty to a batch, never through Recently deleted,
  /// and their held rows with them, as the pair's Microsoft count goes
  /// down (were the rows left for the next run to find gone, it would
  /// count them gone a second time). Gmail's copies are not touched: the
  /// next run, asked for here, gives Gmail what the synced copy gained.
  ///
  /// What is done is kept on the pair as it goes, so a run stopped part
  /// way carries on at the next; the ask stays until a pass has dealt
  /// with every person (merged, listed, failed or passed over). Done
  /// again, a merged person reads as the same, and any copy left is
  /// deleted.
  Future<void> _copies() async {
    final stored = _Held.parse((await store.pair(pairId))?.held).copies;
    final asked = stored.asked;
    final answered = {
      for (final d in stored.differing)
        if (d['answer'] is String) d['key']! as String,
    };
    if (asked == null && answered.isEmpty) return;
    final watch = Stopwatch()..start();
    final rows = await store.links(pairId);
    final paired = {
      for (final l in rows)
        if (l.isPaired && l.graphId != null) l.graphId!: l,
    };
    final groups = [
      for (final g in _Copies.bySynced(plan.duplicates))
        if (paired.containsKey(g.graphSynced) &&
            (asked != null || answered.contains(g.graphSynced)))
          g,
    ];
    final pass = _CopiesCounts();
    final step = _CopiesStep(this, stored, pass, rows);
    var complete = false;
    (Object, StackTrace)? stopped;
    try {
      await step.go(groups, paired, whole: asked != null);
      complete = true;
    } on Exception catch (e, stack) {
      // A failure of the one request leaves the ask for the next run;
      // anything else (a stop, a sign-in) is the run's, once what was done
      // is kept.
      if (_failsAlone(e)) {
        debugPrint('[myemail] contacts: the merge of copies stopped short '
            '(${e.runtimeType})');
      } else {
        stopped = (e, stack);
      }
    }
    await step.save(
      ended: complete,
      short: !complete && stopped == null,
      asked: asked,
      at: sync._now(),
    );
    debugPrint('[myemail] contacts: copies: ${pass.people} people, '
        '${pass.deleted} deleted, ${pass.added} added, '
        '${pass.differing} differ, ${pass.failed} failed, '
        '${pass.passedOver} passed over, '
        '${watch.elapsedMilliseconds} ms');
    if (step.changedAny) sync._again = true;
    if (stopped case (final e, final stack)) {
      Error.throwWithStackTrace(e, stack);
    }
  }

  /// Whether [answer], a contact as Graph answered a write, holds [written]
  /// as written: a text the same as the sync compares one (line breaks of
  /// any kind, runs of spaces and the ends aside), a list each value
  /// written, a collection each part.
  static bool _holds(Object? written, Object? answer) {
    if (written == null) return true;
    if (written is String) {
      return answer is String && _asText(answer) == _asText(written);
    }
    if (written is List) {
      return answer is List &&
          written.every((w) => answer.any((a) => _holds(w, a)));
    }
    if (written is Map) {
      return answer is Map &&
          written.entries.every((e) => _holds(e.value, answer[e.key]));
    }
    return written == answer;
  }

  /// [text] as a written text is compared: line breaks as LF, runs of
  /// spaces as one, each line and the whole trimmed.
  static String _asText(String text) => text
      .replaceAll(RegExp(r'\r\n?'), '\n')
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .join('\n')
      .trim();

  // --- the end ---------------------------------------------------------------

  /// Everything read was applied: the feeds' positions move on, with the
  /// counts, the result and the claim. Recorded before the merge of
  /// Hadco's copies ([_copies]), which keeps its own progress as it goes
  /// and lowers the Microsoft count itself; a stop in the merge then keeps
  /// all this ([_halted]), and the people left to merge are counted after
  /// it ([_countCopies]).
  Future<void> _finish() async {
    final firstSync = pair.firstDoneAt == null;
    final at = sync._now();
    final outcomes = plan.answers;
    // Brake answers this run carried out (or found nothing left to act
    // on), by question and choice: their answers are cleared. Which items
    // stay is the rows' to say (prune): one still held under its brake is
    // shown again, open, never left held with nothing to answer.
    // An answer given while this run went is not among them: only the
    // items each answer was planned for, by key and choice, and the whole
    // question's answer where it was.
    final carried = [
      for (final (i, source) in answerSources.indexed)
        if (source.questionId != null &&
            i < outcomes.length &&
            outcomes[i] != ContactAnswerOutcome.waiting)
          source,
    ];
    bool carriedItem(int question, ContactSyncChoice choice, String key) =>
        carried.any(
          (s) =>
              s.questionId == question &&
              s.questionChoice == choice &&
              s.questionItems.contains(key),
        );
    bool carriedWhole(int question, ContactSyncChoice choice) => carried.any(
      (s) => s.questionId == question && s.questionChoice == choice && s.whole,
    );
    // Those it planned and could not carry out, a contact of theirs not
    // read: each of their items says why, kept answered, until a run
    // carries it out. Not one answered while this run went, which no run
    // has tried yet.
    final waited = [
      for (final (i, source) in answerSources.indexed)
        if (source.questionId != null &&
            i < outcomes.length &&
            outcomes[i] == ContactAnswerOutcome.waiting)
          source,
    ];
    bool waitedOn(int question, ContactSyncChoice choice, String key) =>
        waited.any(
          (s) =>
              s.questionId == question &&
              s.questionChoice == choice &&
              s.questionItems.contains(key),
        );
    final binIds = {for (final b in await store.bin(pairId)) b.binId};
    final tallyNow = tally.toTally(at, complete: true);
    await store.transaction(() async {
      // Restores whose bin rows went this run without them (found back by
      // the plan, or pruned): what they made is kept, as their notes go.
      await _keepMade(
        held.restoring.where((n) => !binIds.contains(n['binId'])),
      );
      final rows = await store.links(pairId);
      await store.updatePair(pairId, (p) {
        final h = _Held.parse(p.held);
        // The answers this run planned came off the pair as their writes
        // came back ([_carriedOut]); one still marked (none should be) goes
        // with the run done. Those kept for a run that reads their
        // contacts stay as they are kept, re-keys and all, and so do the
        // merge's, kept as it wrote them.
        h.pending.removeWhere((a) => a.containsKey(_Held.writing));
        h.questions.removeWhere(
          (q) => q.kind == ContactSyncQuestionKind.emptyAnswer,
        );
        for (final q in h.questions) {
          for (final item in q.items) {
            final choice = _Question.answerOf(item);
            if (choice != null &&
                carriedItem(q.id, choice, _Question.keyOf(item))) {
              item.remove('answer');
            }
          }
          if (q.answer case final choice? when carriedWhole(q.id, choice)) {
            q.answer = null;
          }
          for (final item in q.items) {
            item.remove(_Held.waits);
            final choice = _Question.answerOf(item) ?? q.answer;
            if (choice == null ||
                !waitedOn(q.id, choice, _Question.keyOf(item))) {
              continue;
            }
            if (_waitsOn(item) case final why?) item[_Held.waits] = why;
          }
        }
        h.prune(rows);
        h.passedOver
          ..clear()
          ..addAll(plan.graphPassedOver);
        h.quotaUntil = null;
        h.restoring.removeWhere((n) => !binIds.contains(n['binId']));
        h.restoreProblems.removeWhere((id, _) => !binIds.contains(id));
        // The copies of one person as this run leaves them: a copy made of
        // a person's synced copy counts on its side.
        h.duplicates
          ..clear()
          ..addAll(
            plan.duplicates.map((d) => _Duplicates.of(d, made: copiedFrom)),
          );
        return p.copyWith(
          googleSyncToken: googleToken ?? p.googleSyncToken,
          googleMask: googleContactFieldsVersion,
          googleFullAt: googleFull ? now : p.googleFullAt,
          graphDeltaLink: deltaLink ?? p.graphDeltaLink,
          graphMask: graphContactSelectVersion,
          graphFolderId: p.graphFolderId ?? folderId,
          normaliser: contactNormaliserVersion,
          googleCount: plan.googleCount + googleMade - googleDeleted,
          graphCount: plan.graphCount + graphMade - graphDeleted,
          firstDoneAt: p.firstDoneAt ?? (firstSync ? at : null),
          lastDoneAt: at,
          lastResult: _LastResult(tally: tallyNow).encode(),
          held: h.encode(),
        );
      });
    });
    _ended = true;
    await _writeClaim(at);
    debugPrint(
      '[myemail] contacts: read ${googleRead.length}+${graphRead.length}'
      '${googleComplete ? ' (Gmail whole)' : ''}'
      '${graphComplete ? ' (Hadco whole)' : ''}, '
      'wrote Hadco +${tally.addedToGraph} ~${tally.changedGraph} '
      '-${tally.deletedGraph}, Gmail +${tally.addedToGoogle} '
      '~${tally.changedGoogle} -${tally.deletedGoogle}, '
      '${tally.needsALook} to look at, ${tally.refused} refused, '
      '${tally.passedOver} passed over, '
      '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
    );
  }

  /// The sync's own end is recorded ([_finish]): a stop after it is the
  /// merge's.
  bool _ended = false;

  /// The people left to merge ([_Copies.count]), counted once the merge of
  /// Hadco's copies is done with this run ([_copies]): from the rows as it
  /// left them, without the people it merged. A merge cut short is counted
  /// by the next run.
  Future<void> _countCopies() async {
    final rows = await store.links(pairId);
    await store.updatePair(pairId, (p) {
      final h = _Held.parse(p.held);
      h.copies.count(plan.duplicates, rows, norm, merged: copiesMerged);
      return p.copyWith(held: h.encode());
    });
  }

  Future<void> _writeClaim(DateTime at) async {
    final folder = folderId;
    if (folder == null) return;
    try {
      final device = await sync._thisDevice();
      await graph((a) => a.writeClaim(folder, device: device, at: at));
    } catch (e) {
      // A folder that will not take the claim leaves the other device
      // unwarned, which is all the claim is for: not worth failing a run
      // that did everything else.
      debugPrint('[myemail] contacts: the device claim was not written '
          '(${e.runtimeType})');
    }
  }

  /// The empty-answers brake: nothing written, and the question asked.
  Future<void> _emptyAnswer(ContactSyncStop stop) async {
    final at = sync._now();
    await store.updatePair(pairId, (p) {
      final h = _Held.parse(p.held)..stopped(stop, at);
      return p.copyWith(
        held: h.encode(),
        lastResult: _LastResult(
          tally: _LastResult.parse(p.lastResult).tally,
          halt: ContactSyncHalt(
            kind: ContactSyncHaltKind.emptyAnswer,
            at: at,
            side: stop.side,
          ),
        ).encode(),
      );
    });
    debugPrint('[myemail] contacts: stopped, ${stop.side.name} listed '
        '${stop.listed} of ${stop.expected ?? 0} expected');
  }

  /// The run stopped short: why, kept for the screen; the counts moved on
  /// by what was made and deleted; the feeds' positions left as they were.
  /// Stopped in the merge of Hadco's copies, after the sync's own end was
  /// recorded ([_ended]): that stands, its counts and its result (the
  /// merge keeps its own as it goes), with why the run stopped.
  Future<void> _halted(Object e) async {
    final at = sync._now();
    final halt = haltFor(e, at);
    final partial = tally.toTally(at, complete: false);
    try {
      await store.updatePair(pairId, (p) {
        final h = _Held.parse(p.held);
        if (halt.kind == ContactSyncHaltKind.quota) h.quotaUntil = halt.until;
        final before = _LastResult.parse(p.lastResult);
        if (_ended) {
          return p.copyWith(
            held: h.encode(),
            lastResult: _LastResult(tally: before.tally, halt: halt).encode(),
          );
        }
        return p.copyWith(
          googleCount: p.googleCount == null
              ? null
              : p.googleCount! + googleMade - googleDeleted,
          graphCount: p.graphCount == null
              ? null
              : p.graphCount! + graphMade - graphDeleted,
          held: h.encode(),
          lastResult: _LastResult(
            // A stop with nothing done keeps the last run's numbers; one
            // part way through a first sync says how far it got.
            tally: partial.done > 0 || partial.firstSync
                ? partial
                : before.tally,
            halt: halt,
          ).encode(),
        );
      });
    } catch (e) {
      debugPrint('[myemail] contacts: the stop was not recorded '
          '(${e.runtimeType})');
    }
    debugPrint('[myemail] contacts: run stopped (${halt.kind.name}'
        '${halt.side == null ? '' : ', ${halt.side!.name}'}'
        '${e is Exception && halt.kind == ContactSyncHaltKind.failed ? ', ${e.runtimeType}' : ''}), '
        '${tally.done} of ${tally.planned} writes, '
        '${watch.elapsedMilliseconds} ms');
  }

  /// [e] as the reason a run stopped.
  ContactSyncHalt haltFor(Object e, DateTime at) {
    if (e is _Stopped) {
      return ContactSyncHalt(kind: ContactSyncHaltKind.putAway, at: at);
    }
    if (e is _OtherDevice) {
      return ContactSyncHalt(
        kind: ContactSyncHaltKind.otherDevice,
        at: at,
        claimedAt: e.at,
      );
    }
    if (e is ContactQuotaSpent) {
      return ContactSyncHalt(
        kind: ContactSyncHaltKind.quota,
        at: at,
        side: ContactSide.google,
        until: e.until,
        error: ContactSyncFailed(e.message),
      );
    }
    final error = readable(e);
    return ContactSyncHalt(
      kind: error is ContactSyncNeedsSignIn
          ? ContactSyncHaltKind.notAllowed
          : ContactSyncHaltKind.failed,
      at: at,
      side: error is ContactSyncNeedsSignIn ? error.side : _side,
      error: error,
    );
  }

  /// [e] as the screen shows it: a sign-in naming the account, a failure
  /// worth trying again, or one that is not.
  Exception readable(Object e) {
    final side = _side;
    if (side != null &&
        (e is SignInNeedsConsent ||
            e is SignInExpired ||
            e is AuthenticationFailed)) {
      return ContactSyncNeedsSignIn(
        side: side,
        accountId: pair.accountIdOn(side),
        message: (e as ReadableError).message,
        needsAdministrator: switch (e) {
          NeedsSignIn(:final needsAdministrator) => needsAdministrator,
          _ => false,
        },
      );
    }
    if (e is Retryable && e is ReadableError) {
      return ContactSyncFailed((e as ReadableError).message);
    }
    if (e is ContactSyncRefused) return e;
    if (e is ReadableError) return ContactSyncRefused(e.message);
    return ContactSyncFailed(
      'Contact sync stopped on something unexpected (${e.runtimeType}). '
      'It tries again later.',
    );
  }
}

/// Another device's claim: when it last completed a run.
class _OtherDevice implements Exception {
  const _OtherDevice(this.at);
  final DateTime at;
}

/// Where a queued answer came from: a Needs a look item, a brake's
/// question, or a run that planned it and stopped.
class _AnswerSource {
  const _AnswerSource.review(int this.reviewId)
    : questionId = null,
      questionChoice = null,
      questionItems = const {},
      whole = false,
      pendingIndex = null;

  /// A brake question's answer: the choice given, the keys of the items
  /// it acts on, and whether the whole question's answer is among them
  /// (else only items' own).
  const _AnswerSource.question(
    int this.questionId,
    ContactSyncChoice this.questionChoice,
    this.questionItems, {
    required this.whole,
  }) : reviewId = null,
       pendingIndex = null;
  const _AnswerSource.pending(int this.pendingIndex)
    : reviewId = null,
      questionId = null,
      questionChoice = null,
      questionItems = const {},
      whole = false;

  final int? reviewId;
  final int? questionId;
  final ContactSyncChoice? questionChoice;
  final Set<String> questionItems;
  final bool whole;
  final int? pendingIndex;
}

/// One run's numbers as they are counted.
class _Tally {
  bool firstSync = false;
  int addedToGoogle = 0;
  int addedToGraph = 0;
  int changedGoogle = 0;
  int changedGraph = 0;
  int deletedGoogle = 0;
  int deletedGraph = 0;
  int paired = 0;
  int restored = 0;
  int refused = 0;
  int needsALook = 0;
  int heldDeletions = 0;
  int heldChanges = 0;
  int passedOver = 0;
  int planned = 0;
  int done = 0;

  ContactSyncTally toTally(DateTime at, {required bool complete}) =>
      ContactSyncTally(
        at: at,
        complete: complete,
        firstSync: firstSync,
        addedToGoogle: addedToGoogle,
        addedToGraph: addedToGraph,
        changedGoogle: changedGoogle,
        changedGraph: changedGraph,
        deletedGoogle: deletedGoogle,
        deletedGraph: deletedGraph,
        paired: paired,
        restored: restored,
        refused: refused,
        needsALook: needsALook,
        heldDeletions: heldDeletions,
        heldChanges: heldChanges,
        passedOver: passedOver,
        planned: planned,
        done: done,
      );
}

// ---------------------------------------------------------------------------
// What the pair keeps as JSON.

DateTime? _time(Object? ms) =>
    ms is int ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true) : null;

int? _ms(DateTime? at) => at?.millisecondsSinceEpoch;

ContactSide? _sideOf(Object? name) =>
    ContactSide.values.firstWhereOrNull((s) => s.name == name);

/// `ContactPair.held`: the brakes' questions, the answers a stopped run had
/// planned, the Outlook contacts passed over, Google's quota, and when the
/// shell last showed a notice. Ids sit under `googleName` and `graphId`
/// keys, where a re-key reaches them (`rekeyContactJson`).
class _Held {
  _Held();

  factory _Held.parse(String? json) {
    final held = _Held();
    final map = _Run._decode(json);
    if (map == null) return held;
    final questions = map['questions'];
    for (final q in questions is List ? questions : const []) {
      if (q is Map) {
        final parsed = _Question.parse(q.cast<String, Object?>());
        if (parsed != null) held.questions.add(parsed);
      }
    }
    final pending = map['pending'];
    for (final a in pending is List ? pending : const []) {
      if (a is Map) held.pending.add(a.cast<String, Object?>());
    }
    final passed = map['passedOver'];
    for (final id in passed is List ? passed : const []) {
      if (id is String) held.passedOver.add(id);
    }
    held.quotaUntil = _time(map['quotaUntil']);
    held.noticeSeenAt = _time(map['noticeSeenAt']);
    held.lastKey = map['lastKey'] is int ? map['lastKey']! as int : 0;
    final restoring = map['restoring'];
    for (final r in restoring is List ? restoring : const []) {
      if (r is Map) held.restoring.add(r.cast<String, Object?>());
    }
    final problems = map['restoreProblems'];
    if (problems is Map) {
      for (final MapEntry(:key, :value) in problems.entries) {
        final id = int.tryParse('$key');
        if (id != null && value is String) held.restoreProblems[id] = value;
      }
    }
    final duplicates = map['duplicates'];
    for (final d in duplicates is List ? duplicates : const []) {
      if (d is Map) held.duplicates.add(_Duplicates.parse(d));
    }
    held.copies = _Copies.parse(map['copies']);
    return held;
  }

  final List<_Question> questions = [];
  final List<Map<String, Object?>> pending = [];
  final List<String> passedOver = [];
  DateTime? quotaUntil;
  DateTime? noticeSeenAt;

  /// A Restore's creates, each noted before it is sent: the bin row, the
  /// side, the hidden tag it carries, when, and once its answer came, the
  /// contact it made (under `googleName` or `graphId`, where a re-key
  /// reaches it). A note with no contact is a create whose answer was
  /// lost: the next run looks for its tag before anything is made again.
  final List<Map<String, Object?>> restoring = [];

  /// Why a Restore could not be done, by bin row, in a sentence.
  final Map<int, String> restoreProblems = {};

  /// Copies of one person, as the last plan grouped them: counts and
  /// titles only, so a re-key (which moves ids in this JSON) has nothing
  /// here to move, and the next plan groups them afresh.
  final List<_Duplicates> duplicates = [];

  /// The merge of the Microsoft side's copies of one person.
  _Copies copies = _Copies();

  /// The contact a Restore's note says it made, if its answer came.
  static String? madeBy(Map<String, Object?> note) =>
      (note['googleName'] ?? note['graphId']) as String?;

  int get _nextId =>
      questions.fold(0, (n, q) => q.id > n ? q.id : n) + 1;

  /// The last item key minted ([raise]).
  int lastKey = 0;

  /// Under this key in an item, why its answer was not carried out at the
  /// last run: `unread` (a contact of its pair could not be read) or
  /// `movedOut` (its Outlook contact is out of Contacts). Set and cleared
  /// at the end of each run.
  static const waits = 'waits';

  /// Under this key in a pending answer, a number the run that planned it
  /// gives it while its writes are out: the run takes it off by that
  /// number as soon as they come back ([_Run._carriedOut]). Only that run
  /// marks answers; the next one, should this stop first, plans the
  /// answer again and marks it anew. An answer 3.22.1 kept has none, and
  /// is planned as any.
  static const writing = 'writing';

  /// A brake raised this run: added to its kind's open question, or asked
  /// anew where that one already has an answer queued. An item already
  /// asked about (the same contacts) is not asked about twice: it stays
  /// where it stands, with any answer given to it.
  ///
  /// Each item added gets a key of its own, minted here once and kept in
  /// its JSON: what the screen names it by, whatever happens to its
  /// contacts' ids meanwhile (a Gmail re-key).
  void raise(ContactBrake brake, DateTime at) {
    final kind = _kindOf(brake);
    final items = [
      for (final i in brake.items)
        if (_asked(kind, i.toJson()) == null)
          {...i.toJson(), 'key': 'k${++lastKey}'},
    ];
    if (items.isEmpty) return;
    final open = questions.firstWhereOrNull(
      (q) => q.kind == kind && q.answer == null,
    );
    if (open != null) {
      open.items.addAll(items);
      open.at = at;
    } else {
      questions.add(_Question(id: _nextId, kind: kind, at: at, items: items));
    }
  }

  /// What each held item would do, as this run read it
  /// ([ContactSyncPlan.heldBrakes]): every item asked about takes its
  /// changes and hint from the item naming the same contacts, keeping
  /// its question and its answer; one the plan leaves out (a held change
  /// whose pair was not read on both sides) keeps what it had. Not news.
  void refresh(List<ContactBrake> held) {
    for (final brake in held) {
      final kind = _kindOf(brake);
      for (final i in brake.items) {
        final fresh = i.toJson();
        final item = _asked(kind, fresh);
        if (item == null) continue;
        for (final key in const ['changes', 'hint']) {
          if (fresh[key] case final value?) {
            item[key] = value;
          } else {
            item.remove(key);
          }
        }
      }
    }
  }

  static ContactSyncQuestionKind _kindOf(ContactBrake brake) =>
      brake.kind == ContactBrakeKind.deletions
      ? ContactSyncQuestionKind.deletions
      : ContactSyncQuestionKind.changes;

  /// The item of a [kind] question naming the same contacts as [item].
  Map<String, Object?>? _asked(
    ContactSyncQuestionKind kind,
    Map<String, Object?> item,
  ) {
    for (final q in questions) {
      if (q.kind != kind) continue;
      for (final asked in q.items) {
        if (asked['googleName'] == item['googleName'] &&
            asked['graphId'] == item['graphId']) {
          return asked;
        }
      }
    }
    return null;
  }

  /// The empty-answers brake stopped a run.
  void stopped(ContactSyncStop stop, DateTime at) {
    final open = questions.firstWhereOrNull(
      (q) => q.kind == ContactSyncQuestionKind.emptyAnswer && q.side == stop.side,
    );
    if (open != null) {
      open
        ..listed = stop.listed
        ..expected = stop.expected;
      return;
    }
    questions.add(
      _Question(
        id: _nextId,
        kind: ContactSyncQuestionKind.emptyAnswer,
        at: at,
        side: stop.side,
        listed: stop.listed,
        expected: stop.expected,
      ),
    );
  }

  /// Items whose rows the brakes no longer hold go from their questions,
  /// and questions left with none.
  void prune(List<ContactLink> rows) {
    for (final q in questions) {
      final reason = switch (q.kind) {
        ContactSyncQuestionKind.deletions => ContactHeldReason.deletionBrake,
        ContactSyncQuestionKind.changes => ContactHeldReason.changeBrake,
        ContactSyncQuestionKind.emptyAnswer => null,
      };
      if (reason == null) continue;
      q.items.removeWhere(
        (item) => !rows.any(
          (l) =>
              l.reason == reason &&
              ((item['googleName'] != null &&
                      l.googleName == item['googleName']) ||
                  (item['graphId'] != null && l.graphId == item['graphId'])),
        ),
      );
    }
    questions.removeWhere(
      (q) => q.kind != ContactSyncQuestionKind.emptyAnswer && q.items.isEmpty,
    );
  }

  String encode() => jsonEncode({
    if (questions.isNotEmpty)
      'questions': [for (final q in questions) q.toJson()],
    if (pending.isNotEmpty) 'pending': pending,
    if (passedOver.isNotEmpty) 'passedOver': passedOver,
    'quotaUntil': ?_ms(quotaUntil),
    'noticeSeenAt': ?_ms(noticeSeenAt),
    if (lastKey > 0) 'lastKey': lastKey,
    if (restoring.isNotEmpty) 'restoring': restoring,
    if (restoreProblems.isNotEmpty)
      'restoreProblems': {
        for (final MapEntry(:key, :value) in restoreProblems.entries)
          '$key': value,
      },
    if (duplicates.isNotEmpty)
      'duplicates': [for (final d in duplicates) d.toJson()],
    if (copies.toJson() case final c when c.isNotEmpty) 'copies': c,
  });
}

/// The merge of the Microsoft side's copies of one person, as kept on the
/// pair ([ContactSyncService.mergeCopies]). People are named by their
/// synced copy's Graph id, which never changes, under `key` (never
/// `graphId`: a Gmail re-key has nothing here to move). The values listed
/// are contact data: kept on this device like Needs a look items, never
/// logged.
class _Copies {
  _Copies();

  factory _Copies.parse(Object? json) {
    final copies = _Copies();
    if (json is! Map) return copies;
    int n(String key) => json[key] is int ? json[key]! as int : 0;
    copies
      ..asked = _time(json['asked'])
      ..shortStops = n('shortStops')
      ..people = n('people')
      ..extras = n('extras')
      ..notSynced = n('notSynced')
      ..pass = _CopiesCounts.parse(json['pass'])
      ..last = json['last'] is Map ? _CopiesCounts.parse(json['last']) : null
      ..lastAt = _time(json['lastAt']);
    final differing = json['differing'];
    for (final d in differing is List ? differing : const []) {
      if (d is Map && d['key'] is String) {
        copies.differing.add(d.cast<String, Object?>());
      }
    }
    final left = json['left'];
    if (left is Map) {
      for (final MapEntry(:key, :value) in left.entries) {
        if (value is String || value is Map) copies.left['$key'] = value!;
      }
    }
    return copies;
  }

  /// The rules a listing or a leave was made under (`rules`): 3.22.1's,
  /// under which a photo is never a difference. One without was made by
  /// 3.22.0, whose rules listed copies for their photos alone.
  static const rules = 2;

  /// Whether [listing] was made under the rules of now.
  static bool current(Map<String, Object?> listing) =>
      listing['rules'] == rules;

  /// When a merge was asked; null when none is.
  DateTime? asked;

  /// Passes in a row that stopped short, Hadco not read.
  int shortStops = 0;

  /// The people a merge would act on and their other copies, and the
  /// people with copies but no synced copy, as the last run counted them
  /// ([count]).
  int people = 0;
  int extras = 0;
  int notSynced = 0;

  /// What the pass under way has done, through runs stopped part way.
  _CopiesCounts pass = _CopiesCounts();

  /// What the last merge did, and when it ended.
  _CopiesCounts? last;
  DateTime? lastAt;

  /// The people whose copies differ, listed for Ron: `key`, `title`, the
  /// `fingerprint` of the differences shown, the `rules` they were listed
  /// under ([rules]), Ron's `answer` (a copy's key, or `leave`), and
  /// `copies`, each with its `key`, whether `synced`, and its differing
  /// values (`details`: `label`, `value`).
  final List<Map<String, Object?>> differing = [];

  /// People Ron chose to leave as they are, by key: the `fingerprint` of
  /// the differences as they were (empty where none was left) and the
  /// `rules` it was taken under. A merge passes them over while today's
  /// fingerprint is the leave's. One left under 3.22.0 (its fingerprint
  /// alone, of rules that counted photos) is stamped anew by the first
  /// pass that meets it ([currentLeave]).
  final Map<String, Object> left = {};

  /// Whether a leave ([leftAs]) was taken under the rules of now: one
  /// 3.22.0 kept was not.
  static bool currentLeave(Object leftAs) =>
      leftAs is Map && leftAs['rules'] == rules;

  /// The fingerprint of the differences a leave ([leftAs]) was taken on.
  static String? leaveFingerprint(Object leftAs) => switch (leftAs) {
    final Map m =>
      m['fingerprint'] is String ? m['fingerprint']! as String : null,
    final String f => f,
    _ => null,
  };

  /// Whether a [listing] showed a photo among what differed: one 3.22.0
  /// made could.
  static bool showedPhoto(Map<String, Object?>? listing) {
    final copies = listing?['copies'];
    return copies is List &&
        copies.any(
          (c) =>
              c is Map &&
              c['details'] is List &&
              (c['details']! as List).any(
                (d) => d is Map && d['label'] == 'Photo',
              ),
        );
  }

  /// The person listed under [key], if one is.
  Map<String, Object?>? listed(String key) =>
      differing.firstWhereOrNull((d) => d['key'] == key);

  /// A merge asked, or an answer waiting for a run: a run is due at once,
  /// unless the last pass stopped short (then the usual hour applies).
  bool get dueNow =>
      shortStops == 0 &&
      (asked != null || differing.any((d) => d['answer'] != null));

  /// The people listed under the rules of now that Ron has not answered.
  int get unanswered =>
      differing.where((d) => current(d) && d['answer'] == null).length;

  /// [listed]'s version, as the screen is given it: a short stable form of
  /// the fingerprint of its differences.
  static String versionOf(Map<String, Object?> listed) {
    final fingerprint = listed['fingerprint'];
    if (fingerprint is! String) return '';
    return fingerprint.length > 16
        ? fingerprint.substring(0, 16)
        : fingerprint;
  }

  /// The keys of [listed]'s copies.
  static List<String> copyKeys(Map<String, Object?> listed) => [
    for (final c in listed['copies'] is List
        ? listed['copies']! as List
        : const [])
      if (c is Map && c['key'] is String) c['key']! as String,
  ];

  /// The people a merge would act on, as [groups] (this run's plan) and
  /// [rows] leave them: a synced Microsoft copy that is paired, with held
  /// copies beside it, neither merged this run ([merged]), listed nor
  /// left; and the people with copies there but no synced copy.
  ///
  /// A person listed or left whose copies are no longer there to merge
  /// (merged in Outlook, or its synced copy no longer paired) goes from
  /// the list, any answer with it.
  ///
  /// Only the copies joined to the synced copy by an email or a mobile
  /// ([joined], from what the rows hold of each) are the merge's: a person
  /// with a copy that shares only the name with it (a group joined by
  /// name) counts among those left as they are ([notSynced]), as does one
  /// with no synced copy.
  void count(
    List<ContactDuplicateGroup> groups,
    List<ContactLink> rows,
    ContactNormaliser norm, {
    Set<String> merged = const {},
  }) {
    final paired = {
      for (final l in rows)
        if (l.isPaired) ?l.graphId,
    };
    final base = {
      for (final l in rows)
        ?l.graphId: SyncedContact.fromJson(_Run._decode(l.graphBase)),
    };

    final there = {
      for (final g in groups)
        if (g.graphSynced case final synced?
            when g.graphCopies.isNotEmpty && paired.contains(synced))
          synced,
    };
    differing.removeWhere((d) => !there.contains(d['key']));
    left.removeWhere((key, _) => !there.contains(key));
    people = 0;
    extras = 0;
    notSynced = groups
        .where((g) => g.graphSynced == null && g.graphCopies.isNotEmpty)
        .length;
    for (final g in bySynced(groups)) {
      final synced = g.graphSynced!;
      if (!paired.contains(synced) || merged.contains(synced)) continue;
      final ours = mergeable(norm, synced, base[synced], {
        for (final id in g.graphCopies)
          if (!paired.contains(id)) id: ?base[id],
      });
      if (ours.length < g.graphCopies.length) notSynced++;
      // One left is not counted; nor one listed under the rules of now
      // (a merge would only list it again), nor one answered and waiting
      // for a run. One listed under 3.22.0's rules and not answered is: its
      // differences may be no more (a photo), and a merge reads it again.
      // Never counted: one left (a pass asked for others finds whether
      // its differences are still those he left), one listed under the
      // rules of now (a merge would only list it again), one answered and
      // waiting for a run. One listed under 3.22.0's rules and not
      // answered is: its differences may be no more (a photo), and a
      // merge reads it again.
      final l = listed(synced);
      if (ours.isEmpty ||
          left.containsKey(synced) ||
          (l != null && (l['answer'] != null || current(l)))) {
        continue;
      }
      people++;
      extras += ours.length;
    }
  }

  /// [groups] with a synced Hadco copy and held copies there, one to a
  /// synced copy: a group joined to the pair by name only (copies no
  /// longer joined to it by an address) folded into the pair's own.
  static List<ContactDuplicateGroup> bySynced(
    List<ContactDuplicateGroup> groups,
  ) {
    final by = <String, ContactDuplicateGroup>{};
    for (final g in groups) {
      final synced = g.graphSynced;
      if (synced == null || g.graphCopies.isEmpty) continue;
      final had = by[synced];
      by[synced] = had == null
          ? g
          : ContactDuplicateGroup(
              title: had.title ?? g.title,
              googleSynced: had.googleSynced ?? g.googleSynced,
              graphSynced: synced,
              googleCopies: [...had.googleCopies, ...g.googleCopies],
              graphCopies: {...had.graphCopies, ...g.graphCopies}.toList(),
            );
    }
    return [...by.values];
  }

  /// Which of [others] are the merge's copies of the synced copy [key],
  /// [synced]: not the synced copy, nor one any pair names, of the same
  /// full name ([ContactNormaliser.fullNameKey] of the name as copied, as
  /// the plan groups copies), and joined to it by an email or a mobile
  /// ([joined]).
  static Set<String> mergeable(
    ContactNormaliser norm,
    String key,
    SyncedContact? synced,
    Map<String, SyncedContact> others,
  ) {
    if (synced == null) return const {};
    final name = ContactNormaliser.fullNameKey(synced.copyableName);
    return joined(norm, synced, {
      for (final MapEntry(key: id, value: d) in others.entries)
        if (id != key &&
            ContactNormaliser.fullNameKey(d.copyableName) == name)
          id: d,
    });
  }

  /// Which of [others] are joined to [synced] by an email or a mobile,
  /// directly or through another that is, as the plan joins copies of one
  /// person. One sharing only the name is not.
  static Set<String> joined(
    ContactNormaliser norm,
    SyncedContact? synced,
    Map<String, SyncedContact> others,
  ) {
    Set<String> keys(SyncedContact d) => {
      for (final e in d.list(ContactField.emails))
        if (norm.itemKey(ContactField.emails, e) case final k?) 'e $k',
      if (norm.phoneKey(d.text(ContactField.mobile)) case final k?) 'm $k',
    };
    if (synced == null) return const {};
    final have = keys(synced);
    final found = <String>{};
    for (var grew = true; grew;) {
      grew = false;
      for (final MapEntry(key: id, value: d) in others.entries) {
        if (found.contains(id)) continue;
        final k = keys(d);
        if (!k.any(have.contains)) continue;
        found.add(id);
        have.addAll(k);
        grew = true;
      }
    }
    return found;
  }

  Map<String, Object?> toJson() => {
    'asked': ?_ms(asked),
    if (shortStops > 0) 'shortStops': shortStops,
    if (people > 0) 'people': people,
    if (extras > 0) 'extras': extras,
    if (notSynced > 0) 'notSynced': notSynced,
    if (!pass.isEmpty) 'pass': pass.toJson(),
    if (last case final l?) 'last': l.toJson(),
    'lastAt': ?_ms(lastAt),
    if (differing.isNotEmpty) 'differing': differing,
    if (left.isNotEmpty) 'left': left,
  };

  ContactSyncCopies shown() => ContactSyncCopies(
    people: people,
    extras: extras,
    notSynced: notSynced,
    asked: asked != null,
    shortStops: shortStops,
    last: switch ((last, lastAt)) {
      (final l?, final at?) => l.shown(at),
      _ => null,
    },
    // One listed by 3.22.0 and not answered is not shown: its
    // differences may be no more (a photo); the next merge reads it again.
    differing: [
      for (final d in differing)
        if (current(d) || d['answer'] != null) _personOf(d),
    ],
  );

  static ContactSyncCopiesPerson _personOf(Map<String, Object?> d) {
    List<Object?> listOf(Object? v) => v is List ? v : const [];
    return ContactSyncCopiesPerson(
      key: d['key']! as String,
      title: d['title'] is String ? d['title']! as String : '',
      copies: [
        for (final c in listOf(d['copies']))
          if (c is Map && c['key'] is String)
            ContactSyncCopy(
              key: c['key']! as String,
              synced: c['synced'] == true,
              details: [
                for (final x in listOf(c['details']))
                  if (x is Map && x['label'] is String)
                    ContactSyncCopyDetail(
                      label: x['label']! as String,
                      value: x['value'] is String
                          ? x['value']! as String
                          : null,
                    ),
              ],
            ),
      ],
      answer: d['answer'] is String ? d['answer']! as String : null,
      version: versionOf(d),
    );
  }
}

/// A merge's numbers ([ContactSyncCopiesResult]).
class _CopiesCounts {
  _CopiesCounts();

  factory _CopiesCounts.parse(Object? json) {
    final counts = _CopiesCounts();
    if (json is! Map) return counts;
    int n(String key) => json[key] is int ? json[key]! as int : 0;
    return counts
      ..people = n('people')
      ..deleted = n('deleted')
      ..added = n('added')
      ..differing = n('differing')
      ..failed = n('failed')
      ..passedOver = n('passedOver')
      ..stoppedShort = json['stoppedShort'] == true;
  }

  int people = 0;
  int deleted = 0;
  int added = 0;
  int differing = 0;
  int failed = 0;
  int passedOver = 0;

  /// The merge was given up, its passes stopping short.
  bool stoppedShort = false;

  bool get isEmpty =>
      people == 0 && deleted == 0 && added == 0 && differing == 0 &&
      failed == 0 && passedOver == 0 && !stoppedShort;

  void add(_CopiesCounts other) {
    people += other.people;
    deleted += other.deleted;
    added += other.added;
    differing += other.differing;
    failed += other.failed;
    passedOver += other.passedOver;
  }

  Map<String, Object?> toJson() => {
    'people': people,
    'deleted': deleted,
    'added': added,
    'differing': differing,
    'failed': failed,
    'passedOver': passedOver,
    if (stoppedShort) 'stoppedShort': true,
  };

  ContactSyncCopiesResult shown(DateTime at) => ContactSyncCopiesResult(
    at: at,
    people: people,
    deleted: deleted,
    added: added,
    differing: differing,
    failed: failed,
    passedOver: passedOver,
    stoppedShort: stoppedShort,
  );
}

/// The merge rules found a write that did not hold, or a photo to give
/// that could not be read: the person failed, nothing of theirs deleted.
class _CopyNotHeld implements Exception {
  const _CopyNotHeld();
}

/// The person cannot be merged as read: a photo could not be read, or a
/// contact changed (or went) since the read. Passed over, to be tried at a
/// later pass; nothing of theirs deleted (details may already have been
/// added to the synced copy, which the next pass finds there).
class _PassOver implements Exception {
  const _PassOver();
}

/// One run's merge of the Microsoft side's copies ([_Run._copies]): what
/// it reads, does and lists, kept on the pair as it goes ([save]).
class _CopiesStep {
  _CopiesStep(this.run, this.seen, this.pass, List<ContactLink> rows)
    : _rowOf = {
        for (final l in rows)
          if (l.reason == ContactHeldReason.duplicate &&
              l.googleName == null &&
              l.graphId != null)
            l.graphId!: l,
      };

  final _Run run;

  /// The held rows of the copies, by their Graph id.
  final Map<String, ContactLink> _rowOf;

  /// The merge as the run found it: the people listed with Ron's answers,
  /// and those left.
  final _Copies seen;

  /// What this run did, for the log.
  final _CopiesCounts pass;

  /// Not yet kept on the pair: what was done since [save] last ran.
  var _counts = _CopiesCounts();
  final _listed = <String, Map<String, Object?>>{};
  final _unlisted = <String>{};
  final _left = <String, Object>{};
  final _unleft = <String>{};
  var _gone = 0;
  final _rowsGone = <int>{};

  /// Copies to delete, by person: whole people to a batch.
  final _queued = <String, List<String>>{};

  /// The `changeKey` each contact queued should still have when its
  /// delete goes: as read, or for a synced copy written, as the write left
  /// it.
  final _expected = <String, String?>{};

  /// Every copy taken by a person this pass: none is taken twice.
  final _taken = <String>{};

  var _done = 0;
  var _total = 0;

  /// Something was written or deleted: a run more gives Gmail what the
  /// synced copies gained.
  bool changedAny = false;

  ContactSyncStore get store => run.store;

  void _count({
    int people = 0,
    int deleted = 0,
    int added = 0,
    int differing = 0,
    int failed = 0,
    int passedOver = 0,
  }) {
    for (final c in [_counts, pass]) {
      c
        ..people += people
        ..deleted += deleted
        ..added += added
        ..differing += differing
        ..failed += failed
        ..passedOver += passedOver;
    }
  }

  void _progress() => run.sync._progressTo(
    ContactSyncProgress(
      step: ContactSyncStep.merging,
      done: _done,
      total: _total,
      firstSync: run.tally.firstSync,
    ),
  );

  void _personDone() {
    _done++;
    _progress();
  }

  void _passedOver() {
    _count(passedOver: 1);
    _personDone();
  }

  /// Merge [groups], the people whose synced copies are [paired]: the
  /// whole folder read at once for a merge asked ([whole]), or the copies
  /// of the people Ron answered read one by one.
  Future<void> go(
    List<ContactDuplicateGroup> groups,
    Map<String, ContactLink> paired, {
    required bool whole,
  }) async {
    _total = groups.length;
    _progress();
    if (groups.isEmpty) return;

    final read = <String, Map<String, Object?>>{};
    if (whole) {
      final folder = run.folderId;
      for (final c in await run.graph(
        (a) => a.listAll(folderId: folder, whole: true),
      )) {
        if (c['id'] case final String id) read[id] = c;
      }
    } else {
      for (final g in groups) {
        for (final id in [g.graphSynced!, ...g.graphCopies]) {
          run._checkStop();
          final c = await run.graph((a) => a.get(id, whole: true));
          if (c != null && run._inContacts(c)) read[id] = c;
        }
      }
    }

    // Photos: the synced copies first; then the other copies only where
    // theirs can count: a synced copy without one takes the first other
    // copy's, and Ron's answer naming another copy brings that copy's.
    final photo = <String>{};
    final unknown = <String>{};
    Future<void> check(List<String> ids) async {
      if (ids.isEmpty) return;
      run._checkStop();
      final r = await run.graph((a) => a.photos(ids));
      photo.addAll(r.have);
      unknown.addAll(r.unknown);
    }

    bool namesAnother(String key) {
      final answer = seen.listed(key)?['answer'];
      return answer is String &&
          answer != key &&
          answer != ContactSyncCopiesPerson.leave;
    }

    await check([
      for (final g in groups)
        if (read.containsKey(g.graphSynced)) g.graphSynced!,
    ]);
    await check([
      for (final g in groups)
        if (read.containsKey(g.graphSynced) &&
            !unknown.contains(g.graphSynced) &&
            (!photo.contains(g.graphSynced) || namesAnother(g.graphSynced!)))
          for (final id in g.graphCopies)
            if (read.containsKey(id)) id,
    ]);

    for (final g in groups) {
      if (run.sync._stopAsked && !run.preview) await _flush();
      run._checkStop();
      final key = g.graphSynced!;
      final synced = read[key];
      if (synced == null || !g.graphCopies.any(read.containsKey)) {
        // Not in Contacts as read: passed over this time.
        _passedOver();
        continue;
      }
      // The merge's copies only ([_Copies.mergeable]): none another pair
      // names, none taken by another person this pass, of the same name,
      // joined by an email or a mobile. Any other is left as it is.
      final copies = _Copies.mergeable(run.norm, key, syncedFromGraph(synced), {
        for (final id in g.graphCopies)
          if (!paired.containsKey(id) && !_taken.contains(id))
            if (read[id] case final c?) id: syncedFromGraph(c),
      });
      if (copies.isEmpty) {
        _personDone();
        continue;
      }
      // Ron's Leave them always stands: a person he left (or answered so)
      // stays so while the differences are those he left (the
      // fingerprint), whatever else a merge would now say; an added detail
      // never changes them. A leave 3.22.0 kept is stamped with today's
      // differences the first time a pass meets it, and stays. Once they
      // are others, the person is read again as any other: listed for Ron
      // where they differ, merged where none is left.
      final leftAs = seen.left[key];
      final leaving =
          seen.listed(key)?['answer'] == ContactSyncCopiesPerson.leave;
      if (leftAs != null || leaving) {
        // The differences as they are now (a photo never one of them).
        final now = cp.mergeCopies(
          cp.OutlookCopy(id: key, json: synced),
          [for (final id in copies) cp.OutlookCopy(id: id, json: read[id]!)],
          norm: run.norm,
        ).fingerprint;
        if (leaving || leftAs == null || !_Copies.currentLeave(leftAs)) {
          _leave(key, now);
          _personDone();
          continue;
        }
        if (_Copies.leaveFingerprint(leftAs) == now) {
          _personDone();
          continue;
        }
        _unleft.add(key);
      }
      // A copy whose photo could not be checked is not taken as having
      // none.
      if ([key, ...copies].any(unknown.contains)) {
        _passedOver();
        continue;
      }
      try {
        await _person(g, [...copies], read, photo, paired[key]!);
      } on _PassOver {
        _passedOver();
      } on Exception catch (e) {
        if (e is! _CopyNotHeld && !_Run._failsAlone(e)) rethrow;
        _count(failed: 1);
        _personDone();
      }
    }
    await _flush();
  }

  /// One person: its copies read whole in [read], those with a photo
  /// among [photo]; [pair] its synced copy's row.
  Future<void> _person(
    ContactDuplicateGroup g,
    List<String> copies,
    Map<String, Map<String, Object?>> read,
    Set<String> photo,
    ContactLink pair,
  ) async {
    final key = g.graphSynced!;
    // Which copies have a photo, and no more: a photo is never compared
    // (3.22.1), and its bytes are read only for the copy the synced one
    // takes it from.
    String? hasPhoto(String id) => photo.contains(id) ? 'photo' : null;
    final kept = cp.OutlookCopy(
      id: key,
      json: read[key]!,
      photo: hasPhoto(key),
    );
    final others = [
      for (final id in copies)
        cp.OutlookCopy(id: id, json: read[id]!, photo: hasPhoto(id)),
    ];
    final listed = seen.listed(key);
    final answer = listed?['answer'] is String
        ? listed!['answer']! as String
        : null;
    var merge = cp.mergeCopies(kept, others, norm: run.norm);
    // Ron's answer (Leave them is dealt with before) counts only on the
    // differences he saw. Given on a listing under the rules of now, on
    // those very differences (the fingerprint), and never on the photo.
    // Given on one 3.22.0 made, whose differences may no longer be: the
    // synced copy's leaves the rules of now to decide; another copy's, with
    // nothing differing now, brings that copy's photo (the difference he
    // saw); with something differing, the person is listed again as it
    // is, the answer dropped.
    if (answer != null && (answer == key || copies.contains(answer))) {
      final now = listed != null && _Copies.current(listed);
      if (now
          ? merge.outcome == cp.CopiesOutcome.differs &&
                merge.fingerprint == listed['fingerprint']
          : merge.outcome != cp.CopiesOutcome.differs && answer != key) {
        // On today's listings an answer never touches the photo: the
        // synced copy's own stays. On a 3.22.0 listing that showed one,
        // the photo was a difference Ron saw: another copy's brings it.
        merge = cp.mergeCopies(
          kept,
          others,
          keep: answer,
          keepsPhoto: !now && _Copies.showedPhoto(listed),
          norm: run.norm,
        );
      }
    }
    if (merge.outcome == cp.CopiesOutcome.differs) {
      _list(key, g.title ?? '', merge, others);
      _count(differing: 1);
      _personDone();
      return;
    }
    final read0 = {
      for (final id in [key, ...copies])
        id: read[id]!['changeKey'] as String?,
    };
    var syncedKey = read0[key];
    if (merge.outcome == cp.CopiesOutcome.adds) {
      // Nothing written on a stale read: each contact read again first,
      // and the person passed over should one have changed, or gone.
      final now = await _asTheyWere([key, ...copies], read0);
      if (now.length < copies.length + 1 || now.values.contains(false)) {
        throw const _PassOver();
      }
      final from = merge.photoFrom;
      final taken = from == null ? null : await _photoOf(from);
      syncedKey = await _write(key, merge, read[key]!, taken, pair);
      _count(added: merge.adds.length);
      changedAny = true;
    }
    _unlisted.add(key);
    _listed.remove(key);
    _unleft.add(key);
    _left.remove(key);
    if (_queued.values.fold(0, (n, c) => n + c.length) + copies.length >
        GraphContactsApi.batchLimit) {
      await _flush();
    }
    _queued[key] = copies;
    _taken.addAll(copies);
    _expected[key] = syncedKey;
    for (final id in copies) {
      _expected[id] = read0[id];
    }
  }

  /// The photo of the copy [id], for the synced copy to take: one that
  /// cannot be read now passes the person over, rather than reading as
  /// none.
  Future<({List<int> bytes, String type})> _photoOf(String id) async {
    final ({List<int> bytes, String type})? got;
    try {
      got = await run.graph((a) => a.photoBytes(id));
    } on Exception catch (e) {
      if (!_Run._failsAlone(e)) rethrow;
      throw const _PassOver();
    }
    if (got == null) throw const _PassOver();
    return got;
  }

  /// The contacts [ids] read again by id: for each still there, whether
  /// it is as it was ([expected] its `changeKey`) and in Contacts. Those
  /// gone are left out. A read that fails says none is as it was.
  Future<Map<String, bool>> _asTheyWere(
    List<String> ids,
    Map<String, String?> expected,
  ) async {
    final GraphBatchRead r;
    try {
      r = await run.graph((a) => a.getBatch(ids));
    } on Exception catch (e) {
      if (!_Run._failsAlone(e)) rethrow;
      return {for (final id in ids) id: false};
    }
    return {
      for (final id in ids)
        if (!r.notFound.contains(id))
          id: switch (r.found[id]) {
            final c? =>
              run._inContacts(c) &&
                  c['changeKey'] != null &&
                  c['changeKey'] == expected[id],
            null => false,
          },
    };
  }

  /// Write what [merge] adds to the synced copy [key] ([before] as read),
  /// check the answer holds each value, and give it a photo where the
  /// merge says, read back before any copy goes. The details it replaced
  /// go to Gmail at the next run as an answer (Use Hadco's), kept on the
  /// pair at once: the merge's own, never held by the change brake. The
  /// synced copy's `changeKey` as the write left it.
  Future<String?> _write(
    String key,
    cp.CopiesMerge merge,
    Map<String, Object?> before,
    ({List<int> bytes, String type})? photo,
    ContactLink pair,
  ) async {
    var changeKey = before['changeKey'] as String?;
    if (merge.patch.isNotEmpty) {
      final answer = await run.graph((a) => a.update(key, merge.patch));
      for (final MapEntry(key: name, value: value) in merge.patch.entries) {
        if (!_Run._holds(value, answer[name])) throw const _CopyNotHeld();
      }
      changeKey = answer['changeKey'] as String?;
      if (pair.googleName case final googleName?) {
        final was = syncedFromGraph(before);
        final now = syncedFromGraph(answer);
        final replaced = [
          for (final f in ContactField.values)
            if (!_empty(was[f]) && !run.norm.same(f, was[f], now[f])) f.name,
        ];
        if (replaced.isNotEmpty) {
          // With the Gmail contact's version as the write found it: should
          // Gmail change before a run carries it out, the answer is
          // dropped ([_Run._dropStale]) and the usual rules decide.
          final useHadcos = {
            'kind': ContactAnswerKind.useGraph.name,
            'googleName': googleName,
            'graphId': key,
            'fields': replaced,
            'googleEtag': ?pair.googleEtag,
          };
          run.copiesAnswers.add(useHadcos);
          await store.updatePair(run.pairId, (p) {
            final h = _Held.parse(p.held)..pending.add(useHadcos);
            return p.copyWith(held: h.encode());
          });
        }
      }
    }
    if (merge.photoFrom != null) {
      if (photo == null) throw const _CopyNotHeld();
      await run.graph((a) => a.putPhoto(key, photo.bytes, photo.type));
      // The photo there before its copy goes, and the synced copy as the
      // photo left it.
      final there = await run.graph((a) => a.photos([key]));
      if (!there.have.contains(key)) throw const _CopyNotHeld();
      final now = await run.graph((a) => a.getBatch([key]));
      changeKey = now.found[key]?['changeKey'] as String?;
      if (changeKey == null) throw const _CopyNotHeld();
    }
    return changeKey;
  }

  /// Whether a detail's value is none.
  static bool _empty(Object? v) =>
      v == null ||
      (v is String && v.trim().isEmpty) ||
      (v is List && v.isEmpty);

  /// Delete the copies queued, whole people to a batch, each person read
  /// again first: one whose synced copy or a copy changed since (or a
  /// copy moved out) is passed over, nothing of theirs deleted; a copy
  /// gone meanwhile is left out. A person whose copies are all gone is
  /// merged; one with a copy left failed (its update stands, and a later
  /// merge finds the copy the same).
  Future<void> _flush() async {
    if (_queued.isEmpty) return;
    final queued = Map.of(_queued);
    _queued.clear();
    final now = await _asTheyWere([
      for (final MapEntry(key: person, value: copies) in queued.entries) ...[
        person,
        ...copies,
      ],
    ], _expected);
    final people = <String, List<String>>{};
    for (final MapEntry(key: person, value: copies) in queued.entries) {
      if (now[person] != true || copies.any((id) => now[id] == false)) {
        _passedOver();
        continue;
      }
      people[person] = [
        for (final id in copies)
          if (now.containsKey(id)) id,
      ];
    }
    final ids = [for (final c in people.values) ...c];
    GraphBatchDelete? deleted;
    if (ids.isNotEmpty) {
      try {
        deleted = await run.graph((a) => a.deleteBatch(ids));
      } on Exception catch (e) {
        if (!_Run._failsAlone(e)) rethrow;
      }
    }
    final gone = {...?deleted?.deleted, ...?deleted?.gone};
    for (final id in gone) {
      if (_rowOf[id]?.linkId case final row?) _rowsGone.add(row);
    }
    for (final MapEntry(key: person, value: copies) in people.entries) {
      if (copies.every(gone.contains)) {
        _count(people: 1);
        run.copiesMerged.add(person);
      } else {
        _count(failed: 1);
      }
      _personDone();
    }
    _count(deleted: deleted?.deleted.length ?? 0);
    _gone += gone.length;
    run.copiesGone += gone.length;
    if (gone.isNotEmpty) changedAny = true;
    await save();
  }

  /// [key] left as Ron chose, with the [fingerprint] of its differences
  /// as they are now (empty where none is): passed over until they are
  /// others.
  void _leave(String key, String fingerprint) {
    _unlisted.add(key);
    _listed.remove(key);
    _left[key] = {'fingerprint': fingerprint, 'rules': _Copies.rules};
    _unleft.remove(key);
  }

  /// [key] listed with what differs between its copies, [merge] as the
  /// rules found them: the synced copy first, then [others].
  void _list(
    String key,
    String title,
    cp.CopiesMerge merge,
    List<cp.OutlookCopy> others,
  ) {
    _unlisted.remove(key);
    _unleft.add(key);
    _left.remove(key);
    _listed[key] = {
      'key': key,
      'title': title,
      'fingerprint': merge.fingerprint,
      'rules': _Copies.rules,
      'copies': [
        {
          'key': key,
          'synced': true,
          'details': [
            for (final d in merge.differences)
              {'label': d.label, 'value': ?d.kept},
          ],
        },
        for (final o in others)
          {
            'key': o.id,
            'details': [
              for (final d in merge.differences)
                {'label': d.label, 'value': ?d.others[o.id]},
            ],
          },
      ],
    };
  }

  /// What was done since the last save, kept on the pair: the counts, the
  /// people listed and left, the rows of the copies gone, and the pair's
  /// Microsoft count lowered by them. With [ended], the pass dealt with
  /// every person: the merge [asked] is done and its numbers are the last
  /// result; without one asked, what this run did for Ron's answers is
  /// added to the last result. With [short], the pass stopped short
  /// (Hadco could not be read): one more in a row ([_Copies.shortStops]).
  Future<void> save({
    bool ended = false,
    bool short = false,
    DateTime? asked,
    DateTime? at,
  }) async {
    final counts = _counts;
    final listed = Map.of(_listed);
    final unlisted = Set.of(_unlisted);
    final left = Map.of(_left);
    final unleft = Set.of(_unleft);
    final gone = _gone;
    final rows = Set.of(_rowsGone);
    _rowsGone.clear();
    _counts = _CopiesCounts();
    _listed.clear();
    _unlisted.clear();
    _left.clear();
    _unleft.clear();
    _gone = 0;
    await store.transaction(() async {
      if (rows.isNotEmpty) await store.deleteLinks(rows);
      await store.updatePair(run.pairId, (p) {
        final h = _Held.parse(p.held);
        final c = h.copies;
        c.pass.add(counts);
        c.differing.removeWhere((d) => unlisted.contains(d['key']));
        for (final MapEntry(key: key, value: entry) in listed.entries) {
          final i = c.differing.indexWhere((d) => d['key'] == key);
          if (i < 0) {
            c.differing.add(entry);
            continue;
          }
          // An answer given while the run went, on these very differences,
          // stands; one given before was carried out or no longer fits.
          final was = c.differing[i];
          final given = was['answer'];
          if (given != null &&
              given != seen.listed(key)?['answer'] &&
              was['fingerprint'] == entry['fingerprint']) {
            entry['answer'] = given;
          }
          c.differing[i] = entry;
        }
        for (final key in unleft) {
          c.left.remove(key);
        }
        c.left.addAll(left);
        if (short) {
          // A pass that stopped short, Hadco not read: the ask stays, but
          // after three in a row it is given up, and the last result says
          // so. Runs for Ron's answers alone are not passes of a merge.
          if (asked != null && c.asked == asked) c.shortStops++;
          if (asked != null && c.asked == asked && c.shortStops >= 3) {
            c
              ..asked = null
              ..shortStops = 0
              ..last = (c.pass
                ..differing = c.unanswered
                ..stoppedShort = true)
              ..lastAt = at
              ..pass = _CopiesCounts();
          }
        }
        if (ended) {
          c.shortStops = 0;
          if (asked != null) {
            if (c.asked == asked) {
              c
                ..asked = null
                ..last = (c.pass..differing = c.unanswered)
                ..lastAt = at
                ..pass = _CopiesCounts();
            }
          } else {
            c
              ..last = ((c.last ?? _CopiesCounts())
                ..add(c.pass)
                ..differing = c.unanswered)
              ..lastAt = at
              ..pass = _CopiesCounts();
          }
        }
        final count = p.graphCount;
        return p.copyWith(
          held: h.encode(),
          graphCount: count == null ? null : count - gone,
        );
      });
    });
    run.sync._changed();
  }
}

/// One person held more than once, as kept on the pair: what the screen
/// shows of a [ContactDuplicateGroup], with no ids.
class _Duplicates {
  const _Duplicates({
    required this.title,
    required this.googleCopies,
    required this.graphCopies,
    required this.googleSynced,
    required this.graphSynced,
  });

  /// [group]'s counts: the copies each side holds, the synced one among
  /// them.
  ///
  /// [made] are the contacts copied to the other side this run, by their
  /// source: a person's copy made from its synced copy counts on that
  /// other side as its synced copy, as the next plan will list it.
  factory _Duplicates.of(
    ContactDuplicateGroup group, {
    Set<(ContactSide, String)> made = const {},
  }) {
    final g = group.googleSynced;
    final h = group.graphSynced;
    final toGraph =
        h == null && g != null && made.contains((ContactSide.google, g));
    final toGoogle =
        g == null && h != null && made.contains((ContactSide.graph, h));
    return _Duplicates(
      title: group.title ?? '',
      googleCopies:
          group.googleCopies.length + (g != null || toGoogle ? 1 : 0),
      graphCopies: group.graphCopies.length + (h != null || toGraph ? 1 : 0),
      googleSynced: g != null || toGoogle,
      graphSynced: h != null || toGraph,
    );
  }

  factory _Duplicates.parse(Map<Object?, Object?> json) {
    int n(String key) => json[key] is int ? json[key]! as int : 0;
    return _Duplicates(
      title: json['title'] is String ? json['title']! as String : '',
      googleCopies: n('googleCopies'),
      graphCopies: n('graphCopies'),
      googleSynced: json['googleSynced'] == true,
      graphSynced: json['graphSynced'] == true,
    );
  }

  final String title;
  final int googleCopies;
  final int graphCopies;
  final bool googleSynced;
  final bool graphSynced;

  Map<String, Object?> toJson() => {
    'title': title,
    'googleCopies': googleCopies,
    'graphCopies': graphCopies,
    'googleSynced': googleSynced,
    'graphSynced': graphSynced,
  };

  ContactSyncDuplicates shown() => ContactSyncDuplicates(
    title: title,
    googleCopies: googleCopies,
    graphCopies: graphCopies,
    googleSynced: googleSynced,
    graphSynced: graphSynced,
  );
}

class _Question {
  _Question({
    required this.id,
    required this.kind,
    required this.at,
    List<Map<String, Object?>>? items,
    this.side,
    this.listed,
    this.expected,
    this.answer,
  }) : items = items ?? [];

  static _Question? parse(Map<String, Object?> json) {
    final kind = ContactSyncQuestionKind.values.firstWhereOrNull(
      (k) => k.name == json['kind'],
    );
    final id = json['id'];
    final at = _time(json['at']);
    if (kind == null || id is! int || at == null) return null;
    final items = json['items'];
    return _Question(
      id: id,
      kind: kind,
      at: at,
      items: [
        for (final i in items is List ? items : const [])
          if (i is Map) _keyed(i.cast<String, Object?>()),
      ],
      side: _sideOf(json['side']),
      listed: json['listed'] as int?,
      expected: json['expected'] as int?,
      answer: ContactSyncChoice.values.firstWhereOrNull(
        (c) => c.name == json['answer'],
      ),
    );
  }

  final int id;
  final ContactSyncQuestionKind kind;
  DateTime at;
  final List<Map<String, Object?>> items;
  final ContactSide? side;
  int? listed;
  int? expected;
  ContactSyncChoice? answer;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'at': _ms(at),
    if (items.isNotEmpty) 'items': items,
    'side': ?side?.name,
    'listed': ?listed,
    'expected': ?expected,
    'answer': ?answer?.name,
  };

  /// An item's key within its question: the one minted when it was raised
  /// ([_Held.raise]). An item kept before keys were has its contacts' ids
  /// instead (Outlook's, else Gmail's), set on it when it is read, and
  /// kept from the next time the pair is written.
  static String keyOf(Map<String, Object?> item) =>
      (item['key'] ?? item['graphId'] ?? item['googleName'] ?? '') as String;

  /// [item] with its key set on it, for an item kept before keys were.
  static Map<String, Object?> _keyed(Map<String, Object?> item) {
    if (item['key'] is! String) item['key'] = keyOf(item);
    return item;
  }

  /// The answer given to an item on its own, if any.
  static ContactSyncChoice? answerOf(Map<String, Object?> item) =>
      ContactSyncChoice.values.firstWhereOrNull(
        (c) => c.name == item['answer'],
      );

  ContactSyncQuestion shown() => ContactSyncQuestion(
    kind: kind,
    items: [
      for (final i in items) _itemShown(i),
    ],
    side: side,
    listed: listed,
    expected: expected,
    answer: answer,
  );

  ContactSyncQuestionItem _itemShown(Map<String, Object?> json) {
    final item = ContactBrakeItem.fromJson(json);
    final side = _sideOf(json['side']) ?? ContactSide.google;
    return ContactSyncQuestionItem(
      title: json['title'] as String? ?? '',
      side: side,
      key: keyOf(json),
      changes: [
        for (final c in item?.changes ?? const <ContactDetailChange>[])
          ContactSyncDetailChange(
            field: c.field,
            before: c.before,
            after: c.after,
            // Always set: the planner's, its item's for a change kept
            // without one.
            side: c.side,
            clash: c.clash,
          ),
      ],
      hint: item?.hint,
      answer: answerOf(json),
      answerProblem: switch (json[_Held.waits]) {
        'unread' =>
          'Could not be read just now: it is carried out when it can be.',
        'movedOut' =>
          'Its Outlook contact is not in Contacts: it is carried out once '
              'it is back.',
        _ => null,
      },
    );
  }
}

/// `ContactPair.lastResult`: the last run's numbers, and why it stopped.
class _LastResult {
  const _LastResult({this.tally, this.halt});

  factory _LastResult.parse(String? json) {
    final map = _Run._decode(json);
    if (map == null) return const _LastResult();
    final t = map['tally'];
    final h = map['halt'];
    return _LastResult(
      tally: t is Map ? _tallyOf(t.cast<String, Object?>()) : null,
      halt: h is Map ? _haltOf(h.cast<String, Object?>()) : null,
    );
  }

  final ContactSyncTally? tally;
  final ContactSyncHalt? halt;

  String encode() => jsonEncode({
    if (tally case final t?) 'tally': _tallyJson(t),
    if (halt case final h?) 'halt': _haltJson(h),
  });

  static Map<String, Object?> _tallyJson(ContactSyncTally t) => {
    'at': _ms(t.at),
    'complete': t.complete,
    'firstSync': t.firstSync,
    'addedToGoogle': t.addedToGoogle,
    'addedToGraph': t.addedToGraph,
    'changedGoogle': t.changedGoogle,
    'changedGraph': t.changedGraph,
    'deletedGoogle': t.deletedGoogle,
    'deletedGraph': t.deletedGraph,
    'paired': t.paired,
    'restored': t.restored,
    'refused': t.refused,
    'needsALook': t.needsALook,
    'heldDeletions': t.heldDeletions,
    'heldChanges': t.heldChanges,
    'passedOver': t.passedOver,
    'planned': t.planned,
    'done': t.done,
  };

  static ContactSyncTally? _tallyOf(Map<String, Object?> j) {
    final at = _time(j['at']);
    if (at == null) return null;
    int n(String key) => j[key] is int ? j[key]! as int : 0;
    return ContactSyncTally(
      at: at,
      complete: j['complete'] != false,
      firstSync: j['firstSync'] == true,
      addedToGoogle: n('addedToGoogle'),
      addedToGraph: n('addedToGraph'),
      changedGoogle: n('changedGoogle'),
      changedGraph: n('changedGraph'),
      deletedGoogle: n('deletedGoogle'),
      deletedGraph: n('deletedGraph'),
      paired: n('paired'),
      restored: n('restored'),
      refused: n('refused'),
      needsALook: n('needsALook'),
      heldDeletions: n('heldDeletions'),
      heldChanges: n('heldChanges'),
      passedOver: n('passedOver'),
      planned: n('planned'),
      done: n('done'),
    );
  }

  /// A halt as kept: its kind, and of its failure only the kind and the
  /// sentence the app wrote, never a server's.
  static Map<String, Object?> _haltJson(ContactSyncHalt h) {
    final e = h.error;
    return {
      'kind': h.kind.name,
      'at': _ms(h.at),
      'side': ?h.side?.name,
      'until': ?_ms(h.until),
      'claimedAt': ?_ms(h.claimedAt),
      if (e is ReadableError) 'message': (e as ReadableError).message,
      if (e is ContactSyncNeedsSignIn) ...{
        'error': 'signIn',
        'accountId': e.accountId,
        'needsAdministrator': e.needsAdministrator,
      } else if (e is ContactSyncFailed)
        'error': 'retry'
      else if (e != null)
        'error': 'refused',
    };
  }

  static ContactSyncHalt? _haltOf(Map<String, Object?> j) {
    final kind = ContactSyncHaltKind.values.firstWhereOrNull(
      (k) => k.name == j['kind'],
    );
    final at = _time(j['at']);
    if (kind == null || at == null) return null;
    final side = _sideOf(j['side']);
    final message = j['message'] as String? ?? '';
    final Exception? error = switch (j['error']) {
      'signIn' when side != null => ContactSyncNeedsSignIn(
        side: side,
        accountId: j['accountId'] as String? ?? '',
        message: message,
        needsAdministrator: j['needsAdministrator'] == true,
      ),
      'retry' => ContactSyncFailed(message),
      'refused' => ContactSyncRefused(message),
      _ => null,
    };
    return ContactSyncHalt(
      kind: kind,
      at: at,
      side: side,
      error: error,
      until: _time(j['until']),
      claimedAt: _time(j['claimedAt']),
    );
  }
}

/// A stored review as Needs a look shows it.
abstract final class _Look {
  /// The store's kind for [item]: its kind, and a clash's detail, so that
  /// two details of one pair that clash are two items, each with its own
  /// answer.
  static String kindOf(ContactReviewItem item) =>
      item.kind == ContactReviewKind.clash && item.fields.isNotEmpty
      ? '${item.kind.name}:${item.fields.first.name}'
      : item.kind.name;

  static Map<String, Object?> dataOf(ContactReview r) =>
      _Run._decode(r.data) ?? const {};

  static ContactSyncLook? of(ContactReview r) {
    final id = r.reviewId;
    if (id == null) return null;
    final kind = ContactReviewKind.values.firstWhereOrNull(
      (k) => k.name == r.kind.split(':').first,
    );
    if (kind == null) return null;
    final data = dataOf(r);
    final reason = ContactReviewReason.values.firstWhereOrNull(
      (k) => k.name == data['reason'],
    );
    final fields = [
      for (final f in data['fields'] is List ? data['fields']! as List : const [])
        if (f is String) ?ContactField.byName(f),
    ];
    final google = SyncedContact.fromJson(data['google']);
    final graph = SyncedContact.fromJson(data['graph']);
    final losing = SyncedContact.fromJson(data['losing']);
    final candidates = data['candidates'];
    final titles = data['candidateTitles'];
    final ids = [
      for (final c in candidates is List ? candidates : const [])
        if (c is String) c,
    ];
    final names = [
      for (final t in titles is List ? titles : const [])
        if (t is String) t,
    ];
    final samePerson = data['samePerson'] != false;
    final answer = _Run._decode(r.answer);
    return ContactSyncLook(
      id: id,
      kind: kind,
      reason: reason,
      side: switch (kind) {
        ContactReviewKind.kept => _sideOf(data['goneSide']),
        // Merged away in Gmail: what is left is the Outlook contact.
        ContactReviewKind.mergedInGoogle => ContactSide.google,
        _ => _sideOf(data['subjectSide']),
      },
      title: data['title'] as String? ?? '',
      candidates: [
        for (final (i, c) in ids.indexed)
          ContactSyncCandidate(id: c, title: i < names.length ? names[i] : ''),
      ],
      fields: fields,
      googleValues: {
        for (final f in fields)
          if (google[f] != null) f: SyncedContact.describe(f, google[f]),
      },
      graphValues: {
        for (final f in fields)
          if (graph[f] != null) f: SyncedContact.describe(f, graph[f]),
      },
      losing: fields.isEmpty
          ? null
          : SyncedContact.describe(fields.first, losing[fields.first]),
      losingSide: _sideOf(data['losingSide']),
      choices: switch (kind) {
        ContactReviewKind.newContact => [
          if (samePerson && ids.isNotEmpty) ContactSyncChoice.samePerson,
          ContactSyncChoice.copyAnyway,
          ContactSyncChoice.leaveOut,
        ],
        ContactReviewKind.differing => const [
          ContactSyncChoice.useGoogle,
          ContactSyncChoice.useGraph,
          ContactSyncChoice.leaveAsTheyAre,
        ],
        ContactReviewKind.clash => const [
          ContactSyncChoice.useOther,
          ContactSyncChoice.keepNewer,
        ],
        ContactReviewKind.kept => const [
          ContactSyncChoice.copyBack,
          ContactSyncChoice.deleteHereToo,
          ContactSyncChoice.keepOnlyHere,
        ],
        ContactReviewKind.mergedInGoogle => const [
          ContactSyncChoice.deleteHereToo,
          ContactSyncChoice.keepOnlyHere,
        ],
        ContactReviewKind.refused => const [ContactSyncChoice.retry],
      },
      answer: _choiceOf(answer?['kind'], kind),
      createdAt: r.createdAt,
    );
  }

  /// The button an answer queued stands for.
  static ContactSyncChoice? _choiceOf(Object? answer, ContactReviewKind kind) =>
      switch (answer) {
        'samePerson' => ContactSyncChoice.samePerson,
        'copyAnyway' => ContactSyncChoice.copyAnyway,
        'leaveOut' => ContactSyncChoice.leaveOut,
        'useGoogle' => ContactSyncChoice.useGoogle,
        'useGraph' => ContactSyncChoice.useGraph,
        'useValue' => ContactSyncChoice.useOther,
        'copyBack' => ContactSyncChoice.copyBack,
        'deleteHereToo' => ContactSyncChoice.deleteHereToo,
        'keepOnlyHere' => ContactSyncChoice.keepOnlyHere,
        'retry' => ContactSyncChoice.retry,
        _ => null,
      };
}

/// What a plan sends to Needs a look, by kind and reason, and how much the
/// two address books have in common: counts only, never a name or a value.
/// Logged with every plan, since only a real address book shows why a
/// first sync would hold many contacts back.
void _logShape(ContactSyncInput input, ContactSyncPlan plan) {
  final norm = ContactNormaliser(region: input.phoneRegion);
  Set<String> emails(SyncedContact d) => {
    for (final e in d.list(ContactField.emails))
      ?norm.itemKey(ContactField.emails, e),
  };
  bool mobile(SyncedContact d) =>
      norm.phoneKey(d.text(ContactField.mobile)) != null;
  bool parts(SyncedContact d) => d.name?.hasParts ?? false;
  String? fullName(SyncedContact d) =>
      ContactNormaliser.fullNameKey(d.copyableName);

  final gEmails = <String>{};
  final gNames = <String>{};
  var gEmail = 0, gMobile = 0, gParts = 0;
  for (final c in input.google) {
    final e = emails(c.details);
    if (e.isNotEmpty) gEmail++;
    gEmails.addAll(e);
    if (mobile(c.details)) gMobile++;
    if (parts(c.details)) gParts++;
    if (fullName(c.details) case final k?) gNames.add(k);
  }
  final hEmails = <String>{};
  final hNames = <String>{};
  var hEmail = 0, hMobile = 0, hParts = 0, hWhole = 0, hTagged = 0;
  for (final c in input.graph) {
    if (c.readWhole) hWhole++;
    if (c.tag != null) hTagged++;
    final e = emails(c.details);
    if (e.isNotEmpty) hEmail++;
    hEmails.addAll(e);
    if (mobile(c.details)) hMobile++;
    if (parts(c.details)) hParts++;
    if (fullName(c.details) case final k?) hNames.add(k);
  }
  debugPrint(
    '[myemail] contacts: shape: Gmail ${input.google.length} '
    '($gEmail with an email, $gMobile a mobile, $gParts name parts), '
    'Microsoft ${input.graph.length} ($hWhole whole, $hTagged tagged, '
    '$hEmail with an email, $hMobile a mobile, $hParts name parts); '
    'addresses ${gEmails.length} and ${hEmails.length}, '
    '${gEmails.intersection(hEmails).length} on both; full names '
    '${gNames.length} and ${hNames.length}, '
    '${gNames.intersection(hNames).length} on both',
  );
  final reasons = <String, int>{};
  for (final r in plan.reviews) {
    final key = '${r.kind.name}/${r.reason?.name ?? '-'}';
    reasons[key] = (reasons[key] ?? 0) + 1;
  }
  debugPrint(
    '[myemail] contacts: to look at by reason: '
    '${reasons.isEmpty ? 'none' : [
        for (final MapEntry(:key, :value) in reasons.entries) '$key $value',
      ].join(', ')}',
  );
}
