import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ai/on_device_ai.dart';
import '../../domain/draft.dart' show ComposeKind;
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/mail_message.dart';
import '../../state/ai_providers.dart';
import '../../state/providers.dart';
import '../compose/open_compose.dart';

/// The words of [body] worth the AI's reading: the message's own, without
/// the history quoted under a reply.
String ownWordsOf(MailBody body) {
  final lines = <String>[];
  for (final line in body.text.split('\n')) {
    final t = line.trimRight();
    // Where the quote starts: Outlook's "From:" block or Gmail's "On ...
    // wrote:" line, and quoted lines.
    if (RegExp(r'^\s*(From|מאת):\s').hasMatch(t) && lines.isNotEmpty) break;
    if (RegExp(r'^On .{6,} wrote:$').hasMatch(t.trim())) break;
    if (t.trimLeft().startsWith('>')) continue;
    lines.add(t);
  }
  return lines.join('\n').trim();
}

/// The summary above a long message: Outlook's Summary by Copilot, made on
/// the phone. Offered where the phone's AI summarises (the Pixel 9 Pro),
/// for an English message long enough to need it.
class AiSummaryBar extends ConsumerStatefulWidget {
  const AiSummaryBar({super.key, required this.message, required this.body});

  final MailMessage message;
  final MailBody body;

  /// Shorter than this, a summary is the message again; Google's model
  /// wants more than 400 characters too.
  static const longEnough = 600;

  @override
  ConsumerState<AiSummaryBar> createState() => _AiSummaryBarState();
}

class _AiSummaryBarState extends ConsumerState<AiSummaryBar> {
  String? _summary;
  String? _problem;
  bool _busy = false;
  bool _downloading = false;

  @override
  void didUpdateWidget(AiSummaryBar old) {
    super.didUpdateWidget(old);
    if (old.message.id != widget.message.id) {
      _summary = null;
      _problem = null;
      _busy = false;
    }
  }

  Future<void> _summarise(AiReadiness readiness) async {
    final ai = ref.read(onDeviceAiProvider);
    final id = widget.message.id;
    setState(() {
      _busy = true;
      _problem = null;
      _downloading = readiness != AiReadiness.available;
    });
    try {
      if (readiness != AiReadiness.available) {
        await ai.download(AiFeature.summarize);
        ref.invalidate(aiReadinessProvider(AiFeature.summarize));
      }
      final summary = await ai.summarize(ownWordsOf(widget.body));
      if (!mounted || widget.message.id != id) return;
      setState(() => _summary = summary.trim());
    } catch (e) {
      if (!mounted || widget.message.id != id) return;
      setState(() => _problem = e is ReadableError ? e.message : '$e');
    } finally {
      if (mounted && widget.message.id == id) {
        setState(() {
          _busy = false;
          _downloading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final readiness =
        ref.watch(aiReadinessProvider(AiFeature.summarize)).value;
    final words = ownWordsOf(widget.body);
    if (readiness == null ||
        !readiness.usable ||
        words.length < AiSummaryBar.longEnough ||
        !readsAsEnglish(words)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final summary = _summary;
    if (summary != null) {
      return Container(
        key: const ValueKey('ai-summary'),
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer.withAlpha(110),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome,
                          size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text('Summary, made on this phone', style: muted),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SelectableText(summary),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Close summary',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _summary = null),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          TextButton.icon(
            key: const ValueKey('ai-summarise'),
            onPressed: _busy ? null : () => _summarise(readiness),
            icon: _busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome, size: 18),
            label: Text(_busy
                ? (_downloading
                    ? "Getting the phone's AI ready…"
                    : 'Summarising…')
                : 'Summarise'),
          ),
          if (_problem != null)
            Expanded(
              child: Text(
                _problem!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Short replies offered under a message, as Outlook for Android has them:
/// a tap starts a reply with the words in. English mail from someone else,
/// on the phone's own Smart Reply.
final suggestedRepliesProvider = FutureProvider.autoDispose
    .family<List<String>, ({String messageId, String text, String sender, DateTime date})>(
        (ref, m) async {
  if (m.text.isEmpty || !readsAsEnglish(m.text)) return const [];
  final ai = ref.watch(onDeviceAiProvider);
  // The last few hundred words: what is being answered.
  final text = m.text.length > 2000 ? m.text.substring(0, 2000) : m.text;
  return ai.suggestReplies([
    (text: text, time: m.date, mine: false, sender: m.sender),
  ]);
});

class SuggestedReplies extends ConsumerWidget {
  const SuggestedReplies({super.key, required this.message, required this.body});

  final MailMessage message;
  final MailBody body;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = {
      for (final a in ref.watch(accountsProvider).value ?? const [])
        a.emailAddress.toLowerCase(),
    };
    // Not for mail sent from here, nor for what no one answers.
    if (mine.contains(message.from.email.toLowerCase())) {
      return const SizedBox.shrink();
    }
    final replies = ref
            .watch(suggestedRepliesProvider((
              messageId: message.id,
              text: ownWordsOf(body),
              sender: message.from.email,
              date: message.date,
            )))
            .value ??
        const <String>[];
    if (replies.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Row(
          children: [
            for (final (i, reply) in replies.indexed)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  key: ValueKey('ai-reply:$i'),
                  avatar: const Icon(Icons.reply, size: 16),
                  label: Text(reply),
                  onPressed: () => openCompose(
                    context,
                    ref,
                    kind: ComposeKind.reply,
                    original: message,
                    bodyText: reply,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
