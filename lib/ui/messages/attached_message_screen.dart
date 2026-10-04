import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/files/attached_message.dart';
import '../../data/files/message_files.dart' show emlMimeType;
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import '../../state/attachment_providers.dart';
import '../../state/display_providers.dart';
import '../common/bottom_message.dart';
import 'attachment_bar.dart' show attachmentIcon, showDefaultApp;
import 'attachment_save.dart';
import 'date_format.dart';
import 'html_body_view.dart';

/// Open [bytes], an email attached to another, as an email. False when it
/// is not one after all, and the caller hands it to another app instead.
///
/// [key] names where it came from, so the files inside it are kept apart
/// from every other message's.
Future<bool> openAttachedMessage(
  BuildContext context,
  Uint8List bytes, {
  required String key,
}) async {
  final message = AttachedMessage.parse(bytes);
  if (message == null || !context.mounted) return false;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AttachedMessageScreen(message: message, storeKey: key),
    ),
  );
  return true;
}

/// An email that came attached to another: who it is from and to, what is
/// attached to it, and the message itself, as Outlook opens one.
///
/// Read only. Nothing here is in a mailbox, so there is nothing to reply
/// from, move or flag; a file in it opens, saves and shares as any other.
class AttachedMessageScreen extends ConsumerWidget {
  const AttachedMessageScreen({
    super.key,
    required this.message,
    required this.storeKey,
  });

  final AttachedMessage message;

  /// Where its files are written; see [openAttachedMessage].
  final String storeKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = message;
    final files = m.listed;
    final html = m.body.html;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(m.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
        centerTitle: false,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: scheme.primaryContainer,
                      foregroundColor: scheme.onPrimaryContainer,
                      child: Text(_initial(m.from)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          OverflowBar(
                            spacing: 12,
                            alignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                m.from.display,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (m.date != null)
                                Text(
                                  formatMessageDateLong(
                                    m.date!,
                                    use24h: MediaQuery.alwaysUse24HourFormatOf(
                                      context,
                                    ),
                                  ),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                          if (m.from.name != null && m.from.email.isNotEmpty)
                            Text(m.from.email, style: muted),
                          if (m.to.isNotEmpty)
                            Text('To: ${_names(m.to)}', style: muted),
                          if (m.cc.isNotEmpty)
                            Text('Cc: ${_names(m.cc)}', style: muted),
                        ],
                      ),
                    ),
                  ],
                ),
                if (files.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final f in files)
                        _FileChip(file: f, actions: _FileActions(ref, this, f)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: html != null && html.trim().isNotEmpty && !kIsWeb
                ? HtmlBodyView(
                    html: html,
                    inlinePictures: m.inlinePictures,
                    showImages: ref.watch(displayProvider).alwaysShowImages,
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                    child: SelectableText(m.body.text),
                  ),
          ),
        ],
      ),
    );
  }

  static String _initial(MailAddress a) {
    final d = a.display.trim();
    return d.isEmpty ? '?' : d.characters.first.toUpperCase();
  }

  static String _names(List<MailAddress> list) =>
      list.map((a) => a.display).join(', ');
}

/// Open, save or share one file from inside the attached message.
class _FileActions {
  _FileActions(this.ref, this.screen, this.file);

  final WidgetRef ref;
  final AttachedMessageScreen screen;
  final MailAttachment file;

  /// On disk, where the other apps can be handed it.
  Future<File?> _onDisk(BuildContext context) async {
    final bytes = screen.message.bytesOf(file);
    if (bytes == null) {
      if (context.mounted) _say(context, 'Could not read the attachment.');
      return null;
    }
    return ref
        .read(attachmentFilesProvider)
        .write(screen.storeKey, file, bytes);
  }

  Future<void> open(BuildContext context) async {
    // An email in this one opens the same way, one inside the other.
    final bytes = screen.message.bytesOf(file);
    if (file.openAs == emlMimeType &&
        bytes != null &&
        await openAttachedMessage(
          context,
          bytes,
          key: '${screen.storeKey}/${file.id}',
        )) {
      return;
    }
    if (!context.mounted) return;
    final onDisk = await _onDisk(context);
    if (onDisk == null || !context.mounted) return;
    try {
      await ref
          .read(fileBridgeProvider)
          .open(onDisk.path, mimeType: file.openAs);
    } catch (_) {
      if (context.mounted) {
        _say(context, 'Nothing here opens that sort of file.');
      }
    }
  }

  Future<void> save(BuildContext context) async {
    final onDisk = await _onDisk(context);
    if (onDisk == null || !context.mounted) return;
    try {
      final saved = await saveAttachmentAs(file, onDisk);
      if (context.mounted) _say(context, saved ? 'Saved.' : 'Not saved.');
    } catch (_) {
      if (context.mounted) _say(context, 'Could not save the attachment.');
    }
  }

  Future<void> share(BuildContext context) async {
    final onDisk = await _onDisk(context);
    if (onDisk == null || !context.mounted) return;
    await ref
        .read(fileBridgeProvider)
        .share(onDisk.path, mimeType: file.openAs);
  }

  Future<void> openWith(BuildContext context) async {
    final onDisk = await _onDisk(context);
    if (onDisk == null || !context.mounted) return;
    try {
      await ref
          .read(fileBridgeProvider)
          .openWith(onDisk.path, mimeType: file.openAs);
    } catch (_) {
      if (context.mounted) {
        _say(context, 'Nothing here opens that sort of file.');
      }
    }
  }

  Future<void> defaultApp(BuildContext context) =>
      showDefaultApp(context, ref, file, onOpen: () => open(context));

  void _say(BuildContext context, String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text(text)));
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.file, required this.actions});

  final MailAttachment file;
  final _FileActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => actions.open(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                attachmentIcon(file.openAs),
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      formatFileSize(file.sizeBytes),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (choice) => switch (choice) {
                  'openWith' => actions.openWith(context),
                  'save' => actions.save(context),
                  'share' => actions.share(context),
                  'default' => actions.defaultApp(context),
                  _ => actions.open(context),
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'open', child: Text('Open')),
                  PopupMenuItem(value: 'openWith', child: Text('Open with…')),
                  PopupMenuItem(value: 'save', child: Text('Save as…')),
                  PopupMenuItem(value: 'share', child: Text('Share…')),
                  PopupMenuItem(value: 'default', child: Text('Default app…')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
