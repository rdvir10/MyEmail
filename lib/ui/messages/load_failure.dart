import 'package:flutter/material.dart';

/// A message's body that could not be had, said where the body would have
/// been, with Try again under it.
///
/// Opened on the train with no signal, a message went on saying it could
/// not be loaded once the phone was back online, and there was nothing on
/// the screen to tap. Reading it meant leaving it and coming back, and on a
/// tablet, whose pane stays on the message, not even that.
class BodyLoadFailure extends StatelessWidget {
  const BodyLoadFailure({
    super.key,
    required this.error,
    required this.onRetry,
    this.centered = false,
  });

  final Object error;
  final VoidCallback onRetry;

  /// In the middle of the screen, as on a message shown full screen, rather
  /// than at the top of the pane where the text would have started.
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(
          'Could not load the message.\n$error',
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    );
  }
}
