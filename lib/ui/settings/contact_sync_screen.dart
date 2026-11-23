import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/microsoft_oauth.dart' show MicrosoftOAuth;
import '../../data/mail_engine.dart';
import '../../domain/account.dart';
import '../../domain/error_report.dart';
import '../../state/backup_providers.dart';
import '../../state/contact_providers.dart';
import '../../state/providers.dart' show accountsProvider, mailEngineProvider;
import '../accounts/google_sign_in_screen.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import '../common/bottom_message.dart';
import '../common/problem_view.dart';
import '../messages/date_format.dart';
import '../shell/put_away.dart' show isInFront;

/// Settings, Contact sync: Gmail's contacts and a Microsoft account's
/// (Hadco's) kept the same, both ways, by the engine's runner.
///
/// One screen, one subject, like Sync: the switch for this device, the two
/// accounts and whether each allows it, then the first sync's preview,
/// backup and Start, or how the last sync went with Sync now; the brakes'
/// questions; Needs a look and Recently deleted, each on a screen of its
/// own; the counts, for checking; and what to do before an undo in bulk.
/// Nothing here runs a sync but Start and Sync now: the shell starts the
/// rest, and the runner, which outlives this screen, carries them out.
class ContactSyncScreen extends ConsumerStatefulWidget {
  const ContactSyncScreen({super.key});

  /// Whether the screen is open and in front, its own route the current
  /// one: the shell's one-line message about a stop says nothing this
  /// screen is not already showing. Under a screen pushed over it
  /// (Duplicates to merge, Needs a look, Recently deleted, a sign-in),
  /// which shows no stop, it is not, and the message is said there.
  static bool get isOpen => _open.any((s) => s._inFront);
  static final Set<_ContactSyncScreenState> _open = {};

  @override
  ConsumerState<ContactSyncScreen> createState() => _ContactSyncScreenState();
}

class _ContactSyncScreenState extends ConsumerState<ContactSyncScreen> {
  /// Accounts picked here, before the runner has them as its pair.
  String? _pickedGoogle;
  String? _pickedGraph;

  /// Accounts whose Allow is under way.
  final Set<String> _allowing = {};

  /// Gmail accounts signed in again from here: still not allowed after it
  /// means Contacts was left unticked, which Google's consent lets happen.
  final Set<String> _signedInHere = {};

  bool _previewing = false;
  Object? _previewError;
  bool _saving = false;

  /// Start was tapped, and its run has not ended: a second tap, before the
  /// status has caught up, must not ask for a second first sync.
  bool _starting = false;
  Object? _backupError;
  String? _backupSaid;

  /// The Save backup that [_backupError] or [_backupSaid] came from: its
  /// pair, and whether it was the first sync's. Shown only under that
  /// button, so that the first sync's message never stands under the later
  /// one once Start has gone, nor one pair's under another's.
  ({String pair, bool forStart})? _backupFor;

  /// The brakes' questions shown during this visit, each where it was
  /// first shown ([_cards]), and the pair they are of.
  final List<_ShownQuestion> _shownQuestions = [];
  (String?, String?)? _shownFor;

  ContactSyncService get _sync => ref.read(mailEngineProvider).contactSync;

  /// The screen's own route, for [ContactSyncScreen.isOpen].
  ModalRoute<Object?>? _route;

  bool get _inFront => mounted && (_route?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    ContactSyncScreen._open.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    ContactSyncScreen._open.remove(this);
    super.dispose();
  }

  /// The two accounts the screen is about: the pair the runner has, while
  /// both are still in MyEmail; else those picked here, else the only one
  /// there is. Null where Ron still has to pick: with no pair yet and two
  /// Microsoft accounts (or two Gmail ones), the screen does not guess
  /// which he means, since Ron's steps never say to check.
  ///
  /// The runner's pair comes first, switched on or off: turning the switch
  /// off and on again (as Ron will before an Undo changes) must carry on
  /// with Gmail and Hadco, never pair Gmail with whichever Microsoft
  /// account happens to be listed first.
  (Account?, Account?) _pair(List<Account> accounts, ContactSyncStatus? s) {
    final googles = _googleAccounts(accounts);
    final graphs = _graphAccounts(accounts);
    final (runnerGoogle, runnerGraph) = _runnerPair(accounts, s);
    if (runnerGoogle != null && runnerGraph != null) {
      return (runnerGoogle, runnerGraph);
    }
    return (
      _byId(googles, _pickedGoogle) ?? googles.singleOrNull,
      _byId(graphs, _pickedGraph) ?? graphs.singleOrNull,
    );
  }

  /// The runner's pair made [google] and [graph], if it is not already.
  Future<void> _choose(Account google, Account graph) async {
    final sync = _sync;
    final status = await sync.status();
    if (status.googleAccountId == google.id &&
        status.graphAccountId == graph.id) {
      return;
    }
    await sync.choose(googleAccountId: google.id, graphAccountId: graph.id);
  }

  /// The switch alone: it never chooses a pair. Off and on again carries on
  /// with the pair the runner has; a pair is chosen only by a pick, or by
  /// Preview, Save backup or Start.
  Future<void> _setOn(bool on) =>
      ref.read(contactSyncOnProvider.notifier).set(on);

  Future<void> _pick({
    required bool google,
    required List<Account> from,
    required Account? current,
    required Account? other,
  }) async {
    final picked = await showDialog<Account>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(google ? 'Which Gmail account' : 'Sync Gmail with'),
        children: [
          for (final a in from)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(a),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(contactSyncAccountName(a)),
                        Text(
                          a.emailAddress,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (a.id == current?.id) const Icon(Icons.check, size: 20),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted || picked.id == current?.id) return;
    final g = google ? picked : other;
    final m = google ? other : picked;
    if (g == null || m == null) {
      // The other account is still to be picked: nothing can be chosen
      // yet, and nothing is replaced, since there is no pair.
      setState(() => _hold(picked, google: google));
      return;
    }
    // A pair whose first sync has started is replaced only when Ron says
    // so: it stops syncing, and what it holds is set aside with it.
    final sync = _sync;
    final status = await sync.status();
    if (!mounted) return;
    final (runnerGoogle, runnerGraph) = _runnerPair(
      ref.read(accountsProvider).value ?? const <Account>[],
      status,
    );
    if (runnerGoogle != null &&
        runnerGraph != null &&
        status.firstStarted &&
        !await _sureToReplace(
          from: (runnerGoogle, runnerGraph),
          to: (g, m),
        )) {
      return;
    }
    // Taken up only once the runner has it: a pick it refuses (a run
    // going, an account that cannot sync) leaves the screen on the pair
    // it has, with its questions and its answers.
    try {
      await sync.choose(googleAccountId: g.id, graphAccountId: m.id);
      if (mounted) {
        setState(() {
          _pickedGoogle = null;
          _pickedGraph = null;
        });
      }
    } catch (e) {
      if (mounted) _sayFailure(context, e);
    }
  }

  void _hold(Account picked, {required bool google}) {
    if (google) {
      _pickedGoogle = picked.id;
    } else {
      _pickedGraph = picked.id;
    }
  }

  /// Whether Ron wants pair [from], whose first sync has started, replaced
  /// by [to].
  Future<bool> _sureToReplace({
    required (Account, Account) from,
    required (Account, Account) to,
  }) async {
    final (_, oldGraph) = from;
    final (newGoogle, newGraph) = to;
    final oldName = contactSyncAccountName(oldGraph);
    final sameGraph = newGraph.id == oldGraph.id;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('contact-sync-replace'),
        title: Text(
          sameGraph
              ? 'Sync ${newGoogle.emailAddress} with $oldName instead?'
              : 'Sync Gmail with ${contactSyncAccountName(newGraph)} '
                  'instead?',
        ),
        content: Text(
          'Gmail and $oldName stop syncing. Their Needs a look and Recently '
          'deleted are set aside, and come back if you choose them again; '
          'no contact is deleted. The new pair starts with a first sync of '
          'its own.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Switch accounts'),
          ),
        ],
      ),
    );
    return sure ?? false;
  }

  /// A sign-in that asks for the contacts beside the mail, as View's
  /// address books do: Microsoft's with the contacts permission added, so
  /// that where the organisation decides, the sign-in sends it the request;
  /// Google's whole, since an installed app cannot add a permission to a
  /// sign-in it has. A Gmail account on an app password moves to Google
  /// sign-in by it. The account keeps everything cached.
  Future<void> _allow(Account account) async {
    final messenger = ScaffoldMessenger.of(context);
    final accountsNotifier = ref.read(accountsProvider.notifier);
    setState(() => _allowing.add(account.id));
    try {
      switch (account.provider) {
        case MailProvider.outlook:
          final token = await MicrosoftSignInScreen.show(
            context,
            loginHint: account.emailAddress,
            scopes: [
              ...MicrosoftOAuth.scopes,
              ...MicrosoftOAuth.contactSyncScopes,
            ],
          );
          if (token == null) return;
          await accountsNotifier.signInAgain(
            accountId: account.id,
            token: token,
          );
        case MailProvider.gmail:
          final result = await GoogleSignInScreen.show(
            context,
            loginHint: account.emailAddress,
          );
          if (result == null) return;
          await accountsNotifier.signInAgain(
            accountId: account.id,
            token: result.token,
            signedInAs: result.identity?.email,
          );
          _signedInHere.add(account.id);
      }
    } catch (e) {
      // Queued, never in place of what is there: perhaps a send's Undo.
      messenger.showSnackBar(SnackBar(
        duration: kBottomMessage,
        content: Text(e is ReadableError ? e.message : '$e'),
      ));
    } finally {
      if (mounted) {
        ref.invalidate(contactSyncAccessProvider(account.id));
        setState(() => _allowing.remove(account.id));
      }
    }
  }

  Future<void> _preview(Account google, Account graph) async {
    final steps = ref.read(contactSyncFirstStepsProvider.notifier);
    final sync = _sync;
    setState(() {
      _previewing = true;
      _previewError = null;
    });
    try {
      await _choose(google, graph);
      final preview = await sync.preview();
      steps.previewed(
        ContactSyncFirstSteps.pairKey(google.id, graph.id),
        preview,
      );
    } catch (e) {
      if (mounted) setState(() => _previewError = e);
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  /// Both address books read in full and saved as two files, each where
  /// Ron chooses: a vCard Google Contacts imports, and Outlook's CSV.
  /// [forStart]: the first sync's backup, which Start waits for; else one
  /// saved later, whenever Ron wants a copy.
  Future<void> _saveBackup(
    Account google,
    Account graph,
    String graphName, {
    bool forStart = true,
  }) async {
    final steps = ref.read(contactSyncFirstStepsProvider.notifier);
    final files = ref.read(backupFilesProvider);
    final sync = _sync;
    final pair = ContactSyncFirstSteps.pairKey(google.id, graph.id);
    setState(() {
      _saving = true;
      _backupError = null;
      _backupSaid = null;
      _backupFor = (pair: pair, forStart: forStart);
    });
    try {
      await _choose(google, graph);
      final backup = await sync.backup();
      final saved = <ContactSyncBackupFile>[];
      for (final file in backup) {
        final ok = await files.save(
          fileName: file.fileName,
          contents: file.contents,
          mimeType: file.mimeType,
          dialogTitle:
              "Save ${_sideName(file.side, graphName)}'s contacts",
        );
        if (!ok) continue;
        saved.add(file);
        if (forStart) steps.backupSaved(pair, file.side);
      }
      // Two tries that saved one file each have saved both: said when both
      // are from the last hour, else left to the note under Start.
      final kept = steps.of(pair);
      final both = forStart && kept.backupSaved;
      final fresh = forStart && kept.backupFresh(DateTime.now());
      if (mounted) {
        setState(
          () => _backupSaid = _savedSaid(
            saved,
            forStart: forStart,
            both: both,
            fresh: fresh,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _backupError = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// What was saved. Both files are one for each side, whatever number
  /// of files the runner handed over; [both]: the first sync's two files
  /// are saved, counting one an earlier Save backup saved, and [fresh]:
  /// both within the hour.
  static String? _savedSaid(
    List<ContactSyncBackupFile> saved, {
    required bool forStart,
    bool both = false,
    bool fresh = false,
  }) {
    if (saved.isEmpty) return null;
    String one(ContactSyncBackupFile f) =>
        '${f.fileName}, ${_count(f.count, 'contact', 'contacts')}, which '
        '${f.side == ContactSide.google ? 'Google Contacts' : 'Outlook on the web'} '
        'can import';
    final said = 'Saved ${saved.map(one).join(', and ')}.';
    if ({for (final f in saved) f.side}.length == ContactSide.values.length) {
      return said;
    }
    if (!forStart) {
      return '$said The other file was not saved: Save backup again for both.';
    }
    if (fresh) return '$said Both files are saved.';
    // Both, but one over an hour old: the note under Start says so.
    if (both) return said;
    return '$said Start sync needs both files: Save backup again.';
  }

  Future<void> _start(Account google, Account graph) async {
    final sync = _sync;
    // The screen may have stood open since the button was last drawn.
    final steps = ref
        .read(contactSyncFirstStepsProvider.notifier)
        .of(ContactSyncFirstSteps.pairKey(google.id, graph.id));
    if (!steps.readyAt(DateTime.now())) {
      setState(() {});
      return;
    }
    setState(() => _starting = true);
    try {
      await _choose(google, graph);
    } catch (e) {
      if (mounted) {
        setState(() => _starting = false);
        _sayFailure(context, e);
      }
      return;
    }
    // Completes when the run ends, and never throws: the status shows it.
    unawaited(sync.start().whenComplete(() {
      if (mounted) setState(() => _starting = false);
    }));
  }

  void _syncNow() => unawaited(_sync.syncNow());

  @override
  Widget build(BuildContext context) {
    final on = ref.watch(contactSyncOnProvider);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    // Read while off too, for the pair the runner has.
    final statusValue = ref.watch(contactSyncStatusProvider);
    final status = statusValue.value;
    final (google, graph) = _pair(accounts, status);
    final (runnerGoogle, runnerGraph) = _runnerPair(accounts, status);
    final carriesOn = runnerGoogle == null || runnerGraph == null
        ? ''
        : 'syncing Gmail with ${contactSyncAccountName(runnerGraph)} ';

    return Scaffold(
      appBar: AppBar(title: const Text('Contact sync'), centerTitle: false),
      body: _Body(
        children: [
          const _Para(
            "Keeps your Gmail contacts and a Microsoft account's the same, "
            'both ways: a contact added, changed or deleted on one side is '
            'added, changed or deleted on the other. It runs when MyEmail '
            'is opened, at most once an hour, and with Sync now; never '
            'while MyEmail is closed. Photos, labels and categories stay '
            'where they are.',
            top: 16,
          ),
          SwitchListTile(
            key: const ValueKey('contact-sync-on'),
            title: const Text('Sync contacts on this device'),
            subtitle: const Text(
              'Turn it on on one device only. Each device keeps its own '
              'record of what it paired and deleted, so two would work '
              'against each other.',
            ),
            isThreeLine: true,
            value: on,
            onChanged: _setOn,
          ),
          if (!on)
            _Para(
              'Off: nothing syncs on this device. Turning it off deletes '
              'nothing, and turning it on again carries on ${carriesOn}where '
              'it stopped.',
              key: const ValueKey('contact-sync-off'),
              muted: true,
            )
          else if (_googleAccounts(accounts).isEmpty ||
              _graphAccounts(accounts).isEmpty)
            const _Para(
              'Contact sync needs a Gmail account and a Microsoft account '
              'in MyEmail. Add them in Settings, Accounts.',
            )
          else
            ..._onFor(accounts, statusValue, google, graph),
          if (on)
            const _Para(
              "Turn this off before using Google's Undo changes, Outlook's "
              'Recover deleted items or a backup file.',
              muted: true,
              top: 20,
            ),
        ],
      ),
    );
  }

  List<Widget> _onFor(
    List<Account> accounts,
    AsyncValue<ContactSyncStatus> statusValue,
    Account? google,
    Account? graph,
  ) {
    final googles = _googleAccounts(accounts);
    final graphs = _graphAccounts(accounts);
    final graphName = contactSyncAccountName(graph);
    final s = statusValue.value;
    // The runner's state is this pair's only once it has them; before that
    // the screen offers the first sync for the accounts shown.
    final ours = s != null &&
        google != null &&
        graph != null &&
        s.googleAccountId == google.id &&
        s.graphAccountId == graph.id;
    return [
      if (googles.length > 1)
        ListTile(
          key: const ValueKey('contact-sync-google'),
          title: const Text('Gmail account'),
          subtitle: Text(google?.emailAddress ?? 'Choose the Gmail account'),
          trailing: const Icon(Icons.arrow_drop_down),
          onTap: () => _pick(
            google: true,
            from: googles,
            current: google,
            other: graph,
          ),
        ),
      ListTile(
        key: const ValueKey('contact-sync-with'),
        title: const Text('Sync Gmail with'),
        subtitle: Text(
          graph == null ? 'Choose the Microsoft account' : graphName,
        ),
        trailing: graphs.length > 1 ? const Icon(Icons.arrow_drop_down) : null,
        onTap: graphs.length > 1
            ? () => _pick(
                  google: false,
                  from: graphs,
                  current: graph,
                  other: google,
                )
            : null,
      ),
      for (final account in [?google, ?graph])
        _AccessRow(
          account: account,
          busy: _allowing.contains(account.id),
          leftOut: _signedInHere.contains(account.id),
          onAllow: () => _allow(account),
        ),
      const Divider(height: 24),
      if (s == null)
        switch (statusValue) {
          AsyncError(:final error) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ProblemView(
                problem: ProblemReport(
                  doing: 'Reading where contact sync stands',
                  error: error,
                ),
              ),
            ),
          _ => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
        }
      else if (ours && s.isRunning)
        ..._running(s.running!, graphName)
      else ...[
        // Why the runner's pair stopped, first sync or not: a stop before
        // Start's first write (access, the other device, the network)
        // must show as plainly as one after it, and above the result, so
        // that "Synced at" over it does not read as all well.
        if (ours)
          if (s.halt case final halt?
              when halt.kind != ContactSyncHaltKind.putAway)
            ..._halt(s, halt, google, graph, graphName),
        if (!ours || !s.firstStarted)
          ..._firstSync(google, graph, graphName)
        else
          ..._lastResult(s, google, graph, graphName),
      ],
      if (s != null && ours) ...[
        for (final card in _cards(s))
          _QuestionCard(
            question: card.question,
            listed: card.listed,
            shown: card.shown,
            graphName: graphName,
            onAnswer: (choice, {items}) => _act(
              context,
              () => _sync.answerQuestion(
                card.question.kind,
                choice,
                items: items,
              ),
              // Refused, perhaps because the question changed since it was
              // drawn: said, and read again, to be answered as it is now.
              onFailure: () {
                if (mounted) ref.invalidate(contactSyncStatusProvider);
              },
            ),
          ),
        if (s.firstStarted ||
            s.needsALook.isNotEmpty ||
            s.recentlyDeleted.isNotEmpty ||
            s.duplicates.isNotEmpty) ...[
          ListTile(
            key: const ValueKey('contact-sync-looks'),
            minVerticalPadding: 10,
            leading: const Icon(Icons.rate_review_outlined),
            title: Text('Needs a look (${s.needsALook.length})'),
            subtitle: const Text(
              'Contacts the sync could not settle on its own',
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _push(const _LooksScreen()),
          ),
          // Copies of one person: not questions, so not among Needs a
          // look, and a row only while there are some to merge.
          if (s.duplicates.isNotEmpty)
            ListTile(
              key: const ValueKey('contact-sync-duplicates'),
              minVerticalPadding: 10,
              leading: const Icon(Icons.people_outline),
              title: Text(
                'Duplicates to merge when you like '
                '(${_count(s.duplicates.length, 'person', 'people')})',
              ),
              subtitle: const Text(
                'Copies of the same person: one on each side is synced, the '
                'others are left as they are',
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => _push(const _DuplicatesScreen()),
            ),
          ListTile(
            key: const ValueKey('contact-sync-deleted'),
            minVerticalPadding: 10,
            leading: const Icon(Icons.restore_from_trash_outlined),
            title: Text('Recently deleted (${s.recentlyDeleted.length})'),
            subtitle: const Text(
              'What the sync deleted in the last 30 days, with Restore',
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _push(const _DeletedScreen()),
          ),
        ],
        if (s.googleCount != null || s.graphCount != null)
          _Para(
            'As the sync counts them, Gmail has '
            '${_count(s.googleCount ?? 0, 'contact', 'contacts')} and '
            '$graphName has ${s.graphCount ?? 0}: for checking against '
            'Google Contacts and Outlook on the web.',
            muted: true,
            top: 12,
          ),
        // A backup whenever Ron wants one, not only before the first sync:
        // the same two files, named with the day.
        if (s.firstStarted) ...[
          _Buttons([
            OutlinedButton.icon(
              key: const ValueKey('contact-sync-backup-later'),
              onPressed: _saving
                  ? null
                  : () => _saveBackup(
                        google,
                        graph,
                        graphName,
                        forStart: false,
                      ),
              icon: const Icon(Icons.save_alt),
              label: const Text('Save backup'),
            ),
          ]),
          const _Para(
            'Two files, one Google Contacts can import and one Outlook on the '
            'web can import.',
            muted: true,
          ),
          if (_saving && _backupFrom(google, graph, forStart: false))
            const _Working(),
          if (_backupError case final e?
              when _backupFrom(google, graph, forStart: false))
            _Problem(
              doing: 'Saving the contacts backup',
              error: e,
              onRemedy: _remedy(
                e,
                google,
                graph,
                () => _saveBackup(google, graph, graphName, forStart: false),
              ),
            ),
          if (_backupSaid case final said?
              when _backupFrom(google, graph, forStart: false))
            _Para(said, key: const ValueKey('contact-sync-backup-said')),
        ],
      ],
    ];
  }

  /// The last Save backup's message is this pair's, and this button's.
  bool _backupFrom(Account google, Account graph, {required bool forStart}) =>
      _backupFor ==
      (
        pair: ContactSyncFirstSteps.pairKey(google.id, graph.id),
        forStart: forStart,
      );

  void _push(Widget screen) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => screen),
      );

  /// The brakes' questions as shown: each where it was first shown during
  /// this visit, its contacts in the order first shown. A contact the
  /// runner no longer lists (its answer carried out by the run the answer
  /// started, or no longer held) stays in its place, shown as done, until
  /// the screen is left, and so does a question it no longer lists at all,
  /// so that nothing moves under the finger while Ron answers one by one,
  /// as on Duplicates to merge. Questions and contacts held since go under
  /// them.
  List<_ShownQuestion> _cards(ContactSyncStatus s) {
    final pair = (s.googleAccountId, s.graphAccountId);
    if (_shownFor != pair) {
      _shownFor = pair;
      _shownQuestions.clear();
    }
    final listed = <_ShownQuestion>{};
    for (final q in s.questions) {
      var card = _shownQuestions.firstWhereOrNull(
        (c) => !listed.contains(c) && c.isOf(q),
      );
      if (card == null) {
        card = _ShownQuestion(q);
        _shownQuestions.add(card);
      }
      card.take(q);
      listed.add(card);
    }
    // Gone, with no contact of its own shown (an empty answer's): nothing
    // on it was answered, so nothing stays.
    _shownQuestions.removeWhere((c) => !listed.contains(c) && !c.keeps);
    for (final c in _shownQuestions) {
      c.listed = listed.contains(c);
    }
    return _shownQuestions;
  }

  /// Before the first sync: the preview, the backup, and Start, greyed out
  /// until both are done; all three greyed out until both accounts are
  /// known.
  List<Widget> _firstSync(Account? google, Account? graph, String graphName) {
    final both = google != null && graph != null;
    final all = ref.watch(contactSyncFirstStepsProvider);
    final steps = both &&
            all.pair == ContactSyncFirstSteps.pairKey(google.id, graph.id)
        ? all
        : const ContactSyncFirstSteps();
    final preview = steps.preview;
    final now = DateTime.now();
    final ready = both && steps.readyAt(now);
    final mine = both && _backupFrom(google, graph, forStart: true);
    final backupSaid = (mine ? _backupSaid : null) ??
        switch (steps.saved.keys.toList()) {
          [] => null,
          [final side] => "${_sideName(side, graphName)}'s file is saved. "
              'Start sync needs both files: Save backup again.',
          _ => 'Both files are saved.',
        };
    // Why Start is greyed out, in Ron's order of steps: a preview or a
    // backup from over an hour ago is of the address books as they were.
    final whyNotYet = [
      if (preview == null)
        'Start sync is ready once you have seen the preview and saved both '
            'backup files.'
      else if (!steps.backupSaved)
        'Start sync is ready once you have saved both backup files.',
      if (preview != null && !steps.previewFresh(now))
        'The preview is over an hour old, and the address books may have '
            'changed since: Preview again.',
      if (steps.backupSaved && !steps.backupFresh(now))
        'The backup files are over an hour old: Save backup again, so that '
            'they hold the address books as they are now.',
    ].join(' ');
    return [
      const _Heading('First sync'),
      if (!both)
        const _Para(
          'Choose the accounts to sync first: Preview, Save backup and '
          'Start sync wait for it.',
          key: ValueKey('contact-sync-choose-first'),
          strong: true,
        ),
      const _Para(
        'Nothing changes until you have seen a preview of the first sync. '
        'It deletes nothing, and never overwrites a detail that differs '
        'between the two copies: it lists those under Needs a look '
        'instead.',
      ),
      _Buttons([
        OutlinedButton.icon(
          key: const ValueKey('contact-sync-preview'),
          onPressed:
              _previewing || !both ? null : () => _preview(google, graph),
          icon: const Icon(Icons.visibility_outlined),
          label: Text(preview == null ? 'Preview' : 'Preview again'),
        ),
      ]),
      if (_previewing) const _Working(),
      if (_previewError case final e?)
        _Problem(
          doing: 'Previewing the first contact sync',
          error: e,
          onRemedy: both
              ? _remedy(e, google, graph, () => _preview(google, graph))
              : null,
        ),
      if (preview != null) _PreviewTable(preview: preview, graphName: graphName),
      const _Para(
        'Then save a backup of both address books, as two files: one Google '
        'Contacts can import, one Outlook on the web can import.',
        top: 12,
      ),
      _Buttons([
        OutlinedButton.icon(
          key: const ValueKey('contact-sync-backup'),
          onPressed: _saving || !both
              ? null
              : () => _saveBackup(google, graph, graphName),
          icon: const Icon(Icons.save_alt),
          label: const Text('Save backup'),
        ),
      ]),
      if (_saving && mine) const _Working(),
      if (_backupError case final e? when mine)
        _Problem(
          doing: 'Saving the contacts backup',
          error: e,
          onRemedy: both
              ? _remedy(
                  e,
                  google,
                  graph,
                  () => _saveBackup(google, graph, graphName),
                )
              : null,
        ),
      if (backupSaid != null) _Para(backupSaid),
      // Only once there is a Microsoft account to name: "the Microsoft
      // account's IT" says nothing.
      if (graph != null)
        _Para(
          "Worth knowing: your Gmail contacts will be kept in $graphName's "
          "mailbox too, where $graphName's IT can see them and where they "
          "stay if you leave, and $graphName's contacts will be in your "
          'Gmail. The backup files hold both address books.',
          muted: true,
          top: 12,
        ),
      _Buttons([
        FilledButton.icon(
          key: const ValueKey('contact-sync-start'),
          onPressed:
              ready && !_starting ? () => _start(google, graph) : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start sync'),
        ),
      ]),
      _Para(
        ready
            ? 'Keep MyEmail open until this says Synced. If it is closed '
                'sooner, the first sync carries on the next time MyEmail is '
                'opened.'
            : whyNotYet,
        key: const ValueKey('contact-sync-start-note'),
        muted: true,
      ),
    ];
  }

  /// The first sync's steps taken for [google] and [graph], or none.
  /// Watched while building, read in a tap.
  ContactSyncFirstSteps _stepsFor(
    Account google,
    Account graph, {
    bool watch = true,
  }) {
    final pair = ContactSyncFirstSteps.pairKey(google.id, graph.id);
    final all = watch
        ? ref.watch(contactSyncFirstStepsProvider)
        : ref.read(contactSyncFirstStepsProvider);
    return all.pair == pair ? all : const ContactSyncFirstSteps();
  }

  /// The way out of a failure, where there is one: the account's Allow
  /// for one that has not allowed it, or [again] for one worth trying
  /// again.
  VoidCallback? _remedy(
    Object e,
    Account google,
    Account graph,
    VoidCallback? again,
  ) =>
      switch (e) {
        ContactSyncNeedsSignIn(:final side) => () =>
            _allow(side == ContactSide.google ? google : graph),
        Retryable() => again,
        _ => null,
      };

  List<Widget> _running(ContactSyncProgress running, String graphName) {
    // Counted while it writes, and while it merges the Microsoft side's
    // copies, a person at a time.
    final counted =
        running.step != ContactSyncStep.reading && running.total > 0;
    return [
      _Heading(running.firstSync ? 'First sync' : 'Syncing'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: LinearProgressIndicator(
          key: const ValueKey('contact-sync-progress'),
          value: counted ? running.done / running.total : null,
        ),
      ),
      _Para(switch ((running.step, running.total)) {
        (ContactSyncStep.reading, _) => 'Reading both address books…',
        (ContactSyncStep.writing, 0) => 'Copying changes…',
        (ContactSyncStep.writing, final total) =>
          'Copying changes: ${running.done} of $total',
        (ContactSyncStep.merging, 0) => "Merging $graphName's copies…",
        (ContactSyncStep.merging, final total) =>
          "Merging $graphName's copies: ${running.done} of "
              "${_count(total, 'person', 'people')}",
      }),
      if (running.firstSync)
        const _Para(
          'Keep MyEmail open until this says Synced. If it is closed sooner, '
          'the first sync carries on the next time MyEmail is opened.',
          muted: true,
        ),
    ];
  }

  /// How the last sync went, and Sync now.
  List<Widget> _lastResult(
    ContactSyncStatus s,
    Account google,
    Account graph,
    String graphName,
  ) {
    final now = DateTime.now();
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final last = s.last;
    final line = switch (last) {
      final l? when l.complete => _syncedLine(l, now, use24h, graphName),
      final l? when l.firstSync =>
        'The first sync got ${l.done} of ${l.planned} changes done. It '
            'carries on when MyEmail is open.',
      final l? => 'The last sync stopped ${_when(l.at, now, use24h)}, '
          '${l.done} of ${l.planned} changes done. The next one carries on '
          'from there.',
      null when s.firstUnfinished =>
        'The first sync has not finished. It carries on when MyEmail is '
            'open.',
      null => null,
    };
    // A failure worth trying again offers Try again in Sync now's place,
    // and another device Sync here. A failure that is not worth it offers
    // no Try again, and an empty answer's Keep waiting starts nothing, so
    // Sync now stays for both: there must always be a way on, and after
    // Keep waiting, Sync now is how to look again.
    final halt = s.halt;
    final offersItsOwn = switch (halt?.kind) {
      ContactSyncHaltKind.failed =>
        remedyFor(_failureOf(halt!)) == ErrorRemedy.retry,
      ContactSyncHaltKind.otherDevice => true,
      _ => false,
    };
    return [
      if (line != null) _Para(line, key: const ValueKey('contact-sync-last')),
      if (!offersItsOwn)
        _Buttons([
          FilledButton.tonalIcon(
            key: const ValueKey('contact-sync-now'),
            onPressed: _syncNow,
            icon: const Icon(Icons.sync),
            label: const Text('Sync now'),
          ),
        ]),
    ];
  }

  List<Widget> _halt(
    ContactSyncStatus s,
    ContactSyncHalt halt,
    Account google,
    Account graph,
    String graphName,
  ) {
    final now = DateTime.now();
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final side = _haltSide(halt);
    // Before the first sync has started, Sync here would start it without
    // Start's preview and backup from the last hour.
    final firstGated =
        !s.firstStarted && !_stepsFor(google, graph).readyAt(now);
    final line = _stopLine(s, halt, graphName, now, use24h);
    if (line == null) return const [];
    switch (halt.kind) {
      case ContactSyncHaltKind.notAllowed:
        final account = switch (side) {
          ContactSide.google => google,
          ContactSide.graph => graph,
          null => null,
        };
        return [
          _Para(line),
          if (halt.error case final e?)
            _Problem(
              doing: 'Syncing contacts',
              error: e,
              onRemedy: account == null ? null : () => _allow(account),
            ),
        ];
      case ContactSyncHaltKind.otherDevice:
        return [
          _Para(line, strong: true),
          _Para(_otherDeviceLine(halt, now, use24h)),
          _Buttons([
            OutlinedButton(
              key: const ValueKey('contact-sync-here'),
              onPressed: firstGated
                  ? null
                  : () => _act(context, () async {
                        // Checked again: the screen may have stood open
                        // past the hour since the button was drawn.
                        final steps =
                            _stepsFor(google, graph, watch: false);
                        if (!s.firstStarted &&
                            !steps.readyAt(DateTime.now())) {
                          if (mounted) setState(() {});
                          return;
                        }
                        await _sync.syncHere();
                      }),
              child: const Text('Sync here'),
            ),
          ]),
          if (firstGated)
            const _Para(
              'To sync here instead, see the preview and save the backup '
              'below first.',
              key: ValueKey('contact-sync-here-note'),
              muted: true,
            ),
        ];
      case ContactSyncHaltKind.emptyAnswer:
        // Its question says it, with the buttons.
        if (s.questions.any(
          (q) => q.kind == ContactSyncQuestionKind.emptyAnswer,
        )) {
          return const [];
        }
        return [_Para(line)];
      case ContactSyncHaltKind.quota:
        return [_Para(line)];
      case ContactSyncHaltKind.failed:
        return [
          _Para(line),
          // Before the first sync, a run goes only through Start, just
          // below, and its preview and backup from the last hour: no Try
          // again beside it.
          _Problem(
            doing: 'Syncing contacts',
            error: _failureOf(halt),
            onRemedy: _remedy(
              _failureOf(halt),
              google,
              graph,
              s.firstStarted ? _syncNow : null,
            ),
          ),
        ];
      case ContactSyncHaltKind.putAway:
        return const [];
    }
  }

  /// A failed run's failure, or one worth trying again where the runner
  /// gave none.
  static Object _failureOf(ContactSyncHalt halt) =>
      halt.error ?? const ContactSyncFailed('Contact sync could not finish.');

  static String _syncedLine(
    ContactSyncTally t,
    DateTime now,
    bool use24h,
    String graphName,
  ) {
    final counts = [
      if (t.added > 0 || t.changed > 0 || t.deleted > 0) ...[
        _none(t.added, 'added'),
        _none(t.changed, 'changed'),
        _none(t.deleted, 'deleted'),
      ],
      if (t.paired > 0) '${t.paired} paired up',
      if (t.restored > 0) '${t.restored} restored',
      if (t.refused > 0) '${t.refused} could not be copied',
      if (t.needsALook > 0)
        _count(t.needsALook, 'needs a look', 'need a look'),
      if (t.passedOver > 0)
        '${t.passedOver} in $graphName could not be read whole, left for '
            'the next sync',
    ];
    return 'Synced ${_when(t.at, now, use24h)}: '
        '${counts.isEmpty ? 'nothing needed changing' : counts.join(', ')}';
  }

  static String _none(int n, String what) =>
      n == 0 ? 'none $what' : '$n $what';
}

/// One account's line: whether it allows contact sync, and Allow where a
/// sign-in can allow it. Laid out as View's online address books are.
class _AccessRow extends ConsumerWidget {
  const _AccessRow({
    required this.account,
    required this.busy,
    required this.leftOut,
    required this.onAllow,
  });

  final Account account;
  final bool busy;

  /// Signed in again from here, with Google.
  final bool leftOut;
  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(contactSyncAccessProvider(account.id));
    final state = access.value?.state;
    final gmail = account.provider == MailProvider.gmail;
    final (String line, bool offer) = switch (state) {
      null when access.hasError => ('Could not check just now.', false),
      null => ('Checking…', false),
      ContactSyncAccessState.allowed => ('Allowed.', false),
      ContactSyncAccessState.needsSignIn ||
      ContactSyncAccessState.needsAdministrator when gmail && leftOut => (
          'Contacts was left unticked at the sign-in. Allow again, and tick '
              'every box.',
          true,
        ),
      ContactSyncAccessState.needsSignIn ||
      ContactSyncAccessState.needsAdministrator when gmail => (
          'Not allowed yet. Allow, then sign in with Google and tick every '
              'box.',
          true,
        ),
      // Microsoft gives the same refusal whether the person or only the
      // organisation can allow it, so the line says both.
      ContactSyncAccessState.needsSignIn ||
      ContactSyncAccessState.needsAdministrator => (
          'Not allowed yet. Allow, then sign in. Where your organisation has '
              'to approve it, the sign-in sends them the request, and once '
              'they have, it starts on its own.',
          true,
        ),
      ContactSyncAccessState.notPossible
          when gmail && account.authMethod == AuthMethod.appPassword =>
        (
          'Uses an app password, which reaches mail only. Allow signs it in '
              'with Google instead.',
          true,
        ),
      ContactSyncAccessState.notPossible => (
          'Not possible for this account.',
          false,
        ),
      ContactSyncAccessState.unknown => (
          'Could not check just now. ${access.value?.message ?? ''}'.trim(),
          false,
        ),
    };
    return ListTile(
      key: ValueKey('contact-sync-access:${account.id}'),
      minVerticalPadding: 10,
      leading: Icon(
        state == ContactSyncAccessState.allowed
            ? Icons.cloud_done_outlined
            : Icons.cloud_off_outlined,
      ),
      title: Text(account.emailAddress),
      subtitle: Text(line),
      trailing: busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : offer
              ? TextButton(onPressed: onAllow, child: const Text('Allow'))
              : null,
    );
  }
}

/// What the first sync would do, in numbers.
class _PreviewTable extends StatelessWidget {
  const _PreviewTable({required this.preview, required this.graphName});

  final ContactSyncPreview preview;
  final String graphName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = preview;
    final rows = [
      ('In Gmail now', '${p.googleListed}'),
      ('In $graphName now', '${p.graphListed}'),
      ('To be added to $graphName', '${p.addToGraph}'),
      ('To be added to Gmail', '${p.addToGoogle}'),
      ('Already in both, to be paired up', '${p.pairUp}'),
      ('Of those, with details that differ, left as they are',
          '${p.differingPairs}'),
      ('Need a look', '${p.needsALook}'),
      // Copies of one person beyond the one synced on each side: not
      // among those to add or to look at, and said only where there are
      // some.
      if (p.duplicateCopies > 0)
        ('Copies of the same person, left as they are',
            '${p.duplicateCopies}'),
      ('Deleted', p.deletions == 0 ? 'none' : '${p.deletions}'),
    ];
    return Container(
      key: const ValueKey('contact-sync-preview-table'),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text('$label:')),
                  const SizedBox(width: 12),
                  Text(
                    value,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// What answers a brake's question: the whole of it, with [items] null,
/// or only the contacts those keys name.
typedef _QuestionAnswer = void Function(
  ContactSyncChoice choice, {
  Set<String>? items,
});

/// A brake's question as shown during one visit to the Contact sync
/// screen ([_ContactSyncScreenState._cards]): as last listed, with its
/// contacts in the order first shown, each as last listed, so that one
/// the runner no longer lists stays in its place, done.
class _ShownQuestion {
  _ShownQuestion(this.question);

  /// As last listed.
  ContactSyncQuestion question;

  /// The runner lists it still.
  bool listed = true;

  /// Its contacts' keys in the order first shown, and each contact as
  /// last listed, with whether the question's answer for the rest covered
  /// it then. Kept only where every contact has a key, as the runner's
  /// always do.
  final List<String> _order = [];
  final Map<String, ({ContactSyncQuestionItem item, bool byQuestion})>
      _seen = {};

  /// It showed contacts of its own, which stay once done.
  bool get keeps => _order.isNotEmpty;

  /// Whether [q], as listed now, is this question: it names a contact
  /// shown here; or, with no contacts to tell it by (an empty answer's),
  /// it is of the same kind and side.
  bool isOf(ContactSyncQuestion q) {
    if (q.kind != question.kind) return false;
    if (_keyed(q)) return q.items.any((i) => _seen.containsKey(i.key));
    return !keeps && q.side == question.side;
  }

  void take(ContactSyncQuestion q) {
    question = q;
    if (!_keyed(q)) return;
    for (final i in q.items) {
      if (!_seen.containsKey(i.key)) _order.add(i.key);
      _seen[i.key] = (
        item: i,
        byQuestion: i.answer == null && q.answer != null,
      );
    }
  }

  /// Its contacts in their places: those listed as listed, the others
  /// done, as last listed.
  List<_ShownItem> get shown {
    if (!keeps) {
      return [
        for (final i in question.items)
          (item: i, done: false, byQuestion: false),
      ];
    }
    final now = {
      if (listed)
        for (final i in question.items) i.key: i,
    };
    return [
      for (final key in _order)
        if (now[key] case final i?)
          (item: i, done: false, byQuestion: false)
        else if (_seen[key] case final s?)
          (item: s.item, done: true, byQuestion: s.byQuestion),
    ];
  }

  static bool _keyed(ContactSyncQuestion q) =>
      q.items.isNotEmpty && q.items.every((i) => i.key.isNotEmpty);
}

/// A brake's contact as its card shows it: as listed, or [done], as last
/// listed before the runner stopped listing it; [byQuestion], its answer
/// then was the question's for the rest, which the card says for it.
typedef _ShownItem = ({
  ContactSyncQuestionItem item,
  bool done,
  bool byQuestion,
});

/// A brake's question: what is held, contact by contact with what each
/// would lose or have deleted, and the two answers, for all of them at
/// once or for one contact alone.
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.graphName,
    required this.onAnswer,
    this.listed = true,
    this.shown,
  });

  /// As listed; once the runner no longer lists it, as last listed.
  final ContactSyncQuestion question;
  final String graphName;
  final _QuestionAnswer onAnswer;

  /// The runner lists the question still: once it does not, all of it is
  /// done.
  final bool listed;

  /// Its contacts in their places, done ones among them; null for those
  /// the question lists, as it lists them.
  final List<_ShownItem>? shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final q = question;
    String side(ContactSide s) => _sideName(s, graphName);
    // Every contact drawn, in its place, and those the question lists now:
    // only these can be answered, or be held up.
    final shown = this.shown ??
        [
          for (final i in q.items) (item: i, done: false, byQuestion: false),
        ];
    final items = listed ? q.items : const <ContactSyncQuestionItem>[];
    final n = shown.length;
    // No number, neither the brakes' thresholds (a question stays until
    // answered, and may by then hold fewer than the more than 5 or 10 that
    // raised it) nor a count the title, counting only those still waiting,
    // would contradict.
    final (these, they) =
        n == 1 ? ('this contact', 'it is') : ('these contacts', 'they are');
    // The side every contact's change (or deletion) is about, where they
    // share one: said once, rather than under every name.
    final sides = {for (final s in shown) ..._sidesOf(s.item)};
    final oneSide = sides.length == 1 ? sides.single : null;
    // Counted as the Settings row and the one-line message count them:
    // only the contacts still waiting for Ron.
    final waiting = listed ? _waiting(q) : 0;
    final (String title, String body, String explain) = switch (q.kind) {
      ContactSyncQuestionKind.deletions => (
          waiting > 0
              ? _count(
                  waiting,
                  'deletion needs your OK',
                  'deletions need your OK',
                )
              : '${_count(n, 'deletion', 'deletions')}, '
                  '${n == 1 ? 'answered' : 'all answered'}',
          'One sync would delete $these at once, so $they held for your '
              'OK, and everything else carries on.',
          'Delete them deletes '
              '${oneSide == null ? "each one's copy on the other side" : 'their copies in ${side(oneSide.other)}'}'
              ', each read again first. '
              "Don't delete them: "
              '${_staySide([for (final s in shown) s.item], graphName)} but '
              'stop syncing, and each waits under Needs a look, where it '
              'can still be copied back.',
        ),
      ContactSyncQuestionKind.changes => (
          waiting > 0
              ? 'Changes to ${_count(waiting, 'contact', 'contacts')} need '
                  'your OK'
              : 'Changes to ${_count(n, 'contact', 'contacts')}, '
                  '${n == 1 ? 'answered' : 'all answered'}',
          'One sync would remove or replace details '
              '${oneSide == null ? '' : 'in ${side(oneSide)} '}on $these at '
              "once, as Google's Undo changes, a backup imported again or a "
              'bulk edit can, so $they held for your OK, and everything else '
              'carries on. Under each name, each detail as it is '
              '${oneSide == null ? 'now on the side named' : 'in ${side(oneSide)} now'}'
              ', and what it would become.',
          // Copy back puts back what the side would lose, from that
          // side; but a detail changed on both sides keeps its newer
          // edit, and a list only gains (a replaced address leaves both).
          oneSide == null
              ? 'Apply makes each change on the side named. Copy back '
                  'keeps what that side has and puts it back on the other, '
                  'except a detail changed on both sides; a list only '
                  'gains, so a replaced address leaves both. Either way '
                  'each contact is read again first.'
              : 'Apply makes these changes in ${side(oneSide)}. Copy back '
                  'keeps what ${side(oneSide)} has and puts it back in '
                  '${side(oneSide.other)}, except a detail changed on both '
                  'sides; a list only gains, so a replaced address leaves '
                  'both. Either way each contact is read again first.',
        ),
      ContactSyncQuestionKind.emptyAnswer => (
          q.listed == null
              ? '${_capital(_bookOrNot(q.side, graphName))} listed far '
                  'fewer contacts than expected'
              : '${_capital(_bookOrNot(q.side, graphName))} listed only '
                  '${_count(q.listed!, 'contact', 'contacts')}',
          '${q.expected == null ? 'Far more were' : '${q.expected} were'} '
              'expected. Contact sync has stopped and written nothing, '
              'because a lapsed permission, a wrong folder or an empty '
              'answer must never read as everything deleted.',
          // Not only a number: carrying on reads every contact missing
          // from the listing as deleted, and deletes its copy.
          "That's right, carry on takes "
              '${q.listed == null ? 'the new count' : '${q.listed}'} as the '
              'number to expect: the contacts no longer listed '
              '${q.side == null ? 'there' : 'in ${side(q.side!)}'} are then '
              'taken as deleted there, and their copies '
              '${q.side == null ? 'on the other side' : 'in ${side(q.side!.other)}'} '
              'are deleted too (it asks first if that is more than 5). Keep '
              'waiting leaves it stopped, and the next sync looks again.',
        ),
    };
    final whole = q.answer;
    // Contacts answered one by one: in a question of more than one, whose
    // contacts the runner names. Not an empty answer, which is a count.
    final oneByOne = n > 1 &&
        q.kind != ContactSyncQuestionKind.emptyAnswer &&
        shown.every((s) => s.item.key.isNotEmpty);
    final open = items.where((i) => i.answer == null).length;
    final someAnswered = open < n;
    // Some contact has (or had, done) an answer of its own: the question's
    // answer is for the rest.
    final forTheRest = shown.any((s) => s.item.answer != null);
    // What the buttons for all answer: the contacts shown here with no
    // answer of their own, by name, so that one held since Ron last looked
    // is not answered by a tap made before he saw it, nor one done. A
    // question of none (an empty answer), or one whose contacts carry no
    // keys, is answered whole.
    final forAll = items.isNotEmpty && items.every((i) => i.key.isNotEmpty)
        ? {
            for (final i in items)
              if (i.answer == null) i.key,
          }
        : null;
    // What held up the question's answer at the last run, for the contacts
    // it covers: under that answer, as the runner says it; once where one
    // reason holds up all of them, else each with its contact's name.
    final covered = whole == null
        ? const <ContactSyncQuestionItem>[]
        : [
            for (final i in items)
              if (i.answer == null) i,
          ];
    final reasons = {for (final i in covered) ?i.answerProblem};
    final heldUp = reasons.length == 1 &&
            covered.every((i) => i.answerProblem == reasons.single)
        ? [reasons.single]
        : [
            for (final i in covered)
              if (i.answerProblem case final p?) '${_title(i.title)}: $p',
          ];
    return Card(
      key: ValueKey('contact-sync-question:${q.kind.name}'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      color: theme.colorScheme.surfaceContainerHighest,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(body),
            const SizedBox(height: 8),
            // The answer for all comes first: with 58 contacts below, at
            // their foot it would be a long way down.
            if (whole != null) ...[
              // Done, a line of about the same length, as on each contact.
              Text(
                'You chose ${_choiceLabel(whole, graphName)}'
                '${forTheRest ? ' for the rest' : ''}'
                '${listed ? '. The next sync carries it out.' : ': done. '
                    '${_capital(they)} no longer held.'}',
                key: const ValueKey('contact-sync-question-answer'),
                style: TextStyle(color: theme.colorScheme.primary),
              ),
              for (final line in heldUp)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(line, style: muted),
                ),
            ]
            // Open while any contact is (a question of none, an empty
            // answer, is open until answered).
            else if (n == 0 || open > 0) ...[
              if (oneByOne)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    someAnswered
                        ? 'For the $open not yet answered:'
                        : 'For all $n at once:',
                    key: const ValueKey('contact-sync-question-for'),
                    style: theme.textTheme.labelLarge,
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in q.choices)
                    OutlinedButton(
                      key: ValueKey('contact-sync-answer:${c.name}'),
                      onPressed: () => onAnswer(c, items: forAll),
                      child: Text(_choiceLabel(c, graphName)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(explain, style: muted),
            ],
            if (shown.isNotEmpty) ...[
              const SizedBox(height: 4),
              for (final s in shown) ...[
                const Divider(height: 17),
                _QuestionItemTile(
                  item: s.item,
                  kind: q.kind,
                  graphName: graphName,
                  namesSide: oneSide == null,
                  choices: !s.done && oneByOne && whole == null
                      ? q.choices
                      : const [],
                  done: s.done,
                  byQuestion: s.byQuestion,
                  onAnswer: (c) => onAnswer(c, items: {s.item.key}),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Where the copies left by deletions stay, if they were not deleted.
  static String _staySide(
    List<ContactSyncQuestionItem> items,
    String graphName,
  ) {
    final sides = {for (final i in items) i.side.other};
    return sides.length == 1
        ? 'they stay in ${_sideName(sides.single, graphName)}'
        : 'they stay where they are';
  }
}

/// One contact in a brake's question: its name, what the held change
/// would do to it detail by detail (or, for a deletion, an email or mobile
/// to tell it apart), and its own two answers, or the one given to it.
/// Compact, as a question may hold dozens.
class _QuestionItemTile extends StatelessWidget {
  const _QuestionItemTile({
    required this.item,
    required this.kind,
    required this.graphName,
    required this.namesSide,
    required this.choices,
    required this.onAnswer,
    this.done = false,
    this.byQuestion = false,
  });

  final ContactSyncQuestionItem item;
  final ContactSyncQuestionKind kind;
  final String graphName;

  /// The question's contacts are not all about one side, so each names
  /// its own.
  final bool namesSide;

  /// The answers it may have on its own; none where it cannot be answered
  /// alone.
  final List<ContactSyncChoice> choices;
  final ValueChanged<ContactSyncChoice> onAnswer;

  /// The runner no longer lists it, as last listed: its answer carried out,
  /// or it is no longer held. It keeps its place, with no buttons, and its
  /// answer said as done.
  final bool done;

  /// Done, and its answer was the question's for the rest, which the card
  /// says: nothing said here, as nothing was while it waited.
  final bool byQuestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final i = item;
    final answer = i.answer;
    // Where its changes land: one side, said once (or by the question),
    // or both, said on each line.
    final itsSides = _sidesOf(i);
    final eachLine = itsSides.length > 1;
    final after = switch (kind) {
      ContactSyncQuestionKind.deletions =>
        ': ${_goneFrom(i.side, graphName, lower: true)}',
      ContactSyncQuestionKind.changes => namesSide && !eachLine
          ? ': in ${_sideName(itsSides.single, graphName)}'
          : '',
      ContactSyncQuestionKind.emptyAnswer => '',
    };
    final about = [
      Text.rich(TextSpan(children: [
        TextSpan(
          text: _title(i.title),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (after.isNotEmpty) TextSpan(text: after),
      ])),
      for (final c in i.changes)
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 2),
          child: Text(contactSyncChangeLine(
            c,
            inSide: eachLine ? _sideName(_landsOn(c, i), graphName) : null,
          )),
        ),
      if (kind == ContactSyncQuestionKind.changes && i.changes.isEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 2),
          child: Text(
            'The details show after the next sync.',
            style: muted,
          ),
        ),
      if (i.hint case final hint?)
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 2),
          child: Text(hint, style: muted),
        ),
      if (answer != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          // Done, a line of about the same length, so that it wraps as
          // the one before did and moves nothing under it.
          child: Text(
            done
                ? 'You chose ${_itemChoiceLabel(answer, graphName, i)}: '
                    'done. It is no longer held.'
                : 'You chose ${_itemChoiceLabel(answer, graphName, i)}: the '
                    'next sync carries it out.',
            style: TextStyle(color: theme.colorScheme.primary),
          ),
        )
      // Gone from the question with no answer: its rows no longer held
      // (the change undone, the contact gone).
      else if (done && !byQuestion)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('No longer held: nothing to answer.', style: muted),
        ),
      // Held up at the last run: why, as the runner says it.
      if (i.answerProblem case final problem? when answer != null && !done)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(problem, style: muted),
        ),
    ];
    final buttons = done || answer != null || choices.isEmpty
        ? null
        : Wrap(
            spacing: 4,
            children: [
              for (final c in choices)
                TextButton(
                  key: ValueKey('contact-sync-item:${i.key}:${c.name}'),
                  onPressed: () => onAnswer(c),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 36),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(_itemChoiceLabel(c, graphName, i)),
                ),
            ],
          );
    return LayoutBuilder(
      key: i.key.isEmpty ? null : ValueKey('contact-sync-item:${i.key}'),
      builder: (context, box) {
        final column = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: about,
        );
        if (buttons == null) return column;
        // Wide, as on the tablet, the two buttons sit beside the contact
        // rather than under it: a line less for each of dozens.
        if (box.maxWidth >= 560) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: column),
              const SizedBox(width: 12),
              buttons,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...about,
            Padding(padding: const EdgeInsets.only(top: 2), child: buttons),
          ],
        );
      },
    );
  }
}

/// A brake's answer for one contact: the question's own, said of one. Its
/// Delete names the side the copy is deleted from, the other from where
/// the contact went, since the body names none.
String _itemChoiceLabel(
  ContactSyncChoice c,
  String graphName,
  ContactSyncQuestionItem i,
) =>
    switch (c) {
      ContactSyncChoice.applyThem => 'Apply',
      ContactSyncChoice.copyThemBack => 'Copy back',
      ContactSyncChoice.deleteThem =>
        'Delete in ${_sideName(i.side.other, graphName)}',
      ContactSyncChoice.dontDelete => "Don't delete",
      _ => _choiceLabel(c, graphName),
    };

/// One detail a held change would remove or replace: "Job title: Sales
/// manager → Purchasing manager", "Mobile: +1 555 123 4567 → removed".
/// A long value is shortened to one line; a note too long to show comes
/// with no value at all, and is said to be changed or removed. [inSide]
/// names the side it lands on, for a contact whose changes land on both
/// ("In Hadco, Company: …"). A detail changed on both sides keeps its
/// newer edit whichever answer is given, and says so.
String contactSyncChangeLine(ContactSyncDetailChange c, {String? inSide}) {
  final where = inSide == null ? '' : 'In $inSide, ';
  final what = _fieldLabel(c.field);
  final clash = c.clash
      ? ' (changed on both sides: the newer edit stays whichever you '
          'choose; the other value goes under Needs a look)'
      : '';
  // No value shown: never "(none)", which would read as nothing lost.
  if (c.before == null) {
    return '$where$what: '
        '${c.after == null ? 'removed (too long to show here)' : 'changed'}'
        '$clash';
  }
  return '$where$what: ${_shortValue(c.before)} \u2192 '
      '${c.after == null ? 'removed' : _shortValue(c.after)}$clash';
}

/// The side a change lands on: its own, where the runner says, else its
/// contact's. The one place that reads [ContactSyncDetailChange.side].
ContactSide _landsOn(ContactSyncDetailChange c, ContactSyncQuestionItem i) =>
    c.side ?? i.side;

/// The sides a contact's held changes land on: its own side where it
/// lists none.
Set<ContactSide> _sidesOf(ContactSyncQuestionItem i) => i.changes.isEmpty
    ? {i.side}
    : {for (final c in i.changes) _landsOn(c, i)};

/// A value on one line, and no longer than about half a phone's width.
String _shortValue(String? value) {
  final one = (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
  if (one.isEmpty) return '(none)';
  const most = 60;
  final chars = one.characters;
  if (chars.length <= most) return one;
  return '${chars.take(most - 1).toString().trimRight()}…';
}

/// Needs a look: each contact the sync could not settle on its own, with
/// its answers, and one answer for every new pair whose details differ.
class _LooksScreen extends ConsumerStatefulWidget {
  const _LooksScreen();

  @override
  ConsumerState<_LooksScreen> createState() => _LooksScreenState();
}

class _LooksScreenState extends ConsumerState<_LooksScreen> {
  /// The items shown during this visit, in the order first shown, each as
  /// last listed: one the runner no longer lists (its answer carried out
  /// by the run the answer started, Leave as they are, or its contacts
  /// gone) stays where it was, shown as done, until the screen is left, so
  /// that nothing moves under the finger, as on Duplicates to merge. New
  /// ones go under them.
  final List<int> _order = [];
  final Map<int, ContactSyncLook> _seen = {};

  /// The answers given here, with the item's version then: what a done
  /// item says where the status never showed its answer (Leave as they
  /// are and Keep the newer take the item away at once).
  final Map<int, ({ContactSyncChoice choice, String version})> _gaveHere =
      {};

  ContactSyncService get _sync => ref.read(mailEngineProvider).contactSync;

  void _readAgain() {
    if (mounted) ref.invalidate(contactSyncStatusProvider);
  }

  List<({ContactSyncLook look, bool listed})> _shown(
    List<ContactSyncLook> looks,
  ) {
    final listed = {for (final l in looks) l.id: l};
    for (final l in looks) {
      if (!_seen.containsKey(l.id)) _order.add(l.id);
      _seen[l.id] = l;
    }
    return [
      for (final id in _order)
        if (listed[id] case final l?)
          (look: l, listed: true)
        else if (_seen[id] case final l?)
          (look: l, listed: false),
    ];
  }

  /// The answer a done item was given: its own as last listed, else one
  /// given here to it as it was then.
  ContactSyncChoice? _doneWith(ContactSyncLook l) {
    if (l.answer case final answer?) return answer;
    final given = _gaveHere[l.id];
    return given != null && given.version == l.version ? given.choice : null;
  }

  void _given(Map<int, String> looks, ContactSyncChoice choice) {
    if (!mounted) return;
    setState(() {
      for (final MapEntry(key: id, value: version) in looks.entries) {
        _gaveHere.putIfAbsent(id, () => (choice: choice, version: version));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(contactSyncStatusProvider).value;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final graphName =
        contactSyncAccountName(_byId(accounts, status?.graphAccountId));
    final looks = status?.needsALook ?? const <ContactSyncLook>[];
    final shown = _shown(looks);
    final differing = [
      for (final l in looks)
        if (l.kind == ContactReviewKind.differing && l.answer == null) l,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Needs a look'), centerTitle: false),
      body: _Body(
        children: [
          const _Para(
            'Contacts the sync could not settle on its own. An answer is '
            'carried out in the next sync, which starts at once.',
            top: 16,
          ),
          if (shown.isEmpty) const _Para('Nothing needs a look.'),
          if (differing.length > 1)
            _AllDiffering(
              looks: differing,
              graphName: graphName,
              onAnswer: (c, named) => _act(
                context,
                () async {
                  await _sync.answerAllDiffering(c, named);
                  _given(named, c);
                },
                // Refused, none of them still as shown: said, and read
                // again, to be answered as they are now.
                onFailure: _readAgain,
              ),
            ),
          for (final (:look, :listed) in shown) ...[
            const Divider(height: 1),
            _LookTile(
              look: look,
              graphName: graphName,
              done: !listed,
              doneWith: listed ? null : _doneWith(look),
              onAnswer: (choice, {candidateId}) => _act(
                context,
                () async {
                  await _sync.answerLook(
                    look.id,
                    choice,
                    candidateId: candidateId,
                  );
                  _given({look.id: look.version}, choice);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One answer for every new pair shown whose details differ, set apart
/// from each contact's own buttons, and asked again before one side's
/// details replace the other's on all of them: the brakes do not hold
/// Ron's own answers back, so this is the only question there is.
class _AllDiffering extends StatelessWidget {
  const _AllDiffering({
    required this.looks,
    required this.graphName,
    required this.onAnswer,
  });

  /// The pairs it answers: those shown whose details differ, with no
  /// answer yet.
  final List<ContactSyncLook> looks;
  final String graphName;

  /// The answer, for [looks] as they were when it was tapped: each one's
  /// id to its version.
  final void Function(ContactSyncChoice choice, Map<int, String> looks)
      onAnswer;

  Future<void> _answer(BuildContext context, ContactSyncChoice c) async {
    // Those the count came from, taken as the button is tapped: the
    // question names their number, and the answer covers them alone,
    // never a pair listed while the question is open.
    final shown = {for (final l in looks) l.id: l.version};
    final count = shown.length;
    if (c == ContactSyncChoice.leaveAsTheyAre) {
      onAnswer(c, shown);
      return;
    }
    final (kept, replaced) = c == ContactSyncChoice.useGoogle
        ? ('Gmail', graphName)
        : (graphName, 'Gmail');
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('contact-sync-all-sure'),
        title: Text("Use $kept's details for all $count?"),
        content: Text(
          "On the $count contacts whose details differ, $replaced's are "
          "replaced with $kept's at the next sync, which starts at once. "
          'This is the only time you are asked.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text("Replace $replaced's"),
          ),
        ],
      ),
    );
    if (sure == true) onAnswer(c, shown);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('contact-sync-all'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'All ${looks.length} pairs whose details differ',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'One answer for every one of them at once.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (c, label) in [
                (ContactSyncChoice.useGoogle, "Use Gmail's for all"),
                (ContactSyncChoice.useGraph, "Use $graphName's for all"),
                (ContactSyncChoice.leaveAsTheyAre, 'Leave all as they are'),
              ])
                FilledButton.tonal(
                  key: ValueKey('contact-sync-all:${c.name}'),
                  onPressed: () => _answer(context, c),
                  child: Text(label),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

typedef _LookAnswer = void Function(
  ContactSyncChoice choice, {
  String? candidateId,
});

class _LookTile extends StatelessWidget {
  const _LookTile({
    required this.look,
    required this.graphName,
    required this.onAnswer,
    this.done = false,
    this.doneWith,
  });

  final ContactSyncLook look;
  final String graphName;
  final _LookAnswer onAnswer;

  /// The runner no longer lists it, as last listed: it keeps its place,
  /// with no buttons, and the answer it was given, [doneWith], said as
  /// done; with none, that it no longer needs a look.
  final bool done;
  final ContactSyncChoice? doneWith;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final l = look;
    final answer = l.answer;
    final showsValues = l.kind == ContactReviewKind.differing ||
        l.kind == ContactReviewKind.clash;
    return Padding(
      key: ValueKey('contact-sync-look:${l.id}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_title(l.title), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(_lookLine(l, graphName)),
          if (showsValues)
            for (final f in l.fields) ...[
              const SizedBox(height: 6),
              Text(_fieldLabel(f), style: theme.textTheme.labelMedium),
              Text('Gmail: ${_valueOf(l.googleValues[f])}'),
              Text('$graphName: ${_valueOf(l.graphValues[f])}'),
            ],
          const SizedBox(height: 8),
          // Done, a line of about the same length as the answer's, so that
          // it wraps as that one did and moves nothing under it.
          if (done)
            switch (doneWith) {
              final choice? => Text(
                  'You chose ${_lookChoiceLabel(l, choice, graphName)}: '
                  'done. No longer needs a look.',
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
              null => Text('No longer needs a look.', style: muted),
            }
          else if (answer != null)
            Text(
              'You chose ${_lookChoiceLabel(l, answer, graphName)}. The next '
              'sync carries it out.',
              style: TextStyle(color: theme.colorScheme.primary),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _offered(l))
                  if (c == ContactSyncChoice.samePerson &&
                      l.candidates.length > 1)
                    for (final candidate in l.candidates)
                      OutlinedButton(
                        key: ValueKey(
                          'contact-sync-look:${l.id}:${c.name}:${candidate.id}',
                        ),
                        onPressed: () =>
                            onAnswer(c, candidateId: candidate.id),
                        child: Text(
                          'Same person as ${_title(candidate.title)}',
                        ),
                      )
                  else
                    OutlinedButton(
                      key: ValueKey('contact-sync-look:${l.id}:${c.name}'),
                      onPressed: () => onAnswer(
                        c,
                        candidateId: c == ContactSyncChoice.samePerson
                            ? l.candidates.singleOrNull?.id
                            : null,
                      ),
                      child: Text(_lookChoiceLabel(l, c, graphName)),
                    ),
              ],
            ),
          if (l.kind == ContactReviewKind.refused &&
              answer == null &&
              !done) ...[
            const SizedBox(height: 6),
            Text(
              'It is tried again when the contact changes, or with Retry.',
              style: muted,
            ),
          ],
        ],
      ),
    );
  }

  static String _valueOf(String? value) =>
      value == null || value.trim().isEmpty ? '(none)' : value;
}

/// Duplicates to merge when you like: each person held more than once, how
/// many copies each side holds, and which side's copy is synced. Gmail's
/// copies are Ron's to merge, in Google Contacts, and the sync follows
/// whichever copy is left. The Microsoft side's are merged here: the synced
/// copy stays and takes what only another copy holds, the others are
/// deleted, and the people whose copies differ are listed for Ron to
/// choose.
class _DuplicatesScreen extends ConsumerStatefulWidget {
  const _DuplicatesScreen();

  @override
  ConsumerState<_DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends ConsumerState<_DuplicatesScreen> {
  /// Save backup and merge: the backup file being read or saved, or the
  /// merge asked for.
  bool _saving = false;

  /// A merge asked for here that the status does not show yet: the button
  /// stays off until it does, or a newer result shows, since a second tap
  /// would read the address book and ask for the file again.
  bool _askedHere = false;

  /// The status the screen had when the merge was asked for but the status
  /// after it could not be read, so that whether anything was asked is not
  /// known: the next status the screen gets decides.
  ContactSyncStatus? _askUnread;
  bool _askUnsure = false;

  /// What the last Save backup and merge said.
  String? _said;

  /// Why the last Save backup and merge merged nothing, what it was doing
  /// then, and Try again: the whole of it, or only the asking where the
  /// file was saved.
  ({String doing, Object error, VoidCallback retry})? _problem;

  /// The last merge's time when [_said] or [_problem] was said: they go
  /// once a merge is asked for, its progress taking over, or a newer result
  /// shows.
  DateTime? _saidWith;

  /// The people whose copies differ, in the order first shown, each as
  /// last listed: one answered that the next sync carries out stays where
  /// it was, shown as answered, until the screen is left, so that nothing
  /// moves under the finger.
  final List<String> _order = [];
  final Map<String, ContactSyncCopiesPerson> _seen = {};

  /// The answers given here, with the differences each was given on: shown
  /// at once, before the status says so, while the person is listed with
  /// those differences still.
  final Map<String, ({String answer, String version})> _gaveHere = {};

  ContactSyncService get _sync => ref.read(mailEngineProvider).contactSync;

  DateTime? _lastNow() =>
      ref.read(contactSyncStatusProvider).value?.copies.last?.at;

  void _say(String said) => setState(() {
        _said = said;
        _saidWith = _lastNow();
      });

  /// In front, or, as under test, nothing has said otherwise.
  static bool _inFront() =>
      isInFront() || WidgetsBinding.instance.lifecycleState == null;

  /// Waiting for MyEmail to be in front again, to open the save dialog:
  /// false once the screen closes.
  Completer<bool>? _front;

  /// True once MyEmail is in front, now or later (the screen off, a call,
  /// the shade, another app focused beside it); false if the screen closes
  /// first. Put away, MyEmail closes the screen.
  Future<bool> _untilInFront() async {
    if (_inFront()) return true;
    final front = _front = Completer<bool>();
    final back = AppLifecycleListener(onResume: () {
      if (!front.isCompleted) front.complete(true);
    });
    try {
      return await front.future;
    } finally {
      back.dispose();
      if (identical(_front, front)) _front = null;
    }
  }

  @override
  void dispose() {
    if (_front case final front? when !front.isCompleted) front.complete(false);
    super.dispose();
  }

  /// The merge is asked for only once the Microsoft side's backup file is
  /// saved, through the save dialog as Save backup saves it: a save backed
  /// out of, or one that fails, asks for nothing, and so does leaving the
  /// screen before the file is saved. A read that ends while MyEmail is out
  /// of sight is kept, and the dialog opens once it is back.
  Future<void> _saveAndMerge(String graphName) async {
    final files = ref.read(backupFilesProvider);
    final sync = _sync;
    // Open still: neither closed nor on its way out.
    final route = ModalRoute.of(context);
    bool open() => mounted && (route?.isActive ?? true);
    setState(() {
      _saving = true;
      _said = null;
      _problem = null;
    });
    try {
      // Hadco's file alone: Gmail is not read for it.
      final backup = await sync.backup(only: ContactSide.graph);
      // No save dialog over whatever is in front now: it waits for MyEmail.
      if (!open() || !await _untilInFront() || !open()) return;
      final file =
          backup.firstWhereOrNull((f) => f.side == ContactSide.graph);
      if (file == null) {
        _say("$graphName's backup file was not made, so nothing is merged.");
        return;
      }
      final saved = await files.save(
        fileName: file.fileName,
        contents: file.contents,
        mimeType: file.mimeType,
        dialogTitle: "Save $graphName's contacts",
      );
      if (!open()) return;
      if (!saved) {
        _say("$graphName's backup file was not saved, so nothing is merged.");
        return;
      }
      await _askMerge(graphName, file, sync);
    } catch (e) {
      if (mounted) {
        setState(() {
          _problem = (
            doing: "Saving $graphName's backup file for the merge",
            error: e,
            retry: () => _saveAndMerge(graphName),
          );
          _saidWith = _lastNow();
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The merge asked for, [file] saved; then the status read again, to say
  /// whether one is asked for now: there may be nothing to merge by then.
  /// Failing, Try again asks again, without reading or saving the file
  /// again.
  Future<void> _askMerge(
    String graphName,
    ContactSyncBackupFile file,
    ContactSyncService sync,
  ) async {
    final saved = 'Saved ${file.fileName}, '
        '${_count(file.count, 'contact', 'contacts')}, which Outlook on the '
        'web can import.';
    // Try again's: from Save backup and merge, the button is off already.
    if (!_saving) {
      setState(() {
        _saving = true;
        _problem = null;
      });
    }
    try {
      await sync.mergeCopies();
      // Asked for: a read that fails now does not undo it.
      ContactSyncStatus? now;
      try {
        now = await sync.status();
      } catch (_) {
        now = null;
      }
      if (!mounted) return;
      final asked = now?.copies.asked ?? true;
      setState(() {
        _askedHere = asked;
        _askUnsure = now == null;
        _askUnread = ref.read(contactSyncStatusProvider).value;
        _said = switch (now) {
          null => '$saved The merge is asked for.',
          _ when asked => '$saved The merge starts now.',
          _ => '$saved There is nothing to merge just now.',
        };
        _saidWith = now == null ? _lastNow() : now.copies.last?.at;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _said = saved;
          _problem = (
            doing: "Asking for the merge of $graphName's copies",
            error: e,
            retry: () => _askMerge(graphName, file, sync),
          );
          _saidWith = _lastNow();
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// An answer for one person, on the differences shown, queued. Refused,
  /// the person, the copy or those differences no longer listed: said, and
  /// read again, to be answered as it is now.
  Future<void> _answer(ContactSyncCopiesPerson p, String? keep) => _act(
        context,
        () async {
          await _sync.answerCopies(p.key, keep, p.version);
          if (!mounted) return;
          setState(() => _gaveHere[p.key] = (
                answer: keep ?? ContactSyncCopiesPerson.leave,
                version: p.version,
              ));
        },
        onFailure: _readAgain,
      );

  /// [p]'s answer: the runner's, or one given here on the differences it
  /// is listed with still.
  String? _answerOf(ContactSyncCopiesPerson p) {
    if (p.answer case final answer?) return answer;
    final given = _gaveHere[p.key];
    return given != null && given.version == p.version ? given.answer : null;
  }

  void _readAgain() {
    if (mounted) ref.invalidate(contactSyncStatusProvider);
  }

  /// The synced copy's details for the people shown with no answer, on
  /// the differences shown: one listed since, or listed now with others, is
  /// not answered by it. Asked again first: the other copies go, with the
  /// values that differ.
  Future<void> _keepSyncedForAll(List<ContactSyncCopiesPerson> shown) async {
    final people = {for (final p in shown) p.key: p.version};
    final open = people.length;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('contact-sync-copies-all-sure'),
        title: Text("Keep the synced copy's details for all $open?"),
        content: Text(
          'For each of the $open people, the synced copy keeps its values '
          'and gains the details only another copy has, and the other '
          'copies are deleted at the next sync, which starts at once. '
          '$_deletedCopiesKept',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text("Keep the synced copy's"),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _act(
      context,
      () async {
        await _sync.answerAllCopies(people);
        if (!mounted) return;
        setState(() {
          for (final p in shown) {
            if (p.copies.firstWhereOrNull((c) => c.synced) case final c?) {
              _gaveHere[p.key] = (answer: c.key, version: p.version);
            }
          }
        });
      },
      onFailure: _readAgain,
    );
  }

  /// The people whose copies differ as shown: those listed, each where it
  /// was first shown, and those answered that the runner no longer lists
  /// ([listed] false: done, or their write failed and the answer was
  /// dropped); new ones under them.
  List<({ContactSyncCopiesPerson person, String? answer, bool listed})>
      _shownDiffering(List<ContactSyncCopiesPerson> differing) {
    final listed = {for (final p in differing) p.key: p};
    for (final p in differing) {
      if (!_seen.containsKey(p.key)) _order.add(p.key);
      _seen[p.key] = p;
    }
    return [
      for (final key in _order)
        if (listed[key] case final p?)
          (person: p, answer: _answerOf(p), listed: true)
        else if (_seen[key] case final p? when _answerOf(p) != null)
          (person: p, answer: _answerOf(p), listed: false),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(contactSyncStatusProvider).value;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final graphName =
        contactSyncAccountName(_byId(accounts, status?.graphAccountId));
    final copies = status?.copies ?? const ContactSyncCopies();
    // Asked for here, and now shown so, or done already; or, not known to
    // be asked for, any status since says.
    if (_askedHere &&
        (copies.asked ||
            copies.last?.at != _saidWith ||
            (_askUnsure && !identical(status, _askUnread)))) {
      _askedHere = false;
      _askUnsure = false;
    }
    final differing = copies.differing;
    final shown = _shownDiffering(differing);
    final open = [
      for (final s in shown)
        if (s.answer == null) s.person,
    ];
    // By name, to find someone among a few hundred.
    final people = [...?status?.duplicates]..sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    // The merge: while there is something for it to do, one is asked for
    // or has been done, or Save backup and merge has something to say.
    final merge = copies.people > 0 ||
        copies.asked ||
        copies.last != null ||
        _saving ||
        _said != null ||
        _problem != null;
    // The sync moves to another copy only while the side Ron removes from
    // still holds one: a person's last copy there goes as any deletion,
    // and in Outlook on the web a delete can take hidden copies with it.
    final intro = 'These are copies of the same person. One copy on each '
        'side is synced; the others are left as they are. Merge '
        "Gmail's copies with Merge & fix in Google Contacts"
        "${merge ? ", and $graphName's with the merge below" : ''}. Where a "
        'side holds more than one copy, whichever one you remove there, the '
        'sync moves to one that is left, and nothing is deleted on the other '
        "side. Removing a person's last copy on one side deletes it on the "
        'other too, as any deletion does. In Outlook on the web, deleting a '
        'contact can delete its hidden copies too, and the sync then deletes '
        'the person in Gmail.';
    // Built as it scrolls: Ron's address books hold hundreds, and the
    // copies that differ may run to dozens. The intro and the merge; then
    // the copies that differ, under their heading; then everyone with
    // copies, under theirs.
    const differFrom = 1;
    final peopleFrom = differFrom + (shown.isEmpty ? 0 : shown.length + 1);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duplicates to merge'),
        centerTitle: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView.builder(
            key: const ValueKey('contact-sync-duplicates-list'),
            padding: const EdgeInsets.only(bottom: 32),
            itemCount: peopleFrom + 1 + people.length,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Para(intro, top: 16),
                    if (merge) _mergePanel(status, copies, graphName),
                  ],
                );
              }
              if (i < peopleFrom) {
                if (i == differFrom) {
                  return _differingHead(
                    shown.length,
                    open,
                    asked: copies.asked,
                  );
                }
                final (:person, :answer, :listed) = shown[i - differFrom - 1];
                return _CopiesPerson(
                  key: ValueKey('contact-sync-copies-person:${person.key}'),
                  person: person,
                  answer: answer,
                  listed: listed,
                  onAnswer: (keep) => _answer(person, keep),
                );
              }
              if (i == peopleFrom) {
                return people.isEmpty
                    ? const _Para('No copies left to merge.')
                    : _Heading('People with copies (${people.length})');
              }
              final d = people[i - peopleFrom - 1];
              return Padding(
                key: ValueKey('contact-sync-duplicate:${i - peopleFrom - 1}'),
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                    text: _title(d.title),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: ': ${contactSyncCopiesLine(d, graphName)}'),
                ])),
              );
            },
          ),
        ),
      ),
    );
  }

  /// The merge of the Microsoft side's copies: what it does, the counts and
  /// Save backup and merge; while it is asked for, how far it has got;
  /// after, what it did.
  Widget _mergePanel(
    ContactSyncStatus? s,
    ContactSyncCopies c,
    String graphName,
  ) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final running = s?.running;
    final merging = running?.step == ContactSyncStep.merging ? running : null;
    final last = c.last;
    final left = c.notSynced;
    // What Save backup and merge said, until a merge is asked for or a
    // newer result shows.
    final fresh = !c.asked && last?.at == _saidWith;
    final said = fresh ? _said : null;
    final problem = fresh ? _problem : null;
    // Asked for, no sync going, and the last one stopped: nothing starts
    // another while Ron waits here, and the shell's one-line message may
    // have come and gone, so the box says why it waits. Not for MyEmail
    // put away: the next opening carries it on.
    final stop = c.asked && running == null
        ? switch (s?.halt) {
            final h? when h.kind != ContactSyncHaltKind.putAway => h,
            _ => null,
          }
        : null;
    return Container(
      key: const ValueKey('contact-sync-copies'),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Merge $graphName's copies", style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          // A photo is never a difference: nearly every one of Hadco's
          // contacts has one, and no two copies' match byte for byte.
          const Text(
            'Keeps the synced copy of each person, adds to it any detail '
            'only another copy has, and deletes the other copies. '
            '$_deletedCopiesKept When both copies have a photo, the synced '
            'copy keeps its own. Copies that differ are left for you to '
            'choose.',
            key: ValueKey('contact-sync-copies-what'),
          ),
          const SizedBox(height: 4),
          const Text(
            'Nothing is deleted in Gmail; it gets the added details at the '
            'next sync.',
          ),
          // What the last one did; while another is asked for, how far that
          // one has got instead.
          if (last != null && !c.asked) ...[
            const SizedBox(height: 8),
            Text(
              contactSyncMergedLine(
                last,
                DateTime.now(),
                graphName: graphName,
                use24h: MediaQuery.alwaysUse24HourFormatOf(context),
                // Given up: the way to try again, where it is offered.
                tryAgain: c.people > 0 && (s?.firstDone ?? false),
              ),
              key: const ValueKey('contact-sync-copies-last'),
            ),
          ],
          if (c.people > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${_count(c.people, 'person has', 'people have')} '
              '${_count(c.extras, 'other copy', 'other copies')} in '
              '$graphName.',
              key: const ValueKey('contact-sync-copies-counts'),
            ),
          ],
          if (left > 0) ...[
            const SizedBox(height: 4),
            Text(
              "${left == 1 ? "1 person's" : "$left people's"} copies in "
              '$graphName are left as they are: none is synced there, or a '
              'copy shares only the name.',
              style: muted,
            ),
          ],
          if (c.asked) ...[
            const SizedBox(height: 10),
            if (running != null)
              LinearProgressIndicator(
                key: const ValueKey('contact-sync-copies-progress'),
                value: merging != null && merging.total > 0
                    ? merging.done / merging.total
                    : null,
              ),
            const SizedBox(height: 6),
            Text(
              switch (merging) {
                final m? when m.total > 0 => 'Merging: ${m.done} of '
                    '${_count(m.total, 'person', 'people')}',
                _? => 'Merging…',
                null when running != null =>
                  'Merge asked for: it starts once the sync has made its '
                      'changes.',
                null when stop != null =>
                  'Merge asked for: it starts once the sync can carry on.',
                // The pass before stopped short, and the next waits the
                // usual hour.
                null when c.shortStops > 0 =>
                  'The last try stopped short: $graphName could not be read. '
                      'The next sync tries again (in about an hour, or Sync '
                      'now).',
                null => 'Merge asked for: the next sync carries it out.',
              },
              key: const ValueKey('contact-sync-copies-running'),
            ),
            if (s != null && stop != null) ..._waitsOn(s, stop, graphName),
            // Only while a sync runs: with none, as after a short stop,
            // the next pass may wait the hour.
            if (running != null) ...[
              const SizedBox(height: 4),
              Text(
                'Keep MyEmail open until it is done. If it is closed sooner, '
                'the merge carries on the next time MyEmail is opened.',
                style: muted,
              ),
            ],
          ] else if (c.people > 0) ...[
            const SizedBox(height: 8),
            // The first sync pairs the copies the merge keeps.
            if (s?.firstDone ?? false) ...[
              Text(
                "It starts once you have saved $graphName's backup file, "
                'which Outlook on the web can import.',
                style: muted,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('contact-sync-copies-merge'),
                onPressed: _saving || _askedHere
                    ? null
                    : () => _saveAndMerge(graphName),
                icon: const Icon(Icons.merge_type),
                label: const Text('Save backup and merge'),
              ),
            ] else
              Text(
                'Offered once the first sync is done.',
                key: const ValueKey('contact-sync-copies-later'),
                style: muted,
              ),
          ],
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          if (said != null) ...[
            const SizedBox(height: 8),
            Text(said, key: const ValueKey('contact-sync-copies-said')),
          ],
          if (problem != null) ...[
            const SizedBox(height: 8),
            ProblemView(
              problem: ProblemReport(
                doing: problem.doing,
                error: problem.error,
              ),
              onRemedy: problem.error is Retryable ? problem.retry : null,
            ),
            const Text(
              'Nothing is merged.',
              key: ValueKey('contact-sync-copies-nothing'),
            ),
          ],
        ],
      ),
    );
  }

  /// Why the merge asked for waits: the last sync's [stop], as the Contact
  /// sync screen says it, and the way on from here, the one that screen
  /// offers: Sync here for another device's claim, which Sync now would
  /// only meet again, else Sync now.
  List<Widget> _waitsOn(
    ContactSyncStatus s,
    ContactSyncHalt stop,
    String graphName,
  ) {
    final now = DateTime.now();
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final elsewhere = stop.kind == ContactSyncHaltKind.otherDevice;
    // The failure itself, under the line, where that screen shows one.
    final error = switch (stop.kind) {
      ContactSyncHaltKind.failed => _ContactSyncScreenState._failureOf(stop),
      ContactSyncHaltKind.notAllowed => stop.error,
      _ => null,
    };
    return [
      const SizedBox(height: 4),
      Text(
        _stopLine(s, stop, graphName, now, use24h) ?? '',
        key: const ValueKey('contact-sync-copies-stop'),
      ),
      if (elsewhere) Text(_otherDeviceLine(stop, now, use24h)),
      if (error != null) ...[
        const SizedBox(height: 4),
        ProblemView(
          problem: ProblemReport(doing: 'Syncing contacts', error: error),
        ),
      ],
      const SizedBox(height: 8),
      if (elsewhere)
        OutlinedButton(
          key: const ValueKey('contact-sync-copies-here'),
          onPressed: () => _act(context, _sync.syncHere),
          child: const Text('Sync here'),
        )
      else
        FilledButton.tonalIcon(
          key: const ValueKey('contact-sync-copies-sync-now'),
          onPressed: () => unawaited(_sync.syncNow()),
          icon: const Icon(Icons.sync),
          label: const Text('Sync now'),
        ),
    ];
  }

  /// The heading of the copies that differ, what the answers do, and the
  /// answer for all of them, set apart from each person's own.
  Widget _differingHead(
    int n,
    List<ContactSyncCopiesPerson> open, {
    required bool asked,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Heading('Copies that differ ($n)'),
          const _Para(
            "Keep these puts that copy's values in the synced copy, which "
            'always stays, and in Gmail at the next sync; then every other '
            'copy is deleted, and Outlook keeps it for a while. Values the '
            'synced copy loses are kept only in your backup file. Leave them '
            'leaves every copy as it is. An answer is carried out in the next '
            'sync, which starts at once.',
            muted: true,
          ),
          if (open.length > 1)
            _Buttons([
              FilledButton.tonal(
                key: const ValueKey('contact-sync-copies-all'),
                // Off while a merge is asked for: it lists people as it
                // goes, under those Ron has seen.
                onPressed: asked ? null : () => _keepSyncedForAll(open),
                child: Text("Keep the synced copy's for all ${open.length}"),
              ),
            ]),
        ],
      );
}

/// One person whose copies on the Microsoft side differ: each copy's
/// values of what differs, with Keep these beside each, and Leave them; or
/// the answer given.
class _CopiesPerson extends StatelessWidget {
  const _CopiesPerson({
    super.key,
    required this.person,
    required this.answer,
    required this.listed,
    required this.onAnswer,
  });

  final ContactSyncCopiesPerson person;

  /// The answer shown: the person's, or, once the runner no longer lists
  /// the person, the one given here.
  final String? answer;

  /// Listed by the runner still; not, once its answer is done, or dropped
  /// because its write failed.
  final bool listed;

  /// A copy's key, or null: leave them as they are.
  final ValueChanged<String?> onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = person;
    final answer = this.answer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1, indent: 16, endIndent: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_title(p.title), style: theme.textTheme.titleSmall),
              for (final (j, c) in p.copies.indexed) ...[
                const SizedBox(height: 6),
                // Keep these beside the copy's name, over the values it
                // keeps: Leave them, under them all, is the person's.
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      contactSyncCopyName(p, j),
                      style: theme.textTheme.labelMedium,
                    ),
                    if (answer == null)
                      TextButton(
                        key: ValueKey(
                          'contact-sync-copies-keep:${p.key}:${c.key}',
                        ),
                        onPressed: () => onAnswer(c.key),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 36),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('Keep these'),
                      ),
                  ],
                ),
                for (final d in c.details)
                  Text('${d.label}: ${_LookTile._valueOf(d.value)}'),
              ],
              const SizedBox(height: 10),
              // No longer listed: done, or dropped with its write failed, so
              // a line that promises nothing, of about the same length, so
              // as not to move those under it. Left as they are, there is
              // nothing to write, so it is done.
              if (answer != null)
                Text(
                  switch ((listed, answer)) {
                    (true, _) => 'You chose ${_copiesChoice(p, answer)}; the '
                        'next sync carries it out.',
                    (false, ContactSyncCopiesPerson.leave) =>
                      'You chose ${_copiesChoice(p, answer)}; done.',
                    (false, _) => 'You chose ${_copiesChoice(p, answer)}; see '
                        'the result above.',
                  },
                  style: TextStyle(color: theme.colorScheme.primary),
                )
              else
                OutlinedButton(
                  key: ValueKey('contact-sync-copies-leave:${p.key}'),
                  onPressed: () => onAnswer(null),
                  child: const Text('Leave them'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A copy's name among its person's: "Synced copy", then "Other copy"
/// where there are two, else "Copy 2", "Copy 3", by place.
String contactSyncCopyName(ContactSyncCopiesPerson p, int j) {
  if (p.copies[j].synced) return 'Synced copy';
  final oneOther = p.copies.length == 2 && p.copies.any((c) => c.synced);
  return oneOther ? 'Other copy' : 'Copy ${j + 1}';
}

/// The answer given, after "You chose".
String _copiesChoice(ContactSyncCopiesPerson p, String answer) {
  if (answer == ContactSyncCopiesPerson.leave) {
    return 'to leave them as they are';
  }
  final j = p.copies.indexWhere((c) => c.key == answer);
  if (j < 0) return "one copy's details";
  final name = contactSyncCopyName(p, j);
  return name.startsWith('Copy ')
      ? "$name's details"
      : "the ${name.toLowerCase()}'s details";
}

/// Where the merge's deleted copies can be had back. Graph's ordinary
/// delete is used (never `permanentDelete`), but whether Exchange puts a
/// contact deleted that way in Deleted Items or straight among the
/// mailbox's recoverable items (kept 14 days unless the organisation
/// says otherwise) has not been checked, and Microsoft's pages do not
/// say: this is true either way.
const _deletedCopiesKept = 'Outlook keeps deleted contacts for a while: in '
    'Deleted Items, or under Recover items deleted from this folder at the '
    'top of Deleted Items.';

/// What the last merge of the Microsoft side's copies did: "Merged at
/// 10:42: 1089 people, 1143 copies deleted, 210 details added.", or that it
/// was given up, with what it did before; then the people whose copies
/// differ, those that failed and those left for the next merge, if any;
/// and, given up, the way to try again where [tryAgain] offers it.
String contactSyncMergedLine(
  ContactSyncCopiesResult r,
  DateTime now, {
  required String graphName,
  bool use24h = true,
  bool tryAgain = false,
}) {
  String no(int n, String one, String many) =>
      n == 0 ? 'no $many' : _count(n, one, many);
  final when = _when(r.at, now, use24h);
  final did = '${no(r.deleted, 'copy', 'copies')} deleted, '
      '${no(r.added, 'detail', 'details')} added';
  final some = r.people > 0 || r.deleted > 0 || r.added > 0;
  return [
    if (r.stoppedShort) ...[
      'The merge was given up $when: $graphName could not be read three '
          'times in a row.',
      if (some)
        'Before that: ${_count(r.people, 'person', 'people')} merged, $did.',
    ] else if (r.people == 0)
      'The merge $when merged nobody.'
    else
      'Merged $when: ${_count(r.people, 'person', 'people')}, $did.',
    if (r.differing > 0)
      '${_count(r.differing, 'person', 'people')} whose copies differ '
          '${r.differing == 1 ? 'is' : 'are'} left for you.',
    if (r.failed > 0)
      '${_count(r.failed, 'person', 'people')} could not be merged in full: '
          'what is left of their copies is as it was, and the next merge '
          'tries again.',
    // Nothing of theirs deleted, but what was added may be on the synced
    // copy already: nothing said of what was written.
    if (r.passedOver > 0)
      '${_count(r.passedOver, 'person was', 'people were')} left for the '
          'next merge: a copy changed meanwhile, $graphName could not be '
          'read just then, a photo could not be read, or a copy is no longer '
          'in Contacts.',
    if (r.stoppedShort && tryAgain) 'Save backup and merge to try again.',
  ].join(' ');
}

/// One person's copies, after the name: "2 in Gmail, 3 in Hadco; one of
/// each is synced". A side with none is left out; with one copy synced
/// on one side only, it says which, or that its copy on the other side is
/// still to be made.
String contactSyncCopiesLine(ContactSyncDuplicates d, String graphName) {
  final counts = [
    if (d.googleCopies > 0) '${d.googleCopies} in Gmail',
    if (d.graphCopies > 0) '${d.graphCopies} in $graphName',
  ];
  final bothSides = counts.length == 2;
  final googleSynced = d.googleSynced && d.googleCopies > 0;
  final graphSynced = d.graphSynced && d.graphCopies > 0;
  final synced = switch ((googleSynced, graphSynced)) {
    (true, true) => bothSides ? 'one of each is synced' : 'one is synced',
    (true, false) when d.graphCopies == 0 =>
      'one is synced, and its copy in $graphName is still to be made',
    (false, true) when d.googleCopies == 0 =>
      'one is synced, and its copy in Gmail is still to be made',
    (true, false) => bothSides ? 'one in Gmail is synced' : 'one is synced',
    (false, true) =>
      bothSides ? 'one in $graphName is synced' : 'one is synced',
    (false, false) => 'none is synced yet',
  };
  return '${counts.join(', ')}; $synced';
}

/// Recently deleted: what the sync deleted in the last 30 days, with
/// Restore.
class _DeletedScreen extends ConsumerWidget {
  const _DeletedScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(contactSyncStatusProvider).value;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final graphName =
        contactSyncAccountName(_byId(accounts, status?.graphAccountId));
    final sync = ref.read(mailEngineProvider).contactSync;
    final deleted = status?.recentlyDeleted ?? const <ContactSyncDeleted>[];
    final now = DateTime.now();
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String line(ContactSyncDeleted d) {
      final from = _sideName(d.side, graphName);
      final said = switch (d.state) {
        ContactSyncDeletedState.deleting => 'Being deleted from $from',
        ContactSyncDeletedState.deleted => d.deletedAt == null
            ? 'Deleted from $from'
            : 'Deleted from $from ${_when(d.deletedAt!, now, use24h)}',
        ContactSyncDeletedState.back => 'Already back',
      };
      return d.restoreAsked &&
              d.restoreProblem == null &&
              d.state != ContactSyncDeletedState.back
          ? '$said. Restore asked for: the next sync brings it back.'
          : said;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Recently deleted'), centerTitle: false),
      body: _Body(
        children: [
          const _Para(
            'Every contact the sync deleted in the last 30 days. Restore '
            'makes it again where it was deleted, with every detail that '
            'can be written, and on the other side too unless it is back '
            'there already; the two are then paired. Photos, and '
            "Outlook's fax, pager and anniversary, come back only through "
            "Google's Trash or Outlook's Recover deleted items.",
            top: 16,
          ),
          if (deleted.isEmpty)
            const _Para('Nothing deleted in the last 30 days.'),
          for (final d in deleted)
            ListTile(
              key: ValueKey('contact-sync-deleted:${d.id}'),
              minVerticalPadding: 10,
              title: Text(_title(d.title)),
              subtitle: switch (d.restoreProblem) {
                null => Text(line(d)),
                // A Restore refused: why, under the contact, and Restore
                // still offered, since pressing it again tries again.
                final problem => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(line(d)),
                      Text(
                        problem,
                        key: ValueKey('contact-sync-restore-problem:${d.id}'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ),
              },
              trailing: d.state == ContactSyncDeletedState.back ||
                      (d.restoreAsked && d.restoreProblem == null)
                  ? null
                  : TextButton(
                      key: ValueKey('contact-sync-restore:${d.id}'),
                      onPressed: () => _act(context, () => sync.restore(d.id)),
                      child: const Text('Restore'),
                    ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Words.

/// The Settings row's subtitle: what contact sync is doing, from the same
/// status the screen shows, naming only accounts still in MyEmail.
String contactSyncSubtitle({
  required bool on,
  required AsyncValue<ContactSyncStatus>? status,
  required List<Account> accounts,
  required DateTime now,
  bool use24h = true,
}) {
  if (!on) return 'Off';
  final s = status?.value;
  if (s == null) {
    return status is AsyncError ? 'Could not be read' : 'Loading';
  }
  final google = _byId(_googleAccounts(accounts), s.googleAccountId);
  final graph = _byId(_graphAccounts(accounts), s.graphAccountId);
  if (google == null || graph == null) return 'Not set up yet';
  final graphName = contactSyncAccountName(graph);
  final pair = 'Gmail and $graphName';
  for (final q in s.questions) {
    if (q.answer != null) continue;
    // Only the contacts still waiting for Ron: one answered on its own
    // waits for the next sync, not for him.
    final waiting = _waiting(q);
    switch (q.kind) {
      case ContactSyncQuestionKind.deletions when waiting > 0:
        return _count(
          waiting,
          'deletion needs your OK',
          'deletions need your OK',
        );
      case ContactSyncQuestionKind.changes when waiting > 0:
        return 'Changes to ${_count(waiting, 'contact', 'contacts')} '
            'need your OK';
      case ContactSyncQuestionKind.deletions:
      case ContactSyncQuestionKind.changes:
        continue;
      case ContactSyncQuestionKind.emptyAnswer:
        return 'Stopped: ${_bookOrNot(q.side, graphName)} listed too few '
            'contacts';
    }
  }
  if (s.isRunning) return '$pair, syncing now';
  if (s.halt case final halt?) {
    switch (halt.kind) {
      case ContactSyncHaltKind.notAllowed:
        return 'Not allowed yet for '
            '${_sideOrNot(_haltSide(halt), graphName)}';
      case ContactSyncHaltKind.otherDevice:
        return 'Syncing on your other device';
      case ContactSyncHaltKind.emptyAnswer:
        return 'Stopped: ${_bookOrNot(_haltSide(halt), graphName)} listed '
            'too few contacts';
      case ContactSyncHaltKind.quota:
        return "Waiting for Google's daily limit";
      case ContactSyncHaltKind.failed:
        return 'Could not sync ${_atOrOn(halt.at, now, use24h)}';
      case ContactSyncHaltKind.putAway:
        break;
    }
  }
  if (!s.firstStarted) return '$pair, not started yet';
  if (s.firstUnfinished) return '$pair, first sync unfinished';
  final looks = s.needsALook.where((l) => l.answer == null).length;
  if (looks > 0) {
    return '${_count(looks, 'contact needs', 'contacts need')} a look';
  }
  if (s.lastDoneAt case final at?) {
    return '$pair, synced ${_atOrOn(at, now, use24h)}';
  }
  return pair;
}

/// The one-line message the shell shows once per stop, or null for a stop
/// with nothing to say (MyEmail put away).
String? contactSyncNoticeText(
  ContactSyncNotice notice, {
  required String graphName,
}) {
  final held = [
    if (notice.heldDeletions > 0)
      _count(notice.heldDeletions, 'deletion', 'deletions'),
    if (notice.heldChanges > 0)
      'changes to ${_count(notice.heldChanges, 'contact', 'contacts')}',
  ];
  if (held.isNotEmpty) {
    final one = notice.heldDeletions == 1 && notice.heldChanges == 0;
    return 'Contact sync has stopped: ${held.join(' and ')} '
        '${one ? 'needs' : 'need'} your OK';
  }
  final halt = notice.halt;
  if (halt == null) return null;
  final side = _haltSide(halt);
  return switch (halt.kind) {
    ContactSyncHaltKind.notAllowed => 'Contact sync has stopped: not allowed '
        'yet for ${_sideOrNot(side, graphName)}',
    ContactSyncHaltKind.otherDevice => 'Contact sync is on on your other device',
    ContactSyncHaltKind.emptyAnswer => 'Contact sync has stopped: '
        '${_bookOrNot(side, graphName)} listed far fewer contacts than before',
    ContactSyncHaltKind.quota =>
      "Contact sync has stopped: Google's daily limit on changes is spent",
    ContactSyncHaltKind.failed => 'Contact sync could not finish',
    ContactSyncHaltKind.putAway => null,
  };
}

/// Why the last run stopped, [halt], in the line the Contact sync screen
/// opens that stop with: also said on Duplicates to merge while a merge
/// waits on it. Null for MyEmail put away, which is no stop to tell.
String? _stopLine(
  ContactSyncStatus s,
  ContactSyncHalt halt,
  String graphName,
  DateTime now,
  bool use24h,
) {
  final side = _haltSide(halt);
  final until = halt.until;
  return switch (halt.kind) {
    ContactSyncHaltKind.notAllowed => 'Contact sync has stopped: not allowed '
        'yet for ${_sideOrNot(side, graphName)}.',
    ContactSyncHaltKind.otherDevice =>
      'Contact sync is on on your other device',
    ContactSyncHaltKind.emptyAnswer => 'Contact sync has stopped: '
        '${_bookOrNot(side, graphName)} listed far fewer contacts than '
        'expected.',
    ContactSyncHaltKind.quota =>
      "Google's daily limit on changes to contacts is spent. Contact sync "
          'carries on '
          '${until == null ? 'tomorrow' : 'after ${_clockOrDay(until, now, use24h)}'}.',
    ContactSyncHaltKind.failed => s.firstStarted
        ? 'The last sync stopped ${_when(halt.at, now, use24h)}.'
        : 'The first sync could not begin: it stopped '
            '${_when(halt.at, now, use24h)}.',
    ContactSyncHaltKind.putAway => null,
  };
}

/// Under another device's stop: when it last synced there, and what to
/// do about it.
String _otherDeviceLine(ContactSyncHalt halt, DateTime now, bool use24h) =>
    '${switch (halt.claimedAt) {
      null => 'It has synced there lately',
      final at => 'It last synced there ${_when(at, now, use24h)}',
    }}. Only one device may sync, or the two would work against each '
    'other: turn it off there, or sync here instead.';

/// The Microsoft account's name in what contact sync says: its name in
/// MyEmail ("Hadco"), or its address where it has none.
String contactSyncAccountName(Account? account) {
  if (account == null) return 'the Microsoft account';
  final name = account.displayName.trim();
  return name.isEmpty ? account.emailAddress : name;
}

/// The contacts of a brake's question still waiting for Ron: none once
/// the whole question is answered, else those with no answer of their own.
int _waiting(ContactSyncQuestion q) =>
    q.answer != null ? 0 : q.items.where((i) => i.answer == null).length;

String _sideName(ContactSide side, String graphName) =>
    side == ContactSide.google ? 'Gmail' : graphName;

/// The side a stop is about: its own, or the account a sign-in failure
/// names. Null where neither says, and then nothing is named at a guess.
ContactSide? _haltSide(ContactSyncHalt halt) =>
    halt.side ??
    switch (halt.error) {
      ContactSyncNeedsSignIn(:final side) => side,
      _ => null,
    };

String _sideOrNot(ContactSide? side, String graphName) =>
    side == null ? 'one of the accounts' : _sideName(side, graphName);

String _bookOrNot(ContactSide? side, String graphName) =>
    side == null ? 'one address book' : _sideName(side, graphName);

String _capital(String said) =>
    '${said[0].toUpperCase()}${said.substring(1)}';

/// A Needs a look item's buttons, less Delete it ... too and Keep it only
/// in ... for a kept contact whose side is not known: they would name a
/// side at a guess.
List<ContactSyncChoice> _offered(ContactSyncLook l) => [
      for (final c in l.choices)
        if (!(l.kind == ContactReviewKind.kept &&
            l.side == null &&
            (c == ContactSyncChoice.deleteHereToo ||
                c == ContactSyncChoice.keepOnlyHere)))
          c,
    ];

/// Where a contact went: Gmail's deletes are deletions, while one gone
/// from Outlook may have been moved to Deleted Items.
String _goneFrom(ContactSide side, String graphName, {bool lower = false}) {
  final said = side == ContactSide.google
      ? 'Deleted in Gmail'
      : 'Gone from $graphName';
  return lower ? '${said[0].toLowerCase()}${said.substring(1)}' : said;
}

String _title(String title) => title.trim().isEmpty ? '(no name)' : title;

String _count(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// "at 10:42" today, "on Fri 20 Nov at 10:42" another day.
String _when(DateTime at, DateTime now, bool use24h) {
  final clock = formatClock(at, use24h: use24h);
  return _sameDay(at, now)
      ? 'at $clock'
      : 'on ${formatDay(at, now: now)} at $clock';
}

/// "at 10:42" today, "on 20 Nov" another day: the Settings row's shorter
/// form.
String _atOrOn(DateTime at, DateTime now, bool use24h) => _sameDay(at, now)
    ? 'at ${formatClock(at, use24h: use24h)}'
    : 'on ${formatMessageDate(at, now: now, use24h: use24h)}';

String _clockOrDay(DateTime at, DateTime now, bool use24h) =>
    _sameDay(at, now)
        ? formatClock(at, use24h: use24h)
        : '${formatDay(at, now: now)}, ${formatClock(at, use24h: use24h)}';

bool _sameDay(DateTime a, DateTime b) {
  final x = a.toLocal();
  final y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

String _choiceLabel(ContactSyncChoice c, String graphName) => switch (c) {
      ContactSyncChoice.samePerson => 'Same person',
      ContactSyncChoice.copyAnyway => 'Copy it anyway',
      ContactSyncChoice.leaveOut => 'Leave it out',
      ContactSyncChoice.useGoogle => "Use Gmail's",
      ContactSyncChoice.useGraph => "Use $graphName's",
      ContactSyncChoice.leaveAsTheyAre => 'Leave as they are',
      ContactSyncChoice.useOther => 'Use the other',
      ContactSyncChoice.keepNewer => 'Keep the newer',
      ContactSyncChoice.copyBack => 'Copy it back',
      ContactSyncChoice.deleteHereToo => 'Delete it here too',
      ContactSyncChoice.keepOnlyHere => 'Keep it only here',
      ContactSyncChoice.retry => 'Retry',
      ContactSyncChoice.deleteThem => 'Delete them',
      ContactSyncChoice.dontDelete => "Don't delete them",
      ContactSyncChoice.applyThem => 'Apply them',
      ContactSyncChoice.copyThemBack => 'Copy them back',
      ContactSyncChoice.carryOn => "That's right, carry on",
      ContactSyncChoice.keepWaiting => 'Keep waiting',
    };

/// A Needs a look button, naming the side where the plan's "here" would
/// leave it unclear: this screen is in neither address book.
String _lookChoiceLabel(
  ContactSyncLook l,
  ContactSyncChoice c,
  String graphName,
) {
  // The copy that is left: for a contact deleted on one side, the other's;
  // for one left by a merge in Gmail, Hadco's.
  final kept = l.kind == ContactReviewKind.mergedInGoogle
      ? ContactSide.graph
      : (l.side ?? ContactSide.google).other;
  final keptName = _sideName(kept, graphName);
  return switch (c) {
    ContactSyncChoice.useOther => l.losingSide == null
        ? 'Use the other'
        : "Use ${_sideName(l.losingSide!, graphName)}'s instead",
    ContactSyncChoice.deleteHereToo => 'Delete it in $keptName too',
    ContactSyncChoice.keepOnlyHere => 'Keep it only in $keptName',
    _ => _choiceLabel(c, graphName),
  };
}

/// What a Needs a look item is about, in a sentence or two.
String _lookLine(ContactSyncLook l, String graphName) {
  String side(ContactSide s) => _sideName(s, graphName);
  final here = l.side ?? ContactSide.google;
  final there = here.other;
  final named = switch (l.candidates) {
    [final only] => '${_title(only.title)} in ${side(there)}',
    _ => 'a contact in ${side(there)}',
  };
  switch (l.kind) {
    case ContactReviewKind.newContact:
      final why = switch (l.reason) {
        ContactReviewReason.taggedPaired =>
          "MyEmail's own link names $named, which is already paired with "
              'another contact.',
        ContactReviewReason.matchPaired =>
          'Its email or mobile matches $named, which is already paired with '
              'another contact.',
        ContactReviewReason.matchHeld =>
          'Its email or mobile matches $named, which is waiting here itself.',
        // Raised for a match by email or mobile, and for MyEmail's own
        // link naming a contact under another name (a copy typed over as
        // someone else, found after a reinstall): the line fits both.
        ContactReviewReason.namesDisagree =>
          "MyEmail's own link, or its email or mobile, points to $named, "
              'but the names differ.',
        ContactReviewReason.sharedAddress =>
          "Its email or mobile is shared by several contacts, as a family's "
              'is.',
        ContactReviewReason.severalMatches =>
          'Its details match more than one contact in ${side(there)}.',
        ContactReviewReason.sameName =>
          '${side(there)} has a contact with the same name and nothing else '
              'in common.',
        _ => 'It could not be placed safely, so it was not copied.',
      };
      return 'New in ${side(here)}. $why';
    case ContactReviewKind.differing:
      return 'In both, and paired. These details differ, and are left as '
          'they are on both sides until you choose:';
    case ContactReviewKind.clash:
      final losing = l.losing;
      final losingSide = l.losingSide;
      return 'Changed on both sides since the last sync, and the newer '
          'change was kept'
          '${losing == null || losingSide == null ? '' : '. ${side(losingSide)} had: $losing'}'
          '.';
    case ContactReviewKind.kept when l.side == null:
      // Which side it went from is not known: nothing named at a guess.
      return switch (l.reason) {
        ContactReviewReason.changedSince =>
          'Deleted on one side, changed on the other since: kept.',
        ContactReviewReason.firstSync => 'Deleted on one side during the '
            'first sync, which deletes nothing: kept on the other.',
        ContactReviewReason.notDeleted => "Deleted on one side. You chose "
            "Don't delete them: it stays on the other but stops syncing.",
        ContactReviewReason.copyOfGone => 'A copy of a contact that no '
            'longer syncs: its synced copy went, or no longer matches it. '
            'This copy was left as it is.',
        _ => 'Deleted on one side, kept on the other.',
      };
    case ContactReviewKind.kept:
      final gone = _goneFrom(here, graphName);
      return switch (l.reason) {
        ContactReviewReason.changedSince =>
          '$gone, changed in ${side(there)} since: kept.',
        ContactReviewReason.firstSync =>
          '$gone during the first sync, which deletes nothing: kept in '
              '${side(there)}.',
        ContactReviewReason.notDeleted =>
          "$gone. You chose Don't delete them: it stays in ${side(there)} "
              'but stops syncing.',
        // A held copy of a person no longer synced: its pair went, or
        // was renamed away from it. Nothing need have been deleted, so
        // nothing is said to have been. The side named is the copy's.
        ContactReviewReason.copyOfGone => 'A copy of a contact that no '
            'longer syncs: its synced copy went, or no longer matches it. '
            'This copy in ${side(there)} was left as it is.',
        _ => '$gone, kept in ${side(there)}.',
      };
    case ContactReviewKind.mergedInGoogle:
      return 'Merged in Gmail with another contact: delete it in $graphName '
          'too, or keep it only there.';
    case ContactReviewKind.refused:
      return switch (l.side) {
        final refusedBy? => 'Could not copy to ${side(refusedBy)}: it would '
            'not take this contact, perhaps for a detail too long.',
        null => 'Could not copy this contact: the other side would not take '
            'it, perhaps for a detail too long.',
      };
  }
}

String _fieldLabel(ContactField f) => switch (f) {
      ContactField.name => 'Name',
      ContactField.nickname => 'Nickname',
      ContactField.emails => 'Emails',
      ContactField.mobile => 'Mobile',
      ContactField.homePhones => 'Home phones',
      ContactField.workPhones => 'Work phones',
      ContactField.homeAddress => 'Home address',
      ContactField.workAddress => 'Work address',
      ContactField.otherAddress => 'Other address',
      ContactField.company => 'Company',
      ContactField.department => 'Department',
      ContactField.jobTitle => 'Job title',
      ContactField.office => 'Office',
      ContactField.birthday => 'Birthday',
      ContactField.notes => 'Notes',
      ContactField.spouse => 'Spouse',
      ContactField.children => 'Children',
      ContactField.manager => 'Manager',
      ContactField.assistant => 'Assistant',
      ContactField.webPage => 'Web page',
      ContactField.im => 'IM names',
    };

// ---------------------------------------------------------------------------
// Accounts.

Account? _byId(List<Account> accounts, String? id) =>
    id == null ? null : accounts.firstWhereOrNull((a) => a.id == id);

/// The pair the runner has, each account only while it is still in
/// MyEmail.
(Account?, Account?) _runnerPair(List<Account> accounts, ContactSyncStatus? s) =>
    (
      _byId(_googleAccounts(accounts), s?.googleAccountId),
      _byId(_graphAccounts(accounts), s?.graphAccountId),
    );

/// Gmail accounts that could take part: not a mailbox shared through
/// another account.
List<Account> _googleAccounts(List<Account> accounts) => [
      for (final a in accounts)
        if (a.provider == MailProvider.gmail && !a.isShared) a,
    ];

/// Microsoft accounts' own mailboxes, whose Contacts folder is theirs.
List<Account> _graphAccounts(List<Account> accounts) => [
      for (final a in accounts)
        if (a.provider == MailProvider.outlook && !a.isShared) a,
    ];

// ---------------------------------------------------------------------------
// Pieces.

/// An answer or a Restore, queued: a failure said along the bottom,
/// after whatever is there now.
Future<void> _act(
  BuildContext context,
  Future<void> Function() action, {
  VoidCallback? onFailure,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await action();
  } catch (e) {
    messenger?.showSnackBar(SnackBar(
      duration: kBottomMessage,
      content: Text(e is ReadableError ? e.message : '$e'),
    ));
    onFailure?.call();
  }
}

void _sayFailure(BuildContext context, Object e) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
    duration: kBottomMessage,
    content: Text(e is ReadableError ? e.message : '$e'),
  ));
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        text,
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _Para extends StatelessWidget {
  const _Para(
    this.text, {
    super.key,
    this.muted = false,
    this.strong = false,
    this.top = 4,
  });

  final String text;
  final bool muted;
  final bool strong;
  final double top;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, top, 16, 8),
      child: Text(
        text,
        style: muted
            ? theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
            : strong
                ? theme.textTheme.titleSmall
                : theme.textTheme.bodyMedium,
      ),
    );
  }
}

/// The screen's list, no wider than reads well: on a tablet, a line across
/// the whole screen is hard to follow, and a number at its far end harder
/// still to tie to its label.
class _Body extends StatelessWidget {
  const _Body({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: children,
          ),
        ),
      );
}

class _Buttons extends StatelessWidget {
  const _Buttons(this.children);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Wrap(spacing: 8, runSpacing: 8, children: children),
      );
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: LinearProgressIndicator(),
      );
}

class _Problem extends StatelessWidget {
  const _Problem({required this.doing, required this.error, this.onRemedy});

  final String doing;
  final Object error;
  final VoidCallback? onRemedy;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: ProblemView(
          problem: ProblemReport(doing: doing, error: error),
          onRemedy: onRemedy,
        ),
      );
}
