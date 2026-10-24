import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/display_settings.dart';
import '../../domain/error_report.dart';
import '../../domain/mail_message.dart';
import '../../state/display_providers.dart';
import '../../state/list_filter.dart' show ownAddressesProvider;
import '../../state/providers.dart';
import '../../state/read_receipts.dart';
import '../../state/unsubscribe.dart' show openedHeadersProvider;
import '../common/bottom_message.dart';

/// A read receipt asked for, as Outlook asks: "The sender of this message
/// has requested a read receipt", with Send receipt and Don't send. Or, as
/// Settings, View has it, sent without asking, or never offered.
///
/// On a Gmail account only for now: see `MailEngine.answersReadReceipts`.
class ReadReceiptBar extends ConsumerStatefulWidget {
  const ReadReceiptBar({super.key, required this.message});

  final MailMessage message;

  @override
  ConsumerState<ReadReceiptBar> createState() => _ReadReceiptBarState();
}

class _ReadReceiptBarState extends ConsumerState<ReadReceiptBar> {
  bool _busy = false;

  /// Sent without asking already, or tried: once a message, so a receipt
  /// that fails is not tried again on every rebuild.
  bool _sentUnasked = false;

  Future<void> _answer({required bool send}) async {
    final message = widget.message;
    final engine = ref.read(mailEngineProvider);
    final answered = ref.read(answeredReceiptsProvider.notifier);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      if (send) {
        await engine.sendReadReceipt(message.id);
      } else {
        await engine.declineReadReceipt(message.id);
      }
      answered.add(message);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(
        duration: kBottomMessage,
        content: Text(
          'The read receipt was not sent. '
          '${e is ReadableError ? e.message : '$e'}',
        ),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final answer = ref.watch(displayProvider.select((d) => d.receipts));
    final engine = ref.watch(mailEngineProvider);
    if (answer == ReceiptAnswer.never ||
        !engine.answersReadReceipts(message.accountId)) {
      return const SizedBox.shrink();
    }
    final offered = answersReceiptOn(
      message,
      role: ref.watch(folderIndexProvider)[message.folderId]?.role,
      ownAddresses: ref.watch(ownAddressesProvider),
    );
    if (!offered) return const SizedBox.shrink();
    if (ref.watch(answeredReceiptsProvider).contains(receiptKey(message))) {
      return const SizedBox.shrink();
    }
    final asked = ref.watch(openedHeadersProvider(message.id)).value?.receiptTo;
    if (asked == null) return const SizedBox.shrink();

    if (answer == ReceiptAnswer.always) {
      // Sent as it opens, once: the set of answered requests says it went.
      if (!_sentUnasked) {
        _sentUnasked = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _answer(send: true);
        });
      }
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(
              Icons.mark_email_read_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${message.from.display} asked to be told you read this.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              TextButton(
                onPressed: () => _answer(send: false),
                child: const Text("Don't send"),
              ),
              TextButton(
                key: const ValueKey('send-receipt'),
                onPressed: () => _answer(send: true),
                child: const Text('Send receipt'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
