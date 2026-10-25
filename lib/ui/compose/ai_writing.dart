import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ai/on_device_ai.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../state/ai_providers.dart';
import '../common/bottom_message.dart';

/// What the phone's AI can be asked to do with a draft: Proofread, or one
/// of the rewriting styles.
typedef AiWritingChoice = ({String label, RewriteStyle? style});

const aiWritingChoices = <AiWritingChoice>[
  (label: 'Proofread', style: null),
  (label: 'Shorter', style: RewriteStyle.shorter),
  (label: 'Friendlier', style: RewriteStyle.friendlier),
  (label: 'More formal', style: RewriteStyle.formal),
  (label: 'Longer', style: RewriteStyle.longer),
  (label: 'Rephrase', style: RewriteStyle.rephrase),
];

/// Google's models take this many tokens at a time, about 190 English
/// words; a little under, for the counting being rough.
const aiWritingLimit = 240;

/// The compose bar's button for the phone's AI, Outlook's Coaching and
/// Draft with Copilot made on the phone: there only where the phone has it
/// (the Pixel 9 Pro).
class AiWritingButton extends ConsumerWidget {
  const AiWritingButton({
    super.key,
    required this.enabled,
    required this.read,
    required this.write,
  });

  final bool enabled;

  /// The words to work on: those selected, or all the message's own.
  final Future<String> Function() read;

  /// The answer in their place.
  final Future<void> Function(String text) write;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proofread =
        ref.watch(aiReadinessProvider(AiFeature.proofread)).value;
    final rewrite = ref.watch(aiReadinessProvider(AiFeature.rewrite)).value;
    if (!(proofread?.usable ?? false) && !(rewrite?.usable ?? false)) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<AiWritingChoice>(
      key: const ValueKey('compose-ai'),
      tooltip: 'Proofread or rewrite',
      enabled: enabled,
      icon: const Icon(Icons.auto_awesome),
      onSelected: (choice) => runAiWriting(
        context,
        ref,
        choice: choice,
        read: read,
        write: write,
      ),
      itemBuilder: (_) => [
        for (final c in aiWritingChoices)
          if (c.style == null ? proofread?.usable ?? false : rewrite?.usable ?? false)
            PopupMenuItem(
              key: ValueKey('compose-ai:${c.label}'),
              value: c,
              child: Text(c.label),
            ),
      ],
    );
  }
}

/// [choice] on what [read] gives, the answer shown, and put in its place
/// with Use this.
Future<void> runAiWriting(
  BuildContext context,
  WidgetRef ref, {
  required AiWritingChoice choice,
  required Future<String> Function() read,
  required Future<void> Function(String text) write,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: kBottomMessage,
      persist: false,
      content: Text(text),
    ));

  final text = (await read()).trim();
  if (!context.mounted) return;
  if (text.isEmpty) {
    say('Write something first, or select the words to work on.');
    return;
  }
  if (!readsAsEnglish(text, minimum: 1)) {
    say("The phone's AI works in English only.");
    return;
  }
  if (roughTokens(text) > aiWritingLimit) {
    say("Select a part of it first: the phone's AI takes about 150 words "
        'at a time.');
    return;
  }

  final ai = ref.read(onDeviceAiProvider);
  final feature =
      choice.style == null ? AiFeature.proofread : AiFeature.rewrite;
  final answer = await showDialog<String>(
    context: context,
    builder: (_) => _AiAnswer(
      choice: choice,
      original: text,
      ask: () async {
        if (await ai.readiness(feature) != AiReadiness.available) {
          await ai.download(feature);
          ref.invalidate(aiReadinessProvider(feature));
        }
        final options = choice.style == null
            ? await ai.proofread(text)
            : await ai.rewrite(text, choice.style!);
        return options.isEmpty ? text : options.first;
      },
    ),
  );
  if (answer == null || !context.mounted) return;
  await write(answer);
}

/// The answer as it comes, with Use this and Cancel.
class _AiAnswer extends StatefulWidget {
  const _AiAnswer({
    required this.choice,
    required this.original,
    required this.ask,
  });

  final AiWritingChoice choice;
  final String original;
  final Future<String> Function() ask;

  @override
  State<_AiAnswer> createState() => _AiAnswerState();
}

class _AiAnswerState extends State<_AiAnswer> {
  late final Future<String> _answer = widget.ask();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<String>(
      future: _answer,
      builder: (context, snapshot) {
        final answer = snapshot.data;
        final error = snapshot.error;
        return AlertDialog(
          title: Text(widget.choice.label),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: switch ((answer, error)) {
                (final a?, _) when a.trim() == widget.original.trim() =>
                  Text(
                    widget.choice.style == null
                        ? 'Nothing to correct.'
                        : 'It came back the same.',
                    key: const ValueKey('ai-answer-same'),
                  ),
                (final a?, _) => SelectableText(
                    a,
                    key: const ValueKey('ai-answer'),
                  ),
                (_, final e?) => Text(
                    e is ReadableError ? e.message : '$e',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                _ => const Row(
                    children: [
                      SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Expanded(child: Text('Working on it, on the phone…')),
                    ],
                  ),
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            if (answer != null && answer.trim() != widget.original.trim())
              FilledButton(
                key: const ValueKey('ai-use'),
                onPressed: () => Navigator.of(context).pop(answer),
                child: const Text('Use this'),
              ),
          ],
        );
      },
    );
  }
}
