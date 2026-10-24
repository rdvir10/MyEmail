import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';

import 'mail_message.dart';

/// What a conditional format looks at.
enum RowCondition {
  from('From contains', 'A name or an address, or part of one: hadco.com'),
  subject('Subject contains', 'A word or a phrase in the subject'),
  onlyToMe('Sent only to me', 'You alone on the To line, nobody copied');

  const RowCondition(this.label, this.hint);

  final String label;
  final String hint;

  /// Whether the condition needs words to look for.
  bool get needsText => this != onlyToMe;
}

/// The colours a rule can paint a row's first line in.
///
/// Each in two shades, one for a white list and one for a dark one, both
/// readable as text: the light ones are Outlook's own, the dark ones the
/// same hues raised to show on the dark list.
enum RowColour {
  red('Red', Color(0xFFC50F1F), Color(0xFFFF8A80)),
  orange('Orange', Color(0xFFCA5010), Color(0xFFFFB27A)),
  green('Green', Color(0xFF107C10), Color(0xFF7FD67F)),
  teal('Teal', Color(0xFF038387), Color(0xFF5FD4D6)),
  blue('Blue', Color(0xFF0F6CBD), Color(0xFF6CB8F6)),
  purple('Purple', Color(0xFF8764B8), Color(0xFFC3A6F0)),
  pink('Pink', Color(0xFFC239B3), Color(0xFFF29AE6)),
  brown('Brown', Color(0xFF8E562E), Color(0xFFD9A47E));

  const RowColour(this.label, this.light, this.dark);

  final String label;
  final Color light;
  final Color dark;

  Color on(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// One of Outlook's conditional formats: rows matching [condition] have
/// their first line drawn in [colour], and bold where [bold] says.
///
/// Kept on this device and in the settings backup. The first rule that
/// matches a message is the one it gets, so the order of the list is the
/// order of precedence, as it is in Outlook.
@immutable
class RowFormat {
  const RowFormat({
    required this.id,
    required this.condition,
    this.text = '',
    this.colour = RowColour.blue,
    this.bold = false,
  });

  final String id;
  final RowCondition condition;

  /// What [condition] looks for, as typed. Matched without regard to case.
  final String text;
  final RowColour colour;
  final bool bold;

  /// Whether [message] gets this format. [ownAddresses] are the accounts'
  /// addresses in lower case. A rule with nothing to look for matches
  /// nothing, rather than every message.
  bool matches(MailMessage message, Set<String> ownAddresses) {
    switch (condition) {
      case RowCondition.from:
        final needle = text.trim().toLowerCase();
        if (needle.isEmpty) return false;
        return message.from.email.toLowerCase().contains(needle) ||
            (message.from.name?.toLowerCase().contains(needle) ?? false);
      case RowCondition.subject:
        final needle = text.trim().toLowerCase();
        if (needle.isEmpty) return false;
        return message.subject.toLowerCase().contains(needle);
      case RowCondition.onlyToMe:
        return message.to.length == 1 &&
            message.cc.isEmpty &&
            ownAddresses.contains(message.to.single.email.trim().toLowerCase());
    }
  }

  /// What the rule does, in a line: "From contains hadco.com".
  String get summary => condition.needsText
      ? '${condition.label} “${text.trim()}”'
      : condition.label;

  RowFormat copyWith({
    RowCondition? condition,
    String? text,
    RowColour? colour,
    bool? bold,
  }) =>
      RowFormat(
        id: id,
        condition: condition ?? this.condition,
        text: text ?? this.text,
        colour: colour ?? this.colour,
        bold: bold ?? this.bold,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'condition': condition.name,
        'text': text,
        'colour': colour.name,
        'bold': bold,
      };

  /// Null for a record that cannot be read, so one bad rule does not cost
  /// the rest.
  static RowFormat? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final condition = _byName(RowCondition.values, json['condition']);
    if (id is! String || id.isEmpty || condition == null) return null;
    return RowFormat(
      id: id,
      condition: condition,
      text: json['text'] is String ? json['text'] as String : '',
      colour: _byName(RowColour.values, json['colour']) ?? RowColour.blue,
      bold: json['bold'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RowFormat &&
      other.id == id &&
      other.condition == condition &&
      other.text == text &&
      other.colour == colour &&
      other.bold == bold;

  @override
  int get hashCode => Object.hash(id, condition, text, colour, bold);
}

/// The first of [rules] that [message] matches, or null.
RowFormat? rowFormatFor(
  MailMessage message,
  List<RowFormat> rules,
  Set<String> ownAddresses,
) {
  for (final rule in rules) {
    if (rule.matches(message, ownAddresses)) return rule;
  }
  return null;
}

T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}
