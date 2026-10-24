import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/files/file_bridge.dart' show MailtoLink;
import '../../domain/mail_message.dart';
import '../../domain/unsubscribe.dart';
import '../../state/list_filter.dart' show ownAddressesProvider;
import '../../state/providers.dart';
import '../../state/unsubscribe.dart';
import '../common/bottom_message.dart';

/// Unsubscribe, beside the sender of a message from a mailing list, as
/// Gmail and new Outlook put it: there when the list's headers say how to
/// leave it, and nowhere else. Asked for when the message opens.
class UnsubscribeLink extends ConsumerWidget {
  const UnsubscribeLink({super.key, required this.message});

  final MailMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offered = offersUnsubscribe(
      message,
      role: ref.watch(folderIndexProvider)[message.folderId]?.role,
      ownAddresses: ref.watch(ownAddressesProvider),
    );
    if (!offered) return const SizedBox.shrink();
    final options = ref.watch(unsubscribeOptionsProvider(message.id)).value;
    if (options == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final done =
        ref.watch(unsubscribedProvider).contains(unsubscribeKey(options));
    if (done) {
      return Text(
        'Unsubscribed',
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return InkWell(
      key: const ValueKey('unsubscribe'),
      borderRadius: BorderRadius.circular(4),
      onTap: () => confirmUnsubscribe(context, ref, message, options),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Text(
          'Unsubscribe',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationColor: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Says what Unsubscribe will do, the way it will be done, and does it if
/// asked to; then says how it went.
Future<void> confirmUnsubscribe(
  BuildContext context,
  WidgetRef ref,
  MailMessage message,
  UnsubscribeOptions options,
) async {
  final sender = message.from.display;
  final account = ref
      .read(accountsProvider)
      .value
      ?.where((a) => a.id == message.accountId)
      .firstOrNull;
  final to = MailtoLink.parse('${options.mailto}')?.to.firstOrNull;
  final how = switch (options.way) {
    UnsubscribeWay.oneClick =>
      'MyEmail tells them now, and they take you off their list.',
    UnsubscribeWay.email => 'MyEmail sends the email they ask for'
        '${to == null ? '' : ' to $to'}'
        '${account == null ? '' : ', from ${account.emailAddress}'}.',
    UnsubscribeWay.page =>
      'They ask you to finish on their own page, which opens in your browser.',
  };
  final go = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Unsubscribe'),
      content: Text('Stop getting mail from $sender?\n\n$how'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(
            options.way == UnsubscribeWay.page ? 'Open page' : 'Unsubscribe',
          ),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await unsubscribe(ref.read, message, options);
  final said = switch (outcome) {
    UnsubscribeOutcome.done =>
      'Unsubscribed from $sender. It can take them a few days.',
    UnsubscribeOutcome.sent =>
      'Unsubscribe email sent to $sender. It can take them a few days.',
    UnsubscribeOutcome.opened => null,
    UnsubscribeOutcome.failed =>
      'Could not unsubscribe from $sender. Try again later.',
  };
  if (said == null) return;
  messenger?.showSnackBar(
    SnackBar(duration: kBottomMessage, content: Text(said)),
  );
}
