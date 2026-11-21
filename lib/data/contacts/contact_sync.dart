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
    await _Run(this, pair, takeClaim: _takeClaim).go();
    _takeClaim = false;
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
      if (!firstUnfinished &&
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
            ),
      ],
      googleCount: pair.googleCount,
      graphCount: pair.graphCount,
      notice: _noticeOf(held, last),
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
      if (q.kind == ContactSyncQuestionKind.deletions) {
        deletions += q.items.length;
      } else if (q.kind == ContactSyncQuestionKind.changes) {
        changes += q.items.length;
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
    ContactSyncChoice choice,
  ) async {
    if (choice == ContactSyncChoice.keepWaiting) return;
    if (!ContactSyncQuestion(kind: kind).choices.contains(choice)) {
      throw ArgumentError.value(choice, 'choice', 'not an answer to $kind');
    }
    final pair = await _attachedPair();
    if (pair == null) return;
    await store.updatePair(pair.pairId, (p) {
      final held = _Held.parse(p.held);
      for (final q in held.questions) {
        if (q.kind == kind && q.answer == null) q.answer = choice;
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
      if (r.kind != ContactReviewKind.differing.name || r.reviewId == null) {
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
    _changed();
    if (entry != null) unawaited(_go(again: true));
  }

  @override
  Future<void> syncHere() async {
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
      );
    } catch (e) {
      throw run.readable(e);
    } finally {
      run.close();
    }
  }

  @override
  Future<List<ContactSyncBackupFile>> backup() async {
    final pair = await _chosenPair();
    final run = _Run(this, pair, preview: true);
    try {
      final watch = Stopwatch()..start();
      final people = await run.google((a) => a.listAll(everyField: true));
      final labels = await run.google((a) => a.labels());
      final folder =
          pair.graphFolderId ?? await run.graph((a) => a.mainFolderId());
      final contacts = await run.graph(
        (a) => a.listAll(folderId: folder, whole: true),
      );
      final at = _now();
      debugPrint('[myemail] contacts: backup of ${people.people.length} + '
          '${contacts.length} contacts, ${watch.elapsedMilliseconds} ms');
      return [
        ContactSyncBackupFile(
          side: ContactSide.google,
          fileName: ContactBackup.vCardName(at),
          mimeType: ContactBackup.vCardType,
          contents: ContactBackup.vCard(people.people, labelNames: labels),
          count: people.people.length,
        ),
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
    _checkStop();
  }

  /// The device claim: another device's, younger than a week, stops the
  /// run unless this one was told to take it over.
  Future<void> _claim() async {
    final claim = await graph((a) => a.readClaim(folderId!));
    final me = await sync._thisDevice();
    if (claim == null || claim.device == me || takeClaim) return;
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
    await _confirmGoogle(
      toRead.google.where(
        (n) => !googleRead.containsKey(n) && !googleGone.contains(n),
      ),
    );
    for (final id in toRead.graph) {
      if (graphRead.containsKey(id) || graphGone.contains(id)) continue;
      _checkStop();
      await _confirmGraph(id);
    }

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
      final now = person['resourceName'];
      if (now is String && now != name) {
        googleReKeys[name] = now;
        googleRead[now] = person;
      } else {
        googleRead[name] = person;
      }
    }
    googleGone.addAll(r.notFound);
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
  List<ContactBinInput> _binInputs() => [
    for (final b in bin)
      if (b.binId != null && b.state != ContactBinState.back)
        ContactBinInput(
          binId: b.binId!,
          side: b.side,
          contactId: b.contactId,
          partnerId: b.partnerId,
          done: b.state == ContactBinState.done,
          raw: _decode(b.raw),
          partnerBase: _decode(b.partnerBase),
          title: b.title,
          restore: b.restore,
        ),
  ];

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
      final kind = switch (q.answer) {
        ContactSyncChoice.deleteThem => ContactAnswerKind.deleteHeld,
        ContactSyncChoice.dontDelete => ContactAnswerKind.keepHeld,
        ContactSyncChoice.applyThem => ContactAnswerKind.applyHeld,
        ContactSyncChoice.copyThemBack => ContactAnswerKind.copyHeldBack,
        ContactSyncChoice.carryOn => ContactAnswerKind.carryOn,
        _ => null,
      };
      if (kind == null) continue;
      // Only the contacts the question named: a later brake of the same
      // kind holds others, under a question of its own.
      final items = [
        for (final i in q.items) ?ContactBrakeItem.fromJson(i),
      ];
      answers.add(
        ContactAnswer(
          kind,
          side: q.side,
          held: kind == ContactAnswerKind.carryOn ? null : items,
        ),
      );
      answerSources.add(_AnswerSource.question(q.id));
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
    return planContactSync(
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
  }

  // --- the run ---------------------------------------------------------------

  late ContactNormaliser norm;
  late ContactSyncPlan plan;
  final tally = _Tally();
  final watch = Stopwatch();

  /// Contacts made and deleted this run, per side, for the counts.
  var googleMade = 0;
  var graphMade = 0;
  var googleDeleted = 0;
  var graphDeleted = 0;

  /// Reviews saved this run, by what names them, so a pair planned again
  /// can replace its own.
  final savedReviews = <(String, String?, String?), int>{};

  Future<void> go() async {
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
      norm = ContactNormaliser(
        region: pair.phoneRegion ?? sync._regionNow(),
      );
      plan = planContactSync(input());
      if (plan.stop case final stop?) {
        await _emptyAnswer(stop);
        return;
      }
      tally
        ..firstSync = pair.firstDoneAt == null
        ..passedOver = plan.counts.passedOver
        ..paired = plan.counts.pairUp
        ..heldDeletions = plan.counts.heldDeletions
        ..heldChanges = plan.counts.heldChanges;
      await _saveFirst();
      await _write();
      await _finish();
    } catch (e) {
      await _halted(e);
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

    // Answers planned: their items go, and the answers are kept on the
    // pair until the run is done, so a run stopped before their writes
    // plans them again.
    final pending = <Map<String, Object?>>[];
    final dropReviews = <int>{};
    for (final (i, source) in answerSources.indexed) {
      final outcome = i < outcomes.length ? outcomes[i] : null;
      if (outcome == null) continue;
      if (source.reviewId case final id?) {
        if (outcome == ContactAnswerOutcome.waiting) continue;
        dropReviews.add(id);
        if (outcome == ContactAnswerOutcome.applied) {
          final r = reviews.firstWhereOrNull((r) => r.reviewId == id);
          if (_decode(r?.answer) case final answer?) pending.add(answer);
        }
      }
      if (source.pendingIndex case final at?
          when outcome != ContactAnswerOutcome.dropped &&
              at < held.pending.length) {
        pending.add(held.pending[at]);
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
      if (plan.brakes.isNotEmpty) {
        await store.updatePair(pairId, (p) {
          final h = _Held.parse(p.held);
          for (final brake in plan.brakes) {
            h.raise(brake, now);
          }
          return p.copyWith(held: h.encode());
        });
      }
    });
    final rekeyed = reKeys.length;
    if (rekeyed > 0) debugPrint('[myemail] contacts: $rekeyed Gmail re-keys');
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

  /// A create landed: its row saved and its journal entry cleared in one.
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
    await store.completeCreates({op.opId: link});
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
        await _refusedPair(p, gAnswer: gAnswer, hAnswer: hAnswer);
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
    final writtenH = hAnswer == null ? null : GraphContact.fromJson(hAnswer);
    if (writtenH != null && (!writtenH.readWhole || writtenH.details.isEmpty)) {
      // A write's answer that lacks a property cannot stand for the
      // contact; read it whole instead.
      final fresh = await this.graph((a) => a.get(p.graphId!));
      if (fresh == null || !_inContacts(fresh)) return null;
      graph = GraphContact.fromJson(fresh);
      if (!graph.readWhole || graph.details.isEmpty) return null;
      return p.replan(google: google, graph: graph);
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
  Future<void> _refusedPair(
    ContactLinkPlan p, {
    Map<String, Object?>? gAnswer,
    Map<String, Object?>? hAnswer,
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
  Future<void> _delete(ContactLinkPlan p) async {
    final d = p.delete!;
    final onGoogle = d.side == ContactSide.google;
    final full = onGoogle
        ? await google((a) => a.get(d.contactId, everyField: true))
        : await graph((a) => a.get(d.contactId, whole: true));
    final already = await store.binEntry(pairId, d.side, d.contactId);
    if (full == null) {
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
      });
      return;
    }
    final version = onGoogle
        ? googleContactEtag(full)
        : full['changeKey'] as String?;
    final expected = d.expectedVersion;
    final moved = !onGoogle && !_inContacts(full);
    if ((expected != null && version != expected) || moved) {
      // Changed since it was last synced: kept, and Ron is asked.
      await store.transaction(() async {
        await store.saveLink(_linkOf(p.keptInstead()));
        await _saveReview(p.keptReview());
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
      final tag = read == null ? null : GraphContactsApi.tagOf(read);
      if (tag == null || tag == name) return;
      final answer = await graph((a) => a.update(id, graphTagPatch(name)));
      sync._tags[id] = (changeKey: answer['changeKey'] as String?, tag: name);
      final link = await store.linkFor(pairId, ContactSide.graph, id);
      if (link != null && answer['changeKey'] is String) {
        // The patch moved its changeKey: kept, so a later delete does not
        // read the sync's own write as a change.
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

  Future<void> _restore(ContactRestorePlan r, Set<String> labels) async {
    final entry = bin.firstWhereOrNull((b) => b.binId == r.binId);
    if (entry == null) return;
    String? g = r.googleName;
    String? h = r.graphId;
    Map<String, Object?>? gMade;
    Map<String, Object?>? hMade;
    // Tagged with the ids the bin row names, which is how the next run
    // finds them back should this one stop between the two creates.
    if (r.googleRaw case final raw?) {
      gMade = await google<Map<String, Object?>>(
        (a) => a.create(
          googleRestoreBody(raw, labelsThatExist: labels),
          tag: entry.partnerId,
        ),
      );
      g = gMade['resourceName'] as String?;
    }
    if (r.graphRaw case final raw?) {
      hMade = await graph<Map<String, Object?>>(
        (a) => a.create(graphRestoreBody(raw), tag: entry.partnerId),
      );
      h = hMade['id'] as String?;
    }
    if (r.googleDetails case final details? when g == null) {
      gMade = await google<Map<String, Object?>>(
        (a) => a.create(googleCreateBody(details), tag: entry.contactId),
      );
      g = gMade['resourceName'] as String?;
    }
    if (r.graphDetails case final details? when h == null) {
      hMade = await graph<Map<String, Object?>>(
        (a) => a.create(graphCreateBody(details), tag: entry.contactId),
      );
      h = hMade['id'] as String?;
    }
    if (gMade != null) googleMade++;
    if (hMade != null) graphMade++;
    tally.restored++;
    // One found back rather than made is paired as it is now.
    var googleNow = gMade ?? (g == null ? null : googleRead[g]);
    var graphNow = hMade ?? (h == null ? null : graphRead[h]);
    if (googleNow == null && g != null) {
      googleNow = await google((a) => a.get(g!));
    }
    if (graphNow == null && h != null) {
      graphNow = await graph((a) => a.get(h!));
    }
    final googleName = g;
    final graphId = h;
    final googleOne = googleNow;
    final graphOne = graphNow;
    await store.transaction(() async {
      await store.dropBin([r.binId]);
      if (googleName == null ||
          graphId == null ||
          googleOne == null ||
          graphOne == null) {
        return;
      }
      await store.deleteLinks(r.alsoRemove);
      await store.saveLink(
        ContactLink(
          linkId: r.linkId,
          pairId: pairId,
          googleName: googleName,
          graphId: graphId,
          googleEtag: googleContactEtag(googleOne),
          graphChangeKey: graphOne['changeKey'] as String?,
          googleBase: _encode(syncedFromPerson(googleOne)),
          graphBase: _encode(syncedFromGraph(graphOne)),
          state: ContactLinkState.paired,
          googleWrittenAt: gMade != null ? now : null,
        ),
      );
    });
  }

  // --- the end ---------------------------------------------------------------

  /// Everything read was applied: the feeds' positions move on, with the
  /// counts, the result and the claim.
  Future<void> _finish() async {
    final firstSync = pair.firstDoneAt == null;
    final at = sync._now();
    final outcomes = plan.answers;
    // Answers a stopped run had planned and this one could not: kept.
    final waitingPending = <Map<String, Object?>>[
      for (final (i, source) in answerSources.indexed)
        if (source.pendingIndex case final at?
            when i < outcomes.length &&
                outcomes[i] == ContactAnswerOutcome.waiting &&
                at < held.pending.length)
          held.pending[at],
    ];
    final answeredQuestions = <int>{
      for (final (i, source) in answerSources.indexed)
        if (source.questionId case final id?
            when i < outcomes.length &&
                outcomes[i] != ContactAnswerOutcome.waiting)
          id,
    };
    final rows = await store.links(pairId);
    final tallyNow = tally.toTally(at, complete: true);
    await store.updatePair(pairId, (p) {
      final h = _Held.parse(p.held);
      h.pending
        ..clear()
        ..addAll(waitingPending);
      h.questions.removeWhere(
        (q) =>
            answeredQuestions.contains(q.id) ||
            q.kind == ContactSyncQuestionKind.emptyAnswer,
      );
      h.prune(rows);
      h.passedOver
        ..clear()
        ..addAll(plan.graphPassedOver);
      h.quotaUntil = null;
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
  Future<void> _halted(Object e) async {
    final at = sync._now();
    final halt = haltFor(e, at);
    final partial = tally.toTally(at, complete: false);
    try {
      await store.updatePair(pairId, (p) {
        final h = _Held.parse(p.held);
        if (halt.kind == ContactSyncHaltKind.quota) h.quotaUntil = halt.until;
        final before = _LastResult.parse(p.lastResult);
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
      pendingIndex = null;
  const _AnswerSource.question(int this.questionId)
    : reviewId = null,
      pendingIndex = null;
  const _AnswerSource.pending(int this.pendingIndex)
    : reviewId = null,
      questionId = null;

  final int? reviewId;
  final int? questionId;
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
    return held;
  }

  final List<_Question> questions = [];
  final List<Map<String, Object?>> pending = [];
  final List<String> passedOver = [];
  DateTime? quotaUntil;
  DateTime? noticeSeenAt;

  int get _nextId =>
      questions.fold(0, (n, q) => q.id > n ? q.id : n) + 1;

  /// A brake raised this run: added to its kind's open question, or asked
  /// anew where that one already has an answer queued.
  void raise(ContactBrake brake, DateTime at) {
    final kind = brake.kind == ContactBrakeKind.deletions
        ? ContactSyncQuestionKind.deletions
        : ContactSyncQuestionKind.changes;
    final items = [for (final i in brake.items) i.toJson()];
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
  });
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
          if (i is Map) i.cast<String, Object?>(),
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

  ContactSyncQuestion shown() => ContactSyncQuestion(
    kind: kind,
    items: [
      for (final i in items)
        ContactSyncQuestionItem(
          title: i['title'] as String? ?? '',
          side: _sideOf(i['side']) ?? ContactSide.google,
        ),
    ],
    side: side,
    listed: listed,
    expected: expected,
    answer: answer,
  );
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
