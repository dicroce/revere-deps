# revere-deps

Prebuilt Windows native dependencies for building [Revere](https://github.com/dicroce/revere) in CI.

This repo contains **no binaries in git** — only [`update_deps.ps1`](update_deps.ps1)
and [`manifest.json`](manifest.json). The actual dependency bytes live as
**GitHub Release assets** on this repo, one zip per dependency.

## Why this exists

Revere links against OpenCV, GStreamer, FFmpeg, and (optionally) NCNN. Fetching
these from their upstream sites in CI is slow and unreliable (variable
throughput, downtime, mutable "latest" URLs). Hosting pinned copies here gives
CI a fast, dependable, reproducible source.

OpenCV is the **stock** build — Revere needs only core modules (MOG2 lives in
`opencv_video`, not contrib), so no custom contrib build is required.

## How it works

```
update_deps.ps1   -> zips each *_TOP_DIR tree, uploads as release assets,
                     writes manifest.json with version + sha256 + url
manifest.json     -> pins exactly what was published (committed to git)
Revere CI         -> reads manifest, actions/cache keyed on deps_version,
                     on miss downloads each asset and verifies sha256
```

The zips are packaged **whole-tree, without a base directory**: the zip root
holds `bin/`, `include/`, `x64/`, etc. directly. CI extracts each to
`deps\<name>` and points the matching `*_TOP_DIR` env var there.

## Publishing / updating deps

Run on a Windows dev box that has the deps installed and `*_TOP_DIR` env vars set
(same ones Revere uses). Requires the `gh` CLI authenticated with push access.

```powershell
# First publish of all four deps:
.\update_deps.ps1 -DepsVersion windows-deps-v1

# Bump just FFmpeg into a new deps version (others carried forward):
.\update_deps.ps1 -DepsVersion windows-deps-v2 -Only ffmpeg

# Dry run: build zips + hashes locally, no upload:
.\update_deps.ps1 -DepsVersion windows-deps-v1 -SkipUpload
```

Then **commit `manifest.json`** and bump the `deps_version` pin in Revere's CI.

## Dependency sources / licensing

These are redistributions of third-party libraries, all under permissive
licenses (OpenCV: Apache-2.0; FFmpeg: LGPL/GPL per build; GStreamer: LGPL;
NCNN: BSD-3). Each zip retains the upstream `LICENSE`/`COPYING` files.
