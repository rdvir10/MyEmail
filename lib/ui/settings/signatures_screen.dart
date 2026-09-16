import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/account.dart';
import '../../domain/signature.dart';
import '../../state/compose_providers.dart';
import '../../state/providers.dart';

/// A signature per account, because the whole point of several accounts is
/// that they are not the same person writing.
///
/// Plain text, not the rich editor. A signature is a few lines of contact
/// details; giving it the full WebView editor would be a second editor to
/// maintain for a worse result. Line breaks become `<br>` on the way in, and
/// back again on the way out, so what is typed is what is sent.
class SignaturesScreen extends ConsumerWidget {
  const SignaturesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Signatures'), centerTitle: false),
      body: accounts.isEmpty
          ? const Center(child: Text('Add an account first.'))
          : ListView(
              children: [
                for (final account in accounts)
                  _AccountSignature(key: ValueKey(account.id), account: account),
              ],
            ),
    );
  }
}

class _AccountSignature extends ConsumerStatefulWidget {
  const _AccountSignature({super.key, required this.account});

  final Account account;

  @override
  ConsumerState<_AccountSignature> createState() => _AccountSignatureState();
}

class _AccountSignatureState extends ConsumerState<_AccountSignature> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final existing =
        ref.read(signaturesProvider.notifier).forAccount(widget.account.id);
    _controller = TextEditingController(text: htmlToSignatureText(existing.html));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save({String? text, bool? onReply}) {
    final current =
        ref.read(signaturesProvider.notifier).forAccount(widget.account.id);
    ref.read(signaturesProvider.notifier).set(
          Signature(
            accountId: widget.account.id,
            html: text == null ? current.html : signatureTextToHtml(text),
            onReply: onReply ?? current.onReply,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signature =
        ref.watch(signaturesProvider)[widget.account.id] ??
            Signature(accountId: widget.account.id, html: '');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 8,
                backgroundColor: Color(widget.account.colorValue),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.account.emailAddress,
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            maxLines: 5,
            minLines: 3,
            // Saved as you type. A Save button on a settings screen is one
            // more thing to forget, and there is nothing here worth confirming.
            onChanged: (text) => _save(text: text),
            decoration: const InputDecoration(
              hintText: 'Ron Dvir\nrdvir@example.com',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Add to replies and forwards'),
            subtitle: const Text(
              'Off keeps it to new messages, so it does not pile up down a '
              'long thread.',
            ),
            value: signature.onReply,
            onChanged: (v) => _save(onReply: v),
          ),
          const Divider(),
        ],
      ),
    );
  }
}

/// A typed signature as the HTML that goes into the message.
///
/// Escaped first: someone whose job title contains an ampersand should not
/// have it silently turn into an entity in the message they send.
String signatureTextToHtml(String text) {
  final trimmed = text.trimRight();
  if (trimmed.trim().isEmpty) return '';
  final escaped = trimmed
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return '<p>${escaped.split('\n').join('<br>')}</p>';
}

/// The reverse, so the box shows what was typed rather than the markup.
String htmlToSignatureText(String html) {
  if (html.trim().isEmpty) return '';
  return html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</?p[^>]*>', caseSensitive: false), '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .trim();
}
