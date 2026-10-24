import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/account.dart';
import '../../domain/signature.dart';
import 'signature_editor_screen.dart';
import '../../state/compose_providers.dart';
import '../../state/providers.dart';

/// Signatures per account, because the whole point of several accounts is
/// that they are not the same person writing; and several per account, as
/// Outlook has them, with one for new messages and one for replies.
///
/// Each shows what it says, as words, with an Edit that opens the message
/// editor on it: a signature is pasted more often than typed, and a plain
/// box threw away everything a pasted one carried.
class SignaturesScreen extends ConsumerWidget {
  const SignaturesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).value ?? const [];
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Signatures'), centerTitle: false),
      body: accounts.isEmpty
          ? const Center(child: Text('Add an account first.'))
          : ListView(
              children: [
                for (final account in accounts)
                  _AccountSignatures(key: ValueKey(account.id), account: account),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Text(
                    'A signature your organisation adds on its mail server '
                    '(CodeTwo, Exchange rules) goes on after sending and '
                    'does not show here. Add one here only if the server '
                    'does not. While writing, the Signature button on the '
                    'bar under the message puts in another, or takes it out.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
    );
  }
}

class _AccountSignatures extends ConsumerWidget {
  const _AccountSignatures({super.key, required this.account});

  final Account account;

  void _edit(BuildContext context, String? id) => Navigator.of(context).push(
        MaterialPageRoute<bool>(
          builder: (_) => SignatureEditorScreen(account: account, signatureId: id),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final signature = ref.watch(signaturesProvider)[account.id] ??
        Signature(accountId: account.id);
    final notifier = ref.read(signaturesProvider.notifier);

    Widget choice(String label, String? value, ValueChanged<String?> onChanged) =>
        Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            DropdownButton<String?>(
              value: value,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('None')),
                for (final s in signature.named)
                  DropdownMenuItem<String?>(value: s.id, child: Text(s.name)),
              ],
              onChanged: onChanged,
            ),
          ],
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 8,
                backgroundColor: Color(account.colorValue),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  account.emailAddress,
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (signature.named.isEmpty)
            Text(
              'Nothing yet',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          for (final s in signature.named)
            _SignatureCard(
              key: ValueKey('signature:${account.id}:${s.id}'),
              signature: s,
              onEdit: () => _edit(context, s.id),
              onDelete: () => notifier.set(signature.without(s.id)),
            ),
          TextButton.icon(
            onPressed: () => _edit(context, null),
            icon: const Icon(Icons.add),
            label: Text(signature.named.isEmpty
                ? 'Add a signature'
                : 'Add another signature'),
          ),
          if (signature.named.isNotEmpty) ...[
            choice(
              'New messages',
              signature.forNew,
              (id) => notifier.set(signature.withDefaults(
                forNew: id,
                forReplies: signature.forReplies,
              )),
            ),
            choice(
              'Replies and forwards',
              signature.forReplies,
              (id) => notifier.set(signature.withDefaults(
                forNew: signature.forNew,
                forReplies: id,
              )),
            ),
          ],
          const Divider(),
        ],
      ),
    );
  }
}

class _SignatureCard extends StatelessWidget {
  const _SignatureCard({
    super.key,
    required this.signature,
    required this.onEdit,
    required this.onDelete,
  });

  final NamedSignature signature;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = htmlToSignatureText(signature.html);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(signature.name, style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: onEdit,
                ),
                IconButton(
                  tooltip: 'Delete signature',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onDelete,
                ),
              ],
            ),
            // Words, not the HTML: what it says is what matters here, and
            // how it looks is what the editor is for.
            Text(
              words.isEmpty ? 'Empty' : words,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
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
  // A div, not a paragraph, which every mail program spaces out.
  return '<div>${escaped.split('\n').join('<br>')}</div>';
}

/// The reverse, so the box shows what was typed rather than the markup.
String htmlToSignatureText(String html) {
  if (html.trim().isEmpty) return '';
  return html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|tr|li)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<img\b[^>]*>', caseSensitive: false), '[picture]')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
