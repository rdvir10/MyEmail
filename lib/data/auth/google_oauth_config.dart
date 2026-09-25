/// The OAuth client ID of the app's registration in Google Cloud.
///
/// Not a secret, for the same reason as [microsoftClientId]: a phone app has
/// nowhere to keep one, so Google's flow for installed apps does not use
/// one. The ID names the registration and grants nothing on its own.
///
/// Empty until the registration exists. See docs/google-sign-in.md for the
/// walkthrough that produces it, and [googleSignInConfigured], which the
/// add-account screen checks so an unconfigured build explains itself.
const googleClientId = String.fromEnvironment(
  'GOOGLE_CLIENT_ID',
  defaultValue: _registeredClientId,
);

/// The MyEmail client in Ron's Google Cloud project (myemail-509715),
/// created 25 September 2026. Android type, tied to the release signing
/// key, with custom URI schemes enabled.
const _registeredClientId =
    '405275087615-atj0c35i92g4v34bthoqau2erhfh3mlu.apps.googleusercontent.com';

/// The desktop client's secret, which goes with [googleClientId] on every
/// token request.
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
