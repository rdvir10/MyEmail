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

import '../../data/compose/quote_builder.dart' show carriesSignature;
import '../../data/files/file_bridge.dart';
import '../../domain/draft.dart';
import '../../state/attachment_providers.dart';
import '../../state/compose_providers.dart';
import '../../state/drop_providers.dart';
import '../../state/providers.dart';
import '../../state/window_providers.dart';
import '../../domain/window_handoff.dart';
import 'header_fields.dart';
import 'html_editor.dart';

/// Write, reply to or forward a message.
///
/// The body is a WebView editor holding one document: your new text, the
/// signature, and the quoted original, all editable. The toolbar is Flutter
/// rather than HTML because it has to sit above the soft keyboard and track
/// its inset, which an in-page toolbar cannot do.
class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key, required this.draft, this.disposable = true});

  final Draft draft;

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
    with WidgetsBindingObserver {
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

  late List<DraftAttachment> _attachments = List.of(widget.draft.attachments);
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
  bool _backgroundSaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _showBcc = widget.draft.bcc.isNotEmpty;
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
    super.dispose();
  }

  void _onEditorState() => setState(() {});

  Future<void> _noteOpened() async {
    try {
      _openedHtml ??= await _editor.getHtml();
    } on EditorUnreadable {
      // Then nothing counts as unchanged, and leaving asks.
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
      now.htmlBody == (_openedHtml ?? widget.draft.htmlBody);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _saveInBackground();
  }

  /// Put what is written in Drafts as the app goes into the background.
  /// Quietly: nothing on screen changes, and a failure changes nothing
  /// either, because the window is still open with everything in it.
  Future<void> _saveInBackground() async {
    if (_sending || _backgroundSaving) return;
    _backgroundSaving = true;
    try {
      final now = await _currentDraft();
      if (!now.isWorthSaving || _unchanged(now)) return;
      final holds = _fingerprint(now);
      if (holds == _backgroundCopyOf || !mounted) return;
      final saved = await saveDraft(ref, now.withSavedAs(_backgroundCopy));
      _backgroundCopy = saved.savedAs;
      _backgroundCopyOf = holds;
    } catch (_) {
      // Offline, most likely. The message is still on screen.
    } finally {
      _backgroundSaving = false;
    }
  }

  String _fingerprint(Draft d) => [
        d.accountId,
        d.to,
        d.cc,
        d.bcc,
        d.subject,
        d.htmlBody,
        for (final a in d.attachments) identityHashCode(a),
      ].join('\u0000');

  /// The window is ending some other way, so the background copy has done
  /// its job. Not waited for: leaving must not hang on the network, and a
  /// copy that fails to go is untidy rather than wrong.
  void _dropBackgroundCopy() {
    final copy = _backgroundCopy;
    if (copy == null) return;
    _backgroundCopy = null;
    _backgroundCopyOf = null;
    unawaited(
      ref.read(mailEngineProvider).discardDraft(copy).catchError((_) {}),
    );
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

  /// Put [accountId]'s signature in the message in place of the one it
  /// has. It used to keep the first account's, so a message sent from a
  /// second account went out signed as the first, or unsigned.
  void _useSignatureOf(String accountId) {
    final signature =
        ref.read(signaturesProvider.notifier).forAccount(accountId);
    final carried = carriesSignature(
      widget.draft.kind,
      signature.html,
      onReply: signature.onReply,
    );
    unawaited(_editor.setSignature(carried ? signature.html : ''));
  }

  /// Ctrl+Enter sends and Esc leaves, from the header fields. The body is a
  /// WebView, whose keys never reach Flutter; the editor's page reports the
  /// same two, and they come in through [_onEditorKey].
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final control = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final key = event.logicalKey;
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
    }
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
      setState(() => _problem = ProblemReport(
            doing: 'Sending a message',
            error: e,
            account: _accountOrNull(),
          ));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
          widget.draft.savedAs == null
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

  /// What is on screen right now, as a draft.
  Future<Draft> _currentDraft() async => widget.draft.copyWith(
        accountId: _accountId,
        to: parseAddresses(_to.text),
        cc: parseAddresses(_cc.text),
        bcc: parseAddresses(_bcc.text),
        subject: _subject.text,
        htmlBody: await _editor.getHtml(),
        attachments: _attachments,
      );

  /// Carry on writing in a window of its own. What has been typed goes
  /// across as it stands, and this copy closes without asking: the
  /// message has not been lost, it has moved.
  Future<void> _moveToWindow() async {
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
    setState(() {
      _sending = true;
      _invalid = null;
      _problem = null;
    });
    try {
      await saveDraft(ref, await _currentDraft());
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
        switch (await _askOnLeave()) {
          case _LeaveChoice.keepWriting:
            return;
          case _LeaveChoice.save:
            await _saveAndLeave();
          case _LeaveChoice.discard:
            if (!context.mounted) return;
            _dropBackgroundCopy();
            Navigator.of(context).pop(false);
        }
      },
      child: Focus(
        // Keys reach this only from a focused descendant, and a reply has
        // none: its To is filled, so nothing takes the cursor. Then this
        // takes the focus itself. A new message gives it to To instead,
        // which is below here, so its keys pass through all the same.
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
            const SizedBox(width: 4),
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
              enabled: !_sending,
              // A new message starts with the cursor here. A reply already
              // has its recipients, so the cursor is better off in the body.
              autofocus: widget.draft.to.isEmpty,
            ),
            RecipientField(
              label: 'Cc',
              controller: _cc,
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
                enabled: !_sending,
              ),
            HeaderField(
              label: 'Subject',
              controller: _subject,
              enabled: !_sending,
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
            if (widget.draft.lostAttachmentNames.isNotEmpty &&
                _attachments.isEmpty)
              _Notice(
                widget.draft.kind == ComposeKind.forward
                    ? 'The files on the message being forwarded could not '
                        'be fetched, so they are not attached. Attach them '
                        'again before sending, or forward it again when '
                        'online.'
                    : 'This draft had an attachment that could not be '
                        'brought back. Attach it again before sending.',
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
            EditorToolbar(controller: _editor, enabled: !_sending),
          ],
        ),
        ),
      ),
    );
  }
}

/// What to do with a half-written message when the screen is backed out of.
enum _LeaveChoice { keepWriting, save, discard }

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
