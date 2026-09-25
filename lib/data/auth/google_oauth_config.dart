/// The OAuth client ID of the app's registration in Google Cloud.
///
/// Handed to the build by tool/release.ps1 as a `--dart-define`, read from
/// android/google-oauth.properties, which git ignores. Not because the ID
/// is a secret (a phone app has nowhere to keep one, and the ID grants
/// nothing on its own) but because GitHub's secret scanning refuses a push
/// carrying it beside the client secret, and the two belong together.
///
/// Empty in a build made without the file: tests, and a checkout with no
/// registration. See docs/google-sign-in.md for the walkthrough that
/// produces the values, and [googleSignInConfigured], which the
/// add-account screen checks so an unconfigured build explains itself.
const googleClientId = String.fromEnvironment(
  'GOOGLE_CLIENT_ID',
  defaultValue: _registeredClientId,
);

const _registeredClientId = '';

/// The desktop client's secret, which goes with [googleClientId] on every
/// token request. From the same file, the same way.
///
/// Carried inside the app on purpose. Google's own guidance for installed
/// apps says the secret of a desktop client is not confidential, since an
/// app on someone's device cannot keep one, and the flow is protected by
/// PKCE and the loopback redirect instead; Thunderbird ships its Gmail
/// client this way. The desktop client is used at all because it is the
/// one kind an unreviewed app may make with a way back into the app:
/// custom URI schemes on an Android client wait on a brand review.
const googleClientSecret = String.fromEnvironment(
  'GOOGLE_CLIENT_SECRET',
  defaultValue: _registeredClientSecret,
);

const _registeredClientSecret = '';

bool get googleSignInConfigured => googleClientId.isNotEmpty;

/// The custom URI scheme Google sends the browser back to after a sign-in:
/// the client ID reversed, which is the one form Google accepts for an
/// Android client. `1234-abcd.apps.googleusercontent.com` becomes
/// `com.googleusercontent.apps.1234-abcd`.
///
/// The same scheme is written into AndroidManifest.xml, where it cannot be
/// computed; a test keeps the two in step.
String googleRedirectScheme(String clientId) {
  const suffix = '.apps.googleusercontent.com';
  final prefix = clientId.endsWith(suffix)
      ? clientId.substring(0, clientId.length - suffix.length)
      : clientId;
  return 'com.googleusercontent.apps.$prefix';
}

/// Where the browser lands after a sign-in, for the request and for telling
/// a redirect from any other URL the app is handed.
String googleRedirectUri(String clientId) =>
    '${googleRedirectScheme(clientId)}:/oauth2redirect';
