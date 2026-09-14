import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../state/search_providers.dart';

/// The message search box above the list, with a scope chooser underneath
/// once there is something to search for.
class MessageSearchBar extends ConsumerStatefulWidget {
  const MessageSearchBar({super.key});

  @override
  ConsumerState<MessageSearchBar> createState() => _MessageSearchBarState();
}

class _MessageSearchBarState extends ConsumerState<MessageSearchBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final folderId = ref.watch(effectiveSelectedFolderIdProvider);
    final folder =
        folderId == null ? null : ref.watch(folderIndexProvider)[folderId];
    // "This folder" has no meaning in the unified Inbox, which is not one.
    final canScopeToFolder = folder != null && !folder.isSynthetic;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: canScopeToFolder
                  ? 'Search ${folder.displayName}'
                  : 'Search mail',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Clear',
                      onPressed: () {
                        _controller.clear();
                        ref.read(searchQueryProvider.notifier).clear();
                      },
                    ),
            ),
            onChanged: (value) =>
                ref.read(searchQueryProvider.notifier).set(value),
          ),
        ),
        if (query.trim().isNotEmpty && canScopeToFolder)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<SearchScopeChoice>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                segments: [
                  ButtonSegment(
                    value: SearchScopeChoice.folder,
                    label: Text(folder.displayName),
                  ),
                  const ButtonSegment(
                    value: SearchScopeChoice.account,
                    label: Text('Account'),
                  ),
                  const ButtonSegment(
                    value: SearchScopeChoice.everywhere,
                    label: Text('All mail'),
                  ),
                ],
                selected: {ref.watch(searchScopeChoiceProvider)},
                onSelectionChanged: (s) => ref
                    .read(searchScopeChoiceProvider.notifier)
                    .set(s.first),
              ),
            ),
          ),
      ],
    );
  }
}
