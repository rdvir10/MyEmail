import 'package:flutter/material.dart';

import '../../domain/folder_role.dart';
import '../../state/folder_tree.dart';
import '../../theme/app_theme.dart';

/// One folder line: twisty, icon, name, count.
///
/// Indentation is applied to the leading area rather than the whole tile, so
/// that the row's tap target still spans the full width at any depth. Deeply
/// nested folders are otherwise annoying to hit on a phone.
///
/// The row has a minimum height rather than a fixed one, so a two-line variant
/// (name plus path in search results) still fits under large accessibility
/// text scaling instead of clipping.
class FolderTile extends StatelessWidget {
  const FolderTile({
    super.key,
    required this.row,
    required this.isSelected,
    required this.onTap,
    required this.onToggleExpand,
    this.onLongPress,
  });

  final FolderRow row;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onToggleExpand;
  final VoidCallback? onLongPress;

  static const double _indentPerLevel = 16;
  static const double _twistyWidth = 28;
  static const double _minHeight = 36;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final folder = row.folder;
    final count = folder.badgeCount;
    final hasUnread =
        !folder.showsTotalInsteadOfUnread && folder.unreadCount > 0;
    final accent =
        row.accentColor == null ? scheme.primary : Color(row.accentColor!);

    return Semantics(
      selected: isSelected,
      expanded: row.hasChildren ? row.isExpanded : null,
      child: Material(
        color: isSelected
            ? scheme.secondaryContainer.withValues(alpha: 0.7)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          // Right-click opens the same menu, for the browser preview and any
          // tablet with a mouse or trackpad attached.
          onSecondaryTap: onLongPress,
          child: Padding(
            padding: EdgeInsets.only(
              left: 4 + row.depth * _indentPerLevel,
              top: row.subtitle == null ? 0 : 4,
              bottom: row.subtitle == null ? 0 : 4,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _minHeight),
              child: Row(
                children: [
                  SizedBox(
                    width: _twistyWidth,
                    child: row.hasChildren
                        ? IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: _twistyWidth,
                              height: 32,
                            ),
                            iconSize: 18,
                            icon: AnimatedRotation(
                              turns: row.isExpanded ? 0.25 : 0,
                              duration: const Duration(milliseconds: 120),
                              child: const Icon(Icons.chevron_right),
                            ),
                            tooltip: row.isExpanded ? 'Collapse' : 'Expand',
                            onPressed: onToggleExpand,
                          )
                        : null,
                  ),
                  Icon(
                    _iconFor(row),
                    size: 18,
                    color: folder.role == FolderRole.user
                        ? scheme.onSurfaceVariant
                        : accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _label(theme, hasUnread)),
                  if (count > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      _formatCount(count),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: hasUnread
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        fontWeight:
                            hasUnread ? FontWeight.w700 : FontWeight.w400,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(ThemeData theme, bool hasUnread) {
    final name = Text(
      row.folder.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w400,
      ),
    );

    final subtitle = row.subtitle;
    if (subtitle == null) return name;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        name,
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  static IconData _iconFor(FolderRow row) => switch (row.folder.role) {
        FolderRole.inbox => FolderIcons.inbox,
        FolderRole.drafts => FolderIcons.drafts,
        FolderRole.sent => FolderIcons.sent,
        FolderRole.deleted => FolderIcons.deleted,
        FolderRole.junk => FolderIcons.junk,
        FolderRole.archive => FolderIcons.archive,
        FolderRole.outbox => FolderIcons.outbox,
        FolderRole.unifiedInbox => FolderIcons.unified,
        FolderRole.user => row.isExpanded && row.hasChildren
            ? FolderIcons.folderOpen
            : FolderIcons.folder,
      };

  /// Outlook caps the badge rather than letting a five-digit count push the
  /// folder name out of the row.
  static String _formatCount(int count) =>
      count > 999 ? '999+' : count.toString();
}
