import 'dart:async';

import 'package:myemail/data/mail_engine.dart';

/// A [ContactSyncService] for the screen and the shell: a status set by the
/// test, the accounts' access, and a record of every call.
///
/// [startIfDue] keeps the runner's own rule, so a test can show the shell's
/// part in it: a run when the first sync was started and the last completed
/// one is [ContactSyncStatus.dueAfter] old by [now], or the first sync is
/// unfinished.
class FakeContactSync implements ContactSyncService {
  FakeContactSync({
    ContactSyncStatus status = const ContactSyncStatus(),
    Map<String, ContactSyncAccess>? access,
    this.previewAnswer = const ContactSyncPreview(),
    this.backupFiles = const [],
  })  : current = status,
        accessFor = access ?? {};

  /// What [status] answers; [set] changes it.
  ContactSyncStatus current;

  /// Each account's access, by id; unknown ones are allowed.
  final Map<String, ContactSyncAccess> accessFor;

  ContactSyncPreview previewAnswer;
  Object? previewFailure;

  /// What [choose] throws, as the runner refuses a pair while a run is
  /// going or for an account that cannot sync.
  Object? chooseFailure;

  /// What [answerQuestion] throws, as the runner refuses an answer to a
  /// question that has changed since it was drawn.
  Object? answerFailure;

  /// What [backup] throws, as when an address book cannot be read.
  Object? backupFailure;

  /// What [answerCopies] throws, as the runner refuses an answer for a
  /// person or a copy no longer listed.
  Object? copiesFailure;
  List<ContactSyncBackupFile> backupFiles;

  /// The clock [startIfDue] judges by.
  DateTime now = DateTime.now();

  final _changes = StreamController<void>.broadcast();

  /// Every call, by name, in order.
  final List<String> calls = [];
  final List<({String google, String graph})> chosen = [];
  final List<(ContactSyncQuestionKind, ContactSyncChoice)> questionAnswers =
      [];

  /// The items each answer to a question named, in step with
  /// [questionAnswers]: null for the whole question.
  final List<Set<String>?> questionItems = [];
  final List<({int id, ContactSyncChoice choice, String? candidateId})>
      lookAnswers = [];
  final List<ContactSyncChoice> allDiffering = [];
  final List<int> restored = [];

  /// Each [answerCopies] call: the person, and the copy kept (null: leave
  /// them).
  final List<({String person, String? keep})> copiesAnswers = [];
  final List<DateTime> noticesSeen = [];
  final List<String> accessAsked = [];

  /// Runs [startIfDue] started.
  int runs = 0;

  /// How many times [status] was read.
  int statusReads = 0;

  /// Holds [start] until completed, as a first sync takes its time.
  Completer<void>? startGate;

  int count(String call) => calls.where((c) => c == call).length;

  /// A new status, as the runner would say one.
  void set(ContactSyncStatus status) {
    current = status;
    _changes.add(null);
  }

  @override
  Future<ContactSyncStatus> status() async {
    statusReads++;
    return current;
  }

  @override
  Stream<void> get changed => _changes.stream;

  @override
  Future<ContactSyncAccess> access(String accountId) async {
    accessAsked.add(accountId);
    return accessFor[accountId] ??
        const ContactSyncAccess(ContactSyncAccessState.allowed);
  }

  @override
  Future<void> choose({
    required String googleAccountId,
    required String graphAccountId,
  }) async {
    calls.add('choose');
    if (chooseFailure case final failure?) throw failure;
    chosen.add((google: googleAccountId, graph: graphAccountId));
    set(copy(current, google: googleAccountId, graph: graphAccountId));
  }

  @override
  Future<ContactSyncPreview> preview() async {
    calls.add('preview');
    if (previewFailure case final failure?) throw failure;
    return previewAnswer;
  }

  @override
  Future<List<ContactSyncBackupFile>> backup() async {
    calls.add('backup');
    if (backupFailure case final failure?) throw failure;
    return backupFiles;
  }

  @override
  Future<void> start() async {
    calls.add('start');
    await startGate?.future;
  }

  @override
  Future<void> syncNow() async => calls.add('syncNow');

  @override
  Future<bool> startIfDue() async {
    calls.add('startIfDue');
    final s = current;
    final last = s.lastDoneAt;
    final due = s.firstStarted &&
        (s.firstUnfinished ||
            last == null ||
            now.difference(last) >= ContactSyncStatus.dueAfter);
    if (!due) return false;
    runs++;
    set(copy(s, lastDoneAt: now));
    return true;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> answerQuestion(
    ContactSyncQuestionKind kind,
    ContactSyncChoice choice, {
    Set<String>? items,
  }) async {
    calls.add('answerQuestion');
    if (answerFailure case final failure?) throw failure;
    questionAnswers.add((kind, choice));
    questionItems.add(items);
  }

  @override
  Future<void> answerLook(
    int lookId,
    ContactSyncChoice choice, {
    String? candidateId,
  }) async {
    calls.add('answerLook');
    lookAnswers.add((id: lookId, choice: choice, candidateId: candidateId));
  }

  @override
  Future<void> answerAllDiffering(ContactSyncChoice choice) async {
    calls.add('answerAllDiffering');
    allDiffering.add(choice);
  }

  @override
  Future<void> restore(int deletedId) async {
    calls.add('restore');
    restored.add(deletedId);
  }

  @override
  Future<void> syncHere() async => calls.add('syncHere');

  @override
  Future<void> mergeCopies() async => calls.add('mergeCopies');

  @override
  Future<void> answerCopies(String person, String? keep) async {
    calls.add('answerCopies');
    if (copiesFailure case final failure?) throw failure;
    copiesAnswers.add((person: person, keep: keep));
  }

  @override
  Future<void> answerAllCopies() async => calls.add('answerAllCopies');

  @override
  Future<void> noticeSeen(DateTime at) async {
    calls.add('noticeSeen');
    noticesSeen.add(at);
    if (current.notice?.at == at) set(copy(current, dropNotice: true));
  }

  /// [s] with the accounts, the last completed run or the notice changed.
  static ContactSyncStatus copy(
    ContactSyncStatus s, {
    String? google,
    String? graph,
    DateTime? lastDoneAt,
    bool dropNotice = false,
  }) =>
      ContactSyncStatus(
        googleAccountId: google ?? s.googleAccountId,
        graphAccountId: graph ?? s.graphAccountId,
        firstStartedAt: s.firstStartedAt,
        firstDoneAt: s.firstDoneAt,
        lastAttemptAt: s.lastAttemptAt,
        lastDoneAt: lastDoneAt ?? s.lastDoneAt,
        running: s.running,
        last: s.last,
        halt: s.halt,
        questions: s.questions,
        needsALook: s.needsALook,
        recentlyDeleted: s.recentlyDeleted,
        googleCount: s.googleCount,
        graphCount: s.graphCount,
        notice: dropNotice ? null : s.notice,
        duplicates: s.duplicates,
        copies: s.copies,
      );
}
