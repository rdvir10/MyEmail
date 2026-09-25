import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/google_oauth_config.dart';
import 'package:myemail/data/auth/oauth_redirects.dart';

/// The way back from the browser after a Google sign-in is written in three
/// places that cannot see each other: the manifest's intent filter, the
/// Kotlin that passes the URL on, and the Dart that takes it. This reads the
/// Android half as text and holds it to the Dart half.
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final mainActivity =
      File('android/app/src/main/kotlin/com/rdvir/mailtree/MainActivity.kt')
          .readAsStringSync();
  final redirectActivity = File(
    'android/app/src/main/kotlin/com/rdvir/mailtree/OAuthRedirectActivity.kt',
  ).readAsStringSync();

  test('the redirect activity is there for the browser to start', () {
    final block = RegExp(
      r'<activity\s+android:name="\.OAuthRedirectActivity"[\s\S]*?</activity>',
    ).firstMatch(manifest)?.group(0);
    expect(block, isNotNull);
    expect(block, contains('android:exported="true"'));
    expect(block, contains('android.intent.action.VIEW'));
    expect(block, contains('android.intent.category.BROWSABLE'));
    expect(redirectActivity, contains('FLAG_ACTIVITY_CLEAR_TOP'),
        reason: 'what closes the browser tab and reaches the running app');
  });

  test('the manifest scheme is the client ID reversed', () {
    final scheme = RegExp(r'<data android:scheme="([^"]+)"/>')
        .allMatches(manifest)
        .map((m) => m.group(1)!)
        .where((s) => s.startsWith('com.googleusercontent.apps.'))
        .toList();
    expect(scheme, hasLength(1));
    // The ID lives in a file git ignores and the release script reads;
    // where the file is here, the scheme has to follow it. Elsewhere (a
    // fresh checkout) the shape is all that can be checked.
    final properties = File('android/google-oauth.properties');
    final clientId = googleSignInConfigured
        ? googleClientId
        : properties.existsSync()
            ? RegExp(r'^\s*clientId\s*=\s*(\S+)', multiLine: true)
                .firstMatch(properties.readAsStringSync())
                ?.group(1)
            : null;
    if (clientId != null) {
      expect(scheme.single, googleRedirectScheme(clientId));
    } else {
      expect(scheme.single, matches(r'^com\.googleusercontent\.apps\.\S+$'));
    }
  });

  test('the Kotlin passes the URL on the channel the Dart listens on', () {
    expect(mainActivity, contains('"${OAuthRedirects.channelName}"'));
    expect(mainActivity, contains('invokeMethod("redirect"'));
    expect(
      mainActivity,
      contains('OAUTH_SCHEME_PREFIX = "com.googleusercontent.apps."'),
      reason: 'only a URL on a Google scheme is believed',
    );
    expect(mainActivity, contains('override fun onNewIntent'));
  });

  test('and answers the call that brings the app back in front of the tab',
      () {
    // The loopback way back leaves the browser's tab on top; Dart asks for
    // this once the code is in hand, and CLEAR_TOP finishes the tab.
    expect(mainActivity, contains('"foreground" ->'));
    expect(mainActivity, contains('FLAG_ACTIVITY_CLEAR_TOP'));
  });
}
