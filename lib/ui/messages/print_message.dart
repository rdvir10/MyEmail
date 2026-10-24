import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/print/message_printer.dart';
import '../../domain/html_safety.dart';
import '../../domain/mail_message.dart';
import '../../domain/trusted_senders.dart';
import '../../state/attachment_providers.dart';
import '../../state/display_providers.dart';
import '../../state/print_providers.dart';
import '../../state/trusted_senders.dart';
import '../common/bottom_message.dart';
import 'html_body_view.dart' show stripRemoteContent;

/// The system's print sheet for [message], which is also where "Save as
/// PDF" lives. The one way to print, for the pane's menu and for Ctrl+P
/// alike: the shortcut had a copy of its own, which had drifted, printing a
/// trusted sender's message without its pictures and saying nothing when
/// printing failed.
///
/// What is on screen is what prints. Pictures from the web only where the
/// setting or a trusted sender loads them in the pane, since printing a
/// message must not tell its sender it was read. The pictures the message
/// carries itself, named by Content-ID, are put in place as the pane puts
/// them: the page the print sheet is given has nothing to load for a cid:
/// link, and a pasted screenshot or a signature's logo printed as a broken
/// box.
Future<void> printMessage(
  BuildContext context,
  WidgetRef ref,
  MailMessage message,
  MailBody body,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final printer = ref.read(messagePrinterProvider);
  final showImages = ref.read(displayProvider).alwaysShowImages ||
      isSenderTrusted(ref.read(trustedSendersProvider), message.from.email);
  final html = body.html ?? '';
  final pictures = namesInlinePictures(html)
      ? ref.read(inlinePicturesProvider(message.id).future)
      : null;
  try {
    final shown = withInlinePictures(
      showImages ? html : stripRemoteContent(html),
      await _orNone(pictures),
    );
    final ok = await printer.print(
      title: message.subject.trim().isEmpty ? 'Message' : message.subject,
      html: printableMessage(
        message,
        body,
        bodyHtml: shown,
        remoteAllowed: showImages,
      ),
    );
    if (!ok) {
      messenger?.showSnackBar(
        const SnackBar(
          duration: kBottomMessage,
          content: Text('Printing is not available here.'),
        ),
      );
    }
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(
        duration: kBottomMessage,
        content: Text('Could not print. $e'),
      ),
    );
  }
}

/// The pictures, or none where they cannot be had: the message is still
/// worth printing without them, as it is still worth reading.
Future<Map<String, String>> _orNone(
  Future<Map<String, String>>? pictures,
) async {
  if (pictures == null) return const {};
  try {
    return await pictures;
  } catch (_) {
    return const {};
  }
}
