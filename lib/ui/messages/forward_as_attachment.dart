import '../common/bottom_message.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/files/message_files.dart';
import '../../data/mail_engine.dart' show rawMessageBytes;
import '../../domain/draft.dart';
import '../../domain/mail_message.dart';
import '../../state/providers.dart';
import '../compose/open_compose.dart';

/// Messages as `.eml` attachments, each as it arrived, and each naming the
/// message it is so that it can be marked forwarded once the draft is away.
Future<List<DraftAttachment>> emlAttachments(
  WidgetRef ref,
  List<MailMessage> messages,
) async {
  final engine = ref.read(mailEngineProvider);
  return [
    for (final m in messages)
      DraftAttachment(
        fileName: emlFileName(m),
        mimeType: emlMimeType,
        bytes: rawMessageBytes(await engine.rawMessage(m.id)),
        forwardedMessageId: m.id,
      ),
  ];
}

/// A new message carrying these messages as files, the way Outlook's
/// "Forward as attachment" does: the originals go across whole, headers
/// and all, rather than quoted.
Future<void> forwardAsAttachment(
  BuildContext context,
  WidgetRef ref,
  List<MailMessage> messages,
) async {
  if (messages.isEmpty) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final List<DraftAttachment> attachments;
  try {
    attachments = await emlAttachments(ref, messages);
  } catch (e) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text('Could not fetch the messages: $e')));
    return;
  }
  if (!context.mounted) return;
  await openCompose(
    context,
    ref,
    kind: ComposeKind.newMessage,
    attachments: attachments,
    subject: messages.length == 1
        ? 'FW: ${messages.single.subject}'
        : 'FW: ${messages.length} messages',
  );
}
