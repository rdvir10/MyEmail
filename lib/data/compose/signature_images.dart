import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A signature's hosted pictures, brought inside it.
///
/// A signature pasted from Outlook or a CodeTwo template carries its logo
/// as a link to a web server. The editor strips remote pictures from what
/// it shows — it does that to every message, so that opening one does
/// not tell the sender you did — and a link is one outage away from a
/// broken picture in every message sent. Fetched once here and written
/// into the signature as data, the logo is part of the signature and
/// travels with it.
///
/// Best effort: a picture that cannot be fetched is left as the link it
/// was. Only http(s) sources are touched; data and cid ones already are
/// what they are.
Future<String> inlineRemoteImages(
  String html, {
  Future<FetchedImage?> Function(Uri) fetch = fetchImageOverHttp,
  int maxBytes = 2 * 1024 * 1024,
}) async {
  final pattern = RegExp(
    r'''(<img\b[^>]*?\bsrc\s*=\s*)(["']?)(https?://[^"'\s>]+)\2''',
    caseSensitive: false,
  );
  final matches = pattern.allMatches(html).toList();
  if (matches.isEmpty) return html;

  final out = StringBuffer();
  var last = 0;
  for (final m in matches) {
    out.write(html.substring(last, m.start));
    final uri = Uri.tryParse(m[3]!);
    FetchedImage? got;
    if (uri != null) {
      try {
        got = await fetch(uri);
      } catch (_) {
        got = null;
      }
    }
    if (got == null || got.bytes.length > maxBytes) {
      out.write(m[0]);
    } else {
      final quote = m[2]!.isEmpty ? '"' : m[2]!;
      out.write(
        '${m[1]}$quote'
        'data:${got.mimeType};base64,${base64Encode(got.bytes)}'
        '$quote',
      );
    }
    last = m.end;
  }
  out.write(html.substring(last));
  return out.toString();
}

/// What a fetch hands back.
class FetchedImage {
  const FetchedImage(this.bytes, this.mimeType);

  final Uint8List bytes;
  final String mimeType;
}

Future<FetchedImage?> fetchImageOverHttp(Uri uri) async {
  final response = await http.get(uri).timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) return null;
  final type = response.headers['content-type']?.split(';').first.trim();
  if (type == null || !type.startsWith('image/')) return null;
  return FetchedImage(response.bodyBytes, type);
}
