<#
.SYNOPSIS
    Apply ARM64 patches for the Windows ARM64 build of PiliPlus.

.DESCRIPTION
    Run AFTER `flutter pub get` (ephemeral plugin symlinks must exist)
    and AFTER `lib/scripts/patch.ps1 windows` (Flutter SDK patches).

    Patches applied:
    1. windows/CMakeLists.txt
       - Add /wd4819 to suppress C4819 (non-ASCII characters in source)
    2. media_kit_libs_windows_video/windows/CMakeLists.txt (via .plugin_symlinks)
       - Add an ARM64 branch selecting pre-built ARM64 archives:
         libmpv : zhongfly/mpv-winbuild daily builds (latest resolved at runtime,
                  with a pinned fallback because daily releases get cleaned up)
         ANGLE  : talynone/flutter-windows-ANGLE-OpenGL-ES v1.0.1
       - Replace `cmake -E tar xzf` with `7z x` for archive extraction:
         the ARM64 archives use LZMA2 which older CMake/libarchive bundles
         cannot extract. 7-Zip is preinstalled on GitHub's windows-*-arm
         runners and available on typical Windows dev machines.

    Idempotent: safe to run multiple times.
#>

$ErrorActionPreference = "Stop"

$workspace = $env:GITHUB_WORKSPACE
if (-not $workspace) {
    $workspace = (Get-Location).Path
}

Write-Host "=== Applying ARM64 patches ==="
Write-Host "Workspace: $workspace"

# ----------------------------------------------------------------------------
# Pinned fallbacks (used only if the GitHub API cannot be queried).
# zhongfly/mpv-winbuild keeps only recent daily releases, so prefer resolving
# the newest mpv-dev-aarch64 asset at runtime and fall back to a known-good one.
# ----------------------------------------------------------------------------
$FallbackMpvName = "mpv-dev-aarch64-20260923-git-bdefd6cb42.7z"
$FallbackMpvUrl = "https://github.com/zhongfly/mpv-winbuild/releases/download/2026-09-23-bdefd6cb42/$FallbackMpvName"
$FallbackMpvMd5 = "4a4b8750a42c31a958f5cea886f0cda0"

$AngleName = "ANGLE_WINARM64.7z"
$AngleUrl = "https://github.com/talynone/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/$AngleName"
$AngleMd5 = "b56aaae894ccf6c8ee90b59ee642a787"

# ----------------------------------------------------------------------------
# Resolve the newest mpv-dev-aarch64 asset from zhongfly/mpv-winbuild.
# Downloads it once to a temp file to compute the MD5 that CMake verifies.
# ----------------------------------------------------------------------------
function Resolve-LatestMpvDev {
    param([hashtable]$Headers)

    try {
        $releases = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/zhongfly/mpv-winbuild/releases?per_page=15" `
            -UseBasicParsing -Headers $Headers -TimeoutSec 60

        foreach ($release in $releases) {
            if ($release.draft -or $release.prerelease) { continue }
            $asset = $release.assets |
                Where-Object { $_.name -match '^mpv-dev-aarch64-.*\.7z$' } |
                Select-Object -First 1
            if (-not $asset) { continue }

            $tmp = Join-Path $env:TEMP $asset.name
            if (-not (Test-Path $tmp)) {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing -TimeoutSec 300
            }
            $md5 = (Get-FileHash $tmp -Algorithm MD5).Hash.ToLower()
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            return @{
                Name = $asset.name
                Url  = $asset.browser_download_url
                Md5  = $md5
                Tag  = $release.tag_name
            }
        }
        Write-Warning "No mpv-dev-aarch64 asset found in recent releases."
    }
    catch {
        Write-Warning "Failed to query zhongfly/mpv-winbuild releases: $($_.Exception.Message)"
    }
    return $null
}

$apiHeaders = @{ "User-Agent" = "piliplus-arm64-ci" }
if ($env:GITHUB_TOKEN) {
    $apiHeaders["Authorization"] = "Bearer $env:GITHUB_TOKEN"
}

$mpv = Resolve-LatestMpvDev -Headers $apiHeaders
if ($mpv) {
    Write-Host "Resolved latest ARM64 libmpv: $($mpv.Name) (release $($mpv.Tag))"
} else {
    $mpv = @{
        Name = $FallbackMpvName
        Url  = $FallbackMpvUrl
        Md5  = $FallbackMpvMd5
        Tag  = "pinned"
    }
    Write-Host "Using pinned ARM64 libmpv: $($mpv.Name)"
}

# ----------------------------------------------------------------------------
# Helper: replace a literal block in a file, skip when not found (idempotent).
# ----------------------------------------------------------------------------
function Update-FileContent {
    param(
        [string]$FilePath,
        [string]$OldContent,
        [string]$NewContent,
        [string]$Description
    )
    if (-not (Test-Path $FilePath)) {
        Write-Warning "File not found, skipping: $FilePath ($Description)"
        return $false
    }
    # Normalize line endings (pub-cache git checkouts are often CRLF).
    $content = (Get-Content -Path $FilePath -Raw -Encoding UTF8) -replace "`r`n", "`n"
    $old = $OldContent -replace "`r`n", "`n"
    $new = $NewContent -replace "`r`n", "`n"
    if ($content -notmatch [regex]::Escape($old)) {
        Write-Host "  [SKIP] pattern not found (already patched?): $Description"
        return $false
    }
    $content = $content.Replace($old, $new)
    Set-Content -Path $FilePath -Value $content -Encoding UTF8 -NoNewline
    Write-Host "  [OK] $Description"
    return $true
}

# ----------------------------------------------------------------------------
# 1. windows/CMakeLists.txt: /wd4819
# ----------------------------------------------------------------------------
$null = Update-FileContent `
    -FilePath "$workspace/windows/CMakeLists.txt" `
    -OldContent 'target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")' `
    -NewContent 'target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100" /wd"4819")' `
    -Description "windows/CMakeLists.txt: add /wd4819"

# ----------------------------------------------------------------------------
# 2. media_kit_libs_windows_video CMakeLists.txt (through .plugin_symlinks)
# ----------------------------------------------------------------------------
$libsCmake = "$workspace/windows/flutter/ephemeral/.plugin_symlinks/media_kit_libs_windows_video/windows/CMakeLists.txt"

if (-not (Test-Path $libsCmake)) {
    # Fall back to the pub-cache git checkout if the symlink layout differs.
    $candidate = Get-ChildItem "$env:LOCALAPPDATA\Pub\Cache\git\cache" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "libs\windows\media_kit_libs_windows_video\windows\CMakeLists.txt" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if ($candidate) { $libsCmake = $candidate }
}

if (Test-Path $libsCmake) {
    $libsContent = Get-Content -Path $libsCmake -Raw -Encoding UTF8

    if ($libsContent -match 'windows-arm64') {
        Write-Host "  [SKIP] media_kit_libs_windows_video already patched for ARM64"
    } else {
        $patched = $false

        # --- libmpv block ---
        $oldLibmpv = @'
set(LIBMPV "mpv-dev-x86_64-20260607-git-43b14a4.7z")

# Download URL & MD5 hash of the libmpv archive.
set(LIBMPV_URL "https://github.com/bggRGjQaUbCoE/mpv-winbuild-cmake/releases/download/20260607/${LIBMPV}")
set(LIBMPV_MD5 "b84900bbc6fcb995ca6a24f62bee671f")
'@
        $newLibmpv = @"
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(LIBMPV "$($mpv.Name)")
  set(LIBMPV_URL "$($mpv.Url)")
  set(LIBMPV_MD5 "$($mpv.Md5)")
else()
  set(LIBMPV "mpv-dev-x86_64-20260607-git-43b14a4.7z")
  set(LIBMPV_URL "https://github.com/bggRGjQaUbCoE/mpv-winbuild-cmake/releases/download/20260607/`${LIBMPV}")
  set(LIBMPV_MD5 "b84900bbc6fcb995ca6a24f62bee671f")
endif()
"@
        if (Update-FileContent -FilePath $libsCmake -OldContent $oldLibmpv -NewContent $newLibmpv -Description "libs: ARM64 libmpv ($($mpv.Name))") { $patched = $true }

        # --- ANGLE block ---
        $oldAngle = @'
set(ANGLE "ANGLE.7z")

# Download URL & MD5 hash of the ANGLE archive.
set(ANGLE_URL "https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z")
set(ANGLE_MD5 "e866f13e8d552348058afaafe869b1ed")
'@
        $newAngle = @"
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(ANGLE "$AngleName")
  set(ANGLE_URL "$AngleUrl")
  set(ANGLE_MD5 "$AngleMd5")
else()
  set(ANGLE "ANGLE.7z")
  set(ANGLE_URL "https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z")
  set(ANGLE_MD5 "e866f13e8d552348058afaafe869b1ed")
endif()
"@
        if (Update-FileContent -FilePath $libsCmake -OldContent $oldAngle -NewContent $newAngle -Description "libs: ARM64 ANGLE ($AngleName)") { $patched = $true }

        # --- extraction: cmake tar -> 7z (LZMA2-safe, runner has 7-Zip) ---
        # Only needed when at least one archive was swapped to an ARM64 build.
        if ($patched) {
            $null = Update-FileContent `
                -FilePath $libsCmake `
                -OldContent 'COMMAND "${CMAKE_COMMAND}" -E tar xzf "\"${LIBMPV_ARCHIVE}\""' `
                -NewContent 'COMMAND 7z x -y -o"${LIBMPV_SRC}" "\"${LIBMPV_ARCHIVE}\""' `
                -Description "libs: extract libmpv via 7z"

            $null = Update-FileContent `
                -FilePath $libsCmake `
                -OldContent 'COMMAND "${CMAKE_COMMAND}" -E tar xzf "\"${ANGLE_ARCHIVE}\""' `
                -NewContent 'COMMAND 7z x -y -o"${ANGLE_SRC}" "\"${ANGLE_ARCHIVE}\""' `
                -Description "libs: extract ANGLE via 7z"
        }
    }
} else {
    Write-Warning "media_kit_libs_windows_video CMakeLists.txt not found. Run 'flutter pub get' first."
}

Write-Host "=== ARM64 patches applied ==="
