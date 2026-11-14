import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    final options =
        ref.watch(openedHeadersProvider(message.id)).value?.unsubscribe;
    if (options == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final key = unsubscribeKey(options);
    final done = ref.watch(unsubscribedProvider).contains(key);
    final going = ref.watch(unsubscribingProvider).contains(key);
    if (done || going) {
      return Text(
        done ? 'Unsubscribed' : 'Unsubscribing…',
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
///
/// Carried on through the app's container, not [ref]: the dialog closed,
/// Ron may leave the message at once (Delete, Back, the next one), which
/// takes this link and its ref away, and a ref read after that throws. An
/// email that went was then reported as not sent, and a one-click list
/// left said nothing and was not remembered as left.
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
  // What the email says is the list's to write, so it is shown, and shown
  // too where it is only the way should one click fail: it goes from Ron's
  // account all the same.
  final email = unsubscribeEmail(options);
  final says = email == null
      ? ''
      : email.words.toLowerCase() == email.subject.toLowerCase()
          ? ', with the subject "${email.subject}"'
          : ', with the subject "${email.subject}" and the words '
              '"${email.words}"';
  final sends = 'the email they ask for'
      '${email == null ? '' : ' to ${email.to}'}'
      '${account == null ? '' : ', from ${account.emailAddress}'}'
      '$says';
  final how = switch (options.way) {
    UnsubscribeWay.oneClick =>
      'MyEmail tells them now, and they take you off their list.'
          '${email == null ? '' : ' Should that not work, it sends $sends.'}',
    UnsubscribeWay.email => 'MyEmail sends $sends.',
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
  final read = ProviderScope.containerOf(context, listen: false).read;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final going = read(unsubscribingProvider.notifier);
  if (!going.start(options)) return;
  // Seconds, perhaps, and nothing else shows it: a page opens at once.
  // Its own bar, and only its own is ever taken down: it waits behind one
  // already up, and Delete pressed straight after puts the delete's bar,
  // with its Undo, over it.
  final progress = messenger == null || options.way == UnsubscribeWay.page
      ? null
      : _Progress(messenger, 'Unsubscribing from $sender…');
  final UnsubscribeOutcome outcome;
  try {
    outcome = await unsubscribe(read, message, options);
  } finally {
    going.end(options);
  }
  final said = switch (outcome) {
    UnsubscribeOutcome.done =>
      'Unsubscribed from $sender. It can take them a few days.',
    UnsubscribeOutcome.sent =>
      'Unsubscribe email sent to $sender. It can take them a few days.',
    UnsubscribeOutcome.opened => null,
    UnsubscribeOutcome.failed =>
      'Could not unsubscribe from $sender. Try again later.',
  };
  if (progress != null && progress.waiting) {
    // Not up yet, behind another bar: it says how it went when it is.
    progress.words.value = said ?? 'Their page is open in your browser.';
    return;
  }
  progress?.closeIfUp();
  if (said == null) return;
  messenger?.showSnackBar(
    SnackBar(duration: kBottomMessage, content: Text(said)),
  );
}

/// Unsubscribe's bar while it works, which knows whether it is up, gone,
/// or still waiting behind another bar. Flutter closes a bar only while
/// it is the one on screen; hiding the current bar instead took down
/// whatever was there.
class _Progress {
  _Progress(ScaffoldMessengerState messenger, String saying)
      : words = ValueNotifier(saying) {
    _bar = messenger.showSnackBar(SnackBar(
      duration: kBottomMessage,
      content: _ProgressWords(this),
    ));
    _bar.closed.then((_) => _gone = true);
  }

  final ValueNotifier<String> words;
  late final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> _bar;
  bool _gone = false;

  /// Places it is drawn now: only ever the bar on screen is.
  int _drawn = 0;

  /// Neither up nor gone: queued behind another bar.
  bool get waiting => !_gone && _drawn == 0;

  void closeIfUp() {
    if (!_gone && _drawn > 0) _bar.close();
  }
}

class _ProgressWords extends StatefulWidget {
  const _ProgressWords(this.progress);

  final _Progress progress;

  @override
  State<_ProgressWords> createState() => _ProgressWordsState();
}

class _ProgressWordsState extends State<_ProgressWords> {
  @override
  void initState() {
    super.initState();
    widget.progress._drawn++;
  }

  @override
  void dispose() {
    widget.progress._drawn--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: widget.progress.words,
        builder: (_, words, _) => Text(words),
      );
}
