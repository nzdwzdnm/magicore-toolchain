#!/usr/bin/env bash
# Downloads upstream toolchain binaries for all five target platforms,
# verifies sha256, and emits per-platform tar.zst tarballs ready for
# `gh release upload`.
#
# Usage:
#   scripts/fetch-and-pack.sh <toolchain-version>
#
# Reads:   manifests/<version>/manifest.yaml
# Writes:  dist/toolchain-<version>-<goos>-<goarch>.tar.zst
#          dist/manifest.json   (sidecar; sha256 of each tarball)
#
# Requires: bash 4+, curl, sha256sum, tar (with zstd support), unzip,
#           xz, yq (mikefarah), jq, zstd.
#
# Environment overrides:
#   FETCH_CACHE=/path  override download cache (default: dist/.cache)
#   PLATFORMS=...      space-separated subset (default: all five)
set -euo pipefail

VERSION="${1:?usage: fetch-and-pack.sh <toolchain-version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${ROOT}/manifests/${VERSION}/manifest.yaml"
DIST="${ROOT}/dist"
CACHE="${FETCH_CACHE:-${DIST}/.cache}"
PLATFORMS="${PLATFORMS:-linux-amd64 linux-arm64 darwin-amd64 darwin-arm64 windows-amd64}"

[[ -f "$MANIFEST" ]] || { echo "missing $MANIFEST" >&2; exit 1; }
mkdir -p "$DIST" "$CACHE"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
for c in curl sha256sum tar unzip xz yq jq zstd; do need "$c"; done

# fetch_one <url> <expected-sha256> <out-path>
fetch_one() {
  local url="$1" want="$2" out="$3"
  if [[ -f "$out" ]] && [[ "$(sha256sum "$out" | awk '{print $1}')" == "$want" ]]; then
    return 0
  fi
  curl -fsSL --retry 3 -o "$out" "$url"
  local got
  got="$(sha256sum "$out" | awk '{print $1}')"
  if [[ "$got" != "$want" ]]; then
    echo "sha256 mismatch for $url: want=$want got=$got" >&2
    rm -f "$out"
    exit 1
  fi
}

pack_platform() {
  local plat="$1"
  local stage="${DIST}/.stage/${plat}"
  rm -rf "$stage"
  mkdir -p "${stage}/bin"

  for tool in $(yq -r '.tools | keys | .[]' "$MANIFEST"); do
    local url want
    url="$(yq -r ".tools.${tool}.platforms.\"${plat}\".url" "$MANIFEST")"
    want="$(yq -r ".tools.${tool}.platforms.\"${plat}\".sha256" "$MANIFEST")"
    [[ "$url" != "null" ]] || { echo "$tool has no $plat entry" >&2; exit 1; }
    [[ "$want" != "TODO" ]] || { echo "TODO sha for $tool/$plat" >&2; exit 1; }

    local fname="${tool}-${plat}.${url##*.}"
    [[ "${url##*/}" =~ \.tar\.gz$ ]] && fname="${tool}-${plat}.tar.gz"
    [[ "${url##*/}" =~ \.tar\.xz$ ]] && fname="${tool}-${plat}.tar.xz"
    [[ "${url##*/}" =~ \.zip$ ]]    && fname="${tool}-${plat}.zip"

    local cached="${CACHE}/${VERSION}/${tool}-${plat}-${fname}"
    mkdir -p "$(dirname "$cached")"
    fetch_one "$url" "$want" "$cached"

    # Unpack into stage. Strategy depends on suffix.
    case "$fname" in
      *.tar.gz) tar -xzf "$cached" -C "$stage" ;;
      *.tar.xz) tar -xJf "$cached" -C "$stage" ;;
      *.zip)    unzip -q -o "$cached" -d "$stage" ;;
      *)        # single binary (e.g. jq)
                local bn
                bn="$(yq -r ".tools.${tool}.binaries[0]" "$MANIFEST")"
                [[ "$plat" == windows-* ]] && bn="${bn}.exe"
                cp "$cached" "${stage}/bin/${bn}"
                chmod +x "${stage}/bin/${bn}"
                ;;
    esac
  done

  # NOTE: post-extract layout normalisation is tool-specific; the real
  # implementation will move uv binaries into bin/, set up node symlinks,
  # and trim docs/. Stub here so the script is end-to-end runnable for
  # the smoke release; replace with the production layout-walker before
  # cutting v1.0.0 final.

  local out="${DIST}/toolchain-${VERSION}-${plat}.tar.zst"
  tar -I 'zstd -19' -cf "$out" -C "$stage" .
  local sha
  sha="$(sha256sum "$out" | awk '{print $1}')"
  echo "{\"platform\":\"${plat}\",\"file\":\"$(basename "$out")\",\"sha256\":\"${sha}\"}"
}

results="["
first=1
for plat in $PLATFORMS; do
  echo ">> packing $plat" >&2
  entry="$(pack_platform "$plat")"
  if [[ $first -eq 1 ]]; then first=0; else results+=","; fi
  results+="$entry"
done
results+="]"

echo "$results" | jq --arg v "$VERSION" '{toolchain_version:$v, artifacts:.}' > "${DIST}/manifest.json"
echo ">> wrote ${DIST}/manifest.json"
