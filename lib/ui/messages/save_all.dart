import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_attachment.dart';
import '../../state/attachment_providers.dart';
import '../common/bottom_message.dart';

/// Save All Attachments, as Outlook has it: one folder chosen, every file
/// on the message put in it.
///
/// The folder first, so that backing out costs nothing; then each file,
/// downloaded where it is not here yet (its chip shows it coming) and
/// written into the folder under its own name. One that cannot be fetched
/// or written does not stop the rest, and the bar says which they were.
Future<void> saveAllAttachments(
  BuildContext context,
  WidgetRef ref,
  String messageId,
  List<MailAttachment> files,
) async {
  if (files.isEmpty) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(text)));

  final bridge = ref.read(fileBridgeProvider);
  final String? folder;
  try {
    folder = await bridge.pickFolder();
  } catch (e) {
    say('Could not open the folder picker.');
    return;
  }
  if (folder == null) return;

  final downloads = ref.read(attachmentDownloadsProvider.notifier);
  final missed = <String>[];
  for (final attachment in files) {
    final file = await downloads.file(messageId, attachment);
    var saved = false;
    if (file != null) {
      try {
        saved = await bridge.saveIntoFolder(
          folder,
          file.path,
          name: safeFileName(attachment.name),
          mimeType: attachment.openAs,
        );
      } catch (_) {
        saved = false;
      }
    }
    if (!saved) missed.add(attachment.name);
  }
  say(saveAllOutcome(files.length, missed));
}

/// What Save all says when it is done: [count] files asked for, [missed]
/// the names of those that did not make it.
String saveAllOutcome(int count, List<String> missed) {
  if (missed.isEmpty) {
    return count == 1 ? 'Saved the file.' : 'Saved all $count files.';
  }
  if (missed.length == count) {
    return count == 1 ? 'Could not save the file.' : 'Could not save the files.';
  }
  return 'Saved ${count - missed.length} of $count. Not saved: '
      '${missed.join(', ')}.';
}
