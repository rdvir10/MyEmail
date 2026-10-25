import 'ai_writing.dart';
import 'dart:async';

import '../common/bottom_message.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/account.dart';
import '../../domain/error_report.dart';
import '../common/problem_view.dart';

import '../../data/files/file_bridge.dart';
import '../../domain/draft.dart';
import '../../domain/address_suggestions.dart'
    show AddressSuggestion, formatRecipient;
import '../../domain/signature.dart';
import 'free_times.dart';
import 'insert_picture.dart';
import 'mail_tips_line.dart';
import 'mention_suggestions.dart';
import '../../domain/send_checks.dart';
import '../../state/display_providers.dart';
import '../../state/held_sends.dart';
import '../../state/attachment_providers.dart';
import '../../state/compose_providers.dart';
import '../../state/drop_providers.dart';
import '../../state/providers.dart';
import '../../state/window_providers.dart';
import '../../domain/window_handoff.dart';
import 'header_fields.dart';
import 'html_editor.dart';
import '../shell/put_away.dart';

/// Write, reply to or forward a message.
///
/// The body is a WebView editor holding one document: your new text, the
/// signature, and the quoted original, all editable. The toolbar is Flutter
/// rather than HTML because it has to sit above the soft keyboard and track
/// its inset, which an in-page toolbar cannot do.
class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({
    super.key,
    required this.draft,
    this.disposable = true,
    this.inWindow = false,
  });

  final Draft draft;

  /// In a window of its own, where Undo Send does not hold the message:
  /// the window closes as it goes, and there is no bar left to undo on.
  final bool inWindow;

  /// Whether closing the window as it opened loses nothing, because what it
  /// opened with can be had again: a new message, reply or forward as the
  /// app builds it, or a draft already in Drafts. False for one carried
  /// across from another window, or holding what another app shared, which
  /// exists nowhere else; leaving that always asks.
  final bool disposable;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen>
    with WidgetsBindingObserver, GuardsPutAway<ComposeScreen> {
  late final HtmlEditorController _editor =
      HtmlEditorController(initialHtml: widget.draft.htmlBody)
        ..onKey = _onEditorKey;
  late final TextEditingController _to =
      TextEditingController(text: formatAddresses(widget.draft.to));
  late final TextEditingController _cc =
      TextEditingController(text: formatAddresses(widget.draft.cc));
  late final TextEditingController _bcc =
      TextEditingController(text: formatAddresses(widget.draft.bcc));
  late final TextEditingController _subject =
      TextEditingController(text: widget.draft.subject);

  final _fromFocus = FocusNode();
  final _toFocus = FocusNode();
  final _ccFocus = FocusNode();
  final _bccFocus = FocusNode();
  final _subjectFocus = FocusNode();

  /// The body has been given the cursor a reply starts with, or did not
  /// need it.
  bool _caretPlaced = false;

  late List<DraftAttachment> _attachments = List.of(widget.draft.attachments);

  /// The ⋮ menu's choices: High or Low importance, and a read receipt.
  late Importance _importance = widget.draft.importance;
  late bool _readReceipt = widget.draft.requestReadReceipt;
  /// Bcc is the one line that stays hidden until asked for: it is rare, and
  /// a row nobody uses on every message is a row between them and the body.
  bool _showBcc = false;
  bool _sending = false;
  /// Something the person can correct by typing — a missing recipient, an
  /// address with a typo. Not a failure, and nothing to report.
  String? _invalid;

  /// Something that went wrong out of their hands. Worth reporting.
  ProblemReport? _problem;

  /// Where a dropped file goes while this screen is open.
  DropTargets? _drops;

  /// The editor's document once it had loaded, before anything was typed:
  /// what "unchanged" is measured against. The browser rewrites markup as
  /// it parses, so the draft's own HTML would never compare equal.
  String? _openedHtml;

  /// A copy put in Drafts because the app went into the background, where
  /// Android may end it without a word: the file picker, a switch to
  /// another app, Recents. Kept apart from the copy this was opened from, so
  /// Discard still means discard and a reopened draft is never overwritten
  /// behind the person's back. Each later background save replaces it, and
  /// it goes once the window ends any other way. If the app is ended, it is
  /// what is left.
  String? _backgroundCopy;

  /// What [_backgroundCopy] holds, so an unchanged message is not saved
  /// again every time the app is put away.
  String? _backgroundCopyOf;

  /// The background copy being saved, while it is.
  Future<void>? _backgroundSaving;

  /// Where this message's own draft is: where it was opened from, and then
  /// wherever putting the app away saved it, since a save gives it a new
  /// name. Should the person be back before the screen closes, it stays
  /// open, and a later save replaces that copy rather than leaving a second
  /// beside it.
  late String? _savedAs = widget.draft.savedAs;

  /// The save of putting the app away, while it runs; no background copy
  /// is started meanwhile. The person can be back, with this screen in
  /// front of them, before it has finished.
  Future<bool>? _puttingAway;

  /// The whole of [whenPutAway] while it runs, its wait for a background
  /// copy still going up included, which is before [_puttingAway] starts.
  Future<bool>? _pendingPutAway;

  /// How many times the app has come back to the front, so a save on the
  /// way out can tell whether the person was back while it ran, even if
  /// they are away again by the time it ends.
  var _timesBack = 0;

  /// The window has ended: sent, saved, discarded, moved or put away. No
  /// background copy is started after that.
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Shown too where the notice asks for a Bcc to be added again.
    _showBcc = widget.draft.bcc.isNotEmpty || widget.draft.storedCopyUnread;
    _editor.addListener(_onEditorState);
    // While this screen is open, a file dropped anywhere on the app is an
    // attachment for this message rather than the start of a new one. Held
    // in a field because dispose cannot reach through ref: by then the
    // element is on its way out.
    final drops = ref.read(dropTargetProvider);
    _drops = drops;
    drops.claim(_takeIncoming);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _drops?.release(_takeIncoming);
    _editor
      ..removeListener(_onEditorState)
      ..dispose();
    _to.dispose();
    _cc.dispose();
    _bcc.dispose();
    _subject.dispose();
    for (final node in [
      _fromFocus,
      _toFocus,
      _ccFocus,
      _bccFocus,
      _subjectFocus,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  void _onEditorState() => setState(() {});

  Future<void> _noteOpened() async {
    try {
      _openedHtml ??= await _editor.getHtml();
    } on EditorUnreadable {
      // Then nothing counts as unchanged, and leaving asks.
    }
    // A reply has its recipients already, so the cursor starts in the body,
    // above the quote. Not if it has been put in a field meanwhile, and only
    // the once: the page finishing again is no reason to take it back.
    if (!mounted || _caretPlaced) return;
    _caretPlaced = true;
    if (widget.draft.to.isNotEmpty &&
        !_tabStops().any((stop) => stop?.hasFocus ?? false)) {
      await _editor.focus();
    }
  }

  /// Whether leaving loses nothing: the window is as it opened, and what it
  /// opened with can be had again.
  ///
  /// Asked on its own, "is there anything here" said yes to every reply,
  /// which has a recipient and a subject before a word is typed, so backing
  /// out of one opened by mistake always asked to save it.
  bool _unchanged(Draft now) =>
      widget.disposable &&
      now.accountId == widget.draft.accountId &&
      _to.text == formatAddresses(widget.draft.to) &&
      _cc.text == formatAddresses(widget.draft.cc) &&
      _bcc.text == formatAddresses(widget.draft.bcc) &&
      _subject.text == widget.draft.subject &&
      listEquals(_attachments, widget.draft.attachments) &&
      _importance == widget.draft.importance &&
      _readReceipt == widget.draft.requestReadReceipt &&
      now.htmlBody == (_openedHtml ?? widget.draft.htmlBody);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _saveInBackground();
    if (state == AppLifecycleState.resumed) _timesBack++;
  }

  /// Put what is written in Drafts as the app goes into the background.
  /// Quietly: nothing on screen changes, and a failure changes nothing
  /// either, because the window is still open with everything in it.
  void _saveInBackground() {
    if (_sending || _puttingAway != null || _ended) return;
    _backgroundSaving ??=
        _copyToDrafts().whenComplete(() => _backgroundSaving = null);
  }

  Future<void> _copyToDrafts() async {
    try {
      final now = await _currentDraft();
      if (!now.isWorthSaving || _unchanged(now)) return;
      final holds = _fingerprint(now);
      if (holds == _backgroundCopyOf || !mounted || _ended) return;
      final saved = await saveDraft(ref, now.withSavedAs(_backgroundCopy));
      // Kept even if the window has ended meanwhile: that is what
      // _dropBackgroundCopy is waiting for, to take it out again.
      _backgroundCopy = saved.savedAs;
      _backgroundCopyOf = holds;
    } catch (_) {
      // Offline, most likely. The message is still on screen.
    }
  }

  /// Put away by the person (Home, another app): saved to Drafts as Save
  /// draft would save it, and the screen may close, so the app comes back
  /// to the mail rather than to a message half written. A message as it
  /// opened, untouched, just closes.
  ///
  /// Stays open while it is being sent, and when it cannot be saved:
  /// closing then would lose it.
  @override
  Future<bool> whenPutAway() async {
    final whole = _putAway();
    _pendingPutAway = whole;
    try {
      return await whole;
    } finally {
      if (identical(_pendingPutAway, whole)) _pendingPutAway = null;
    }
  }

  Future<bool> _putAway() async {
    if (_sending) return false;
    // The background copy started a moment ago, as the app went out of
    // sight; it is dropped below once the real one is saved. Or the last
    // put-away's save, the person having been back and away again before
    // it had finished: this one saves over what that one saved.
    await _quietSavesDone();
    // Sent, saved or thrown away meanwhile, the screen merely not gone yet
    // with the app out of sight: there is nothing left to save.
    if (!mounted || _ended) return true;
    // Back already, or leaving some other way: the screen stays, so there
    // is nothing to save it for.
    if (_sending || isInFront()) return false;
    final saving = _saveForPutAway();
    _puttingAway = saving;
    try {
      return await saving;
    } finally {
      _puttingAway = null;
    }
  }

  /// The save of [whenPutAway], and whether the screen may go once it is
  /// done.
  Future<bool> _saveForPutAway() async {
    final timesBack = _timesBack;
    final Draft now;
    try {
      now = await _currentDraft();
    } on EditorUnreadable {
      return false;
    }
    // Back while it was saved, even if away again since: what was read
    // may not be all there is now, and the screen stays, for whatever the
    // person does next with it.
    bool backMeanwhile() => _timesBack != timesBack;
    if (now.isWorthSaving && !_unchanged(now)) {
      // A message with no draft of its own yet is saved over that copy:
      // one draft in Drafts, not a second beside it.
      final into = _savedAs ?? _backgroundCopy;
      final String? savedAs;
      try {
        savedAs = (await saveDraft(ref, now.withSavedAs(into))).savedAs;
      } catch (_) {
        return false;
      }
      if (into != null && into == _backgroundCopy) {
        _backgroundCopy = null;
        _backgroundCopyOf = null;
      }
      if (_savedAs == null && backMeanwhile()) {
        // With no draft of its own, what was saved is a copy against the
        // app being ended, as the background one is, and it goes the same
        // way: saved over next time, and thrown away if the message is.
        _backgroundCopy = savedAs;
        _backgroundCopyOf = _fingerprint(now);
        return false;
      }
      _savedAs = savedAs;
    }
    // Back meanwhile, the screen stays, and goes on keeping a background
    // copy against the app being ended: the one saved over is taken out,
    // but the window has not ended.
    if (mounted) _dropBackgroundCopy(ending: !backMeanwhile());
    return !backMeanwhile();
  }

  /// Until no quiet save is under way: the background copy, or the save of
  /// putting the app away. What either leaves in Drafts is only known once
  /// it has finished, and a screen left before then left that copy behind,
  /// with nothing to remove it or save over it.
  Future<void> _quietSavesDone() async {
    for (var saving = _backgroundSaving ?? _puttingAway;
        saving != null;
        saving = _backgroundSaving ?? _puttingAway) {
      try {
        await saving;
      } catch (_) {
        // How it went is its own business; only that it has ended matters.
      }
    }
  }

  /// Waits for a put-away under way, its save included, before the screen
  /// is left by Send, Save, Discard or a window of its
  /// own, with its buttons held meanwhile, so it is not left twice over.
  /// False if it has gone in the meantime.
  ///
  /// The whole put-away, its wait for a background copy included: held for
  /// meanwhile, that put-away finds the screen busy and leaves it alone,
  /// where it otherwise saved a copy of a message just sent, or closed a
  /// screen showing that its send had failed. A background copy on its own
  /// is not waited for: [_dropBackgroundCopy] takes it out once it has
  /// landed, and Save draft saves over it ([_saveForGood]), so a message is
  /// sent or thrown away at once rather than after an upload.
  Future<bool> _readyToLeave() async {
    if (!mounted) return false;
    if (_pendingPutAway == null) return true;
    setState(() => _sending = true);
    try {
      for (var saving = _pendingPutAway;
          saving != null;
          saving = _pendingPutAway) {
        try {
          await saving;
        } catch (_) {
          // How it went is its own business; only that it has ended matters.
        }
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    return mounted;
  }

  /// Save [now] as the window closes on it, once a background copy still
  /// going up has landed. A message with no draft of its own yet is saved
  /// over that copy: one draft in Drafts, not a second beside it.
  ///
  /// Waited for because where a copy went is read back as the newest
  /// message in Drafts. Saved alongside a background copy still going up,
  /// this one landed before that save looked for its own, which it then
  /// took to be this one. So this one was taken out as the window closed:
  /// the copy with the file just picked went, and the older copy stayed.
  Future<void> _saveForGood(Draft now) async {
    await _backgroundSaving;
    final into = _savedAs ?? _backgroundCopy;
    await saveDraft(ref, now.withSavedAs(into));
    if (into != null && into == _backgroundCopy) {
      _backgroundCopy = null;
      _backgroundCopyOf = null;
    }
  }

  String _fingerprint(Draft d) => [
        d.accountId,
        d.to,
        d.cc,
        d.bcc,
        d.subject,
        d.htmlBody,
        d.importance,
        d.requestReadReceipt,
        for (final a in d.attachments) identityHashCode(a),
      ].join('\u0000');

  /// The window is ending some other way, so the background copy has done
  /// its job. Not waited for: leaving must not hang on the network, and a
  /// copy that fails to go is untidy rather than wrong.
  ///
  /// A copy still being saved goes once it has landed. Looked for at once,
  /// it was not there yet, so nothing was taken out: a message sent or
  /// thrown away while the file picker's copy was going up stayed in
  /// Drafts, and one saved and closed was there twice.
  ///
  /// Not [ending] when a put-away has saved over it but the person is back:
  /// the screen stays, and goes on keeping a background copy.
  void _dropBackgroundCopy({bool ending = true}) {
    if (ending) _ended = true;
    final engine = ref.read(mailEngineProvider);
    final saving = _backgroundSaving;
    unawaited(() async {
      await saving;
      final copy = _backgroundCopy;
      if (copy == null) return;
      _backgroundCopy = null;
      _backgroundCopyOf = null;
      await engine.discardDraft(copy).catchError((_) {});
    }());
  }

  /// Files dropped on the app or pasted from the clipboard.
  Future<void> _takeIncoming(List<IncomingFile> files) async {
    final added = await readIncoming(files);
    if (!mounted) return;
    if (added.isEmpty) {
      _say('Nothing there could be read as a file.');
      return;
    }
    setState(() => _attachments = [..._attachments, ...added]);
  }

  Future<void> _pasteAttachment() async {
    final files = await ref.read(fileBridgeProvider).pasteFiles();
    if (!mounted) return;
    if (files.isEmpty) {
      // Text on the clipboard belongs in the body, and the editor already
      // pastes that; saying so beats a button that silently does nothing.
      _say('No file on the clipboard.');
      return;
    }
    await _takeIncoming(files);
  }

  void _say(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(message)));

  Future<void> _addAttachment() async {
    // file_picker 13: pickFiles is static, returns the files directly, and
    // the bytes are read on demand rather than handed over eagerly.
    final files = await FilePicker.pickFiles();
    if (files.isEmpty || !mounted) return;
    final added = <DraftAttachment>[];
    for (final f in files) {
      try {
        added.add(DraftAttachment(
          fileName: f.name,
          mimeType: _mimeFor(f.extension),
          bytes: await f.readAsBytes(),
        ));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
                SnackBar(duration: kBottomMessage, content: Text('Could not read ${f.name}: $e')));
        }
      }
    }
    if (mounted) {
      setState(() => _attachments = [..._attachments, ...added]);
    }
  }

  static String _mimeFor(String? extension) => switch (extension?.toLowerCase()) {
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'txt' => 'text/plain',
        'csv' => 'text/csv',
        'zip' => 'application/zip',
        'doc' => 'application/msword',
        'docx' =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'xls' => 'application/vnd.ms-excel',
        'xlsx' =>
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        _ => 'application/octet-stream',
      };

  /// The account this message is written from, for a report. Null while the
  /// accounts are still loading, which a report survives.
  Account? _accountOrNull() => ref
      .read(accountsProvider)
      .value
      ?.where((a) => a.id == _accountId)
      .firstOrNull;

  /// Which account this goes out from. Starts as the draft's — the account
  /// the original arrived at, for a reply — and can be changed from the
  /// header, because the message in front of you is not always the one the
  /// answer should come from.
  late String _accountId = widget.draft.accountId;

  /// Put [accountId]'s signature for this kind of message in place of the
  /// one it has. It used to keep the first account's, so a message sent
  /// from a second account went out signed as the first, or unsigned.
  void _useSignatureOf(String accountId) {
    final signature =
        ref.read(signaturesProvider.notifier).forAccount(accountId);
    unawaited(_editor.setSignature(signature.htmlFor(widget.draft.kind)));
  }

  /// The Signature menu on the bar under the message, as Outlook has it:
  /// any of the sending account's signatures in place of the one there, or
  /// none. Not there for an account with none.
  Widget? _signatureMenu() {
    final signature = ref.watch(signaturesProvider)[_accountId];
    final named = [
      for (final s in signature?.named ?? const <NamedSignature>[])
        if (!s.isEmpty) s,
    ];
    if (named.isEmpty) return null;
    return PopupMenuButton<String>(
      key: const ValueKey('signature-menu'),
      tooltip: 'Signature',
      enabled: !_sending,
      icon: const Icon(Icons.draw_outlined),
      onSelected: (id) => unawaited(_editor.setSignature(
        named.where((s) => s.id == id).firstOrNull?.html ?? '',
      )),
      itemBuilder: (_) => [
        for (final s in named) PopupMenuItem(value: s.id, child: Text(s.name)),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '', child: Text('No signature')),
      ],
    );
  }

  /// Ctrl+Enter sends, Esc leaves, and Tab moves between the fields, from
  /// the header fields. The body is a WebView, whose keys never reach
  /// Flutter; the editor's page reports the same ones, and they come in
  /// through [_onEditorKey].
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final control = keyboard.isControlPressed || keyboard.isMetaPressed;
    final key = event.logicalKey;
    // Held down too, or the repeats went to Flutter's own Tab, which stops
    // at every button.
    if (key == LogicalKeyboardKey.tab && !control && !keyboard.isAltPressed) {
      _tab(back: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (control &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      _onEditorKey('send');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _onEditorKey('close');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onEditorKey(String key) {
    if (_sending) return;
    switch (key) {
      case 'send':
        _send();
      case 'close':
        Navigator.of(context).maybePop();
      // From the body, the last stop: on round to the first, or back to
      // the one before it.
      case 'tab':
        _goTo(_tabStops().first);
      case 'backTab':
        final stops = _tabStops();
        _goTo(stops[stops.length - 2]);
    }
  }

  /// Where Tab goes, in order, and Shift+Tab back: From where there is a
  /// choice of account, To, Cc, Bcc once it is showing, Subject, and the
  /// body, which is null here, being a WebView with no node of its own.
  /// Then round again. Nothing else is a stop — not the buttons, the
  /// toolbar or an attachment — so Tab only ever moves between the places
  /// a message is written in.
  List<FocusNode?> _tabStops() {
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    return [
      if (accounts.length > 1) _fromFocus,
      _toFocus,
      _ccFocus,
      if (_showBcc) _bccFocus,
      _subjectFocus,
      null,
    ];
  }

  /// One stop on, or back. From anywhere else, a button or nothing at all,
  /// Tab starts at the first stop and Shift+Tab at the body.
  void _tab({required bool back}) {
    final stops = _tabStops();
    final at = stops.indexWhere((stop) => stop?.hasFocus ?? false);
    final next = at < 0
        ? (back ? stops.length - 1 : 0)
        : (at + (back ? -1 : 1)) % stops.length;
    _goTo(stops[next]);
  }

  /// A field is entered with the cursor after what is in it, ready to add
  /// to it; the body where its caret last was.
  void _goTo(FocusNode? stop) {
    if (stop == null) {
      unawaited(_editor.focus());
      return;
    }
    final text = switch (stop) {
      _ when stop == _toFocus => _to,
      _ when stop == _ccFocus => _cc,
      _ when stop == _bccFocus => _bcc,
      _ when stop == _subjectFocus => _subject,
      _ => null,
    };
    if (text != null) {
      text.selection = TextSelection.collapsed(offset: text.text.length);
    }
    stop.requestFocus();
  }

  Future<void> _send() async {
    final to = parseAddresses(_to.text);
    final cc = parseAddresses(_cc.text);
    final bcc = parseAddresses(_bcc.text);
    if (to.isEmpty && cc.isEmpty && bcc.isEmpty) {
      setState(() => _invalid = 'Add at least one recipient.');
      return;
    }
    // Bcc too: a mistyped blind copy is as undeliverable as any other, and
    // is the one nobody else on the message would notice missing.
    if (!addressesLookValid([...to, ...cc, ...bcc])) {
      setState(() => _invalid = 'One of the addresses does not look right.');
      return;
    }

    if (!await _passesChecks()) return;
    if (!await _readyToLeave()) return;
    final hold = ref.read(displayProvider).undoSend.hold;
    if (hold > Duration.zero && !widget.inWindow) {
      await _sendHeld(hold);
      return;
    }
    setState(() {
      _sending = true;
      _invalid = null;
      _problem = null;
    });
    try {
      await sendDraft(ref, await _currentDraft());
      if (!mounted) return;
      _dropBackgroundCopy();
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(duration: kBottomMessage, content: Text('Message sent')));
    } catch (e) {
      // One catch rather than four. Every failure the send path throws on
      // purpose already carries a sentence written for a person, and what the
      // screen needs from the rest is the error itself, so it can be reported.
      // A window that has gone meanwhile has nowhere to say it.
      if (!mounted) return;
      setState(() => _problem = ProblemReport(
            doing: 'Sending a message',
            error: e,
            account: _accountOrNull(),
          ));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// An @mention chosen: the name in the message, and the person on To if
  /// they are not on the message already, as Outlook adds them.
  Future<void> _mention(AddressSuggestion person) async {
    final name = person.name?.trim().isNotEmpty ?? false
        ? person.name!.trim()
        : person.email;
    await _editor.insertMention(name, person.email);
    final already = {
      for (final a in [
        ...parseAddresses(_to.text),
        ...parseAddresses(_cc.text),
        ...parseAddresses(_bcc.text),
      ])
        a.email.toLowerCase(),
    };
    if (already.contains(person.email.toLowerCase()) || !mounted) return;
    final kept = _to.text.trim().replaceAll(RegExp(r'[,;\s]+$'), '');
    final added = formatRecipient(person.name, person.email);
    setState(() => _to.text = kept.isEmpty ? added : '$kept, $added');
  }

  /// Outlook's two questions before a message goes, each with its switch
  /// in Settings, View: a message with no subject, and one that mentions an
  /// attachment and has none. False to keep writing.
  Future<bool> _passesChecks() async {
    final settings = ref.read(displayProvider);
    if (settings.askNoSubject && _subject.text.trim().isEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('No subject'),
          content: const Text('This message has no subject. Send it anyway?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('Keep writing'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Send anyway'),
            ),
          ],
        ),
      );
      if (go != true) {
        if (mounted) _subjectFocus.requestFocus();
        return false;
      }
      if (!mounted) return false;
    }
    // A picture in the text is not a file attached.
    if (settings.attachmentReminder &&
        !_attachments.any((a) => a.contentId == null)) {
      String html;
      try {
        html = await _editor.getHtml();
      } on EditorUnreadable {
        html = '';
      }
      if (!mounted) return false;
      if (mentionsAttachment('${_subject.text}\n${ownTextOf(html)}')) {
        final choice = await showDialog<String>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('Attachment reminder'),
            content: const Text(
              'The message says something is attached, but nothing is.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialog).pop('attach'),
                child: const Text('Attach a file'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialog).pop(),
                child: const Text('Keep writing'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialog).pop('send'),
                child: const Text('Send anyway'),
              ),
            ],
          ),
        );
        if (choice == 'attach' && mounted) await _addAttachment();
        if (choice != 'send' || !mounted) return false;
      }
    }
    return true;
  }

  /// Undo Send: the window closes at once and the message waits [hold],
  /// with Undo on the bar, before it goes (see [HeldSends]). Undo opens it
  /// again as it was; a send that fails says so, with the way back to it.
  Future<void> _sendHeld(Duration hold) async {
    final Draft draft;
    try {
      draft = await _currentDraft();
    } on EditorUnreadable catch (e) {
      if (mounted) {
        setState(() => _problem = ProblemReport(
              doing: 'Sending a message',
              error: e,
              account: _accountOrNull(),
            ));
      }
      return;
    }
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    void reopen() => navigator.push(
          MaterialPageRoute<bool>(
            // What was typed exists nowhere else now: closing it asks.
            builder: (_) => ComposeScreen(draft: draft, disposable: false),
          ),
        );
    final held = ref.read(heldSendsProvider.notifier).hold(
      draft,
      hold,
      onSent: () => messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          duration: kBottomMessage,
          content: Text('Message sent'),
        )),
      onFailed: (e) => messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 10),
          persist: false,
          content: Text(
            'The message was not sent. '
            '${e is ReadableError ? e.message : '$e'}',
          ),
          action: SnackBarAction(label: 'Open', onPressed: reopen),
        )),
    );
    _dropBackgroundCopy();
    navigator.pop(true);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: hold,
        persist: false,
        content: const Text('Sending…'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (held.undo()) {
              reopen();
            } else {
              messenger.showSnackBar(const SnackBar(
                duration: kBottomMessage,
                content: Text('Too late: it has gone.'),
              ));
            }
          },
        ),
      ));
  }

  /// Backing out of a half-written message: keep writing, save it, or throw
  /// it away. Saving is the default action and the one on the right, because
  /// losing something you typed is the expensive mistake here.
  ///
  /// An untouched window skips the question entirely. Opening compose and
  /// changing your mind should not produce a dialog, still less a blank draft
  /// on the server.
  Future<_LeaveChoice> _askOnLeave() async {
    // Unreadable, it cannot be judged unchanged, so the question is asked:
    // Discard still works, where not asking would leave no way out.
    Draft? now;
    try {
      now = await _currentDraft();
    } on EditorUnreadable {
      now = null;
    }
    if (now != null && (!now.isWorthSaving || _unchanged(now))) {
      return _LeaveChoice.discard;
    }
    if (!mounted) return _LeaveChoice.keepWriting;
    final choice = await showDialog<_LeaveChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep this message?'),
        content: Text(
          _savedAs == null
              ? 'It has not been sent. Saving puts it in Drafts, where you '
                  'can finish it here or anywhere else you read this mail.'
              : 'It has not been sent. Saving updates the copy in Drafts.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_LeaveChoice.keepWriting),
            child: const Text('Keep writing'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(_LeaveChoice.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_LeaveChoice.save),
            child: const Text('Save draft'),
          ),
        ],
      ),
    );
    return choice ?? _LeaveChoice.keepWriting;
  }

  /// What a draft reopened without its stored copy lacks. Opened as a copy
  /// of its own (draftFromMessage), so the one in Drafts keeps it, and
  /// stays there once this is saved or sent. The file is named until it is
  /// attached again; the Bcc and the copy left behind are worth saying
  /// with or without one.
  String _storedCopyNotice() =>
      widget.draft.lostAttachmentNames.isNotEmpty && _attachments.isEmpty
          ? "This draft's saved copy could not be fetched, so its attachment "
              'and any Bcc it had are not here. Attach the file and add the '
              'Bcc again before sending. The copy in Drafts still has them '
              'and is left as it is, even once this is saved or sent: '
              'delete it when you are done with it.'
          : "This draft's saved copy could not be fetched, so any Bcc it had "
              'is not here. Add the Bcc again before sending. The copy in '
              'Drafts still has it and is left as it is, even once this is '
              'saved or sent: delete it when you are done with it.';

  /// What is on screen right now, as a draft.
  Future<Draft> _currentDraft() async => widget.draft
      .copyWith(
        accountId: _accountId,
        to: parseAddresses(_to.text),
        cc: parseAddresses(_cc.text),
        bcc: parseAddresses(_bcc.text),
        subject: _subject.text,
        htmlBody: await _editor.getHtml(),
        attachments: _attachments,
        importance: _importance,
        requestReadReceipt: _readReceipt,
      )
      .withSavedAs(_savedAs);

  /// Carry on writing in a window of its own. What has been typed goes
  /// across as it stands, and this copy closes without asking: the
  /// message has not been lost, it has moved.
  Future<void> _moveToWindow() async {
    if (!await _readyToLeave()) return;
    final Draft draft;
    try {
      draft = await _currentDraft();
    } on EditorUnreadable catch (e) {
      if (mounted) {
        setState(() => _problem = ProblemReport(
              doing: 'Moving the message to a window',
              error: e,
              account: _accountOrNull(),
            ));
      }
      return;
    }
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final opened = await ref.read(windowOpenerProvider).open(ComposeWindow(draft));
    if (opened) {
      if (mounted) _dropBackgroundCopy();
      navigator.pop(false);
    } else {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(duration: kBottomMessage, 
          content: Text('Could not open a window. Still here.'),
        ));
    }
  }

  Future<void> _saveAndLeave() async {
    if (!await _readyToLeave()) return;
    setState(() {
      _sending = true;
      _invalid = null;
      _problem = null;
    });
    try {
      await _saveForGood(await _currentDraft());
      if (!mounted) return;
      _dropBackgroundCopy();
      Navigator.of(context).pop(false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(duration: kBottomMessage, content: Text('Saved to Drafts')));
    } catch (e) {
      // Staying put is the right failure: popping now would lose the message
      // that could not be saved, which is the thing being protected against.
      if (mounted) {
        setState(() => _problem = ProblemReport(
              doing: 'Saving a draft',
              error: e,
              account: _accountOrNull(),
            ));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final account = accounts.where((a) => a.id == _accountId).firstOrNull;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Not while it is being sent or saved, as Esc and putting the app
        // away wait too. The question said it had not been sent, and
        // Discard closed the window with the send still going: when that
        // send failed, nothing said so and the message was gone. Save draft
        // kept a draft of a message that then went.
        if (_sending) return;
        switch (await _askOnLeave()) {
          case _LeaveChoice.keepWriting:
            return;
          case _LeaveChoice.save:
            await _saveAndLeave();
          case _LeaveChoice.discard:
            if (!await _readyToLeave() || !context.mounted) return;
            _dropBackgroundCopy();
            Navigator.of(context).pop(false);
        }
      },
      child: Focus(
        // Keys reach this only from a focused descendant, and a reply has
        // none until its body has loaded and taken the cursor: its To is
        // filled. Until then this takes the focus itself. A new message
        // gives it to To instead, which is below here, so its keys pass
        // through all the same.
        autofocus: widget.draft.to.isNotEmpty,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Scaffold(
        appBar: AppBar(
          title: Text(switch (widget.draft.kind) {
            ComposeKind.reply || ComposeKind.replyAll => 'Reply',
            ComposeKind.forward => 'Forward',
            ComposeKind.newMessage => 'New message',
          }),
          centerTitle: false,
          actions: [
            if (ref.watch(windowsAvailableProvider).value ?? false)
              IconButton(
                tooltip: 'Open in new window',
                icon: const Icon(Icons.open_in_new),
                onPressed: _sending ? null : _moveToWindow,
              ),
            IconButton(
              tooltip: 'Attach',
              icon: const Icon(Icons.attach_file),
              onPressed: _sending ? null : _addAttachment,
            ),
            IconButton(
              tooltip: 'Paste file',
              icon: const Icon(Icons.content_paste_outlined),
              onPressed: _sending ? null : _pasteAttachment,
            ),
            IconButton(
              tooltip: 'Send',
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              onPressed: _sending ? null : _send,
            ),
            // Outlook's Tags and Options for one message.
            PopupMenuButton<String>(
              key: const ValueKey('compose-more'),
              tooltip: 'More',
              enabled: !_sending,
              onSelected: (choice) => setState(() {
                switch (choice) {
                  case 'high':
                    _importance = _importance == Importance.high
                        ? Importance.normal
                        : Importance.high;
                  case 'low':
                    _importance = _importance == Importance.low
                        ? Importance.normal
                        : Importance.low;
                  case 'receipt':
                    _readReceipt = !_readReceipt;
                  case 'free':
                    unawaited(insertFreeTimes(
                      context,
                      ref,
                      accountId: _accountId,
                      editor: _editor,
                    ));
                }
              }),
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: 'high',
                  checked: _importance == Importance.high,
                  child: const Text('High importance'),
                ),
                CheckedPopupMenuItem(
                  value: 'low',
                  checked: _importance == Importance.low,
                  child: const Text('Low importance'),
                ),
                const PopupMenuDivider(),
                CheckedPopupMenuItem(
                  value: 'receipt',
                  checked: _readReceipt,
                  child: const Text('Request a read receipt'),
                ),
                // Where the account has a calendar the app can read.
                if (account != null &&
                    (account.provider == MailProvider.outlook ||
                        account.authMethod == AuthMethod.oauth)) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'free',
                    child: Text('Insert free times…'),
                  ),
                ],
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            // With one account there is nothing to choose, and a menu with
            // one entry is a puzzle. With more, the sender is a choice like
            // the recipients are, on a row shaped like theirs.
            if (accounts.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(
                        'From',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: DropdownButton<String>(
                        key: const ValueKey('from-account'),
                        focusNode: _fromFocus,
                        value: account?.id,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        style: theme.textTheme.bodyMedium,
                        items: [
                          for (final a in accounts)
                            DropdownMenuItem(
                              value: a.id,
                              child: Text(
                                a.emailAddress,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _sending
                            ? null
                            : (id) {
                                if (id == null || id == _accountId) return;
                                setState(() => _accountId = id);
                                _useSignatureOf(id);
                              },
                      ),
                    ),
                  ],
                ),
              )
            else if (account != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'From ${account.emailAddress}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            RecipientField(
              label: 'To',
              controller: _to,
              focusNode: _toFocus,
              enabled: !_sending,
              // A new message starts with the cursor here. A reply already
              // has its recipients, so the cursor is better off in the body.
              autofocus: widget.draft.to.isEmpty,
            ),
            RecipientField(
              label: 'Cc',
              controller: _cc,
              focusNode: _ccFocus,
              enabled: !_sending,
              trailing: _showBcc
                  ? null
                  : TextButton(
                      onPressed: () => setState(() => _showBcc = true),
                      child: const Text('Bcc'),
                    ),
            ),
            if (_showBcc)
              RecipientField(
                label: 'Bcc',
                controller: _bcc,
                focusNode: _bccFocus,
                enabled: !_sending,
              ),
            // Exchange's word on the recipients, from a Microsoft account.
            if (account?.provider == MailProvider.outlook)
              MailTipsLine(
                key: ValueKey('mail-tips:$_accountId'),
                accountId: _accountId,
                fields: [_to, _cc, _bcc],
              ),
            HeaderField(
              label: 'Subject',
              controller: _subject,
              focusNode: _subjectFocus,
              enabled: !_sending,
            ),
            if (_importance != Importance.normal || _readReceipt)
              _MessageOptions(
                importance: _importance,
                readReceipt: _readReceipt,
              ),
            if (_attachments.isNotEmpty)
              _AttachmentStrip(
                attachments: _attachments,
                onRemove: _sending
                    ? null
                    : (a) => setState(
                          () => _attachments =
                              [..._attachments]..remove(a),
                        ),
              ),
            if (widget.draft.storedCopyUnread)
              _Notice(_storedCopyNotice(), theme: theme)
            else if (widget.draft.kind == ComposeKind.forward &&
                widget.draft.lostAttachmentNames.isNotEmpty &&
                _attachments.isEmpty)
              _Notice(
                'The files on the message being forwarded could not be '
                'fetched, so they are not attached. Attach them again before '
                'sending, or forward it again when online.',
                theme: theme,
              ),
            if (_invalid != null)
              Container(
                width: double.infinity,
                color: theme.colorScheme.errorContainer,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  _invalid!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            if (_problem != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: ProblemView(problem: _problem!),
              ),
            const Divider(height: 1),
            Expanded(
              child: HtmlEditor(controller: _editor, onReady: _noteOpened),
            ),
            // People an @ in the message could mean, as To suggests them.
            MentionSuggestions(controller: _editor, onChoose: _mention),
            EditorToolbar(
              controller: _editor,
              enabled: !_sending,
              onPicture: () => insertPicture(context, ref, _editor),
              signatures: _signatureMenu(),
              assistant: AiWritingButton(
                enabled: !_sending,
                read: _editor.aiText,
                write: _editor.replaceAiText,
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// What to do with a half-written message when the screen is backed out of.
enum _LeaveChoice { keepWriting, save, discard }

/// What the ⋮ menu has set on this message, said under the subject so it
/// is not forgotten: High or Low importance, a read receipt asked for.
class _MessageOptions extends StatelessWidget {
  const _MessageOptions({required this.importance, required this.readReceipt});

  final Importance importance;
  final bool readReceipt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        children: [
          if (importance == Importance.high)
            _option(Icons.priority_high, 'High importance', scheme.error, style),
          if (importance == Importance.low)
            _option(Icons.arrow_downward, 'Low importance', scheme.primary, style),
          if (readReceipt)
            _option(
              Icons.mark_email_read_outlined,
              'Read receipt requested',
              scheme.onSurfaceVariant,
              style,
            ),
        ],
      ),
    );
  }

  Widget _option(IconData icon, String text, Color colour, TextStyle? style) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colour),
          const SizedBox(width: 4),
          Text(text, style: style?.copyWith(color: colour)),
        ],
      );
}

/// A quiet band of explanation, distinct from the error band above it.
class _Notice extends StatelessWidget {
  const _Notice(this.text, {required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({required this.attachments, this.onRemove});

  final List<DraftAttachment> attachments;
  final void Function(DraftAttachment)? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final a in attachments)
            Chip(
              label: Text('${a.fileName}  ${a.readableSize}'),
              onDeleted: onRemove == null ? null : () => onRemove!(a),
            ),
        ],
      ),
    );
  }
}

/// Bold, italic, underline and lists, sitting above the keyboard.
