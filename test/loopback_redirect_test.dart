import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/loopback_redirect.dart';

/// The app listening on its own address for the browser to come back.
void main() {
  Future<HttpClientResponse> get(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      return await request.close();
    } finally {
      client.close();
    }
  }

  test('names a loopback address on a port of its own', () async {
    final a = await LoopbackRedirect.start();
    final b = await LoopbackRedirect.start();
    addTearDown(a.close);
    addTearDown(b.close);

    expect(a.redirectUri, 'http://127.0.0.1:${a.port}/');
    expect(a.port, isNot(b.port));
  });

  test('the first request with a query is the redirect, answered with a page',
      () async {
    final listener = await LoopbackRedirect.start();
    addTearDown(listener.close);

    final response = await get(
      Uri.parse('${listener.redirectUri}?code=c-1&state=s-1'),
    );
    final body = await response.transform(const SystemEncoding().decoder).join();

    expect(response.statusCode, 200);
    expect(body, contains('Signed in'));
    final arrived = await listener.arrival;
    expect(arrived.queryParameters['code'], 'c-1');
    expect(arrived.queryParameters['state'], 's-1');
    expect(arrived.scheme, 'http');
    expect(arrived.port, listener.port);
  });

  test('a request with nothing in it, like a favicon, is not it', () async {
    final listener = await LoopbackRedirect.start();
    addTearDown(listener.close);

    final favicon = await get(Uri.parse('${listener.redirectUri}favicon.ico'));
    expect(favicon.statusCode, 204);
    await favicon.drain<void>();

    var arrived = false;
    // ignore: unawaited_futures
    listener.arrival.then((_) => arrived = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(arrived, isFalse);
  });

  test('closed, the port is let go', () async {
    final listener = await LoopbackRedirect.start();
    final uri = Uri.parse(listener.redirectUri);
    await listener.close();

    expect(() => get(uri), throwsA(isA<SocketException>()));
  });
}
