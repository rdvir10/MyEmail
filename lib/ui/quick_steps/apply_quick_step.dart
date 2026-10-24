import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_message.dart';
import '../../domain/quick_step.dart';
import '../../state/follow_ups.dart';
import '../../state/folder_tree.dart';
import '../../state/meeting_providers.dart' show workWeekProvider;
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../../state/quick_steps.dart';
import '../common/bottom_message.dart';
import '../compose/open_compose.dart';
import '../meetings/new_meeting_screen.dart';
import '../messages/message_actions.dart';

/// [step] on [message], from the ribbon, a row's menu or Ctrl+Shift and its
/// number, saying what came of it. The screens its actions open (a
/// forward, a reply, a new message, a meeting) open from [context].
Future<void> applyQuickStep(
  BuildContext context,
  WidgetRef ref, {
  required QuickStep step,
  required MailMessage message,
  required String listId,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(text)));
  try {
    await runQuickStep(
      step: step,
      notifier: ref.read(messagesProvider(listId).notifier),
      message: message,
      engine: ref.read(mailEngineProvider),
      hooks: quickStepHooks(context, ref),
      onMoved: (folderId) =>
          ref.read(recentMoveTargetsProvider.notifier).record(folderId),
      onElsewhere: () {
        ref.invalidate(messagesProvider(message.folderId));
        ref.invalidate(messagesProvider(kUnifiedInboxId));
        ref.invalidate(messagesProvider(kFlaggedId));
      },
    );
    say('${step.name} applied');
  } catch (e) {
    say('${step.name} failed: $e');
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
