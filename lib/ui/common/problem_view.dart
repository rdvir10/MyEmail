import './bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/error_report.dart';
import '../../state/update_providers.dart';

/// A failure, said once, with the ways out of it.
///
/// Every screen that can fail shows this rather than its own red paragraph.
/// The message was never the hard part; what was missing everywhere was
/// somewhere to go next. A person meeting an error they cannot act on and
/// cannot pass on has nothing to do but try the same thing again.
///
/// [onRemedy] is the screen's own one-tap fix, where it has one — reloading
/// the folders, opening the account. Screens that already carry the obvious
/// button, like Add account with its Sign in button a few lines below, pass
/// nothing and show only the two reporting actions.
class ProblemView extends ConsumerWidget {
  const ProblemView({super.key, required this.problem, this.onRemedy});

  final ProblemReport problem;
  final VoidCallback? onRemedy;

  Future<void> _copy(BuildContext context, WidgetRef ref) async {
    final version = ref.read(installedVersionValueProvider).value;
    await Clipboard.setData(ClipboardData(
      text: problem.text(
        appVersion: version?.version,
        build: version?.build,
      ),
    ));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(duration: kBottomMessage, 
        content: Text('Problem details copied. Paste them anywhere.'),
      ));
  }

  /// File it where the fixes come from.
  ///
  /// The repository is public, so the address is shortened on this path. The
  /// clipboard keeps it whole: that goes wherever the person puts it, which is
  /// theirs to decide, while this one is published the moment they submit.
  Future<void> _report(BuildContext context, WidgetRef ref) async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Report this on GitHub?'),
        content: const Text(
          'This opens a new issue with the details filled in. You can read it '
          'over and change anything before submitting.\n\n'
          'The repository is public, so your email address is shortened to '
          'its first letter and domain. Nothing else about your mail is '
          'included — no message, no subject, no password.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open GitHub'),
          ),
        ],
      ),
    );
    if (agreed != true || !context.mounted) return;

    final version = ref.read(installedVersionValueProvider).value;
    final opened = await launchUrl(
      IssueTracker.newIssueUrl(
        title: problem.issueTitle,
        report: problem.text(
          appVersion: version?.version,
          build: version?.build,
          redactAddress: true,
        ),
      ),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(duration: kBottomMessage, 
          content: Text('Could not open a browser. Use Copy details instead.'),
        ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final remedy = problem.remedy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          problem.message,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.error),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          children: [
            // Only where the screen actually has somewhere to go. A button
            // that cannot work is worse than none: it gets tried, it fails,
            // and then there is nothing left to try.
            if (onRemedy != null && remedy.isOffered)
              _Action(label: remedy.label, onPressed: onRemedy!),
            _Action(
              label: 'Copy details',
              onPressed: () => _copy(context, ref),
            ),
            _Action(
              label: 'Report',
              onPressed: () => _report(context, ref),
            ),
          ],
        ),
      ],
    );
  }
}

/// Small and tightly packed, because these sit under a sentence rather than
/// standing on their own as the point of the screen.
class _Action extends StatelessWidget {
  const _Action({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label),
      );
}
