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

/// Whether [html] names any picture by Content-ID.
bool namesInlinePictures(String html) =>
    html.toLowerCase().contains('cid:');

/// [html] with each picture it names by Content-ID replaced by the data:
/// URI [pictures] has for it, keyed by Content-ID in lower case.
///
/// A WebView handed the HTML alone has nothing to load for `cid:`, so a
/// screenshot pasted into an Outlook message, or the logo in a signature,
/// was a broken image with the picture only reachable as a chip under it.
/// A name not among [pictures] is left as it is.
String withInlinePictures(String html, Map<String, String> pictures) {
  if (pictures.isEmpty) return html;
  return html.replaceAllMapped(
    _cidLink,
    (m) {
      final uri = pictures[_contentIdOf(m[2]!)];
      return uri == null ? m[0]! : '${m[1]}$uri';
    },
  );
}

/// Every Content-ID [html] names in a picture's link, as [withInlinePictures]
/// looks them up: decoded, in lower case.
Set<String> contentIdsNamedIn(String html) => {
      for (final m in _cidLink.allMatches(html)) _contentIdOf(m[2]!),
    };

final _cidLink = RegExp(
  r'''((?<![-\w])(?:src|background)\s*=\s*["']?\s*|url\(\s*["']?\s*)cid:([^"'\s)>]+)''',
  caseSensitive: false,
);

/// A cid: link's Content-ID as a key: decoded, since a link is URL-encoded
/// (RFC 2392) and the header it names is not, and in lower case.
String _contentIdOf(String link) {
  var id = link;
  try {
    id = Uri.decodeComponent(id);
  } catch (_) {
    // Taken as written.
  }
  return id.toLowerCase();
}
