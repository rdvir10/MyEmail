import '../common/bottom_message.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mail_attachment.dart';
import '../../state/attachment_providers.dart';
import 'attachment_save.dart';

/// The files on a message, under its header.
///
/// One chip each: name, size, and what is happening to it. A tap downloads
/// it if it is not here yet and hands it to whatever app opens that sort of
/// file. A long press picks it up, so it can be dragged into another app in
/// split screen. The menu has the rest — save, copy, share.
///
/// Above the chips, a line with how many there are and their size, which
/// folds them away and brings them back ([attachmentsFoldedProvider]).
/// Pictures the body is already showing get no chip at all; see
/// [attachmentsShownInBody].
class AttachmentBar extends ConsumerWidget {
  const AttachmentBar({super.key, required this.messageId});

  final String messageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final attachments = ref.watch(attachmentsProvider(messageId));

    return attachments.when(
      // Nothing while it loads: the message header must not jump about
      // because a list of file names arrived a moment late.
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          children: [
            Icon(Icons.attach_file,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Could not read what is attached.',
                style: theme.textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
      data: (all) {
        final inBody = attachmentsShownInBody(ref, messageId, all);
        final files = [
          for (final f in all)
            if (!inBody.contains(f.id)) f,
        ];
        if (files.isEmpty) return const SizedBox.shrink();
        final folded = ref.watch(attachmentsFoldedProvider);
        final bytes = files.fold<int>(0, (n, f) => n + f.sizeBytes);
        final count =
            '${files.length} ${files.length == 1 ? 'attachment' : 'attachments'}'
            '${bytes > 0 ? ' \u00b7 ${formatFileSize(bytes)}' : ''}';
        final muted = theme.colorScheme.onSurfaceVariant;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: folded ? 'Show attachments' : 'Hide attachments',
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () =>
                      ref.read(attachmentsFoldedProvider.notifier).toggle(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.attach_file, size: 16, color: muted),
                        const SizedBox(width: 4),
                        Text(
                          count,
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: muted),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          folded ? Icons.expand_more : Icons.expand_less,
                          size: 18,
                          color: muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (!folded)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final file in files)
                        _AttachmentChip(messageId: messageId, attachment: file),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _AttachmentChip extends ConsumerWidget {
  const _AttachmentChip({required this.messageId, required this.attachment});

  final String messageId;
  final MailAttachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final downloads = ref.watch(attachmentDownloadsProvider);
    final state = downloads[AttachmentDownloads.keyFor(messageId, attachment)];
    final actions = AttachmentActions(ref, messageId, attachment);

    return Tooltip(
      message: attachment.isInline
          ? '${attachment.name} · in the message'
          : attachment.name,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => actions.open(context),
          // A long press is the gesture Android uses to pick a thing up, and
          // in split screen it is how a file gets from here into the app
          // next door.
          onLongPress: () => actions.drag(context),
          onSecondaryTap: () => actions.menu(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state?.isWorking ?? false)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    state?.error != null
                        ? Icons.error_outline
                        : _iconFor(attachment.openAs),
                    size: 18,
                    color: state?.error != null
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 190),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        attachment.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        state?.error != null
                            ? 'Could not download'
                            : formatFileSize(attachment.sizeBytes),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: state?.error != null
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'More',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.more_vert, size: 18),
                  onPressed: () => actions.menu(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (mime.contains('zip') || mime.contains('compressed')) {
      return Icons.folder_zip_outlined;
    }
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }
}

/// Everything that can be done with one attachment, in one place, so the
/// chip, the menu and any keyboard shortcut all mean the same thing.
class AttachmentActions {
  AttachmentActions(this.ref, this.messageId, this.attachment);

  final WidgetRef ref;
  final String messageId;
  final MailAttachment attachment;

  Future<File?> _file(BuildContext context) async {
    final file = await ref
        .read(attachmentDownloadsProvider.notifier)
        .file(messageId, attachment);
    if (file == null && context.mounted) {
      final error = ref
          .read(attachmentDownloadsProvider)[
              AttachmentDownloads.keyFor(messageId, attachment)]
          ?.error;
      if (error != null) _say(context, 'Could not download the attachment.');
    }
    return file;
  }

  Future<void> open(BuildContext context) async {
    final file = await _file(context);
    if (file == null || !context.mounted) return;
    try {
      await ref
          .read(fileBridgeProvider)
          .open(file.path, mimeType: attachment.openAs);
    } catch (e) {
      if (context.mounted) _say(context, 'Nothing here opens that sort of file.');
    }
  }

  Future<void> drag(BuildContext context) async {
    final file = await _file(context);
    if (file == null || !context.mounted) return;
    await ref.read(fileBridgeProvider).startDrag(
          file.path,
          mimeType: attachment.openAs,
          name: attachment.name,
        );
  }

  Future<void> copy(BuildContext context) async {
    final file = await _file(context);
    if (file == null || !context.mounted) return;
    await ref.read(fileBridgeProvider).copyToClipboard(
          file.path,
          mimeType: attachment.openAs,
          name: attachment.name,
        );
    if (context.mounted) _say(context, 'Copied. Paste it wherever it goes.');
  }

  Future<void> share(BuildContext context) async {
    final file = await _file(context);
    if (file == null || !context.mounted) return;
    await ref
        .read(fileBridgeProvider)
        .share(file.path, mimeType: attachment.openAs);
  }

  Future<void> save(BuildContext context) async {
    final file = await _file(context);
    if (file == null || !context.mounted) return;
    bool saved;
    try {
      saved = await saveAttachmentAs(attachment, file);
    } catch (e) {
      // A full disk, a cloud folder that refuses the write, a copy that
      // could not be read: each used to end with nothing on screen at all,
      // not even "Not saved.", as if the tap had missed.
      if (context.mounted) _say(context, 'Could not save the attachment.');
      return;
    }
    if (!context.mounted) return;
    _say(context, saved ? 'Saved.' : 'Not saved.');
  }

  Future<void> menu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final position = (box == null || overlay == null)
        ? const RelativeRect.fromLTRB(40, 200, 40, 40)
        : RelativeRect.fromRect(
            Rect.fromPoints(
              box.localToGlobal(Offset.zero, ancestor: overlay),
              box.localToGlobal(box.size.bottomRight(Offset.zero),
                  ancestor: overlay),
            ),
            Offset.zero & overlay.size,
          );

    final choice = await showMenu<String>(
      context: context,
      position: position,
      items: const [
        PopupMenuItem(value: 'open', child: Text('Open')),
        PopupMenuItem(value: 'save', child: Text('Save as…')),
        PopupMenuItem(value: 'copy', child: Text('Copy')),
        PopupMenuItem(value: 'share', child: Text('Share…')),
      ],
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'open':
        await open(context);
      case 'save':
        await save(context);
      case 'copy':
        await copy(context);
      case 'share':
        await share(context);
    }
  }

  void _say(BuildContext context, String message) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(duration: kBottomMessage, content: Text(message)));
}
