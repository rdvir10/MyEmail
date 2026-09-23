/// The message without the tags that act on the page rather than show
/// something: `<meta>` (a refresh, and a viewport that would fight the one
/// the app sets) and `<base>` (which re-points every relative link).
///
/// Used before a message is shown and before it is printed. A tag cut short
/// by a `>` inside a quoted value leaves harmless text behind, never a
/// working tag.
String removeDocumentDirectives(String html) => html.replaceAll(
      RegExp(r'<\s*(meta|base)\b[^>]*>', caseSensitive: false),
      '',
    );
