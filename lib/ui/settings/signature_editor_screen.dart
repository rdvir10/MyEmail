import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/compose/signature_images.dart';
import '../../domain/account.dart';
import '../../domain/signature.dart';
import '../../state/compose_providers.dart';
import '../compose/html_editor.dart';

/// One account's signature, in the same editor a message is written in.
///
/// Rich, because a signature is the one part of a message that is pasted
/// rather than typed: from Outlook, from a company template, with a logo
/// and a line of links. The editor keeps what is pasted; the plain box it
/// replaces threw all of that away.
///
/// Saved on the tick, not as you type. An editor in a WebView cannot be
/// read on every keystroke, and a signature is finished before it is used.
class SignatureEditorScreen extends ConsumerStatefulWidget {
  const SignatureEditorScreen({
    super.key,
    required this.account,
    this.inlineImages = inlineRemoteImages,
  });

  final Account account;

  /// How hosted pictures are brought inside the signature on save. A
  /// parameter so tests can hand in a fetch that never touches the network.
  final Future<String> Function(String html) inlineImages;

  @override
  ConsumerState<SignatureEditorScreen> createState() =>
      _SignatureEditorScreenState();
}

class _SignatureEditorScreenState extends ConsumerState<SignatureEditorScreen> {
  late final Signature _initial =
      ref.read(signaturesProvider.notifier).forAccount(widget.account.id);
  late final HtmlEditorController _editor =
      HtmlEditorController(initialHtml: _initial.html);
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _editor.addListener(_onEditorState);
  }

  @override
  void dispose() {
    _editor
      ..removeListener(_onEditorState)
      ..dispose();
    super.dispose();
  }

  void _onEditorState() => setState(() {});

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final html = await widget.inlineImages(await _editor.getHtml());
      ref
          .read(signaturesProvider.notifier)
          .set(_initial.copyWith(html: _isBlank(html) ? '' : html));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text('Could not save: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Back with a change asks; back with none just goes.
  Future<void> _leave() async {
    final navigator = Navigator.of(context);
    final now = await _editor.getHtml();
    if (!mounted) return;
    if (now == _initial.html || (_isBlank(now) && _isBlank(_initial.html))) {
      navigator.pop(false);
      return;
    }
    final keep = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep the changes?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (keep == true) {
      await _save();
    } else if (keep == false) {
      navigator.pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Signature · ${widget.account.emailAddress}'),
          centerTitle: false,
          actions: [
            IconButton(
              tooltip: 'Save',
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                'Paste a signature from Outlook or type one. Pictures in it '
                'are kept with the signature when you save.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(child: HtmlEditor(controller: _editor)),
            EditorToolbar(controller: _editor, enabled: !_saving),
          ],
        ),
      ),
    );
  }
}

bool _isBlank(String html) => html
    .replaceAll(RegExp(r'<br\s*/?>|</?p[^>]*>|</?div[^>]*>|&nbsp;'), '')
    .trim()
    .isEmpty;
