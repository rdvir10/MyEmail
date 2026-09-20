import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/account.dart';
import '../../domain/signature.dart';
import 'signature_editor_screen.dart';
import '../../state/compose_providers.dart';
import '../../state/providers.dart';

/// A signature per account, because the whole point of several accounts is
/// that they are not the same person writing.
///
/// Each account shows what it has, as words, with an Edit that opens the
/// message editor on it: a signature is pasted more often than typed, and
/// a plain box threw away everything a pasted one carried.
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
                  _AccountSignature(key: ValueKey(account.id), account: account),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Text(
                    'A signature your organisation adds on its mail server '
                    '(CodeTwo, Exchange rules) goes on after sending and '
                    'does not show here. Add one here only if the server '
                    'does not.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
    );
  }
}

class _AccountSignature extends ConsumerWidget {
  const _AccountSignature({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final signature = ref.watch(signaturesProvider)[account.id] ??
        Signature(accountId: account.id, html: '');
    final words = htmlToSignatureText(signature.html);

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
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<bool>(
                    builder: (_) => SignatureEditorScreen(account: account),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Words, not the HTML: what it says is what matters here, and how
          // it looks is what the editor is for.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              words.isEmpty ? 'Nothing yet' : words,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: words.isEmpty ? theme.colorScheme.onSurfaceVariant : null,
                fontStyle: words.isEmpty ? FontStyle.italic : null,
              ),
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
            onChanged: (v) => ref
                .read(signaturesProvider.notifier)
                .set(signature.copyWith(onReply: v)),
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
