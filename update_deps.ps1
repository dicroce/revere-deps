<#
.SYNOPSIS
    Package Revere's Windows native dependencies and publish them as GitHub
    Release assets, then regenerate manifest.json.

.DESCRIPTION
    revere-deps holds NO binaries in git -- only this script and the manifest.
    The actual dependency bytes live as assets on a GitHub Release of this repo.

    This script reads the dependency trees from the same *_TOP_DIR environment
    variables Revere itself uses (overridable per-dep with the -*Dir params),
    zips each one whole (no curation), uploads them to a release tag, and writes
    a manifest.json that pins exactly what was uploaded (version, sha256, url).

    Revere's CI reads manifest.json, restores via actions/cache keyed on
    DepsVersion, and on a cache miss downloads each asset and verifies its
    sha256 before trusting it.

.EXAMPLE
    # First publish of everything to a new deps version:
    .\update_deps.ps1 -DepsVersion windows-deps-v1

.EXAMPLE
    # Re-package just FFmpeg into a new deps version (others copied from prev manifest):
    .\update_deps.ps1 -DepsVersion windows-deps-v2 -Only ffmpeg

.EXAMPLE
    # Build the zips + hashes locally without touching GitHub (dry run):
    .\update_deps.ps1 -DepsVersion windows-deps-v1 -SkipUpload
#>
[CmdletBinding()]
param(
    # Release tag on the deps repo that these assets attach to. Bump this each
    # time you change any dependency; Revere pins this string.
    [Parameter(Mandatory = $true)]
    [string]$DepsVersion,

    # owner/repo that hosts the dependency release assets.
    [string]$Repo = "dicroce/revere-deps",

    # Restrict the run to a subset of deps (default: all four). Others are
    # carried forward unchanged from the previous manifest.json if present.
    [ValidateSet("opencv", "gstreamer", "ffmpeg", "ncnn")]
    [string[]]$Only,

    # Per-dep source directory overrides (default: the matching *_TOP_DIR env var).
    [string]$OpenCvDir    = $env:OPENCV_TOP_DIR,
    [string]$GStreamerDir = $env:GST_TOP_DIR,
    [string]$FFmpegDir    = $env:FFMPEG_TOP_DIR,
    [string]$NcnnDir      = $env:NCNN_TOP_DIR,

    # Build zips + compute hashes but skip the GitHub release upload.
    [switch]$SkipUpload,

    # Re-zip even if a staged zip already exists (default: reuse it). Reusing the
    # existing zip makes upload retries fast and avoids re-zipping huge trees.
    [switch]$Force,

    # Where to stage the built zips before upload.
    [string]$WorkDir = (Join-Path $PSScriptRoot "_work")
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot     = $PSScriptRoot
$ManifestPath = Join-Path $RepoRoot "manifest.json"

# -- Dependency table ---------------------------------------------------------
# Version is an informational label baked into the manifest. It defaults to the
# source folder name; edit here (or rely on the folder name) to record the real
# upstream version (e.g. "4.12.0").
$Deps = [ordered]@{
    opencv    = @{ Dir = $OpenCvDir;    Version = $null }
    gstreamer = @{ Dir = $GStreamerDir; Version = $null }
    ffmpeg    = @{ Dir = $FFmpegDir;    Version = $null }
    ncnn      = @{ Dir = $NcnnDir;      Version = $null }
}

$targets = if ($Only) { $Only } else { @($Deps.Keys) }

# -- Load previous manifest so un-touched deps carry forward ------------------
$prev = $null
if (Test-Path $ManifestPath) {
    $prev = Get-Content $ManifestPath -Raw | ConvertFrom-Json
}

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

# Start from previous dep entries, then overwrite the ones we rebuild.
$manifestDeps = [ordered]@{}
if ($prev -and $prev.deps) {
    foreach ($p in $prev.deps.PSObject.Properties) { $manifestDeps[$p.Name] = $p.Value }
}

$built = @()

foreach ($name in $targets) {
    $dep = $Deps[$name]
    $dir = $dep.Dir

    if ([string]::IsNullOrWhiteSpace($dir)) {
        throw "No source directory for '$name'. Set the matching *_TOP_DIR env var or pass -$($name)Dir."
    }
    if (-not (Test-Path $dir)) {
        throw "Source directory for '$name' does not exist: $dir"
    }
    $dir = (Resolve-Path $dir).Path.TrimEnd('\')

    $version = if ($dep.Version) { $dep.Version } else { Split-Path $dir -Leaf }
    $zipName = "$name-win64.zip"
    $zipPath = Join-Path $WorkDir $zipName

    Write-Host "==> Packaging $name" -ForegroundColor Cyan
    Write-Host "    source : $dir"
    Write-Host "    version: $version"

    if ((Test-Path $zipPath) -and -not $Force) {
        Write-Host "    reusing existing zip (pass -Force to re-zip)" -ForegroundColor Yellow
    } else {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

        # Zip the tree WITHOUT the base directory, so the zip root holds bin/include/
        # x64/... directly. CI extracts to deps\<name> and sets *_TOP_DIR there.
        Write-Host "    zipping (this can take a while for large trees)..."
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $dir, $zipPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false)
    }

    $sha  = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
    $size = (Get-Item $zipPath).Length
    Write-Host ("    zip    : {0} ({1:N0} MB)" -f $zipName, ($size / 1MB))
    Write-Host "    sha256 : $sha"

    $manifestDeps[$name] = [ordered]@{
        version = $version
        file    = $zipName
        size    = $size
        sha256  = $sha
        url     = "https://github.com/$Repo/releases/download/$DepsVersion/$zipName"
    }
    $built += [pscustomobject]@{ Name = $name; ZipPath = $zipPath }
}

# -- Upload -------------------------------------------------------------------
if (-not $SkipUpload) {
    # Ensure the release exists (create if missing), then upload/replace assets.
    $exists = $true
    try { gh release view $DepsVersion --repo $Repo *> $null } catch { $exists = $false }
    if (-not $?) { $exists = $false }

    if (-not $exists) {
        Write-Host "==> Creating release $DepsVersion on $Repo" -ForegroundColor Cyan
        gh release create $DepsVersion --repo $Repo --title $DepsVersion `
            --notes "Revere Windows dependency bundle $DepsVersion" --latest=false
        if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)" }
    }

    foreach ($b in $built) {
        Write-Host "==> Uploading $($b.Name)" -ForegroundColor Cyan
        gh release upload $DepsVersion $b.ZipPath --repo $Repo --clobber
        if ($LASTEXITCODE -ne 0) { throw "gh release upload failed for $($b.Name) (exit $LASTEXITCODE)" }
    }
} else {
    Write-Host "==> -SkipUpload set; not touching GitHub." -ForegroundColor Yellow
}

# -- Write manifest -----------------------------------------------------------
$manifest = [ordered]@{
    deps_version = $DepsVersion
    repo         = $Repo
    deps         = $manifestDeps
}
# Write BOM-less UTF-8 (Set-Content -Encoding utf8 emits a BOM on PS 5.1, which
# trips json.load and other parsers in CI).
$json = $manifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($ManifestPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "==> Wrote $ManifestPath (deps_version=$DepsVersion)" -ForegroundColor Green
Write-Host "    Commit manifest.json so CI picks up the new pins." -ForegroundColor Green
