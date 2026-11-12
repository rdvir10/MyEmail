import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/graph/graph_mail_api.dart';

/// No more than a few requests are with Microsoft at once.
///
/// It allows an app four at a time on a mailbox and turns the fifth away
/// with a 429, which is then waited out for seconds. Opening one message
/// with pictures in it sent a request for each of them together, beside the
/// body, its files and whatever sync was running, so some were turned away
/// and the pictures, or the next message opened, came seconds late.
void main() {
  test('requests past the limit wait their turn, and all are answered',
      () async {
    var out = 0;
    var most = 0;
    var answered = 0;
    final api = GraphMailApi(
      accessToken: ({bool force = false}) async => 'token',
      httpClient: http_testing.MockClient((request) async {
        most = ++out > most ? out : most;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        out--;
        answered++;
        return http.Response('', 404);
      }),
    );

    final found = await Future.wait([
      for (var i = 0; i < 12; i++) api.message('m$i'),
    ]);

    expect(found, everyElement(isNull));
    expect(answered, 12);
    expect(most, GraphMailApi.maxAtOnce);
  });

  test('a request that fails gives its place to the next', () async {
    var asked = 0;
    final api = GraphMailApi(
      accessToken: ({bool force = false}) async => 'token',
      httpClient: http_testing.MockClient((request) async {
        asked++;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        throw http.ClientException('Connection reset');
      }),
    );

    final results = await Future.wait([
      for (var i = 0; i < 8; i++)
        api.message('m$i').then<Object?>((m) => m, onError: (Object e) => e),
    ]);

    expect(asked, 8, reason: 'none left waiting for a place never given up');
    expect(results, everyElement(isA<Exception>()));
  });
}
