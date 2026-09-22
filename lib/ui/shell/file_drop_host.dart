import '../common/bottom_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/files/file_bridge.dart';
import '../../state/attachment_providers.dart';
import '../../state/drop_providers.dart';
import '../../state/message_providers.dart';
import '../../state/message_transfer.dart';
import '../../state/providers.dart';
import '../folder_tree/folder_tile.dart';
import '../compose/open_compose.dart';
import '../../domain/draft.dart';

/// Catches files dragged into the app from another one.
///
/// In split screen this is how a file gets from Files, Drive or another mail
/// app into a message here. Android hands the drop to the window rather than
/// to any particular part of the interface, so what it means has to be
/// decided here: a message being written takes it as an attachment, and with
/// nothing open a new message is started holding it.
///
/// Wrapped around the app rather than around the compose screen, because a
/// drop can land while the compose screen is not the thing under the finger.
class FileDropHost extends ConsumerStatefulWidget {
  const FileDropHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<FileDropHost> createState() => _FileDropHostState();
}

class _FileDropHostState extends ConsumerState<FileDropHost> {
  @override
  void initState() {
    super.initState();
    final bridge = ref.read(fileBridgeProvider)
      ..onDropped(_dropped)
      ..onShared(_shared);
    // Opened from a share sheet: what was shared is waiting to be asked
    // for. After the first frame, so the compose screen has a navigator
    // under it to be pushed onto.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final content = await bridge.takeShare();
      if (content != null && mounted) await _shared(content);
    });
  }

  /// Something shared from another app is a new message holding it: files
  /// as attachments, text as the body, a subject if one came along.
  Future<void> _shared(SharedContent content) async {
    if (!mounted) return;
    final attachments = await readIncoming(content.files);
    if (!mounted) return;
    if (attachments.isEmpty && content.text == null) return;
    // Opened from a share sheet, the app is still loading its accounts when
    // this runs, and a new message needs one to be sent from. Waiting here
    // is the difference between the message opening and "Add an account
    // first" on an app that has three.
    try {
      await ref.read(accountsProvider.future);
    } catch (_) {
      // openCompose says what is wrong with the accounts.
    }
    if (!mounted) return;
    await openCompose(
      context,
      ref,
      kind: ComposeKind.newMessage,
      attachments: attachments,
      subject: content.subject,
      bodyText: content.text,
    );
  }

  Future<void> _dropped(DroppedFiles dropped) async {
    if (!mounted) return;
    if (dropped.label == messageDragLabel) {
      await _ownMessages(dropped);
      return;
    }
    final files = dropped.files;
    if (files.isEmpty) return;
    final claimed = ref.read(dropTargetProvider).current;
    debugPrint(
      '[myemail] dropped ${files.length} file(s), '
      '${claimed == null ? 'no message open, starting one' : 'into the open message'}',
    );
    if (claimed != null) {
      claimed(files);
      return;
    }

    final attachments = await readIncoming(files);
    if (!mounted || attachments.isEmpty) return;
    await openCompose(
      context,
      ref,
      kind: ComposeKind.newMessage,
      attachments: attachments,
    );
  }

  /// Messages dragged out of this app — this window or another copy of
  /// it — and dropped back on it. On a folder they are moved there. Into
  /// a message being written they are attached, as any file would be.
  /// Anywhere else they are left alone: a file from outside starts a new
  /// message, but a message of our own dropped on the list is far more
  /// likely a slip than a request to forward it.
  Future<void> _ownMessages(DroppedFiles dropped) async {
    final ids = [
      for (final id in (dropped.text ?? '').split('\n'))
        if (id.trim().isNotEmpty) id.trim(),
    ];
    final folderId = folderUnder(
      dropped.at / MediaQuery.devicePixelRatioOf(context),
    );
    if (folderId != null && ids.isNotEmpty) {
      await _move(ids, folderId);
      return;
    }
    final claimed = ref.read(dropTargetProvider).current;
    if (claimed != null && dropped.files.isNotEmpty) claimed(dropped.files);
  }

  Future<void> _move(List<String> ids, String folderId) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final name = ref.read(folderIndexProvider)[folderId]?.displayName ?? '';
    try {
      // Through the engine rather than a list: the messages may be another
      // window's, and not in any list here. Every list is re-read after.
      await ref.read(mailEngineProvider).moveMessages(ids, folderId);
      ref.invalidate(messagesProvider);
      for (final account in ref.read(accountsProvider).value ?? const []) {
        await ref.read(foldersProvider.notifier).refreshAccount(account.id);
      }
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(duration: kBottomMessage, 
          content: Text(
            '${ids.length == 1 ? 'Message' : '${ids.length} messages'} moved to $name',
          ),
        ));
    } catch (e) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(duration: kBottomMessage, content: Text('Could not move: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The folder whose row is under [point] (logical pixels), anywhere on
/// screen, or null. Found by looking, the way a finger does, rather than
/// by any registry of rows.
String? folderUnder(Offset point) {
  String? found;
  void visit(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is FolderTile) {
      final box = e.renderObject;
      if (box is RenderBox && box.hasSize && box.attached) {
        final rect = box.localToGlobal(Offset.zero) & box.size;
        if (rect.contains(point)) found = w.row.folder.id;
      }
      return;
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}
