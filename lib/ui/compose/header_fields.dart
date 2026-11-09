import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/address_suggestions.dart';
import '../../domain/mail_message.dart';
import '../../domain/text_direction.dart';
import '../../state/compose_providers.dart'
    show addressesLookValid, parseAddresses;
import '../../state/contact_groups.dart';
import '../../state/contact_providers.dart';
import '../common/bottom_message.dart';

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
    this.focusNode,
    this.onNext,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final bool autofocus;
  final TextInputType keyboardType;

  /// The field's own, for a screen that moves the cursor itself.
  final FocusNode? focusNode;

  /// The keyboard's Next, or Enter, for a screen that moves the cursor
  /// itself; Flutter's own order otherwise, which stops on buttons too.
  final VoidCallback? onNext;

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
                focusNode: focusNode,
                enabled: enabled,
                autofocus: autofocus,
                style: theme.textTheme.bodyMedium,
                keyboardType: keyboardType,
                textInputAction: TextInputAction.next,
                onEditingComplete: onNext == null
                    ? null
                    : () {
                        controller.clearComposing();
                        onNext!();
                      },
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

/// The recipient lines of one message, To, Cc and Bcc: a person can be
/// dragged from one to another, or moved there from their bubble's menu.
///
/// Made by the screen that has the lines, and given to each line's
/// [RecipientField], which finds itself among [lines] by its controller.
class RecipientLines {
  RecipientLines({required this.lines, this.reveal, this.onCarrying});

  /// Each line's name and what it holds, in the order they are shown.
  final List<({String label, TextEditingController controller})> lines;

  /// Puts [line] on show where it is not: Bcc, until asked for. Called as
  /// a person is moved there from a bubble's menu.
  final void Function(TextEditingController line)? reveal;

  /// A person picked up (true) or put down (false): the compose screen
  /// shows a hidden Bcc while one is carried, so there is somewhere to drop
  /// them.
  final ValueChanged<bool>? onCarrying;

  /// The lines on show, by what they hold.
  final _shown = <TextEditingController, _RecipientFieldState>{};

  bool _carrying = false;

  void _carry(bool carrying) {
    if (_carrying == carrying) return;
    _carrying = carrying;
    onCarrying?.call(carrying);
  }
}

/// A recipients line: a bubble for each person on it, as Outlook has them,
/// and after them a field where the next is typed, which suggests people
/// as they are typed.
///
/// [controller] holds the line as the rest of the app reads it, one person
/// after another with commas between, what is being typed last. The field
/// writes it as the bubbles change, and makes bubbles of what anyone else
/// writes there (an @mention adding to To).
///
/// A comma or semicolon typed makes a bubble of what came before it;
/// Enter, or leaving the line, of the rest. A bubble shows the name alone
/// (the address for someone without one), in the error colours where the
/// address does not look right. Tapped, it has a menu: the address, Move
/// to the message's other [lines], Edit, Copy address, Remove. Held, it is
/// picked up, to be dropped on another line. Backspace with nothing typed
/// picks out the last bubble, and a second takes it away.
///
/// With the cursor elsewhere, the line [folds] to one row: the bubbles
/// that fit, and +N for the rest. A tap opens it, and leaving folds it
/// again (Ron, 2026-11-09: a reply to many people ran off the side of a
/// one-line field). Open, it grows to a few rows and then scrolls.
///
/// The suggestions come from the phone's address book, if it may be read,
/// from everyone on the cached mail, and a moment later from the accounts'
/// own address books online, where they have allowed it. They are for what
/// is being typed, and leave out whoever is on the line already; choosing
/// one makes them a bubble.
///
/// The list opens only once something is typed, never on a tap into the
/// field, and a tap anywhere else closes it: Ron found a list that came up
/// on its own, covering Cc and Subject, in the way (2.83.1).
///
/// Its own list rather than [RawAutocomplete]'s, which cannot take in the
/// online answers that arrive after the first ones.
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
    this.focusNode,
    this.onNext,
    this.lines,
    this.folds = true,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final Widget? trailing;
  final bool autofocus;

  /// The field's own, for a screen that moves the cursor itself. Left to
  /// whoever made it to dispose.
  final FocusNode? focusNode;

  /// The keyboard's Next, or Enter, for a screen that moves the cursor
  /// itself: after the person the suggestions offer is chosen.
  final VoidCallback? onNext;

  /// The message's lines a person can be moved between, this one among
  /// them. Null where there are none: a meeting's attendees, a group.
  final RecipientLines? lines;

  /// Whether the line folds to one row while the cursor is elsewhere. Not
  /// for a contact group's people, who are what its page is for.
  final bool folds;

  @override
  ConsumerState<RecipientField> createState() => _RecipientFieldState();
}

/// Between one bubble and the next.
const double _gap = 4;

/// Inside a bubble, either side of the name.
const double _bubblePad = 10;

/// The least of a row the typing field is put beside the bubbles with;
/// with less left, it starts a row of its own.
const double _typingRoom = 96;

/// What a folded line keeps after its bubbles for the cursor.
const double _foldedTyping = 16;

/// One person on a recipients line.
class _Bubble {
  _Bubble(this.raw)
      : address = parseAddresses(raw).firstOrNull ?? MailAddress(email: raw);

  /// As the line's text has them: `Dana Levi <dana@example.com>`.
  final String raw;
  final MailAddress address;

  /// The name, as Outlook shows a person; the address for someone without
  /// one.
  String get shown {
    final name = address.name?.trim() ?? '';
    return name.isNotEmpty ? name : address.email;
  }

  bool get looksRight => addressesLookValid([address]);

  /// Who this is, whatever the case: the same address twice is one person.
  String get key => address.email.trim().toLowerCase();

  static String keyOf(String raw) => _Bubble(raw).key;
}

/// A line's text cut into its people, each trimmed, the empty left out.
List<String> _peopleIn(String text) => [
      for (final piece in splitRecipients(text))
        if (piece.trim().isNotEmpty) piece.trim(),
    ];

/// A bubble on its way from one line to another.
class _Carried {
  const _Carried(this.lines, this.from, this.line, this.bubble);

  final RecipientLines lines;
  final _RecipientFieldState from;

  /// What [from] holds, should it have gone meanwhile.
  final TextEditingController line;
  final _Bubble bubble;
}

/// What a bubble's menu was closed with.
enum _Act { move, edit, copy, remove }

class _RecipientFieldState extends ConsumerState<RecipientField> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  final _list = OverlayPortalController();

  /// What is being typed after the bubbles.
  final _typing = TextEditingController();

  /// Keeps the typing field, and the cursor in it, as the line folds and
  /// opens around it.
  final _typingKey = GlobalKey();

  /// Everyone on the line, a bubble each.
  List<_Bubble> _bubbles = const [];

  /// The line as this field last wrote it, or last read it: what tells
  /// someone else's change of the line from its own. Read as the field
  /// starts, not when first needed, which could be after a change.
  String _line = '';

  /// The typing as last seen, so a move of the cursor alone is no change.
  String _typed = '';

  /// The bubble a first Backspace picked out, which a second takes away.
  _Bubble? _picked;

  /// A bubble's menu is up, and has the cursor while it is: leaving the
  /// line for it settles nothing.
  bool _menuUp = false;

  /// The line was open when a bubble's menu came up, and stays open under
  /// it. A folded line stays folded.
  bool _keptOpen = false;

  _Look? _look;

  /// The people on show, best first.
  List<AddressSuggestion> _people = const [];

  /// Which of them Enter would choose, once the arrow keys have been used.
  int _highlight = 0;
  bool _arrowed = false;

  /// The typing as last looked up, so a change of selection alone does not
  /// look the same letters up again.
  String? _lookedUp;

  StreamSubscription<List<AddressSuggestion>>? _answers;

  @override
  void initState() {
    super.initState();
    _line = widget.controller.text;
    _bubbles = [for (final p in _peopleIn(_line)) _Bubble(p)];
    _focus.addListener(_onFocus);
    _typing.addListener(_onText);
    widget.controller.addListener(_onLine);
    widget.lines?._shown[widget.controller] = this;
  }

  @override
  void didUpdateWidget(RecipientField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final moved = !identical(oldWidget.controller, widget.controller);
    if (moved || !identical(oldWidget.lines, widget.lines)) {
      _leave(oldWidget.lines, oldWidget.controller);
      widget.lines?._shown[widget.controller] = this;
    }
    if (moved) {
      oldWidget.controller.removeListener(_onLine);
      widget.controller.addListener(_onLine);
      _line = widget.controller.text;
      _bubbles = [for (final p in _peopleIn(_line)) _Bubble(p)];
      _picked = null;
    }
  }

  void _leave(RecipientLines? lines, TextEditingController line) {
    if (lines != null && identical(lines._shown[line], this)) {
      lines._shown.remove(line);
    }
  }

  @override
  void dispose() {
    _answers?.cancel();
    _leave(widget.lines, widget.controller);
    widget.controller.removeListener(_onLine);
    _typing.dispose();
    _focus.removeListener(_onFocus);
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  bool get _open => !widget.folds || _focus.hasFocus || _keptOpen;

  void _onFocus() {
    if (_focus.hasFocus) {
      ref.read(contactsAccessProvider.notifier).askOnce();
      ref.read(recipientSuggesterProvider).fieldUsed();
      // Nothing is offered for the text already there: only for typing.
      _lookedUp = _typing.text;
    } else {
      _answers?.cancel();
      _lookedUp = null;
      _put(const []);
      // Leaving the line makes a bubble of what was typed. Not for a
      // bubble's menu, which has the cursor only while it is up.
      if (!_menuUp) _settle(all: true);
      _picked = null;
    }
    if (mounted) setState(() {});
  }

  void _onText() {
    final text = _typing.text;
    if (text == _typed) return;
    _typed = text;
    if (_picked != null) setState(() => _picked = null);
    // A comma or semicolon typed, or a list pasted: everyone before the
    // last of them is a bubble.
    if (recipientSeparators(text).isNotEmpty) {
      _settle();
      return;
    }
    _write();
    if (!_focus.hasFocus || text == _lookedUp) return;
    _lookUp();
  }

  /// The line changed by someone else, as an @mention adds to To: its
  /// people are bubbles again, and what is being typed stays, where it is
  /// still the last of them.
  void _onLine() {
    final text = widget.controller.text;
    if (text == _line) return;
    _line = text;
    final people = _peopleIn(text);
    final typed = _typing.text.trim();
    final typing =
        typed.isNotEmpty && people.isNotEmpty && people.last == typed;
    setState(() {
      _bubbles = [
        for (final p in typing ? people.take(people.length - 1) : people)
          _Bubble(p),
      ];
      _picked = null;
    });
    if (!typing && _typing.text.isNotEmpty) _setTyping('');
  }

  /// The line's text, for the rest of the app: everyone on it, then what
  /// is being typed.
  void _write() {
    final typed = _typing.text.trim();
    final text = [
      for (final b in _bubbles) b.raw,
      if (typed.isNotEmpty) typed,
    ].join(', ');
    if (text == _line) return;
    _line = text;
    widget.controller.text = text;
  }

  void _setTyping(String text) {
    _typing.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// What has been typed, made into bubbles: everyone before the last
  /// comma or semicolon, and with [all] the one after it too.
  void _settle({bool all = false}) {
    if (all && _typing.text.isEmpty) return;
    final pieces = splitRecipients(_typing.text);
    final rest = all ? '' : pieces.removeLast().trimLeft();
    _add([
      for (final p in pieces)
        if (p.trim().isNotEmpty) p.trim(),
    ]);
    _setTyping(rest);
    _write();
  }

  /// [people] onto the end of the line, a bubble each, less anyone on it
  /// already.
  void _add(Iterable<String> people) {
    final have = {for (final b in _bubbles) b.key};
    final more = [
      for (final p in people)
        if (have.add(_Bubble.keyOf(p))) _Bubble(p),
    ];
    if (more.isEmpty || !mounted) return;
    setState(() => _bubbles = [..._bubbles, ...more]);
  }

  void _remove(_Bubble bubble) {
    setState(() {
      _bubbles = [
        for (final b in _bubbles)
          if (!identical(b, bubble)) b,
      ];
      if (identical(_picked, bubble)) _picked = null;
    });
    _write();
  }

  /// [raw], someone moved here from another line.
  void _receive(String raw) {
    _add([raw]);
    _write();
  }

  /// [bubble] onto [line], and off this one.
  void _moveTo(TextEditingController line, _Bubble bubble) {
    final lines = widget.lines!;
    final there = lines._shown[line];
    if (there != null && there.mounted) {
      there._receive(bubble.raw);
    } else {
      lines.reveal?.call(line);
      final people = _peopleIn(line.text);
      if (!people.any((p) => _Bubble.keyOf(p) == bubble.key)) {
        line.text = [...people, bubble.raw].join(', ');
      }
    }
    _remove(bubble);
  }

  /// A bubble dropped here from another line.
  void _takeFrom(_Carried carried) {
    _receive(carried.bubble.raw);
    if (carried.from.mounted) {
      carried.from._remove(carried.bubble);
      return;
    }
    final key = carried.bubble.key;
    carried.line.text = [
      for (final p in _peopleIn(carried.line.text))
        if (_Bubble.keyOf(p) != key) p,
    ].join(', ');
  }

  /// A tap on the line, not on a bubble: the cursor, after what is typed.
  void _focusHere() {
    if (!widget.enabled) return;
    _typing.selection =
        TextSelection.collapsed(offset: _typing.text.length);
    _focus.requestFocus();
  }

  /// Ask for the people what is being typed could mean, and show them as
  /// they come. The last answer to an earlier text is dropped with it.
  void _lookUp() {
    _answers?.cancel();
    final text = _typing.text;
    _lookedUp = text;
    final token = lastRecipientToken(text);
    if (!widget.enabled || token.isEmpty) {
      _put(const []);
      return;
    }
    _answers = ref
        .read(recipientSuggesterProvider)
        .suggest(token, exclude: {for (final b in _bubbles) b.key})
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

  /// [chosen] as a bubble, or everyone in a group a bubble each.
  void _choose(AddressSuggestion chosen) {
    _answers?.cancel();
    _lookedUp = '';
    _put(const []);
    _add(_peopleIn(chosen.formatted));
    _setTyping('');
    _write();
  }

  /// Take [person], from the mail history, out of the suggestions until
  /// they are written to again: Outlook's X beside an Auto-Complete name,
  /// for the typo once written to. Said on the bar, with Undo.
  void _forget(AddressSuggestion person) {
    final forgotten = ref.read(forgottenAddressesProvider.notifier);
    forgotten.forget(person.email);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: kBottomMessage,
        persist: false,
        content: Text('${person.email} is no longer suggested.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => forgotten.remember([person.asAddress]),
        ),
      ));
    _lookedUp = null;
    _lookUp();
  }

  /// Enter, or the keyboard's Next: the person the arrow keys are on, or
  /// else the first, unless what was typed is a whole address of its own.
  /// "dan@example.com" typed out is meant as written, not as the
  /// dana@example.com above it. Whatever is not chosen is made a bubble as
  /// typed.
  void _submitted() {
    final token = lastRecipientToken(_typing.text).toLowerCase();
    if (_list.isShowing && _people.isNotEmpty && token.isNotEmpty) {
      if (_arrowed) {
        _choose(_people[_highlight]);
        return;
      }
      final typedOut = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(token);
      if (!typedOut || _people.any((p) => p.email.toLowerCase() == token)) {
        _choose(_people.first);
        return;
      }
    }
    _settle(all: true);
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

  /// A tap anywhere but the field and the list closes the list. The field
  /// keeps the cursor; the next letter typed opens it again.
  void _tappedElsewhere(PointerDownEvent _) {
    if (!_list.isShowing) return;
    _answers?.cancel();
    _put(const []);
  }

  /// While the list is on show, the arrow keys move through it, Esc
  /// closes it, and Tab takes the person Enter would before going on to
  /// the screen, which moves the cursor to the next field. Backspace with
  /// nothing typed picks out the last bubble, and takes it away pressed
  /// again; Esc puts it back. Otherwise every key goes on: the arrows to
  /// the field, Esc to the screen, which closes the message. A key handler
  /// of its own rather than a Shortcuts entry, which kept Esc even when it
  /// had nothing to do with it, and the message stayed open.
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
    if (_showing && key == LogicalKeyboardKey.escape) {
      _put(const []);
      return KeyEventResult.handled;
    }
    if (_showing && key == LogicalKeyboardKey.tab) {
      _submitted();
      return KeyEventResult.ignored;
    }
    // Held down, Backspace deletes what is typed and stops there: only a
    // press of its own reaches the bubbles.
    final erase = key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete;
    if (erase && event is KeyDownEvent && _typing.text.isEmpty) {
      final picked = _picked;
      if (picked != null) {
        _remove(picked);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.backspace && _bubbles.isNotEmpty) {
        setState(() => _picked = _bubbles.last);
        return KeyEventResult.handled;
      }
    }
    if (_picked != null && key == LogicalKeyboardKey.escape) {
      setState(() => _picked = null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// A bubble's menu, under it: the address, then what can be done.
  Future<void> _menu(BuildContext anchor, _Bubble bubble) async {
    final box = anchor.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(box.size.bottomLeft(Offset.zero), ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final theme = Theme.of(context);
    final others = [
      for (final l in widget.lines?.lines ??
          const <({String label, TextEditingController controller})>[])
        if (!identical(l.controller, widget.controller)) l,
    ];
    setState(() {
      _keptOpen = _open;
      _menuUp = true;
    });
    final choice =
        await showMenu<({_Act act, TextEditingController? to})>(
      context: anchor,
      position: position,
      items: [
        PopupMenuItem(
          enabled: false,
          child: Text(
            bubble.address.email,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const PopupMenuDivider(),
        for (final l in others)
          PopupMenuItem(
            key: ValueKey('move-to-${l.label}'),
            value: (act: _Act.move, to: l.controller),
            child: Text('Move to ${l.label}'),
          ),
        const PopupMenuItem(
          key: ValueKey('bubble-edit'),
          value: (act: _Act.edit, to: null),
          child: Text('Edit'),
        ),
        const PopupMenuItem(
          key: ValueKey('bubble-copy'),
          value: (act: _Act.copy, to: null),
          child: Text('Copy address'),
        ),
        const PopupMenuItem(
          key: ValueKey('bubble-remove'),
          value: (act: _Act.remove, to: null),
          child: Text('Remove'),
        ),
      ],
    );
    if (!mounted) return;
    setState(() {
      _menuUp = false;
      _keptOpen = false;
    });
    switch (choice?.act) {
      case _Act.move:
        _moveTo(choice!.to!, bubble);
      case _Act.edit:
        // Typed back into the field, at the end of the line, as it was
        // written; a bubble again once finished.
        _settle(all: true);
        _remove(bubble);
        _setTyping(bubble.raw);
        _focus.requestFocus();
        return;
      case _Act.copy:
        await Clipboard.setData(ClipboardData(text: bubble.address.email));
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            duration: kBottomMessage,
            persist: false,
            content: Text('Address copied.'),
          ));
      case _Act.remove:
        _remove(bubble);
      case null:
        break;
    }
    // The menu had the cursor. Where it was not given back to the line,
    // what was typed there is settled, as leaving the line settles it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus) {
        _settle(all: true);
        setState(() {});
      }
    });
  }

  _Look _lookFor(BuildContext context) {
    final style = DefaultTextStyle.of(context)
        .style
        .merge(Theme.of(context).textTheme.bodyMedium);
    final scaler = MediaQuery.textScalerOf(context);
    final had = _look;
    if (had != null && had.style == style && had.scaler == scaler) return had;
    return _look = _Look(style, scaler);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final look = _lookFor(context);
    final field = TextField(
      key: _typingKey,
      controller: _typing,
      focusNode: _focus,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      style: theme.textTheme.bodyMedium,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      onEditingComplete: widget.onNext == null
          ? null
          : () {
              _typing.clearComposing();
              _submitted();
              widget.onNext!();
            },
      onSubmitted: (_) {
        if (widget.onNext == null) _submitted();
      },
      decoration: const InputDecoration(
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        isDense: true,
        filled: false,
        contentPadding: EdgeInsets.symmetric(vertical: 10),
      ),
    );
    // The rule under the line, as a text field draws its own: thicker, in
    // the theme's colour, while the cursor is there.
    final rule = _focus.hasFocus
        ? BorderSide(color: theme.colorScheme.primary, width: 2)
        : BorderSide(color: theme.dividerColor);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            height: look.row,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                widget.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Expanded(
            child: OverlayPortal.overlayChildLayoutBuilder(
              controller: _list,
              overlayChildBuilder: _buildList,
              // The field and the list are one region: a tap outside both
              // closes the list.
              child: TapRegion(
                groupId: this,
                onTapOutside: _tappedElsewhere,
                child: TextFieldTapRegion(
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: _onKey,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _focusHere,
                      child: DecoratedBox(
                        position: DecorationPosition.foreground,
                        decoration:
                            BoxDecoration(border: Border(bottom: rule)),
                        child: LayoutBuilder(
                          builder: (context, room) =>
                              _layOut(context, room, look, field),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.trailing case final trailing?)
            SizedBox(height: look.row, child: Center(child: trailing)),
        ],
      ),
    );
    final lines = widget.lines;
    if (lines == null) return row;
    // Anywhere on the row, its name included, takes a bubble dropped from
    // another line.
    return DragTarget<_Carried>(
      onWillAcceptWithDetails: (d) =>
          widget.enabled &&
          identical(d.data.lines, lines) &&
          !identical(d.data.line, widget.controller),
      onAcceptWithDetails: (d) => _takeFrom(d.data),
      builder: (context, coming, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: coming.isEmpty
              ? null
              : theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: row,
      ),
    );
  }

  /// The bubbles, and the field after them: all of them, a row after
  /// another, where the line is open; where it is folded, those that fit on
  /// one row and +N for the rest.
  Widget _layOut(
    BuildContext context,
    BoxConstraints room,
    _Look look,
    Widget field,
  ) {
    final width = room.maxWidth;
    final open = _open;
    final widths = [
      for (final b in _bubbles) min(look.bubbleWidth(b.shown), width),
    ];
    var count = _bubbles.length;
    var rest = 0;
    final double typing;
    if (open) {
      final left = _leftOnLastRow(widths, width);
      typing = left >= _typingRoom ? left : width;
    } else {
      final fold = _fold(widths, width, look);
      count = fold.count;
      rest = _bubbles.length - count;
      if (count > 0) widths[0] = fold.first;
      typing = fold.left;
    }
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final wrap = Wrap(
      spacing: _gap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Each as wide as measured: a slot left to its own width would
        // take the whole row, and put every bubble on a row of its own.
        for (var i = 0; i < count; i++)
          SizedBox(
            key: ObjectKey(_bubbles[i]),
            width: widths[i],
            height: look.row,
            child: Center(child: _bubble(_bubbles[i], widths[i], look)),
          ),
        if (rest > 0)
          SizedBox(
            key: const ValueKey('recipients-more'),
            width: look.moreWidth(rest),
            height: look.row,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '+$rest',
                  maxLines: 1,
                  softWrap: false,
                  style: look.style.copyWith(
                    color: muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        SizedBox(width: typing, child: field),
      ],
    );
    if (!widget.folds) return wrap;
    // Open, a few rows and then it scrolls, the field's row in sight: the
    // message has to keep some of the screen.
    final screen = MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    final cap = open
        ? max(2 * look.row, min(4.5 * look.row, screen * 0.3))
        : look.row;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: cap),
      child: SingleChildScrollView(reverse: true, child: wrap),
    );
  }

  /// What is left of the last row after [widths], laid out as [Wrap] lays
  /// them out, less a pixel so the field is sure to fit beside them.
  static double _leftOnLastRow(List<double> widths, double width) {
    var x = 0.0;
    for (final w in widths) {
      x = x == 0 || x + _gap + w > width ? w : x + _gap + w;
    }
    return x == 0 ? width : max(0.0, width - x - _gap - 1);
  }

  /// How many of [widths] fit on one row with the count of the rest after
  /// them, and the cursor's room after that; the first cut short where not
  /// even it fits. What is left is the field's.
  static ({int count, double first, double left}) _fold(
    List<double> widths,
    double width,
    _Look look,
  ) {
    final n = widths.length;
    if (n == 0) return (count: 0, first: 0, left: width);
    double more(int rest) => rest == 0 ? 0 : _gap + look.moreWidth(rest);
    var x = 0.0;
    var count = 0;
    for (var i = 0; i < n; i++) {
      final next = (i == 0 ? 0 : x + _gap) + widths[i];
      if (next + more(n - i - 1) + _gap + _foldedTyping > width) break;
      x = next;
      count = i + 1;
    }
    if (count == 0) {
      final first = max(0.0, width - more(n - 1) - _gap - _foldedTyping - 1);
      return (count: 1, first: first, left: _foldedTyping);
    }
    return (
      count: count,
      first: widths[0],
      left: max(0.0, width - x - more(n - count) - _gap - 1),
    );
  }

  Widget _bubble(_Bubble bubble, double width, _Look look) {
    final picked = identical(bubble, _picked);
    Widget chip({VoidCallback? onTap}) => _BubbleChip(
          bubble: bubble,
          width: width,
          height: look.bubbleHeight,
          style: look.style,
          picked: picked,
          onTap: onTap,
        );
    final tappable = Builder(
      builder: (anchor) => chip(
        onTap: widget.enabled ? () => _menu(anchor, bubble) : null,
      ),
    );
    final lines = widget.lines;
    if (lines == null || !widget.enabled) return tappable;
    return LongPressDraggable<_Carried>(
      data: _Carried(lines, this, widget.controller, bubble),
      maxSimultaneousDrags: 1,
      onDragStarted: () => lines._carry(true),
      onDragCompleted: () => lines._carry(false),
      onDraggableCanceled: (_, _) => lines._carry(false),
      feedback: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
            shadows: kElevationToShadow[6],
          ),
          child: chip(),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: chip()),
      child: tappable,
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
            child: TapRegion(
              groupId: this,
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
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _people.length,
                        itemBuilder: (context, i) => _SuggestionRow(
                          person: _people[i],
                          highlighted: _arrowed && i == _highlight,
                          onTap: () => _choose(_people[i]),
                          // Only what the mail history suggests: an address
                          // book keeps its own, and a group is yours.
                          onForget: _people[i].fromContacts || _people[i].isGroup
                              ? null
                              : () => _forget(_people[i]),
                        ),
                      ),
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

/// One person in the list, on one line: the name, then the address in
/// lighter, smaller type. Two lines a person, as ListTile has it, showed
/// five people in the space of nine (2.83.2).
///
/// The name takes what it needs, up to most of the row, and the address
/// the rest; each is cut short with an ellipsis rather than wrapped.
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.person,
    required this.highlighted,
    required this.onTap,
    this.onForget,
  });

  final AddressSuggestion person;

  /// The one the arrow keys are on.
  final bool highlighted;
  final VoidCallback onTap;

  /// A long press, or a right click: take this one out of the suggestions.
  /// Null where it cannot be.
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final name = person.name;
    return InkWell(
      onTap: onTap,
      onLongPress: onForget,
      onSecondaryTap: onForget,
      child: Ink(
        color: highlighted ? theme.colorScheme.secondaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Icon(
              person.isGroup
                  ? Icons.group_outlined
                  : person.fromContacts
                      ? Icons.person_outline
                      : Icons.history,
              size: 16,
              color: muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, room) => Row(
                  children: [
                    ConstrainedBox(
                      constraints:
                          BoxConstraints(maxWidth: room.maxWidth * 0.6),
                      child: Text(
                        name ?? person.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (name != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          person.isGroup
                              ? '${person.members.length} '
                                  '${person.members.length == 1 ? 'person' : 'people'}'
                              : person.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              theme.textTheme.bodySmall?.copyWith(color: muted),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A person on a recipients line: the name in a pill, in the error colours
/// where the address does not look right, and filled in the theme's colour
/// where Backspace has picked it out.
class _BubbleChip extends StatelessWidget {
  const _BubbleChip({
    required this.bubble,
    required this.width,
    required this.height,
    required this.style,
    required this.picked,
    this.onTap,
  });

  final _Bubble bubble;
  final double width;
  final double height;
  final TextStyle style;
  final bool picked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (fill, ink) = picked
        ? (scheme.primary, scheme.onPrimary)
        : bubble.looksRight
            ? (scheme.surfaceContainerHigh, scheme.onSurface)
            : (scheme.errorContainer, scheme.onErrorContainer);
    final shown = bubble.shown;
    return SizedBox(
      width: width,
      height: height,
      child: Material(
        color: fill,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _bubblePad),
            child: Center(
              child: Text(
                shown,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                textDirection: firstStrongDirection(shown),
                style: style.copyWith(color: ink),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sizes a recipients line is laid out in, measured in its type: a
/// bubble is as wide as its name, so how many fit on a row is known before
/// any is drawn.
class _Look {
  _Look(this.style, this.scaler)
      : line = _measure('Mg', style, scaler).height;

  final TextStyle style;
  final TextScaler scaler;

  /// One line of the type.
  final double line;

  final _widths = <String, double>{};

  /// A row of the line: as high as the typing field, 10 above the type and
  /// 10 below.
  double get row => line + 20;

  double get bubbleHeight => line + 8;

  double bubbleWidth(String shown) => _widths.putIfAbsent(
        shown,
        () => (_measure(shown, style, scaler).width + 2 * _bubblePad + 1)
            .ceilToDouble(),
      );

  /// The +N after a folded line's bubbles, its padding included.
  double moreWidth(int rest) => (_measure(
                '+$rest',
                style.copyWith(fontWeight: FontWeight.w600),
                scaler,
              ).width +
              8)
          .ceilToDouble();

  static Size _measure(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }
}
