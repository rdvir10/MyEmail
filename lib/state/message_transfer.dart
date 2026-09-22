import '../ui/common/bottom_message.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/files/file_bridge.dart';
import '../data/files/message_files.dart';
import '../domain/mail_message.dart';
import 'attachment_providers.dart';
import 'providers.dart';
import 'window_providers.dart';

/// Where `.eml` files are written. main() overrides this with the disk.
final messageFilesProvider =
    Provider<MessageFiles>((ref) => FakeMessageFiles());

/// The label on a drag of messages out of this app, so a copy of the app
/// that receives the drop can tell it from a file coming in from outside:
/// a message dropped on the folder tree is a move, not an attachment.
const messageDragLabel = 'myemail:messages';

/// Whether this window shares the screen: split screen, a pop-up, DeX. In
/// that case a long press and a pull on a message drags it as a file the
/// other window can take, rather than lifting it within this one.
///
/// Refreshed on resume and when the window changes size, which is when
/// the answer changes.
class MultiWindowMode extends Notifier<bool> {
  @override
  bool build() => false;

  Future<void> refresh() async {
    final now = await ref.read(windowOpenerProvider).inMultiWindow();
    if (now != state) state = now;
  }
}

final multiWindowModeProvider =
    NotifierProvider<MultiWindowMode, bool>(MultiWindowMode.new);

/// The message as a file: fetched as it arrived, written once.
Future<File> emlFor(WidgetRef ref, MailMessage message) async {
  final raw = await ref.read(mailEngineProvider).rawMessage(message.id);
  return ref.read(messageFilesProvider).writeEml(emlFileName(message), raw);
}

/// Put the message on the clipboard as an `.eml`. Pasting it into a
/// message being written attaches it; pasting it into a file manager
/// saves it.
Future<void> copyMessage(
  WidgetRef ref,
  BuildContext context,
  MailMessage message,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final file = await emlFor(ref, message);
    await ref.read(fileBridgeProvider).copyToClipboard(
          file.path,
          mimeType: emlMimeType,
          name: emlFileName(message),
        );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(duration: kBottomMessage, content: Text('Message copied')));
  } catch (e) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text('Could not copy: $e')));
  }
}

/// Start dragging messages out of the app as `.eml` files. True if the
/// drag started.
Future<bool> dragMessages(WidgetRef ref, List<MailMessage> messages) async {
  final files = <DragFile>[];
  for (final m in messages) {
    final file = await emlFor(ref, m);
    files.add(DragFile(
      path: file.path,
      mimeType: emlMimeType,
      name: emlFileName(m),
    ));
  }
  if (files.isEmpty) return false;
  return ref.read(fileBridgeProvider).startDragFiles(
        files,
        label: messageDragLabel,
        // The ids ride along, so a copy of the app that receives the
        // drop can move the messages rather than attach them.
        text: messages.map((m) => m.id).join('\n'),
      );
}
