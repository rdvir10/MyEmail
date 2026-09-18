/// The Application (client) ID of the Microsoft app registration.
///
/// This is not a secret. A public client — a phone app, a desktop app, a CLI —
/// has nowhere to keep a secret, so Microsoft's protocol for them does not use
/// one, and the client ID is deliberately safe to ship inside the APK. It
/// names the registration; it grants nothing on its own.
///
/// It is empty until an app registration exists. See
/// docs/microsoft-app-registration.md, which is the five-minute walkthrough
/// that produces the value, and [microsoftSignInConfigured], which is what the
/// add-account screen checks so an unconfigured build explains itself rather
/// than failing at the first network call.
///
/// The `--dart-define` override exists so a build can point at a different
/// registration without editing source, which is how a second registration
/// could be tested without disturbing the one people are signed in to.
const microsoftClientId = String.fromEnvironment(
  'MICROSOFT_CLIENT_ID',
  defaultValue: _registeredClientId,
);

/// The MyEmail registration in the Myhomestudio tenant, created 17 September
/// 2026. Supported account types are "All Microsoft account users", which is
/// what lets a registration living in a work tenant sign in a personal
/// Outlook.com mailbox; see [MicrosoftOAuth.commonAuthority].
const _registeredClientId = '4b23da8c-34ef-4b5d-a50c-c50796de4d23';

bool get microsoftSignInConfigured => microsoftClientId.isNotEmpty;
