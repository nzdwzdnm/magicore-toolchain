# magicore-toolchain

Bundled CLI toolchain (`uv` / `node` / `npm` / `npx` / `ripgrep` / `jq`)
consumed by [magicore-next](https://github.com/nzdwzdnm/magicore-next)
installers as fixed, sha256-pinned per-platform tarballs.

This repo only ships **release artifacts**: the `magicore-next` build
pipeline downloads them, embeds them next to the daemon binary, and the
desktop installer copies them to `~/.magicore/runtime/tools/<version>/`
on first launch.

## Layout

```
manifests/<version>/manifest.yaml      Authoritative version + sha256 list
scripts/fetch-and-pack.sh              Downloads upstream binaries for all
                                       five platforms, verifies sha256, and
                                       repackages into toolchain-<v>-<plat>.tar.zst
```

## Release naming

```
toolchain-v<MAJOR>.<MINOR>.<PATCH>-<goos>-<goarch>.tar.zst
manifest.json   (sidecar with sha256 of every tarball)
```

`<goos>-<goarch>` ∈ { linux-amd64, linux-arm64, darwin-amd64, darwin-arm64, windows-amd64 }.

## Per-platform contents

After unpacking each tarball into `~/.magicore/runtime/tools/<version>/`:

```
bin/
  uv          uv 0.5.10
  uvx         (alias)
  node        node 22.11.0
  npm         (shim into lib/node_modules/npm/)
  npx
  rg          ripgrep 14.1.1
  jq          jq 1.7.1
lib/node_modules/npm/...     (full npm tree; required for npm/npx to work)
manifest.json                 (per-tool upstream version + sha256 + relative path)
```

Windows variants append `.exe` / `.cmd` as appropriate.

## Versioning policy

A toolchain `vX.Y.Z` is a fixed bundle. Magicore-next pins to exactly one
toolchain version per release (injected via `-X buildinfo.ToolchainManifestVersion`).
Independent toolchain upgrades on installed hosts are NOT supported by design.

## Why a separate repo

The bundled binaries are ~325 MB across five platforms. GitHub Releases
storage and bandwidth are unmetered; LFS in the main repo is not. Keeping
the artifacts out of `magicore-next`'s git history also keeps clone size
small for contributors who do not need to rebuild the toolchain.
