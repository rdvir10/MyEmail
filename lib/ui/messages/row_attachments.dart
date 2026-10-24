import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/file_types.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import '../../state/providers.dart';
import '../common/bottom_message.dart';
import 'attachment_bar.dart';

/// One file named on a row: what it is called, and the message it is on.
/// A conversation's row gathers them from every message in it.
typedef RowFile = ({String messageId, String name});

/// The files [message] names for its row: see [MailMessage.attachmentNames].
/// An invitation's own calendar file is left out; the row's meeting mark
/// and the card in the message are what stand for it.
List<RowFile> rowFilesOf(MailMessage message) => [
      for (final name in message.attachmentNames)
        if (!(message.isMeeting && _isCalendarName(name)))
          (messageId: message.id, name: name),
    ];

/// The files a conversation's row names: its messages', newest first, each
/// name once.
List<RowFile> rowFilesOfAll(Iterable<MailMessage> messages) {
  final newestFirst = [...messages]..sort((a, b) => b.date.compareTo(a.date));
  final seen = <String>{};
  return [
    for (final m in newestFirst)
      for (final file in rowFilesOf(m))
        if (seen.add(file.name.toLowerCase())) file,
  ];
}

bool _isCalendarName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.ics') || lower.endsWith('.vcs');
}

/// The file on [listed] that the row's chip for [name] stands for: the
/// [occurrence]th of that name among the files, the ones the body shows
/// left out as the row leaves them out. Null if none goes by it now.
MailAttachment? fileForRow(
  List<MailAttachment> listed,
  String name,
  int occurrence,
) {
  final named = [
    for (final a in listed)
      if (!a.isInline && a.name == name) a,
  ];
  if (named.isEmpty) return null;
  return occurrence < named.length ? named[occurrence] : named.first;
}

/// A row's files under the message, as new Outlook shows them: the first
/// [shown], each a chip with its name, then how many more. A tap opens
/// that file in its usual app without opening the message.
class RowAttachments extends StatelessWidget {
  const RowAttachments({super.key, required this.files});

  final List<RowFile> files;

  /// Chips before the count: three fit a phone's row with room to read
  /// each, and a row is a line of the list, not the message's own list.
  static const shown = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = files.take(shown).toList();
    final more = files.length - first.length;
    // Same-named files are told apart by which of them each chip is.
    final counts = <String, int>{};
    return Row(
      children: [
        for (final (i, file) in first.indexed) ...[
          if (i > 0) const SizedBox(width: 6),
          Flexible(
            child: _RowFileChip(
              file: file,
              occurrence: counts.update(
                    '${file.messageId}\u0000${file.name}',
                    (n) => n + 1,
                    ifAbsent: () => 1,
                  ) -
                  1,
            ),
          ),
        ],
        if (more > 0) ...[
          const SizedBox(width: 6),
          Text(
            '+$more',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _RowFileChip extends ConsumerStatefulWidget {
  const _RowFileChip({required this.file, required this.occurrence});

  final RowFile file;
  final int occurrence;

  @override
  ConsumerState<_RowFileChip> createState() => _RowFileChipState();
}

class _RowFileChipState extends ConsumerState<_RowFileChip> {
  bool _busy = false;

  /// The message's own list of files, asked for now, then the file the
  /// chip names opened as its chip in the message would open it. Asked of
  /// the engine directly: the list has no message open to hold the
  /// listing for.
  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    void say(String text) => messenger?.showSnackBar(
          SnackBar(duration: kBottomMessage, content: Text(text)),
        );
    try {
      final listed = await ref
          .read(mailEngineProvider)
          .listAttachments(widget.file.messageId);
      final file = fileForRow(listed, widget.file.name, widget.occurrence);
      if (!mounted) return;
      if (file == null) {
        say('${widget.file.name} is no longer on the message.');
        return;
      }
      await AttachmentActions(ref, widget.file.messageId, file).open(context);
    } catch (e) {
      say('Could not open ${widget.file.name}.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = widget.file.name;
    return Tooltip(
      message: name,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: ValueKey('row-file:${widget.file.messageId}:$name'),
          borderRadius: BorderRadius.circular(6),
          onTap: _open,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 26, maxWidth: 170),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_busy)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  else
                    Icon(
                      attachmentIcon(mimeTypeForFile(name)),
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
