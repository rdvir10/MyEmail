import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/widget/widget_setup_channel.dart';
import '../../data/widget/widget_state_store.dart';
import '../../domain/mail_folder.dart';
import '../../state/folder_tree.dart' show kUnifiedInboxId;
import '../../state/providers.dart';
import '../../state/widget_providers.dart';
import '../widgets/mailbox_widget_setup.dart';

/// The home-screen widgets that are actually on the home screen.
///
/// Worth a screen of its own because of how little Android offers: some
/// launchers can reopen a widget's setup screen by long-pressing it, and
/// some cannot, so without this the only way to point a widget at a
/// different folder is to drag it off and place a new one — losing its spot
/// on the home screen to change a single setting.
///
/// The list comes from Android rather than from what the app wrote down. A
/// widget dragged to the bin tells the app nothing, so what the app
/// remembers is always a superset of what is really there.
class HomeWidgetsScreen extends ConsumerStatefulWidget {
  const HomeWidgetsScreen({super.key});

  @override
  ConsumerState<HomeWidgetsScreen> createState() => _HomeWidgetsScreenState();
}

class _HomeWidgetsScreenState extends ConsumerState<HomeWidgetsScreen> {
  late Future<Map<String, WidgetMailbox>> _placed = _load();

  Future<Map<String, WidgetMailbox>> _load() async {
    final live = await placedWidgetIds();
    final known = await ref.read(widgetStateStoreProvider).readMailboxes();
    // No answer means Android was not asked — a test, the browser preview,
    // an older build of the Android half. Better to show what is remembered
    // than to claim there is nothing. An empty answer is no widgets.
    if (live == null) return known;
    return {
      for (final id in live)
        if (known[id] != null) id: known[id]!,
    };
  }

  void _reload() => setState(() => _placed = _load());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folders = ref.watch(folderIndexProvider);
    final accounts = ref.watch(accountsProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Home screen widgets')),
      body: FutureBuilder<Map<String, WidgetMailbox>>(
        future: _placed,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final placed = snapshot.data!;
          if (placed.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No widgets yet.\n\nLong-press an empty part of the home '
                  'screen, choose Widgets, and drag out MyEmail.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            );
          }

          final ids = placed.keys.toList()..sort();
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Tap one to change what it shows. Removing a widget is '
                  'done on the home screen, by dragging it off.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              for (final id in ids)
                ListTile(
                  leading: const Icon(Icons.widgets_outlined),
                  title: Text(
                    placed[id]!.label ??
                        _describe(placed[id]!.folderId, folders, accounts),
                  ),
                  subtitle: Text(
                    [
                      if (placed[id]!.label != null)
                        _describe(placed[id]!.folderId, folders, accounts),
                      placed[id]!.counts.label,
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MailboxWidgetSetup(
                          appWidgetId: id,
                          existing: placed[id],
                          // Not Android's placement dance: this widget is
                          // already placed, so finishing just comes back.
                          onDone: () => Navigator.of(context)
                              .popUntil((r) => r.isFirst || r.settings.name == null
                                  ? true
                                  : true),
                        ),
                      ),
                    );
                    if (mounted) _reload();
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  /// What a widget is pointed at, in words, whether or not the folder is
  /// still there.
  static String _describe(
    String folderId,
    Map<String, MailFolder> folders,
    List<dynamic> accounts,
  ) {
    if (folderId == kUnifiedInboxId) return 'All inboxes';
    final folder = folders[folderId];
    if (folder == null) return 'A folder that is no longer here';
    final accountId = folderId.split(':').first;
    for (final account in accounts) {
      if (account.id == accountId) {
        return '${folder.displayName} · ${account.displayName}';
      }
    }
    return folder.displayName;
  }
}
