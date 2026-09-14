import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/folder_role.dart';
import '../../state/folder_drag.dart';
import '../../state/folder_tree.dart';
import '../../theme/app_theme.dart';

/// One folder line: twisty, icon, name, count. Also the drag source and drop
/// target for folder-onto-folder drag and drop.
///
/// Gestures on a row:
///  * tap selects;
///  * hold lifts the folder; drop it on another row to nest or reorder, drop
///    it on an account header to move it to the top level, or let go without
///    moving to open the menu instead;
///  * right-click opens the menu directly (browser preview, tablets with a
///    mouse).
///
/// Indentation is applied to the leading area rather than the whole tile, so
/// that the row's tap target still spans the full width at any depth. The row
/// has a minimum height rather than a fixed one, so a two-line variant still
/// fits under large accessibility text scaling instead of clipping.
class FolderTile extends StatefulWidget {
  const FolderTile({
    super.key,
    required this.row,
    required this.isSelected,
    required this.onTap,
    required this.onToggleExpand,
    this.onLongPress,
    this.onAutoExpand,
    this.onDrop,
    this.onDropMessages,
  });

  final FolderRow row;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onToggleExpand;

  /// Opens the folder menu.
  final VoidCallback? onLongPress;

  /// Called when a drag has hovered over this collapsed folder long enough
  /// that the user probably wants to see inside it.
  final VoidCallback? onAutoExpand;

  /// Called with a folder that was dropped here and where on the row it
  /// landed. Null disables receiving drops.
  final void Function(DraggedFolder dragged, DropZone zone)? onDrop;

  /// Called with messages dropped onto this folder. Null disables it.
  final void Function(DraggedMessages dragged)? onDropMessages;

  static const double indentPerLevel = 16;
  static const double twistyWidth = 28;
  static const double minHeight = 36;
  static const Duration autoExpandDelay = Duration(milliseconds: 600);

  @override
  State<FolderTile> createState() => _FolderTileState();
}

class _FolderTileState extends State<FolderTile> {
  DropZone? _hoverZone;
  Timer? _expandTimer;
  Offset? _pressedAt;
  bool _movedDuringPress = false;

  static const double _menuSlop = 12;

  bool get _canDrag =>
      widget.row.folder.capabilities.canMove && !widget.row.inFavorites;

  bool get _canReceive => widget.onDrop != null && !widget.row.inFavorites;

  @override
  void dispose() {
    _expandTimer?.cancel();
    super.dispose();
  }

  // --- drop target -----------------------------------------------------------

  DropZone? _zoneAt(DragTargetDetails<DraggedFolder> details) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(details.offset);
    final fraction = (local.dy / box.size.height).clamp(0.0, 1.0);
    return resolveDropZone(
      dragged: details.data.folder,
      target: widget.row.folder,
      fraction: fraction,
      flat: widget.row.flat,
    );
  }

  /// Accept the candidate if *any* zone on this row would take it; the exact
  /// zone is decided as the pointer moves. Deciding on entry alone would lock
  /// out, say, "before" on a row entered through its "into" band.
  bool _couldAccept(DragTargetDetails<DraggedFolder> details) {
    for (final fraction in const [0.1, 0.5, 0.9]) {
      final zone = resolveDropZone(
        dragged: details.data.folder,
        target: widget.row.folder,
        fraction: fraction,
        flat: widget.row.flat,
      );
      if (zone != null) return true;
    }
    return false;
  }

  void _onMove(DragTargetDetails<DraggedFolder> details) {
    final zone = _zoneAt(details);
    if (zone != _hoverZone) setState(() => _hoverZone = zone);

    final wantsExpand = zone == DropZone.into &&
        widget.row.hasChildren &&
        !widget.row.isExpanded &&
        widget.onAutoExpand != null;
    if (wantsExpand) {
      _expandTimer ??= Timer(FolderTile.autoExpandDelay, () {
        _expandTimer = null;
        widget.onAutoExpand?.call();
      });
    } else {
      _cancelExpandTimer();
    }
  }

  void _onLeave(DraggedFolder? _) {
    _cancelExpandTimer();
    if (_hoverZone != null) setState(() => _hoverZone = null);
  }

  void _onAccept(DragTargetDetails<DraggedFolder> details) {
    _cancelExpandTimer();
    final zone = _zoneAt(details);
    setState(() => _hoverZone = null);
    if (zone != null) widget.onDrop?.call(details.data, zone);
  }

  void _cancelExpandTimer() {
    _expandTimer?.cancel();
    _expandTimer = null;
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    Widget child = _buildRow(context, menuOnLongPress: !_canDrag);

    if (_canDrag) {
      final plainRow = child;
      child = Listener(
        onPointerDown: (e) {
          _pressedAt = e.position;
          _movedDuringPress = false;
        },
        onPointerMove: (e) {
          final from = _pressedAt;
          if (from != null && (e.position - from).distance > _menuSlop) {
            _movedDuringPress = true;
          }
        },
        child: LongPressDraggable<DraggedFolder>(
          data: DraggedFolder(row.folder),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: _DragFeedback(
            label: row.folder.displayName,
            icon: _iconFor(row),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: plainRow),
          // Held and released in place: that is the menu gesture, not a move.
          onDragEnd: (details) {
            if (!details.wasAccepted && !_movedDuringPress) {
              widget.onLongPress?.call();
            }
          },
          child: plainRow,
        ),
      );
    }

    if (_canReceive) {
      final inner = child;
      child = DragTarget<DraggedFolder>(
        onWillAcceptWithDetails: _couldAccept,
        onMove: _onMove,
        onLeave: _onLeave,
        onAcceptWithDetails: _onAccept,
        builder: (_, _, _) => _withDropIndicator(context, inner),
      );
    }

    if (widget.onDropMessages != null) {
      final inner = child;
      child = DragTarget<DraggedMessages>(
        onWillAcceptWithDetails: (d) =>
            canDropMessagesOn(d.data.messages, row.folder),
        onAcceptWithDetails: (d) => widget.onDropMessages!(d.data),
        builder: (context, candidates, _) => candidates.isEmpty
            ? inner
            : ColoredBox(
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.6),
                child: inner,
              ),
      );
    }

    return Semantics(
      selected: widget.isSelected,
      expanded: row.hasChildren ? row.isExpanded : null,
      child: child,
    );
  }

  Widget _withDropIndicator(BuildContext context, Widget child) {
    final scheme = Theme.of(context).colorScheme;
    return switch (_hoverZone) {
      null => child,
      DropZone.into => ColoredBox(
          color: scheme.primaryContainer.withValues(alpha: 0.6),
          child: child,
        ),
      DropZone.before => DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: scheme.primary, width: 2)),
          ),
          child: child,
        ),
      DropZone.after => DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.primary, width: 2)),
          ),
          child: child,
        ),
    };
  }

  Widget _buildRow(BuildContext context, {required bool menuOnLongPress}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final row = widget.row;
    final folder = row.folder;
    final count = folder.badgeCount;
    final hasUnread =
        !folder.showsTotalInsteadOfUnread && folder.unreadCount > 0;
    final accent =
        row.accentColor == null ? scheme.primary : Color(row.accentColor!);

    return Material(
      color: widget.isSelected
          ? scheme.secondaryContainer.withValues(alpha: 0.7)
          : Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: menuOnLongPress ? widget.onLongPress : null,
        onSecondaryTap: widget.onLongPress,
        child: Padding(
          padding: EdgeInsets.only(
            left: 4 + row.depth * FolderTile.indentPerLevel,
            top: row.subtitle == null ? 0 : 4,
            bottom: row.subtitle == null ? 0 : 4,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: FolderTile.minHeight),
            child: Row(
              children: [
                SizedBox(
                  width: FolderTile.twistyWidth,
                  child: row.hasChildren
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: FolderTile.twistyWidth,
                            height: 32,
                          ),
                          iconSize: 18,
                          icon: AnimatedRotation(
                            turns: row.isExpanded ? 0.25 : 0,
                            duration: const Duration(milliseconds: 120),
                            child: const Icon(Icons.chevron_right),
                          ),
                          tooltip: row.isExpanded ? 'Collapse' : 'Expand',
                          onPressed: widget.onToggleExpand,
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
                      color:
                          hasUnread ? scheme.primary : scheme.onSurfaceVariant,
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
    );
  }

  Widget _label(ThemeData theme, bool hasUnread) {
    final row = widget.row;
    final name = Text(
      row.folder.displayName,
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

/// What follows the finger during a drag: a small card with the folder name,
/// offset so the finger does not cover it.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Transform.translate(
      offset: const Offset(16, -28),
      child: Material(
        elevation: 6,
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
