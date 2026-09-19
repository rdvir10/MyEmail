import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'conversation_tile.dart';
import 'message_tile.dart';

/// The messages whose rows are on screen right now, in list order.
///
/// Measured rather than worked out from a scroll offset and a row height. A
/// list builds a little beyond what it shows, rows are not all the same
/// height once conversations are on, and the arithmetic would quietly go
/// wrong the first time either of those changed.
///
/// More than half a row has to be inside the list's own box to count. A row
/// peeking a few pixels over the edge is not one anyone would say they can
/// see, and a row cut in half at the bottom is.
///
/// An open conversation speaks for nothing: its messages have rows of their
/// own further down, and some of them may be off screen. A closed one stands
/// for everything inside it, because that is what is on screen.
List<String> messagesOnScreen(GlobalKey listKey) {
  final context = listKey.currentContext;
  if (context == null) return const [];
  final list = context.findRenderObject();
  if (list is! RenderBox || !list.hasSize) return const [];

  final ids = <String>[];

  void visit(Element element) {
    final widget = element.widget;
    List<String>? row;
    if (widget is MessageTile) {
      row = [widget.message.id];
    } else if (widget is ConversationTile) {
      row = widget.isExpanded
          ? const []
          : [for (final m in widget.conversation.messages) m.id];
    }

    if (row == null) {
      element.visitChildren(visit);
      return;
    }
    // No rows inside rows, so there is nothing below this worth walking.
    if (row.isEmpty) return;

    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    final top = box.localToGlobal(Offset.zero, ancestor: list).dy;
    final height = box.size.height;
    if (height <= 0) return;
    final shown =
        math.min(top + height, list.size.height) - math.max(top, 0.0);
    if (shown > height / 2) ids.addAll(row);
  }

  context.visitChildElements(visit);
  return ids;
}
