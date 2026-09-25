import 'dart:async';
import 'dart:io';

/// The way back from the browser after a Google sign-in, by the loopback
/// address.
///
/// Google's authorization server sends the browser to a redirect URI when
/// the sign-in is done. For a desktop client, the one kind of client Google
/// lets an unreviewed app make without conditions, that URI may be the
/// device's own loopback address on any port. So for as long as a sign-in
/// is under way the app listens on 127.0.0.1, the browser's tab is sent
/// there with the code, and this answers it with a page saying it is done.
/// Thunderbird signs in to Gmail this way.
///
/// One request is taken, the first with a query string; anything else the
/// browser asks for on the way (a favicon) is answered with nothing. The
/// listener is closed by whoever started it, when the sign-in ends however
/// it ends.
class LoopbackRedirect {
  LoopbackRedirect._(this._server) {
    // Served from the root zone. A widget test runs in a zone that holds
    // its microtasks until the test pumps, and an answer written from such
    // a zone never reaches the socket, so the browser would wait for ever.
    // The app itself runs in the root zone anyway. Whoever awaits
    // [arrival] is called back in their own zone as usual.
    Zone.root.run(() {
      _server.listen(_serve, onError: (Object e) {
        if (!_arrived.isCompleted) _arrived.completeError(e);
      });
    });
  }

  final HttpServer _server;
  final _arrived = Completer<Uri>();

  /// Listening on a port the system chose, which is what the redirect URI
  /// then names.
  static Future<LoopbackRedirect> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return LoopbackRedirect._(server);
  }

  int get port => _server.port;

  /// What the authorization request names, and what the browser is sent
  /// to. The trailing slash matters: Google compares the whole string.
  String get redirectUri => 'http://127.0.0.1:$port/';

  /// The redirect, when the browser follows it: the full URL, query and
  /// all, for [GoogleOAuth.codeFromRedirect].
  Future<Uri> get arrival => _arrived.future;

  Future<void> _serve(HttpRequest request) async {
    final uri = request.uri;
    if (uri.queryParameters.isEmpty || _arrived.isCompleted) {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(_donePage);
    await request.response.close();
    _arrived.complete(Uri.parse(redirectUri).replace(query: uri.query));
  }

  Future<void> close() => _server.close(force: true);

  /// What the tab shows once the code has been taken. The app brings itself
  /// back in front of the tab the moment the code arrives, so this is seen
  /// for a moment if at all; it is here for the case where it is not.
  static const _donePage = '''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>MyEmail</title>
<style>body{font:18px/1.5 -apple-system,Roboto,sans-serif;margin:0;padding:48px 24px;color:#1c1c1c;background:#fafafa}
p{max-width:32em}</style></head>
<body><p><b>Signed in.</b> You can close this tab and go back to MyEmail.</p></body></html>''';
}
