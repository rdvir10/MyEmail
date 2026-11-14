import 'dart:async';

import 'package:http/http.dart' as http;

/// How long a server may take to start answering, and how long it may
/// then go quiet part way through. Without a limit a request on a network
/// that had gone away waited for ever: a pass of the live worker, or a
/// Delete pressed in the shade, held up with it.
///
/// The mail calls had it first. The calendar calls go by it too: the
/// background passes make them after the mail, and one that never came
/// back held every pass after it, so no new mail was checked for until the
/// app was opened.
const answerWithin = Duration(seconds: 90);

/// The slowest upload allowed before a request is given up on: a weak
/// signal, not a dead one. A draft with a photo can be 4 MB of base64.
const slowestUploadBytesPerSecond = 8 * 1024;

/// The response to [sent], within [answerWithin] for the headers, plus
/// the time [uploading] bytes take at the slowest upload allowed, and
/// [answerWithin] for every gap in the body after them. A gap, not the
/// whole body: a large attachment on a slow line may take longer than any
/// fixed limit.
///
/// Past either it throws a [TimeoutException], which each caller reads as
/// no connection.
Future<http.Response> answeredInTime(
  Future<http.StreamedResponse> sent, {
  int uploading = 0,
}) async {
  final http.StreamedResponse streamed;
  try {
    streamed = await sent.timeout(
      answerWithin +
          Duration(seconds: uploading ~/ slowestUploadBytesPerSecond),
    );
  } on TimeoutException {
    // Should the answer come after all, its connection is let go of
    // rather than held open for good.
    unawaited(sent.then(
      (late) => late.stream.listen(null).cancel(),
      onError: (Object _) {},
    ));
    rethrow;
  }
  final body =
      await http.ByteStream(streamed.stream.timeout(answerWithin)).toBytes();
  return http.Response.bytes(
    body,
    streamed.statusCode,
    request: streamed.request,
    headers: streamed.headers,
    isRedirect: streamed.isRedirect,
    persistentConnection: streamed.persistentConnection,
    reasonPhrase: streamed.reasonPhrase,
  );
}
