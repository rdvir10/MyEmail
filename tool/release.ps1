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
# The manifest is written last on purpose. A manifest announcing a build that
# is not uploaded yet points every phone at a 404.

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

    # The public base URL the phone will fetch from. The APK name is appended.
    [string]$BaseUrl = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# --- 1. refuse to build something unreproducible --------------------------
if (-not (Test-Path "$repo\android\key.properties")) {
    throw "android/key.properties is missing, so this would be signed with the debug key. Nothing built."
}
$dirty = & git status --porcelain
if ($dirty) {
    throw "The working tree has uncommitted changes. Commit them first, or a released build cannot be traced to a commit.`n$dirty"
}

# --- 2. stamp the version -------------------------------------------------
$pubspec = "$repo\pubspec.yaml"
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

$built = "$repo\build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $built)) { throw "The build reported success but produced no APK." }

# --- 4. publish under a fixed name ---------------------------------------
New-Item -ItemType Directory -Force $OutDir | Out-Null
$apkName = 'mailtree-arm64.apk'
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
Write-Host ""
Write-Host "Next: upload BOTH files, the APK first. A manifest that names a build" -ForegroundColor Yellow
Write-Host "nobody can download points every phone at a 404." -ForegroundColor Yellow
Write-Host ""
Write-Host "Then commit the pubspec bump and tag it:" -ForegroundColor Cyan
Write-Host "  git commit -am `"Release $Version (build $build)`""
Write-Host "  git tag v$Version"
