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

/// The Content-Security-Policy a received message is shown and printed under.
///
/// The backstop behind the rewriting that hides remote pictures. That
/// rewriting reads text, and a message can name a remote resource in more
/// ways than any pattern covers: a `<base>` under a relative src, an
/// entity-encoded URL, an SVG `<image href>`, `<object data>`, CSS
/// `image-set` or an escaped `url(`. While pictures are hidden this lets
/// nothing at all be fetched, whatever the markup says.
///
/// Either way it refuses frames, plugins and form submissions. Mail has no
/// use for them, and each was a way for a message to show the sender's own
/// page inside the reading pane, under the app's header: a login form posted
/// in place, or a link aimed at an iframe.
String contentPolicyTag({required bool remoteAllowed}) {
  final fetches = remoteAllowed
      ? "img-src * data: blob:; style-src * 'unsafe-inline'; "
          'font-src * data:; media-src * data:;'
      : "img-src data: blob:; style-src 'unsafe-inline'; "
          'font-src data:; media-src data:;';
  return '<meta http-equiv="Content-Security-Policy" '
      "content=\"default-src 'none'; $fetches frame-src 'none'; "
      "object-src 'none'; form-action 'none'; base-uri 'none'\">";
}
