import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/mail_engine.dart' show SearchField;
import '../../state/providers.dart';
import '../../state/search_providers.dart';

/// The message search box above the list, with a chooser underneath once
/// there is something to search for: which part of a message to look in,
/// and, in a real folder, how far to look. On screen only when asked for;
/// see [searchShownProvider].
class MessageSearchBar extends ConsumerStatefulWidget {
  const MessageSearchBar({super.key});

  @override
  ConsumerState<MessageSearchBar> createState() => _MessageSearchBarState();
}

class _MessageSearchBarState extends ConsumerState<MessageSearchBar> {
  // Starts from the search there is, not empty. The selection bar takes
  // this bar's place while messages are ticked, so it comes back new after
  // every selection: empty, over a list still showing the old search's
  // hits, and typing started a new search instead of editing that one.
  late final _controller =
      TextEditingController(text: ref.read(searchQueryProvider));
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Put out empty by the magnifier, the ribbon or Ctrl+F, it takes the
    // keyboard at once: there is nothing else to do with an empty box. Back
    // with a search in it, after a selection, it waits to be touched.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.text.isEmpty) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The search as it stands, kept under a name asked for.
  Future<void> _save(String query) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: query.trim()),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    ref
        .read(savedSearchesProvider.notifier)
        .add(currentSearchAs(ref, name.trim()));
    ref.read(recentSearchesProvider.notifier).remember(query);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Saved: ${name.trim()}'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    // The ribbon's Search button has no field of its own; it asks this one to
    // take focus. Listened to in build rather than initState because the
    // request can arrive at any time the pane is on screen.
    ref.listen(searchFocusRequestsProvider, (_, _) => _focus.requestFocus());
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
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: canScopeToFolder
                  ? 'Search ${folder.displayName}'
                  : 'Search mail',
              prefixIcon: const Icon(Icons.search, size: 18),
              // Puts the box away, the search with it. The box only came
              // out because it was asked for, so there is always a way back.
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Kept to run again, under the tree's Saved searches:
                  // Outlook's New Search Folder.
                  if (query.trim().isNotEmpty)
                    IconButton(
                      key: const ValueKey('search-save'),
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      tooltip: 'Save this search',
                      onPressed: () => _save(query),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Close search',
                    onPressed: () {
                      _controller.clear();
                      ref.read(searchOpenProvider.notifier).close();
                    },
                  ),
                ],
              ),
            ),
            onChanged: (value) =>
                ref.read(searchQueryProvider.notifier).set(value),
            onSubmitted: (value) =>
                ref.read(recentSearchesProvider.notifier).remember(value),
          ),
        ),
        // The last searches, while the box is empty, as Outlook offers them.
        if (query.trim().isEmpty && ref.watch(recentSearchesProvider).isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                key: const ValueKey('search-recent'),
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final recent in ref.watch(recentSearchesProvider))
                    ActionChip(
                      avatar: const Icon(Icons.history, size: 16),
                      label: Text(recent),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        _controller.text = recent;
                        ref.read(searchQueryProvider.notifier).set(recent);
                      },
                    ),
                  TextButton(
                    onPressed: () =>
                        ref.read(recentSearchesProvider.notifier).forgetAll(),
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
          ),
        // Where in the message: everything, or the sender, the subject, the
        // body or a file's name alone. Chips that wrap, not segments: five
        // segments spread to the widest label's width each, and on a phone
        // that is wider than the box.
        if (query.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                key: const ValueKey('search-field'),
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final field in SearchField.values)
                    ChoiceChip(
                      key: ValueKey('search-field-${field.name}'),
                      label: Text(field.label),
                      visualDensity: VisualDensity.compact,
                      selected: ref.watch(searchFieldProvider) == field,
                      onSelected: (_) =>
                          ref.read(searchFieldProvider.notifier).set(field),
                    ),
                ],
              ),
            ),
          ),
        // What the hits must also be: Outlook's search filters. Applied to
        // what the server found, so a tap asks nothing again.
        if (query.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                key: const ValueKey('search-refine'),
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final r in SearchRefinement.values)
                    FilterChip(
                      key: ValueKey('search-refine-${r.name}'),
                      label: Text(r.label),
                      visualDensity: VisualDensity.compact,
                      showCheckmark: false,
                      selected: ref.watch(searchRefinementsProvider).contains(r),
                      onSelected: (_) =>
                          ref.read(searchRefinementsProvider.notifier).toggle(r),
                    ),
                ],
              ),
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

/// A name for a saved search, or a new one for one kept already.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Saved search'),
        content: TextField(
          key: const ValueKey('search-folder-name'),
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('search-folder-save'),
            onPressed: () => Navigator.of(context).pop(_name.text),
            child: const Text('Save'),
          ),
        ],
      );
}

/// A name asked for a saved search, starting from [initial].
Future<String?> askSearchFolderName(BuildContext context, String initial) =>
    showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: initial),
    );
