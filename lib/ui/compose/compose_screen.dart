import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/account.dart';
import '../../domain/error_report.dart';
import '../common/problem_view.dart';

import '../../data/files/file_bridge.dart';
import '../../domain/draft.dart';
import '../../state/attachment_providers.dart';
import '../../state/compose_providers.dart';
import '../../state/drop_providers.dart';
import '../../state/providers.dart';
import 'html_editor.dart';

/// Write, reply to or forward a message.
///
/// The body is a WebView editor holding one document: your new text, the
/// signature, and the quoted original, all editable. The toolbar is Flutter
/// rather than HTML because it has to sit above the soft keyboard and track
/// its inset, which an in-page toolbar cannot do.
class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key, required this.draft});

  final Draft draft;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  late final HtmlEditorController _editor =
      HtmlEditorController(initialHtml: widget.draft.htmlBody);
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

  @override
  void initState() {
    super.initState();
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
    ..showSnackBar(SnackBar(content: Text(message)));

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
                SnackBar(content: Text('Could not read ${f.name}: $e')));
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
      ?.where((a) => a.id == widget.draft.accountId)
      .firstOrNull;

  Future<void> _send() async {
    final to = parseAddresses(_to.text);
    final cc = parseAddresses(_cc.text);
    if (to.isEmpty && cc.isEmpty) {
      setState(() => _invalid = 'Add at least one recipient.');
      return;
    }
    if (!addressesLookValid([...to, ...cc])) {
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
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Message sent')));
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
    if (!await _currentDraft().then((d) => d.isWorthSaving)) {
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
        to: parseAddresses(_to.text),
        cc: parseAddresses(_cc.text),
        bcc: parseAddresses(_bcc.text),
        subject: _subject.text,
        htmlBody: await _editor.getHtml(),
        attachments: _attachments,
      );

  Future<void> _saveAndLeave() async {
    setState(() {
      _sending = true;
      _invalid = null;
      _problem = null;
    });
    try {
      await saveDraft(ref, await _currentDraft());
      if (!mounted) return;
      Navigator.of(context).pop(false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Saved to Drafts')));
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
    final account = ref.watch(accountsProvider).value?.where(
          (a) => a.id == widget.draft.accountId,
        ).firstOrNull;

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
            if (context.mounted) Navigator.of(context).pop(false);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(switch (widget.draft.kind) {
            ComposeKind.reply || ComposeKind.replyAll => 'Reply',
            ComposeKind.forward => 'Forward',
            ComposeKind.newMessage => 'New message',
          }),
          centerTitle: false,
          actions: [
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
            if (account != null)
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
            _Field(
              label: 'To',
              controller: _to,
              enabled: !_sending,
              // A new message starts with the cursor here. A reply already
              // has its recipients, so the cursor is better off in the body.
              autofocus: widget.draft.to.isEmpty,
            ),
            _Field(
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
              _Field(label: 'Bcc', controller: _bcc, enabled: !_sending),
            _Field(
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
                'This draft had an attachment. Attach it again before '
                'sending; reopening a draft does not bring files back.',
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
            Expanded(child: HtmlEditor(controller: _editor)),
            _Toolbar(controller: _editor, enabled: !_sending),
          ],
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

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.enabled,
    this.trailing,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final Widget? trailing;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A name in muted text on the left and a light rule under the field,
    // in the same type as the body below. Enough to say "type here" — the
    // first version was a word and nothing else — without the outlined
    // boxes of the second, which shouted over the message itself.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              autofocus: autofocus,
              style: theme.textTheme.bodyMedium,
              keyboardType: label == 'Subject'
                  ? TextInputType.text
                  : TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                border: UnderlineInputBorder(
                  borderSide: BorderSide(color: theme.dividerColor),
                ),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: theme.dividerColor),
                ),
                isDense: true,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          ?trailing,
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
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller, required this.enabled});

  final HtmlEditorController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = controller.activeFormats;

    Widget button(String command, IconData icon, String tooltip) {
      final isActive = active.contains(command);
      return IconButton(
        tooltip: tooltip,
        isSelected: isActive,
        icon: Icon(icon),
        color: isActive ? theme.colorScheme.primary : null,
        onPressed: enabled ? () => controller.format(command) : null,
      );
    }

    return SafeArea(
      top: false,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: Row(
          children: [
            button('bold', Icons.format_bold, 'Bold'),
            button('italic', Icons.format_italic, 'Italic'),
            button('underline', Icons.format_underlined, 'Underline'),
            const VerticalDivider(width: 8, indent: 10, endIndent: 10),
            button('insertUnorderedList', Icons.format_list_bulleted, 'Bullets'),
            button('insertOrderedList', Icons.format_list_numbered, 'Numbers'),
            const Spacer(),
            IconButton(
              tooltip: 'Remove formatting',
              icon: const Icon(Icons.format_clear),
              onPressed: enabled ? () => controller.format('removeFormat') : null,
            ),
          ],
        ),
      ),
    );
  }
}
