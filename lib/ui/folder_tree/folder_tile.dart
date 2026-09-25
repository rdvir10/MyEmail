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
///  * in Favourites, hold lifts the favourite; drop it on another favourite's
///    top or bottom half to put it before or after, or let go in place for
///    the menu;
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
    this.onDropFavorite,
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

  /// Called with a favourite dropped on this row, which is a favourite too,
  /// and whether it landed on the top half or the bottom. Non-null makes a
  /// favourite row one that can be picked up and dropped on; null for the
  /// tree, where a favourite's copy stays where the tree puts it.
  final void Function(DraggedFavorite dragged, DropZone zone)? onDropFavorite;

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

  bool get _canDragFavorite =>
      widget.row.inFavorites && widget.onDropFavorite != null;

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

  // --- a favourite among favourites ------------------------------------------

  /// Which half of this row a drag is over: the top puts the dragged
  /// favourite before it, the bottom after.
  DropZone? _edgeZoneAt(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(global);
    return edgeZone((local.dy / box.size.height).clamp(0.0, 1.0));
  }

  void _onFavoriteMove(DragTargetDetails<DraggedFavorite> details) {
    // A row is told about its own drag passing over it. Marking itself
    // would rebuild the very widget the drag is held by, which ends the
    // drag without a word; and a favourite cannot land on itself anyway.
    if (details.data.folder.id == widget.row.folder.id) return;
    final zone = _edgeZoneAt(details.offset);
    if (zone != _hoverZone) setState(() => _hoverZone = zone);
  }

  void _onFavoriteAccept(DragTargetDetails<DraggedFavorite> details) {
    final zone = _edgeZoneAt(details.offset) ?? DropZone.after;
    setState(() => _hoverZone = null);
    widget.onDropFavorite?.call(details.data, zone);
  }

  // --- build -----------------------------------------------------------------

  /// Notes whether the pointer moved while it was held, which is what tells
  /// a drag let go in place (the menu gesture) from one that went somewhere
  /// and was refused.
  Widget _trackingPress(Widget child) => Listener(
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
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    Widget child = _buildRow(
      context,
      menuOnLongPress: !_canDrag && !_canDragFavorite,
    );

    if (_canDrag) {
      final plainRow = child;
      child = _trackingPress(
        LongPressDraggable<DraggedFolder>(
          data: DraggedFolder(row.folder),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: DragFeedbackCard(
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
        builder: (_, _, _) => dropIndicated(context, inner, _hoverZone),
      );
    }

    if (_canDragFavorite) {
      // The same hold as a folder's, carrying a favourite: dropped on
      // another favourite it goes before or after it, and let go in place
      // it opens the menu, as a folder does.
      final plainRow = child;
      child = _trackingPress(
        LongPressDraggable<DraggedFavorite>(
          data: DraggedFavorite(row.folder),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: DragFeedbackCard(
            label: row.folder.displayName,
            icon: Icons.star,
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: plainRow),
          onDragEnd: (details) {
            if (!details.wasAccepted && !_movedDuringPress) {
              widget.onLongPress?.call();
            }
          },
          child: plainRow,
        ),
      );
      final inner = child;
      child = DragTarget<DraggedFavorite>(
        onWillAcceptWithDetails: (d) => d.data.folder.id != row.folder.id,
        onMove: _onFavoriteMove,
        onLeave: (_) {
          if (_hoverZone != null) setState(() => _hoverZone = null);
        },
        onAcceptWithDetails: _onFavoriteAccept,
        builder: (_, _, _) => dropIndicated(context, inner, _hoverZone),
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

    // A revealed hidden folder is dimmed and marked, so it is obvious which
    // rows go away again when the reveal is switched off. Wrapped last, so the
    // drag and drop behaviour above is unaffected: a hidden folder is still a
    // real folder you can drop mail onto.
    if (row.isHidden) {
      child = Opacity(
        opacity: 0.5,
        child: Row(
          children: [
            Expanded(child: child),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Icon(
                Icons.visibility_off_outlined,
                size: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Semantics(
      selected: widget.isSelected,
      expanded: row.hasChildren ? row.isExpanded : null,
      label: row.isHidden ? '${row.folder.displayName}, hidden' : null,
      child: child,
    );
  }

  Widget _buildRow(BuildContext context, {required bool menuOnLongPress}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final row = widget.row;
    final folder = row.folder;
    final counts = formatFolderCounts(folder.unreadCount, folder.totalCount);
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
                if (counts != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    counts,
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

}

/// The numbers after a folder's name: unread, a slash, and everything in
/// it — "14/2310" — or nothing for an empty folder. The unread count is
/// capped the way Outlook caps its badge, so a folder with thousands unread
/// does not push its own name out of the row; the total gets one more digit
/// because a total is what it is for.
String? formatFolderCounts(int unread, int total) {
  if (total <= 0) return null;
  String cap(int n, int at) => n > at ? '$at+' : '$n';
  return '${cap(unread, 999)}/${cap(total, 9999)}';
}

/// [child] marked with where a drag over it would land: tinted for into,
/// a line along the top edge for before, along the bottom for after, and
/// as it is when nothing is over it.
///
/// One [DecoratedBox] whatever the zone, undecorated for none, rather than
/// the bare child. The mark comes and goes while a drag is held, and a
/// child that is sometimes wrapped and sometimes not is rebuilt from
/// nothing each time; when that child is the very draggable the drag is
/// held by, the drag loses its end and never says it was let go.
Widget dropIndicated(BuildContext context, Widget child, DropZone? zone) {
  final scheme = Theme.of(context).colorScheme;
  final line = BorderSide(color: scheme.primary, width: 2);
  return DecoratedBox(
    decoration: switch (zone) {
      null => const BoxDecoration(),
      DropZone.into =>
        BoxDecoration(color: scheme.primaryContainer.withValues(alpha: 0.6)),
      DropZone.before => BoxDecoration(border: Border(top: line)),
      DropZone.after => BoxDecoration(border: Border(bottom: line)),
    },
    child: child,
  );
}

/// What follows the finger during a drag: a small card with a name and an
/// icon, or a [leading] widget of the caller's, offset so the finger does
/// not cover it.
class DragFeedbackCard extends StatelessWidget {
  const DragFeedbackCard({
    super.key,
    required this.label,
    this.icon,
    this.leading,
  });

  final String label;
  final IconData? icon;
  final Widget? leading;

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
                leading ??
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
