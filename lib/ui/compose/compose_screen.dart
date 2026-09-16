import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/mail_engine.dart';
import '../../domain/draft.dart';
import '../../state/compose_providers.dart';
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
  late final TextEditingController _subject =
      TextEditingController(text: widget.draft.subject);

  late List<DraftAttachment> _attachments = List.of(widget.draft.attachments);
  bool _showCc = false;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _showCc = widget.draft.cc.isNotEmpty;
    _editor.addListener(_onEditorState);
  }

  @override
  void dispose() {
    _editor
      ..removeListener(_onEditorState)
      ..dispose();
    _to.dispose();
    _cc.dispose();
    _subject.dispose();
    super.dispose();
  }

  void _onEditorState() => setState(() {});

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

  Future<void> _send() async {
    final to = parseAddresses(_to.text);
    final cc = parseAddresses(_cc.text);
    if (to.isEmpty && cc.isEmpty) {
      setState(() => _error = 'Add at least one recipient.');
      return;
    }
    if (!addressesLookValid([...to, ...cc])) {
      setState(() => _error = 'One of the addresses does not look right.');
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await sendDraft(ref, await _currentDraft());
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Message sent')));
    } on SendFailed catch (e) {
      setState(() => _error = e.message);
    } on AuthenticationFailed catch (e) {
      setState(() => _error = e.message);
    } on ConnectionFailed catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not send: $e');
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
        subject: _subject.text,
        htmlBody: await _editor.getHtml(),
        attachments: _attachments,
      );

  Future<void> _saveAndLeave() async {
    setState(() {
      _sending = true;
      _error = null;
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
        setState(() => _error = 'Could not save it to Drafts: $e');
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
              trailing: _showCc
                  ? null
                  : TextButton(
                      onPressed: () => setState(() => _showCc = true),
                      child: const Text('Cc'),
                    ),
            ),
            if (_showCc)
              _Field(label: 'Cc', controller: _cc, enabled: !_sending),
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
            if (_error != null)
              Container(
                width: double.infinity,
                color: theme.colorScheme.errorContainer,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onErrorContainer),
                ),
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
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              keyboardType: label == 'Subject'
                  ? TextInputType.text
                  : TextInputType.emailAddress,
              decoration: const InputDecoration(
                border: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
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
