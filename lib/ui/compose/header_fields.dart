import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/address_suggestions.dart';
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
            child: TextField(
              controller: controller,
              enabled: enabled,
              autofocus: autofocus,
              style: theme.textTheme.bodyMedium,
              keyboardType: keyboardType,
              textInputAction: TextInputAction.next,
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
        ],
      ),
    );
  }
}

/// A recipients field that suggests people as they are typed.
///
/// The suggestions come from the address book, if it may be read, and from
/// everyone on the cached mail either way. They are for whatever follows the
/// last comma — a recipients field is one name after another — and choosing
/// one writes it in the form the rest of the app reads back, with a comma
/// ready for the next.
///
/// The address book's permission is asked for the first time a recipient
/// field takes focus, once. Refused, the field goes on working from the
/// mail history alone.
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

  /// The field's text as of the last keystroke, kept because choosing a
  /// suggestion replaces the whole field with that one name and the rest
  /// of the line has to be put back around it.
  String _typed = '';

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus) {
      ref.read(contactsAccessProvider.notifier).askOnce();
    }
  }

  Future<Iterable<AddressSuggestion>> _options(TextEditingValue value) {
    _typed = value.text;
    final token = lastRecipientToken(value.text);
    if (token.isEmpty) return Future.value(const []);
    return ref.read(recipientSuggesterProvider)(token);
  }

  void _choose(AddressSuggestion chosen) {
    final text = completeLastRecipient(_typed, chosen);
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

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
              widget.label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: RawAutocomplete<AddressSuggestion>(
              textEditingController: widget.controller,
              focusNode: _focus,
              optionsBuilder: _options,
              displayStringForOption: (s) => s.formatted,
              onSelected: _choose,
              fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: widget.enabled,
                  autofocus: widget.autofocus,
                  style: theme.textTheme.bodyMedium,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => onSubmitted(),
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
              },
              optionsViewBuilder: (context, onSelected, options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxHeight: 320, maxWidth: 480),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: options.length,
                        itemBuilder: (context, i) {
                          final s = options.elementAt(i);
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              s.fromContacts
                                  ? Icons.person_outline
                                  : Icons.history,
                              size: 20,
                            ),
                            title: Text(s.name ?? s.email),
                            subtitle: s.name == null ? null : Text(s.email),
                            onTap: () => onSelected(s),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          ?widget.trailing,
        ],
      ),
    );
  }
}
