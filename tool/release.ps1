# Build a release, stamp it, and write the manifest the app checks.
#
#   pwsh tool/release.ps1 -Version 1.1.0 -Notes "Conversations and drafts."
#
# What it does, in order:
#   1. Refuses to run on a dirty tree or without a keystore, because a release
#      you cannot reproduce from a commit is not a release.
#   2. Bumps the version and build number in pubspec.yaml.
#   3. Builds a signed arm64 APK.
#   4. Copies it to the release folder under a FIXED name, so the download URL
#      in the manifest never changes.
#   5. Writes latest.json beside it with the real size of the file it just
#      built, read from disk rather than guessed.
#
#   6. Commits the bump, tags it, pushes, and publishes the GitHub release.
#   7. Checks the published manifest is actually reachable before saying so.
#
# The manifest is uploaded after the APK on purpose. A manifest announcing a
# build that is not there yet points every phone at a 404.
#
# Authentication reuses the GitHub credential git already has on this machine,
# so there is no second login and no token stored anywhere new. It is read at
# the moment it is needed and never written down.

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

    # Where the phone downloads from. GitHub resolves this to the newest
    # published release, so it stays correct as versions come and go.
    [string]$BaseUrl = 'https://github.com/rdvir10/MyEmail/releases/latest/download',

    # owner/name of the repository the release is published to.
    [string]$Repo = 'rdvir10/MyEmail',

    # Build and stage everything, but stop short of publishing. For checking
    # what a release would contain without putting it in front of a device.
    [switch]$StageOnly
)

$ErrorActionPreference = 'Stop'
# repoRoot, not repo. PowerShell variable names are case-insensitive, so a
# local $repo silently IS the $Repo parameter, and gh then gets handed a
# filesystem path where it wants owner/name.
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

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

# --- 3. build -------------------------------------------------------------
$env:PATH = "$env:USERPROFILE\tools\flutter\bin;$env:PATH"
& flutter build apk --release --target-platform android-arm64
if ($LASTEXITCODE -ne 0) { throw "The build failed. pubspec.yaml has been bumped; revert it or fix and rerun." }

$built = "$repoRoot\build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $built)) { throw "The build reported success but produced no APK." }

# --- 4. publish under a fixed name ---------------------------------------
New-Item -ItemType Directory -Force $OutDir | Out-Null
# Fixed, because the manifest URL above is built from it and must not move.
$apkName = 'myemail-arm64.apk'
$apkPath = Join-Path $OutDir $apkName
Copy-Item $built $apkPath -Force

# --- 5. the manifest, with the size read from the file ------------------
$size = (Get-Item $apkPath).Length
$url = if ($BaseUrl) { "$($BaseUrl.TrimEnd('/'))/$apkName" } else { "REPLACE_WITH_PUBLIC_URL/$apkName" }

$manifest = [ordered]@{
    version   = $Version
    build     = $build
    minBuild  = $MinBuild
    apk       = $url
    sizeBytes = $size
}
if ($Notes) { $manifest.notes = $Notes }

$manifestPath = Join-Path $OutDir 'latest.json'
$manifest | ConvertTo-Json -Depth 3 | Set-Content -Path $manifestPath -Encoding utf8

Write-Host ""
Write-Host "Built and staged:" -ForegroundColor Green
Write-Host "  $apkPath  ($([math]::Round($size / 1MB, 1)) MB)"
Write-Host "  $manifestPath"
if (-not $BaseUrl) {
    Write-Host ""
    Write-Host "latest.json has a placeholder URL. Pass -BaseUrl once the release host exists." -ForegroundColor Yellow
}
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
if ($LASTEXITCODE -ne 0) { throw "Could not push. Nothing was published, so nothing is half-done on GitHub." }

# The credential git already holds, read at the moment it is needed. gh's own
# login refuses this token for want of a scope it does not need here, so it is
# handed over directly instead and never stored.
$cred = "protocol=https`nhost=github.com`n`n" | & git credential fill
$line = $cred | Select-String '^password='
if (-not $line) {
    throw "No stored GitHub credential. Run 'git push' once to create one, then rerun."
}
$token = $line.ToString() -replace '^password=', ''

$gh = Join-Path $env:USERPROFILE 'tools\gh\bin\gh.exe'
if (-not (Test-Path $gh)) { throw "The GitHub CLI is not at $gh." }

$env:GH_TOKEN = $token
try {
    # The APK is listed first so it uploads first: a manifest naming a build
    # that is not there yet points every phone at a 404.
    & $gh release create "v$Version" $apkPath $manifestPath --repo $Repo --title $Version --notes $Notes
    if ($LASTEXITCODE -ne 0) {
        throw "The release was not published. The tag is already pushed, so rerun the gh command alone rather than the whole script."
    }
} finally {
    $env:GH_TOKEN = $null
}

# --- 7. prove it is reachable --------------------------------------------
# Not a formality. A release can exist while its assets are still processing,
# and a phone checking in that window is told there is nothing new.
$manifestUrl = "$($BaseUrl.TrimEnd('/'))/latest.json"
$live = Invoke-RestMethod $manifestUrl
if ($live.build -ne $build) {
    throw "Published, but $manifestUrl still reports build $($live.build). Check the release assets."
}

Write-Host ""
Write-Host "Published $Version (build $build), and verified live." -ForegroundColor Green
Write-Host "  https://github.com/$Repo/releases/tag/v$Version"
Write-Host ""
Write-Host "Devices on an older build will see it at their next check." -ForegroundColor Cyan
