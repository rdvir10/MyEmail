import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/address_suggestions.dart';
import '../../domain/text_direction.dart';
import '../../state/contact_providers.dart';

/// The header rows of a compose-shaped screen: a name in muted text on the
/// left and a field with a light rule under it, in the same type as the
/// body below. Enough to say "type here" without the outlined boxes that
/// shouted over the message itself.
///
/// Shared by the compose screen and the new-meeting screen, which is the
/// same act with a time in place of a body and wants the same rows.
class HeaderField extends StatelessWidget {
  const HeaderField({
    super.key,
    required this.label,
    required this.controller,
    required this.enabled,
    this.autofocus = false,
    this.keyboardType = TextInputType.text,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final bool autofocus;
  final TextInputType keyboardType;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            // The field reads the way its first letter does: a Hebrew
            // subject from the right, an English one from the left.
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => TextField(
                controller: controller,
                enabled: enabled,
                autofocus: autofocus,
                style: theme.textTheme.bodyMedium,
                keyboardType: keyboardType,
                textInputAction: TextInputAction.next,
                textDirection: firstStrongDirection(value.text) ??
                    Directionality.of(context),
                decoration: InputDecoration(
                  border: UnderlineInputBorder(
                    borderSide: BorderSide(color: theme.dividerColor),
                  ),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: theme.dividerColor),
                  ),
                  isDense: true,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A recipients field that suggests people as they are typed.
///
/// The suggestions come from the phone's address book, if it may be read,
/// from everyone on the cached mail, and a moment later from the accounts'
/// own address books online, where they have allowed it. They are for
/// whatever follows the last comma — a recipients field is one name after
/// another — and choosing one writes it in the form the rest of the app
/// reads back, with a comma ready for the next.
///
/// Tapped into with nothing after the last comma, it offers the people
/// written to most lately, before a letter is typed. Not straight after a
/// suggestion is chosen: the list would cover Subject just as the next
/// thing to do is often to go there.
///
/// Its own list rather than [RawAutocomplete]'s, which asks for options
/// only when the text changes: it could neither open on a tap into an
/// empty field nor take in the online answers that arrive after the
/// first ones.
///
/// The address book's permission is asked for the first time a recipient
/// field takes focus, once. Refused, the field goes on working without it.
class RecipientField extends ConsumerStatefulWidget {
  const RecipientField({
    super.key,
    required this.label,
    required this.controller,
    required this.enabled,
    this.trailing,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final Widget? trailing;
  final bool autofocus;

  @override
  ConsumerState<RecipientField> createState() => _RecipientFieldState();
}

class _RecipientFieldState extends ConsumerState<RecipientField> {
  final _focus = FocusNode();
  final _list = OverlayPortalController();

  /// The people on show, best first.
  List<AddressSuggestion> _people = const [];

  /// Which of them Enter would choose, once the arrow keys have been used.
  int _highlight = 0;
  bool _arrowed = false;

  /// The field's text as last looked up, so a change of selection alone
  /// does not look the same letters up again.
  String? _lookedUp;

  StreamSubscription<List<AddressSuggestion>>? _answers;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    widget.controller.addListener(_onText);
  }

  @override
  void didUpdateWidget(RecipientField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
  }

  @override
  void dispose() {
    _answers?.cancel();
    widget.controller.removeListener(_onText);
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus) {
      ref.read(contactsAccessProvider.notifier).askOnce();
      ref.read(recipientSuggesterProvider).fieldUsed();
      _lookUp(tappedIn: true);
    } else {
      _answers?.cancel();
      _lookedUp = null;
      _put(const []);
    }
  }

  void _onText() {
    if (!_focus.hasFocus || widget.controller.text == _lookedUp) return;
    _lookUp(tappedIn: false);
  }

  /// Ask for the people [the field's text] could mean, and show them as
  /// they come. The last answer to an earlier text is dropped with it.
  void _lookUp({required bool tappedIn}) {
    _answers?.cancel();
    final text = widget.controller.text;
    _lookedUp = text;
    final token = lastRecipientToken(text);
    // Nothing after the last comma: the usual people, on a tap into the
    // field or while it is empty, but not just after one was chosen.
    if (!widget.enabled ||
        (token.isEmpty && !tappedIn && text.trim().isNotEmpty)) {
      _put(const []);
      return;
    }
    _answers = ref
        .read(recipientSuggesterProvider)
        .suggest(token, exclude: recipientsAlreadyIn(text))
        .listen(_put);
  }

  void _put(List<AddressSuggestion> people) {
    if (!mounted) return;
    final highlighted = _arrowed && _highlight < _people.length
        ? _people[_highlight].email
        : null;
    setState(() {
      _people = people;
      // The person the arrow keys were on stays chosen when the online
      // answers reorder the list under them.
      final kept = highlighted == null
          ? -1
          : people.indexWhere((p) => p.email == highlighted);
      _highlight = kept < 0 ? 0 : kept;
      if (kept < 0) _arrowed = false;
    });
    if (_focus.hasFocus && people.isNotEmpty) {
      _list.show();
    } else {
      _list.hide();
    }
  }

  void _choose(AddressSuggestion chosen) {
    final text = completeLastRecipient(widget.controller.text, chosen);
    _answers?.cancel();
    _lookedUp = text;
    _put(const []);
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Enter, or the keyboard's Next: the person the arrow keys are on, or
  /// else the first, unless what was typed is a whole address of its own.
  /// "dan@example.com" typed out is meant as written, not as the
  /// dana@example.com above it.
  void _submitted() {
    if (!_list.isShowing || _people.isEmpty) return;
    final token = lastRecipientToken(widget.controller.text).toLowerCase();
    if (token.isEmpty) return;
    if (_arrowed) {
      _choose(_people[_highlight]);
      return;
    }
    final typedOut = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(token);
    if (typedOut && !_people.any((p) => p.email.toLowerCase() == token)) {
      return;
    }
    _choose(_people.first);
  }

  void _move(int by) {
    if (_people.isEmpty) return;
    setState(() {
      _highlight = _arrowed
          ? (_highlight + by).clamp(0, _people.length - 1)
          : (by > 0 ? 0 : _people.length - 1);
      _arrowed = true;
    });
  }

  bool get _showing => _list.isShowing && _people.isNotEmpty;

  /// On show for letters typed, not just for tapping in. Only then does Esc
  /// close the list: the usual people come up on their own in an empty new
  /// message, and Esc there still closes the message.
  bool get _showingForTyped =>
      _showing && lastRecipientToken(widget.controller.text).isNotEmpty;

  /// While the list is on show, the arrow keys move through it and Esc
  /// closes it. Otherwise every key goes on: the arrows to the field, Esc
  /// to the screen, which closes the message. A key handler of its own
  /// rather than a Shortcuts entry, which kept Esc even when it had
  /// nothing to do with it, and the message stayed open.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_showing && key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (_showing && key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (_showingForTyped && key == LogicalKeyboardKey.escape) {
      _put(const []);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final field = TextField(
      controller: widget.controller,
      focusNode: _focus,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      style: theme.textTheme.bodyMedium,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      onSubmitted: (_) => _submitted(),
      decoration: InputDecoration(
        border: UnderlineInputBorder(
          borderSide: BorderSide(color: theme.dividerColor),
        ),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: theme.dividerColor),
        ),
        isDense: true,
        filled: false,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              widget.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: OverlayPortal.overlayChildLayoutBuilder(
              controller: _list,
              overlayChildBuilder: _buildList,
              child: TextFieldTapRegion(
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: _onKey,
                  child: field,
                ),
              ),
            ),
          ),
          ?widget.trailing,
        ],
      ),
    );
  }

  /// Under the field where there is room, above it where there is more,
  /// and never under the keyboard: where [RawAutocomplete] puts its list,
  /// worked out the same way.
  Widget _buildList(BuildContext context, OverlayChildLayoutInfo layout) {
    if (layout.childPaintTransform.determinant() == 0.0) {
      return const SizedBox.shrink();
    }
    final fieldSize = layout.childSize;
    final toField = layout.childPaintTransform.clone()..invert();
    final visible = MediaQuery.paddingOf(context).deflateRect(
      MediaQuery.viewInsetsOf(context)
          .deflateRect(Offset.zero & layout.overlaySize),
    );
    final room = MatrixUtils.transformRect(toField, visible);
    final above = -room.top;
    final below = room.bottom - fieldSize.height;
    final up = above > below;
    final height = max(up ? above : below, kMinInteractiveDimension);
    final top = up ? room.top : fieldSize.height;
    final transform = layout.childPaintTransform.clone()
      ..translateByDouble(0.0, top, 0, 1);

    final theme = Theme.of(context);
    return Transform(
      transform: transform,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: fieldSize.width,
          height: height,
          child: Align(
            alignment: up
                ? AlignmentDirectional.bottomStart
                : AlignmentDirectional.topStart,
            child: TextFieldTapRegion(
              child: ExcludeFocus(
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: 320,
                      maxWidth: 480,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: _people.length,
                      itemBuilder: (context, i) {
                        final s = _people[i];
                        return ListTile(
                          dense: true,
                          selected: _arrowed && i == _highlight,
                          selectedTileColor:
                              theme.colorScheme.secondaryContainer,
                          leading: Icon(
                            s.fromContacts
                                ? Icons.person_outline
                                : Icons.history,
                            size: 20,
                          ),
                          title: Text(s.name ?? s.email),
                          subtitle: s.name == null ? null : Text(s.email),
                          onTap: () => _choose(s),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
