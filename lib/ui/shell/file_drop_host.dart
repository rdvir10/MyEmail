import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/files/file_bridge.dart';
import '../../state/attachment_providers.dart';
import '../../state/drop_providers.dart';
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
    ref.read(fileBridgeProvider).onDropped(_dropped);
  }

  Future<void> _dropped(List<IncomingFile> files) async {
    if (!mounted || files.isEmpty) return;
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

  @override
  Widget build(BuildContext context) => widget.child;
}
