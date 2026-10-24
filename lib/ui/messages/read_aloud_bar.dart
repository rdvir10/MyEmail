import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/speech_text.dart';
import '../../state/read_aloud.dart';

/// Read Aloud's controls, over the body of the message being read: back a
/// paragraph, pause or go on, forward a paragraph, where it has got to,
/// the speed, and stop.
class ReadAloudBar extends ConsumerWidget {
  const ReadAloudBar({super.key, required this.messageId});

  final String messageId;

  static const rates = [0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readAloudProvider);
    if (state == null || state.messageId != messageId) {
      return const SizedBox.shrink();
    }
    final reader = ref.read(readAloudProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final count = state.pieces.length;
    final notice = state.unavailable
        ? 'This phone has no text-to-speech voice.'
        : state.missingVoice == null
            ? null
            : count == 0
                ? 'No ${_languageName(state.missingVoice!)} voice is '
                    'installed, so there is nothing to read.'
                : 'No ${_languageName(state.missingVoice!)} voice is '
                    'installed: those parts are skipped.';
    return Material(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.record_voice_over_outlined,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Back a paragraph',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: count == 0 ? null : reader.previous,
                ),
                IconButton(
                  key: const ValueKey('read-aloud-play'),
                  tooltip: state.playing ? 'Pause' : 'Read',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: count == 0
                      ? null
                      : state.playing
                          ? reader.pause
                          : reader.resume,
                ),
                IconButton(
                  tooltip: 'Forward a paragraph',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.skip_next),
                  onPressed: count == 0 ? null : reader.next,
                ),
                const SizedBox(width: 4),
                if (count > 0)
                  Flexible(
                    child: Text(
                      '${state.index + 1} of $count',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                const Spacer(),
                PopupMenuButton<double>(
                  tooltip: 'Speed',
                  initialValue: state.rate,
                  onSelected: reader.setRate,
                  itemBuilder: (_) => [
                    for (final rate in rates)
                      PopupMenuItem(value: rate, child: Text(_rateLabel(rate))),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Text(
                      _rateLabel(state.rate),
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('read-aloud-stop'),
                  tooltip: 'Stop reading',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close),
                  onPressed: reader.stop,
                ),
              ],
            ),
            if (notice != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(notice, style: muted)),
                    TextButton(
                      onPressed: () =>
                          ref.read(speechEngineProvider).openSettings(),
                      child: const Text('Voice settings'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _rateLabel(double rate) =>
      '${rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : rate}×';

  static String _languageName(String voice) => switch (voice) {
        hebrewVoice => 'Hebrew',
        englishVoice => 'English',
        _ => voice,
      };
}
