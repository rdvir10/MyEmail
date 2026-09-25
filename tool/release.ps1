# Build a release, stamp it, and write the manifest the app checks.
#
#   pwsh tool/release.ps1 -Version 1.1.0 -Notes "Conversations and drafts."
#
# What it does, in order:
#   1. Refuses to run on a dirty tree or without a keystore, because a release
#      you cannot reproduce from a commit is not a release.
#   2. Bumps the version and build number in pubspec.yaml.
#   3. Builds a signed arm64 APK.
#   4. Copies it to the release folder as myemail-arm64.apk.
#   5. Writes latest.json beside it with the real size of the file it just
#      built, read from disk rather than guessed, and a link to the APK in
#      this release by its tag.
#
#   6. Commits the bump, tags it, pushes, and publishes the GitHub release.
#   7. Checks the published manifest is actually reachable before saying so.
#
#   pwsh tool/release.ps1 -Version 1.1.0 -PublishOnly
#
# does 6's publishing and 7 alone, for a version already built with
# -StageOnly, committed, tagged and pushed.
#
# The manifest and the APK go up in one gh command, which uploads them side
# by side and keeps the release a draft until both are there. A draft is not
# what releases/latest points at, so no phone sees a manifest announcing a
# build that is not there yet.
#
# The phone reads the manifest from releases/latest, and the APK from the
# release the manifest belongs to (releases/download/v<version>). A "latest"
# link for the APK meant a release published between the check and the tap
# on Download got installed instead: a build the screen did not name, whose
# minBuild nobody had checked.
#
# Publishing uses the GitHub CLI's own login (`gh auth login`, once, as the
# account that owns the repository). Git's credentials are not touched, so
# which account git pushes with has no bearing on where this publishes.

[CmdletBinding()]
param(
    # Shown to the user. The build number is derived and always increases.
    [Parameter(Mandatory = $true)][string]$Version,

    # One line on what changed. Omit it if nothing is worth saying.
    [string]$Notes = '',

    # The oldest build allowed to update straight to this one. Raise it only
    # when a migration genuinely cannot run from further back.
    [int]$MinBuild = 0,

    # Where the APK and latest.json are staged before being published.
    [string]$OutDir = "$env:USERPROFILE\OneDrive\AI Projects\Email client\builds\release",

    # Where the phone looks for latest.json. GitHub resolves this to the
    # newest published release, so it stays correct as versions come and go.
    # The APK is not fetched from here: see the top of this file.
    [string]$BaseUrl = 'https://github.com/rdvir10/MyEmail/releases/latest/download',

    # owner/name of the repository the release is published to.
    [string]$Repo = 'rdvir10/MyEmail',

    # Build and stage everything, but stop short of publishing. For checking
    # what a release would contain without putting it in front of a device.
    [switch]$StageOnly,

    # Publish what is already staged, for a version already committed, tagged
    # and pushed: the half of a release that could not be done at the time.
    [switch]$PublishOnly
)

$ErrorActionPreference = 'Stop'
# repoRoot, not repo. PowerShell variable names are case-insensitive, so a
# local $repo silently IS the $Repo parameter, and gh then gets handed a
# filesystem path where it wants owner/name.
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$apkName = 'myemail-arm64.apk'
$apkPath = Join-Path $OutDir $apkName
$manifestPath = Join-Path $OutDir 'latest.json'

# Steps 6's publishing and 7: the GitHub release, then proof it is live.
function Publish-Release([int]$Build, [string]$Notes) {
    $gh = Join-Path $env:USERPROFILE 'tools\gh\bin\gh.exe'
    if (-not (Test-Path $gh)) { throw "The GitHub CLI is not at $gh." }

    # Checked up front so a missing login fails here, with the fix named, rather
    # than halfway through an upload.
    & $gh auth status --hostname github.com *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "The GitHub CLI is not logged in. Run '$gh auth login' once, as the owner of $Repo, then rerun."
    }

    # One command for both files: gh uploads them together and publishes the
    # release only once both are up, so the manifest never goes live ahead
    # of the APK it names.
    & $gh release create "v$Version" $apkPath $manifestPath --repo $Repo --title $Version --notes $Notes
    if ($LASTEXITCODE -ne 0) {
        throw ("The release was not published. The tag is already pushed, so do not rerun the whole script. " +
            "If gh left a draft release v$Version behind, delete it with '$gh release delete v$Version --repo $Repo --yes' " +
            "(the tag stays), then run: pwsh tool/release.ps1 -Version $Version -PublishOnly")
    }

    # --- 7. prove it is reachable --------------------------------------------
    # Not a formality. A release can exist while its assets are still processing,
    # and a phone checking in that window is told there is nothing new.
    $manifestUrl = "$($BaseUrl.TrimEnd('/'))/latest.json"
    $live = Invoke-RestMethod $manifestUrl
    if ($live.build -ne $build) {
        throw "Published, but $manifestUrl still reports build $($live.build). Check the release assets."
    }
}

if ($PublishOnly) {
    if (-not (Test-Path $apkPath) -or -not (Test-Path $manifestPath)) {
        throw "Nothing is staged in $OutDir. Build it with -StageOnly first."
    }
    $staged = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($staged.version -ne $Version) {
        throw "What is staged is $($staged.version), not $Version."
    }
    if (-not (& git tag --list "v$Version")) {
        throw "There is no tag v$Version. Commit, tag and push the release first."
    }
    Publish-Release -Build $staged.build -Notes ($(if ($Notes) { $Notes } else { $staged.notes }))
    Write-Host ""
    Write-Host "Published $Version (build $($staged.build)), and verified live." -ForegroundColor Green
    Write-Host "  https://github.com/$Repo/releases/tag/v$Version"
    return
}

# --- 1. refuse to build something unreproducible --------------------------
if (-not (Test-Path "$repoRoot\android\key.properties")) {
    throw "android/key.properties is missing, so this would be signed with the debug key. Nothing built."
}
$dirty = & git status --porcelain
if ($dirty) {
    throw "The working tree has uncommitted changes. Commit them first, or a released build cannot be traced to a commit.`n$dirty"
}

# --- 2. stamp the version -------------------------------------------------
$pubspec = "$repoRoot\pubspec.yaml"
$content = Get-Content $pubspec -Raw
if ($content -notmatch '(?m)^version:\s*([0-9.]+)\+(\d+)\s*$') {
    throw "Could not find a 'version: x.y.z+n' line in pubspec.yaml."
}
$build = [int]$Matches[2] + 1
$content = $content -replace '(?m)^version:\s*[0-9.]+\+\d+\s*$', "version: $Version+$build"
Set-Content -Path $pubspec -Value $content -NoNewline
Write-Host "Version $Version, build $build" -ForegroundColor Cyan

# --- 2b. the documents --------------------------------------------------
# Regenerated with the version just stamped, so About never describes an
# older build than the one it is in. They went ten releases out of date
# because this was a step somebody had to remember.
& python "$repoRoot\tool\docs_to_html.py"
if ($LASTEXITCODE -ne 0) { throw "Could not regenerate the documents. pubspec.yaml has been bumped; run 'git checkout -- pubspec.yaml assets/help' before running this again." }

# --- 3. build -------------------------------------------------------------
# The Google sign-in's client ID and secret come from a file git ignores,
# like the signing key: GitHub's secret scanning refuses a push that
# carries them. A build without the file has no Google sign-in, and says
# so on the add-account screen, so the file is required here.
$googleProperties = "$repoRoot\android\google-oauth.properties"
if (-not (Test-Path $googleProperties)) {
    throw "android/google-oauth.properties is missing, so this build would have no Google sign-in. See docs/google-sign-in.md. Run 'git checkout -- pubspec.yaml assets/help' before running this again."
}
$google = @{}
Get-Content $googleProperties | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z]+)\s*=\s*(.+?)\s*$') { $google[$Matches[1]] = $Matches[2] }
}
if (-not $google.clientId -or -not $google.clientSecret) {
    throw "android/google-oauth.properties needs clientId and clientSecret. Run 'git checkout -- pubspec.yaml assets/help' before running this again."
}
$env:PATH = "$env:USERPROFILE\tools\flutter\bin;$env:PATH"
& flutter build apk --release --target-platform android-arm64 `
    --dart-define="GOOGLE_CLIENT_ID=$($google.clientId)" `
    --dart-define="GOOGLE_CLIENT_SECRET=$($google.clientSecret)"
# A rerun refuses the tree this leaves (the bump and the regenerated
# documents), so the way back is said in full.
if ($LASTEXITCODE -ne 0) { throw "The build failed. pubspec.yaml and the documents have been changed; run 'git checkout -- pubspec.yaml assets/help', fix the problem, then run this again." }

$built = "$repoRoot\build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $built)) { throw "The build reported success but produced no APK." }

# --- 4. stage it ----------------------------------------------------------
New-Item -ItemType Directory -Force $OutDir | Out-Null
Copy-Item $built $apkPath -Force

# --- 5. the manifest, with the size read from the file ------------------
$size = (Get-Item $apkPath).Length
# This release's own copy, by its tag, never releases/latest: see the top of
# this file.
$url = "https://github.com/$Repo/releases/download/v$Version/$apkName"

$manifest = [ordered]@{
    version   = $Version
    build     = $build
    minBuild  = $MinBuild
    apk       = $url
    sizeBytes = $size
}
if ($Notes) { $manifest.notes = $Notes }

$manifest | ConvertTo-Json -Depth 3 | Set-Content -Path $manifestPath -Encoding utf8

Write-Host ""
Write-Host "Built and staged:" -ForegroundColor Green
Write-Host "  $apkPath  ($([math]::Round($size / 1MB, 1)) MB)"
Write-Host "  $manifestPath"
if ($StageOnly) {
    Write-Host ""
    Write-Host "Staged only. Nothing committed, tagged or published." -ForegroundColor Yellow
    return
}

# --- 6. commit, tag, push, publish ---------------------------------------
& git commit -q -am "Release $Version (build $build)"
if ($LASTEXITCODE -ne 0) { throw "Could not commit the version bump." }
& git tag "v$Version"
if ($LASTEXITCODE -ne 0) { throw "Could not tag v$Version. Does that tag already exist?" }
& git push -q origin main --tags
if ($LASTEXITCODE -ne 0) { throw "Could not push. Nothing was published, so nothing is half-done on GitHub. The release is committed and tagged here: push with 'git push origin main --tags', then run: pwsh tool/release.ps1 -Version $Version -PublishOnly" }

Publish-Release -Build $build -Notes $Notes

Write-Host ""
Write-Host "Published $Version (build $build), and verified live." -ForegroundColor Green
Write-Host "  https://github.com/$Repo/releases/tag/v$Version"
Write-Host ""
Write-Host "Devices on an older build will see it at their next check." -ForegroundColor Cyan
