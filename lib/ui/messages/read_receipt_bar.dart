import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/display_settings.dart';
import '../../domain/error_report.dart';
import '../../domain/mail_message.dart';
import '../../state/display_providers.dart';
import '../../state/list_filter.dart' show ownAddressesProvider;
import '../../state/providers.dart';
import '../../state/read_marker.dart';
import '../../state/read_receipts.dart';
import '../../state/unsubscribe.dart' show openedHeadersProvider;
import '../common/bottom_message.dart';

/// A read receipt asked for, as Outlook asks: "The sender of this message
/// has requested a read receipt", with Send receipt and Don't send. Or, as
/// Settings, View has it, sent without asking, or never offered.
///
/// The request names where the receipt goes, and the sender writes it. So
/// one that names several addresses is not offered at all, one that names
/// someone other than the sender says who, and only a receipt to the sender
/// goes without asking (RFC 8098 says as much).
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

  /// Read once, while the ref may still be used: it is let go of as the
  /// bar goes.
  late final ReadMarker _marker;

  @override
  void initState() {
    super.initState();
    _marker = ref.read(readMarkerProvider);
    _marker.open.addListener(_onOpened);
  }

  @override
  void dispose() {
    _marker.open.removeListener(_onOpened);
    super.dispose();
  }

  /// A message opened: this one, perhaps, which a receipt set to go without
  /// asking was waiting for. Nothing for a message left, which is told as
  /// the panes are taken down, when a rebuild may not be asked for.
  void _onOpened() {
    if (mounted && _marker.open.value == widget.message.id) setState(() {});
  }

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
    final to =
        ref.watch(openedHeadersProvider(message.id)).value?.receiptAddress;
    if (to == null) return const SizedBox.shrink();
    final toSender =
        to.toLowerCase() == message.from.email.trim().toLowerCase();

    if (answer == ReceiptAnswer.always && toSender) {
      // Sent once it is opened, as being marked read is: not as the app
      // lands on it by itself, opening a folder or after a delete, which
      // is Ron walking past. Once: the set of answered requests says it
      // went.
      if (_marker.open.value != message.id) return const SizedBox.shrink();
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
                toSender
                    ? '${message.from.display} asked to be told you read this.'
                    : '${message.from.display} asked for a receipt to be '
                          'sent to $to.',
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
