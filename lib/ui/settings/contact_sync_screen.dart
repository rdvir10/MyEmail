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

  /// Whether the screen is open: the shell's one-line message about a stop
  /// says nothing this screen is not already showing.
  static bool get isOpen => _open > 0;
  static int _open = 0;

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
  Object? _backupError;
  String? _backupSaid;

  ContactSyncService get _sync => ref.read(mailEngineProvider).contactSync;

  @override
  void initState() {
    super.initState();
    ContactSyncScreen._open++;
  }

  @override
  void dispose() {
    ContactSyncScreen._open--;
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
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
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
  Future<void> _saveBackup(
    Account google,
    Account graph,
    String graphName,
  ) async {
    final steps = ref.read(contactSyncFirstStepsProvider.notifier);
    final files = ref.read(backupFilesProvider);
    final sync = _sync;
    final pair = ContactSyncFirstSteps.pairKey(google.id, graph.id);
    setState(() {
      _saving = true;
      _backupError = null;
      _backupSaid = null;
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
        steps.backupSaved(pair, file.side);
      }
      if (mounted) {
        setState(() => _backupSaid = _savedSaid(saved, backup.length));
      }
    } catch (e) {
      if (mounted) setState(() => _backupError = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String? _savedSaid(List<ContactSyncBackupFile> saved, int of) {
    if (saved.isEmpty) return null;
    String one(ContactSyncBackupFile f) =>
        '${f.fileName}, ${_count(f.count, 'contact', 'contacts')}, which '
        '${f.side == ContactSide.google ? 'Google Contacts' : 'Outlook on the web'} '
        'can import';
    final said = 'Saved ${saved.map(one).join(', and ')}.';
    if (saved.length == of) return said;
    return '$said Start sync needs both files: Save backup again.';
  }

  Future<void> _start(Account google, Account graph) async {
    final sync = _sync;
    try {
      await _choose(google, graph);
    } catch (e) {
      if (mounted) _sayFailure(context, e);
      return;
    }
    // Completes when the run ends, and never throws: the status shows it.
    unawaited(sync.start());
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
        ..._running(s.running!)
      else if (!ours || !s.firstStarted)
        ..._firstSync(google, graph, graphName)
      else
        ..._lastResult(s, google, graph, graphName),
      if (s != null && ours) ...[
        for (final q in s.questions)
          _QuestionCard(
            question: q,
            graphName: graphName,
            onAnswer: (choice) => _act(
              context,
              () => _sync.answerQuestion(q.kind, choice),
            ),
          ),
        if (s.firstStarted ||
            s.needsALook.isNotEmpty ||
            s.recentlyDeleted.isNotEmpty) ...[
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
      ],
    ];
  }

  void _push(Widget screen) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => screen),
      );

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
    final ready = both && preview != null && steps.backupSaved;
    final backupSaid = _backupSaid ??
        switch (steps.saved.length) {
          0 => null,
          1 => "${_sideName(steps.saved.single, graphName)}'s file is "
              'saved. Start sync needs both files: Save backup again.',
          _ => 'Both files are saved.',
        };
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
      if (_saving) const _Working(),
      if (_backupError case final e?)
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
          onPressed: ready ? () => _start(google, graph) : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start sync'),
        ),
      ]),
      _Para(
        ready
            ? 'Keep MyEmail open until this says Synced. If it is closed '
                'sooner, the first sync carries on the next time MyEmail is '
                'opened.'
            : 'Start sync is ready once you have seen the preview and saved '
                'both backup files.',
        muted: true,
      ),
    ];
  }

  /// The way out of a failure, where there is one: the account's Allow
  /// for one that has not allowed it, or [again] for one worth trying
  /// again.
  VoidCallback? _remedy(
    Object e,
    Account google,
    Account graph,
    VoidCallback again,
  ) =>
      switch (e) {
        ContactSyncNeedsSignIn(:final side) => () =>
            _allow(side == ContactSide.google ? google : graph),
        Retryable() => again,
        _ => null,
      };

  List<Widget> _running(ContactSyncProgress running) {
    final writing = running.step == ContactSyncStep.writing;
    return [
      _Heading(running.firstSync ? 'First sync' : 'Syncing'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: LinearProgressIndicator(
          key: const ValueKey('contact-sync-progress'),
          value: writing && running.total > 0
              ? running.done / running.total
              : null,
        ),
      ),
      _Para(switch ((writing, running.total)) {
        (false, _) => 'Reading both address books…',
        (true, 0) => 'Copying changes…',
        (true, final total) => 'Copying changes: ${running.done} of $total',
      }),
      if (running.firstSync)
        const _Para(
          'Keep MyEmail open until this says Synced. If it is closed sooner, '
          'the first sync carries on the next time MyEmail is opened.',
          muted: true,
        ),
    ];
  }

  /// How the last sync went, why it stopped if it did, and Sync now.
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
      final l? when l.complete => _syncedLine(l, now, use24h),
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
    // A failure offers Try again in its place, another device Sync here,
    // and an empty answer its question: a sync now would only stop again.
    final halt = s.halt;
    final offersItsOwn = switch (halt?.kind) {
      ContactSyncHaltKind.failed ||
      ContactSyncHaltKind.otherDevice ||
      ContactSyncHaltKind.emptyAnswer => true,
      _ => false,
    };
    return [
      if (line != null) _Para(line, key: const ValueKey('contact-sync-last')),
      if (halt != null && halt.kind != ContactSyncHaltKind.putAway)
        ..._halt(s, halt, google, graph, graphName, now, use24h),
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
    DateTime now,
    bool use24h,
  ) {
    final side = halt.side ?? ContactSide.graph;
    final name = _sideName(side, graphName);
    switch (halt.kind) {
      case ContactSyncHaltKind.notAllowed:
        final account = side == ContactSide.google ? google : graph;
        return [
          _Para('Contact sync has stopped: not allowed yet for $name.'),
          if (halt.error case final e?)
            _Problem(
              doing: 'Syncing contacts',
              error: e,
              onRemedy: () => _allow(account),
            ),
        ];
      case ContactSyncHaltKind.otherDevice:
        return [
          const _Para(
            'Contact sync is on on your other device',
            strong: true,
          ),
          _Para(
            '${switch (halt.claimedAt) {
              null => 'It has synced there lately',
              final at => 'It last synced there ${_when(at, now, use24h)}',
            }}. Only one device may sync, or the two would work against '
            'each other: turn it off there, or sync here instead.',
          ),
          _Buttons([
            OutlinedButton(
              key: const ValueKey('contact-sync-here'),
              onPressed: () => _act(context, _sync.syncHere),
              child: const Text('Sync here'),
            ),
          ]),
        ];
      case ContactSyncHaltKind.emptyAnswer:
        // Its question says it, with the buttons.
        if (s.questions.any(
          (q) => q.kind == ContactSyncQuestionKind.emptyAnswer,
        )) {
          return const [];
        }
        return [
          _Para(
            'Contact sync has stopped: $name listed far fewer contacts than '
            'expected.',
          ),
        ];
      case ContactSyncHaltKind.quota:
        final until = halt.until;
        return [
          _Para(
            "Google's daily limit on changes to contacts is spent. Contact "
            'sync carries on '
            '${until == null ? 'tomorrow' : 'after ${_clockOrDay(until, now, use24h)}'}.',
          ),
        ];
      case ContactSyncHaltKind.failed:
        return [
          _Para('The last sync stopped ${_when(halt.at, now, use24h)}.'),
          _Problem(
            doing: 'Syncing contacts',
            error: halt.error ??
                const ContactSyncFailed('Contact sync could not finish.'),
            onRemedy: _syncNow,
          ),
        ];
      case ContactSyncHaltKind.putAway:
        return const [];
    }
  }

  static String _syncedLine(ContactSyncTally t, DateTime now, bool use24h) {
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
      ContactSyncAccessState.notPossible when gmail => (
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

/// A brake's question: what is held, and the two answers.
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.graphName,
    required this.onAnswer,
  });

  final ContactSyncQuestion question;
  final String graphName;
  final ValueChanged<ContactSyncChoice> onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = question;
    String side(ContactSide s) => _sideName(s, graphName);
    final n = q.items.length;
    final (String title, String body, String explain) = switch (q.kind) {
      ContactSyncQuestionKind.deletions => (
          _count(n, 'deletion needs your OK', 'deletions need your OK'),
          'One sync would delete more than 5 contacts, so these are held, '
              'and everything else carries on.',
          'Delete them deletes those still due, each read again first. '
              "Don't delete them: ${_staySide(q.items, graphName)} but "
              'stop syncing, and each waits under Needs a look, where it '
              'can still be copied back.',
        ),
      ContactSyncQuestionKind.changes => (
          'Changes to ${_count(n, 'contact', 'contacts')} need your OK',
          'One sync would remove or replace details on more than 10 '
              "contacts, as Google's Undo changes, a backup imported again "
              'or a bulk edit can. These are held, and everything else '
              'carries on.',
          'Copy them back puts the details back where they were removed or '
              'replaced, from the other side. Either way each is read again '
              'first.',
        ),
      ContactSyncQuestionKind.emptyAnswer => (
          q.listed == null
              ? '${side(q.side ?? ContactSide.graph)} listed far fewer '
                  'contacts than expected'
              : '${side(q.side ?? ContactSide.graph)} listed only '
                  '${_count(q.listed!, 'contact', 'contacts')}',
          '${q.expected == null ? 'Far more were' : '${q.expected} were'} '
              'expected. Contact sync has stopped and written nothing, '
              'because a lapsed permission, a wrong folder or an empty '
              'answer must never read as everything deleted.',
          "That's right, carry on takes "
              '${q.listed == null ? 'the new count' : '${q.listed}'} as the '
              'number to expect. Keep waiting leaves it stopped, and the '
              'next sync looks again.',
        ),
    };
    String item(ContactSyncQuestionItem i) => switch (q.kind) {
          ContactSyncQuestionKind.deletions =>
            '${_title(i.title)}: ${_goneFrom(i.side, graphName, lower: true)}',
          ContactSyncQuestionKind.changes =>
            '${_title(i.title)}: would lose details in ${side(i.side)}',
          ContactSyncQuestionKind.emptyAnswer => _title(i.title),
        };
    final answer = q.answer;
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
            if (q.items.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final i in q.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(item(i)),
                ),
            ],
            const SizedBox(height: 8),
            if (answer != null)
              Text(
                'You chose ${_choiceLabel(answer, graphName)}. The next sync '
                'carries it out.',
                style: TextStyle(color: theme.colorScheme.primary),
              )
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in q.choices)
                    OutlinedButton(
                      key: ValueKey('contact-sync-answer:${c.name}'),
                      onPressed: () => onAnswer(c),
                      child: Text(_choiceLabel(c, graphName)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                explain,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
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

/// Needs a look: each contact the sync could not settle on its own, with
/// its answers, and one answer for every new pair whose details differ.
class _LooksScreen extends ConsumerWidget {
  const _LooksScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(contactSyncStatusProvider).value;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final graphName =
        contactSyncAccountName(_byId(accounts, status?.graphAccountId));
    final sync = ref.read(mailEngineProvider).contactSync;
    final looks = status?.needsALook ?? const <ContactSyncLook>[];
    final differing = looks
        .where((l) => l.kind == ContactReviewKind.differing && l.answer == null)
        .length;
    return Scaffold(
      appBar: AppBar(title: const Text('Needs a look'), centerTitle: false),
      body: _Body(
        children: [
          const _Para(
            'Contacts the sync could not settle on its own. An answer is '
            'carried out in the next sync, which starts at once.',
            top: 16,
          ),
          if (looks.isEmpty) const _Para('Nothing needs a look.'),
          if (differing > 1) ...[
            _Para(
              'Every pair whose details differ ($differing):',
              strong: true,
              top: 8,
            ),
            _Buttons([
              for (final c in const [
                ContactSyncChoice.useGoogle,
                ContactSyncChoice.useGraph,
                ContactSyncChoice.leaveAsTheyAre,
              ])
                OutlinedButton(
                  key: ValueKey('contact-sync-all:${c.name}'),
                  onPressed: () =>
                      _act(context, () => sync.answerAllDiffering(c)),
                  child: Text(_choiceLabel(c, graphName)),
                ),
            ]),
          ],
          for (final look in looks) ...[
            const Divider(height: 1),
            _LookTile(
              look: look,
              graphName: graphName,
              onAnswer: (choice, {candidateId}) => _act(
                context,
                () => sync.answerLook(look.id, choice, candidateId: candidateId),
              ),
            ),
          ],
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
  });

  final ContactSyncLook look;
  final String graphName;
  final _LookAnswer onAnswer;

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
          if (answer != null)
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
                for (final c in l.choices)
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
          if (l.kind == ContactReviewKind.refused && answer == null) ...[
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
      return d.restoreAsked && d.state != ContactSyncDeletedState.back
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
              subtitle: Text(line(d)),
              trailing: d.restoreAsked ||
                      d.state == ContactSyncDeletedState.back
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
  String side(ContactSide? side) =>
      _sideName(side ?? ContactSide.graph, graphName);
  final pair = 'Gmail and $graphName';
  for (final q in s.questions) {
    if (q.answer != null) continue;
    switch (q.kind) {
      case ContactSyncQuestionKind.deletions:
        return _count(
          q.items.length,
          'deletion needs your OK',
          'deletions need your OK',
        );
      case ContactSyncQuestionKind.changes:
        return 'Changes to ${_count(q.items.length, 'contact', 'contacts')} '
            'need your OK';
      case ContactSyncQuestionKind.emptyAnswer:
        return 'Stopped: ${side(q.side)} listed too few contacts';
    }
  }
  if (s.isRunning) return '$pair, syncing now';
  if (s.halt case final halt?) {
    switch (halt.kind) {
      case ContactSyncHaltKind.notAllowed:
        return 'Not allowed yet for ${side(halt.side)}';
      case ContactSyncHaltKind.otherDevice:
        return 'Syncing on your other device';
      case ContactSyncHaltKind.emptyAnswer:
        return 'Stopped: ${side(halt.side)} listed too few contacts';
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
  final side = _sideName(halt.side ?? ContactSide.graph, graphName);
  return switch (halt.kind) {
    ContactSyncHaltKind.notAllowed =>
      'Contact sync has stopped: not allowed yet for $side',
    ContactSyncHaltKind.otherDevice => 'Contact sync is on on your other device',
    ContactSyncHaltKind.emptyAnswer =>
      'Contact sync has stopped: $side listed far fewer contacts than before',
    ContactSyncHaltKind.quota =>
      "Contact sync has stopped: Google's daily limit on changes is spent",
    ContactSyncHaltKind.failed => 'Contact sync could not finish',
    ContactSyncHaltKind.putAway => null,
  };
}

/// The Microsoft account's name in what contact sync says: its name in
/// MyEmail ("Hadco"), or its address where it has none.
String contactSyncAccountName(Account? account) {
  if (account == null) return 'the Microsoft account';
  final name = account.displayName.trim();
  return name.isEmpty ? account.emailAddress : name;
}

String _sideName(ContactSide side, String graphName) =>
    side == ContactSide.google ? 'Gmail' : graphName;

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
        ContactReviewReason.namesDisagree =>
          'Its email or mobile matches $named, but the names differ.',
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
        _ => '$gone, kept in ${side(there)}.',
      };
    case ContactReviewKind.mergedInGoogle:
      return 'Merged in Gmail with another contact: delete it in $graphName '
          'too, or keep it only there.';
    case ContactReviewKind.refused:
      return 'Could not copy to ${side(l.side ?? ContactSide.graph)}: it '
          'would not take this contact, perhaps for a detail too long.';
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

/// An answer or a Restore, queued: a failure said along the bottom.
Future<void> _act(BuildContext context, Future<void> Function() action) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await action();
  } catch (e) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: kBottomMessage,
        content: Text(e is ReadableError ? e.message : '$e'),
      ));
  }
}

void _sayFailure(BuildContext context, Object e) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
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
