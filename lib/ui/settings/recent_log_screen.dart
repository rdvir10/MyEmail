import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/recent_log.dart';
import '../../state/attachment_providers.dart';
import '../common/bottom_message.dart';

/// What the app has noted lately, newest first, with a way to copy it or
/// share it: for the phone that is somewhere else when something needs
/// looking at, whose log a computer cannot reach.
class RecentLogScreen extends ConsumerWidget {
  const RecentLogScreen({super.key, this.log});

  /// Handed in by tests; the app's own otherwise.
  final RecentLog? log;

  RecentLog get _shown => log ?? RecentLog.instance;

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _shown.text));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        duration: kBottomMessage,
        content: Text('Copied'),
      ));
  }

  /// As a text file through the share sheet, which reaches mail, a chat or
  /// a note in one step and keeps every line.
  Future<void> _share(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/myemail-log.txt');
      await file.writeAsString(_shown.text);
      await ref.read(fileBridgeProvider).share(file.path, mimeType: 'text/plain');
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: kBottomMessage,
          content: Text('Could not share the log: $e'),
        ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final lines = _shown.lines.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recent log'),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_outlined),
            onPressed: lines.isEmpty ? null : () => _copy(context),
          ),
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: lines.isEmpty ? null : () => _share(context, ref),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: lines.isEmpty
          ? Center(
              child: Text(
                'Nothing noted yet.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: lines.length,
              itemBuilder: (context, i) => SelectableText(
                lines[i],
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
    );
  }
}
