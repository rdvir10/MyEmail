import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/address_suggestions.dart';
import '../../state/contact_providers.dart';
import 'html_editor.dart';

/// People an @ in the message could mean, in a row over the bar under it:
/// the suggestions To makes for what follows the @, people only, since a
/// mention is one person. Gone once a space ends the @, or one is chosen.
///
/// A row and not a list: on a phone with the keyboard up, a list of five
/// took most of what was left of the message.
class MentionSuggestions extends ConsumerStatefulWidget {
  const MentionSuggestions({
    super.key,
    required this.controller,
    required this.onChoose,
  });

  final HtmlEditorController controller;
  final void Function(AddressSuggestion person) onChoose;

  @override
  ConsumerState<MentionSuggestions> createState() => _MentionSuggestionsState();
}

class _MentionSuggestionsState extends ConsumerState<MentionSuggestions> {
  String? _query;
  List<AddressSuggestion> _people = const [];
  StreamSubscription<List<AddressSuggestion>>? _answers;

  @override
  void initState() {
    super.initState();
    widget.controller.mention.addListener(_onMention);
  }

  @override
  void dispose() {
    _answers?.cancel();
    widget.controller.mention.removeListener(_onMention);
    super.dispose();
  }

  void _onMention() {
    final query = widget.controller.mention.value;
    if (query == _query) return;
    _query = query;
    _answers?.cancel();
    if (query == null) {
      setState(() => _people = const []);
      return;
    }
    _answers = ref.read(recipientSuggesterProvider).suggest(query).listen(
      (found) {
        if (!mounted || _query != query) return;
        setState(() => _people = [
              for (final p in found)
                if (!p.isGroup) p,
            ].take(6).toList());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_query == null || _people.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          children: [
            for (final person in _people)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Tooltip(
                  message: person.email,
                  child: ActionChip(
                    key: ValueKey('mention:${person.email}'),
                    avatar: const Icon(Icons.alternate_email, size: 16),
                    label: Text(
                      person.name?.trim().isNotEmpty ?? false
                          ? person.name!
                          : person.email,
                    ),
                    onPressed: () => widget.onChoose(person),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
