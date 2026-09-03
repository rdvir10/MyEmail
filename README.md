# MailTree

Outlook-style mail client for Android. Flutter, runs entirely on the device,
no server. Round one is Gmail only.

Planning docs live in OneDrive under `AI Projects/Email client`; `PLAN.md`
there is the source of truth for scope, architecture and milestones.

## Setup

Toolchain is portable, under `%USERPROFILE%\tools` (JDK 17, Android
command-line tools and SDK, Flutter). Flutter version is pinned in `.fvmrc`.

## Signing

Release builds use one shared keystore that is NOT in this repo. Losing it
means no further update can install over the app. See PLAN.md.
