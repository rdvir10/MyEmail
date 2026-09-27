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
              suffixIcon: IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Close search',
                onPressed: () {
                  _controller.clear();
                  ref.read(searchOpenProvider.notifier).close();
                },
              ),
            ),
            onChanged: (value) =>
                ref.read(searchQueryProvider.notifier).set(value),
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
