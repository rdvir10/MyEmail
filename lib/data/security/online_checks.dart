import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/error_report.dart' show ReadableError;

/// The two outside opinions Check for threats can ask: Google Safe
/// Browsing for links, and VirusTotal for attachments. Each with a key of
/// Ron's own, pasted into Settings, Threat check and kept in the phone's
/// secure storage: the app is published, and a key built into it would be
/// anyone's.

/// What a key is kept under in the credential store.
const safeBrowsingKeyName = 'threat-safe-browsing-key';
const virusTotalKeyName = 'threat-virustotal-key';

/// An outside check that could not be asked, said as it would be to Ron.
class OnlineCheckFailed implements Exception, ReadableError {
  const OnlineCheckFailed(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

/// Google Safe Browsing's Lookup API: which of some links Google lists as
/// phishing, malware or unwanted software. Only the links are sent.
abstract class SafeBrowsing {
  /// The threat type Google lists each of [urls] under, by URL; those it
  /// does not list are left out. Throws [OnlineCheckFailed].
  Future<Map<String, String>> listed(List<String> urls, {required String key});
}

class HttpSafeBrowsing implements SafeBrowsing {
  HttpSafeBrowsing({this.client});

  /// A test's; null for one of its own each time.
  final http.Client? client;

  static final _endpoint =
      Uri.parse('https://safebrowsing.googleapis.com/v4/threatMatches:find');

  @override
  Future<Map<String, String>> listed(
    List<String> urls, {
    required String key,
  }) async {
    if (urls.isEmpty) return const {};
    final client = this.client ?? http.Client();
    final http.Response response;
    try {
      response = await client
          .post(
            _endpoint.replace(queryParameters: {'key': key}),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'client': {'clientId': 'myemail', 'clientVersion': '3'},
              'threatInfo': {
                'threatTypes': [
                  'MALWARE',
                  'SOCIAL_ENGINEERING',
                  'UNWANTED_SOFTWARE',
                  'POTENTIALLY_HARMFUL_APPLICATION',
                ],
                'platformTypes': ['ANY_PLATFORM'],
                'threatEntryTypes': ['URL'],
                'threatEntries': [
                  for (final u in urls.take(500)) {'url': u},
                ],
              },
            }),
          )
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw OnlineCheckFailed('Google Safe Browsing could not be reached. ($e)');
    } finally {
      if (this.client == null) client.close();
    }
    if (response.statusCode == 400 || response.statusCode == 403) {
      throw OnlineCheckFailed(
        'Google Safe Browsing refused the key: check it in Settings, Threat '
        'check, and that the Safe Browsing API is enabled in the Google '
        'Cloud project. (${_messageOf(response)})',
      );
    }
    if (response.statusCode >= 400) {
      throw OnlineCheckFailed(
          'Google Safe Browsing answered HTTP ${response.statusCode}.');
    }
    final json = jsonDecode(response.body);
    final matches = json is Map ? json['matches'] : null;
    return {
      for (final m in matches is List ? matches : const [])
        if (m is Map && m['threat'] is Map && (m['threat'] as Map)['url'] is String)
          (m['threat'] as Map)['url'] as String: '${m['threatType']}',
    };
  }
}

/// VirusTotal's file reports: what 70-odd antivirus engines made of a
/// file, by its SHA-256. Only the fingerprint is sent, never the file.
abstract class VirusTotal {
  /// What the engines said of the file with [sha256], or null where
  /// VirusTotal has never seen it. Throws [OnlineCheckFailed].
  Future<FileVerdict?> file(String sha256, {required String key});
}

/// How many engines found a file malicious, suspicious, or nothing.
typedef FileVerdict = ({int malicious, int suspicious, int clean});

class HttpVirusTotal implements VirusTotal {
  HttpVirusTotal({this.client});

  /// A test's; null for one of its own each time.
  final http.Client? client;

  @override
  Future<FileVerdict?> file(String sha256, {required String key}) async {
    final client = this.client ?? http.Client();
    final http.Response response;
    try {
      response = await client.get(
        Uri.parse('https://www.virustotal.com/api/v3/files/$sha256'),
        headers: {'x-apikey': key},
      ).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw OnlineCheckFailed('VirusTotal could not be reached. ($e)');
    } finally {
      if (this.client == null) client.close();
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const OnlineCheckFailed(
          'VirusTotal refused the key: check it in Settings, Threat check.');
    }
    if (response.statusCode == 429) {
      throw const OnlineCheckFailed(
          "VirusTotal's free allowance is used up for now: four files a "
          'minute. Try again in a minute.');
    }
    if (response.statusCode >= 400) {
      throw OnlineCheckFailed('VirusTotal answered HTTP ${response.statusCode}.');
    }
    final json = jsonDecode(response.body);
    final stats = json is Map
        ? (((json['data'] as Map?)?['attributes'] as Map?)?['last_analysis_stats']
            as Map?)
        : null;
    // Seen, but not looked at yet: as good as not seen.
    if (stats == null) return null;
    int n(String k) => stats[k] is num ? (stats[k] as num).toInt() : 0;
    return (
      malicious: n('malicious'),
      suspicious: n('suspicious'),
      clean: n('undetected') + n('harmless'),
    );
  }
}

String _messageOf(http.Response response) {
  try {
    final json = jsonDecode(response.body);
    final error = json is Map ? json['error'] : null;
    final message = error is Map ? error['message'] : null;
    return message is String ? message : 'HTTP ${response.statusCode}';
  } on FormatException {
    return 'HTTP ${response.statusCode}';
  }
}
