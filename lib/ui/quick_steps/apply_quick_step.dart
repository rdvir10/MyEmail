import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/error_report.dart' show ReadableError;
import '../../domain/mail_message.dart';
import '../../domain/quick_step.dart';
import '../../state/follow_ups.dart';
import '../../state/folder_tree.dart';
import '../../state/list_filter.dart';
import '../../state/meeting_providers.dart' show workWeekProvider;
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../../state/quick_steps.dart';
import '../../state/search_providers.dart';
import '../../state/window_providers.dart';
import '../common/bottom_message.dart';
import '../compose/open_compose.dart';
import '../meetings/new_meeting_screen.dart';
import '../messages/message_actions.dart';

/// [step] on [message], from a row's menu: see [applyQuickStepTo].
Future<void> applyQuickStep(
  BuildContext context,
  WidgetRef ref, {
  required QuickStep step,
  required MailMessage message,
  required String listId,
}) =>
    applyQuickStepTo(context, ref,
        step: step, messages: [message], listId: listId);

/// [step] on each of [messages] in turn, from the ribbon, a row's menu or
/// Ctrl+Shift and its number, saying once what came of it. The screens its
/// actions open (a forward, a reply, a new message, a meeting) open from
/// [context]. The messages it went on, in order: all of them, or those
/// before the one it failed on.
///
/// Several are the ticked ones, which the ribbon and the keys take as
/// Delete and Move beside them do; they took the message open in the
/// reading pane alone, the last row Shift and the arrows reached. A step
/// that opens a screen runs on one message only: a forward for each of
/// twenty ticked would be twenty screens, one after another.
///
/// It stops at the first message the step fails on, as the step itself
/// stops at the action that fails (see [runQuickStep]). Carried on, "Flag,
/// then Move" with a move the server refused flagged all twenty and moved
/// none; what failed once, a folder gone or a permission not given, fails
/// again. What it did not get to is said, for the caller to leave ticked.
/// No Undo, as there is none for a step on one message.
Future<List<MailMessage>> applyQuickStepTo(
  BuildContext context,
  WidgetRef ref, {
  required QuickStep step,
  required List<MailMessage> messages,
  required String listId,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  // The app's container, taken now, as MessageActions takes it: a step that
  // opens a screen ends long after it began.
  final container = ProviderScope.containerOf(context, listen: false);
  void say(String text) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(text)));
  if (messages.isEmpty) return const [];
  if (messages.length > 1 &&
      step.effectiveActions.any((a) => a.type.opensScreen)) {
    say('${step.name} opens a screen for its message, so it works on one '
        'message at a time.');
    return const [];
  }
  final hooks = quickStepHooks(context, ref);
  final went = <MailMessage>[];
  Object? failure;
  for (final message in messages) {
    try {
      final run = runQuickStep(
        step: step,
        notifier: container.read(messagesProvider(listId).notifier),
        message: message,
        engine: container.read(mailEngineProvider),
        hooks: hooks,
        onMoved: (folderId) => container
            .read(recentMoveTargetsProvider.notifier)
            .record(folderId),
        onElsewhere: () {
          container.invalidate(messagesProvider(message.folderId));
          container.invalidate(messagesProvider(kUnifiedInboxId));
          container.invalidate(messagesProvider(kFlaggedId));
        },
      );
      // Noted as on its way to a server, as MessageActions notes its own,
      // so a window of its own waits for it before it ends. A step leaves
      // the message's screen up, and Back pressed while it was still going
      // ended the window with it. See WorkInFlight.
      container.read(workInFlightProvider).add(run);
      await run;
      went.add(message);
    } catch (e) {
      failure = e;
      break;
    }
  }
  // What a filter found on the server and the search on screen are both
  // from before the step, as after a swipe or the menu (see
  // MessageActions): a message filed or deleted came back from them, still
  // in the list, still open in the pane. After a step that failed part way
  // too, since what went before it went.
  if (container.read(searchQueryProvider).trim().isNotEmpty) {
    container.invalidate(searchHitsProvider);
  }
  container.invalidate(filterHitsProvider);
  final n = messages.length;
  final left = n - went.length;
  final why = failure is ReadableError ? failure.message : '$failure';
  if (failure == null) {
    say(n == 1
        ? '${step.name} applied'
        : '${step.name} applied to $n messages');
  } else if (n == 1) {
    say('${step.name} failed: $failure');
  } else {
    // The one it failed on may be half done: "Flag, then Move" flagged it.
    final stop = why.endsWith('.') ? '' : '.';
    say('${step.name} applied to ${went.length} of $n, then failed: $why'
        '$stop ${left == 1 ? 'The one left is' : 'The $left left are'} '
        'still ticked.');
  }
  return went;
}

/// The ticks after [applyQuickStepTo] ran on the ticked [chosen] and went
/// on [went]: all of them gone where it went on every one, as after
/// Delete; else off those it went on only, so the one it failed on and
/// those after it are still ticked, to be seen and tried again.
void untickWhatWent(
  WidgetRef ref,
  List<MailMessage> chosen,
  List<MailMessage> went,
) {
  if (went.isEmpty) return;
  final ticks = ref.read(selectedMessageIdsProvider.notifier);
  if (went.length == chosen.length) {
    ticks.clear();
  } else {
    ticks.removeAll([for (final m in went) m.id]);
  }
}

/// What a Quick Step's actions need from the screen: see [QuickStepHooks].
QuickStepHooks quickStepHooks(BuildContext context, WidgetRef ref) =>
    QuickStepHooks(
      archiveTarget: (accountId) => archiveTargetFor(
        ref.read(foldersProvider).value ?? const {},
        accountId,
      ),
      compose: (kind, original, to) async {
        if (!context.mounted) return;
        await openCompose(context, ref, kind: kind, original: original, to: to);
      },
      meeting: (message) async {
        final body =
            await ref.read(mailEngineProvider).loadMessageBody(message.id);
        if (!context.mounted) return;
        await openNewMeetingFromMessage(context, ref, message, body);
      },
      workWeek: ref.read(workWeekProvider),
      rememberDue: (message, due) =>
          ref.read(followUpsProvider.notifier).setDue(message, due),
    );
