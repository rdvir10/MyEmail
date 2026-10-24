import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/message_filter.dart';
import '../../state/list_filter.dart';

/// Outlook's All and Unread over the list, and its Filter menu beside them
/// for flagged mail, mail with files, and mail sent to you directly.
///
/// A filter narrows the list on the device at once and asks the server for
/// the rest (see `filterHitsProvider`); the small spinner at the end says
/// the server has not answered yet.
class ListFilterBar extends ConsumerWidget {
  const ListFilterBar({super.key, required this.listId});

  final String listId;

  static const _inMenu = [
    MessageFilter.flagged,
    MessageFilter.attachments,
    MessageFilter.toMe,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(listFilterProvider(listId));
    final filters = ref.read(listFiltersProvider.notifier);
    final fromMenu = _inMenu.contains(filter);
    final asking = filter != MessageFilter.all &&
        ref.watch(filterHitsProvider((listId, filter))).isLoading;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          // Scrolls sideways where the list is narrow and the text large,
          // rather than running off the edge.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FilterChoice(
                    label: MessageFilter.all.label,
                    selected: filter == MessageFilter.all,
                    onTap: () => filters.set(listId, MessageFilter.all),
                  ),
                  _FilterChoice(
                    label: MessageFilter.unread.label,
                    selected: filter == MessageFilter.unread,
                    onTap: () => filters.set(listId, MessageFilter.unread),
                  ),
                  PopupMenuButton<MessageFilter>(
                    tooltip: 'Filter',
                    onSelected: (chosen) => filters.set(
                      listId,
                      // The one on already, chosen again, comes off.
                      chosen == filter ? MessageFilter.all : chosen,
                    ),
                    itemBuilder: (_) => [
                      for (final f in _inMenu)
                        CheckedPopupMenuItem<MessageFilter>(
                          value: f,
                          checked: f == filter,
                          child: Text(f.label),
                        ),
                    ],
                    child: _FilterChoice(
                      label: fromMenu ? filter.label : 'Filter',
                      selected: fromMenu,
                      menu: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (asking)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }
}

/// One choice on the bar: a word, underlined in the accent colour when it
/// is the one showing, as Outlook draws All and Unread.
class _FilterChoice extends StatelessWidget {
  const _FilterChoice({
    required this.label,
    required this.selected,
    this.onTap,
    this.menu = false,
  });

  final String label;
  final bool selected;

  /// Null inside the Filter menu's button, which takes the tap itself.
  final VoidCallback? onTap;

  /// Opens a menu, which a small arrow after the word says.
  final bool menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = selected ? scheme.primary : scheme.onSurfaceVariant;
    final look = Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 5),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: colour,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          if (menu) Icon(Icons.arrow_drop_down, size: 18, color: colour),
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: onTap == null ? look : InkWell(onTap: onTap, child: look),
    );
  }
}
