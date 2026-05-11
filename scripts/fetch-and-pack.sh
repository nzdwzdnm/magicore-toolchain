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

is_windows_platform() {
  [[ "$1" == windows-* ]]
}

executable_name() {
  local name="$1" plat="$2"
  if is_windows_platform "$plat"; then
    printf '%s.exe\n' "$name"
    return
  fi
  printf '%s\n' "$name"
}

# fetch_one <url> <expected-sha256> <out-path>
fetch_one() {
  local url="$1" want="$2" out="$3"
  if [[ -f "$out" ]] && [[ "$(sha256sum "$out" | awk '{print $1}')" == "$want" ]]; then
    return 0
  fi
  local tmp="${out}.tmp"
  rm -f "$tmp"
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$tmp" "$url"
  local got
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$got" != "$want" ]]; then
    echo "sha256 mismatch for $url: want=$want got=$got" >&2
    rm -f "$tmp"
    exit 1
  fi
  mv "$tmp" "$out"
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
                bn="$(executable_name "$bn" "$plat")"
                cp "$cached" "${stage}/bin/${bn}"
                chmod +x "${stage}/bin/${bn}"
                ;;
    esac
  done

  normalize_platform "$stage" "$plat"
  write_stage_manifest "$stage" "$plat"

  local out="${DIST}/toolchain-${VERSION}-${plat}.tar.zst"
  tar -I 'zstd -19' -cf "$out" -C "$stage" .
  local sha
  sha="$(sha256sum "$out" | awk '{print $1}')"
  echo "{\"platform\":\"${plat}\",\"file\":\"$(basename "$out")\",\"sha256\":\"${sha}\"}"
}

link_or_copy() {
  local src="$1" dst="$2" plat="$3"
  mkdir -p "$(dirname "$dst")"
  rm -f "$dst"
  if is_windows_platform "$plat"; then
    cp "$src" "$dst"
    chmod +x "$dst"
    return
  fi
  ln -s "$(realpath --relative-to="$(dirname "$dst")" "$src")" "$dst"
}

first_match() {
  local root="$1"
  shift
  find "$root" \
    -not -path "$root/bin/*" \
    -not -path "*/corepack/shims/*" \
    \( "$@" \) \
    -print -quit
}

normalize_platform() {
  local stage="$1" plat="$2"
  mkdir -p "$stage/bin"

  rm -rf \
    "$stage"/node-*/include \
    "$stage"/node-*/share \
    "$stage"/ripgrep-*/complete \
    "$stage"/ripgrep-*/doc
  rm -f \
    "$stage"/node-*/README.md \
    "$stage"/ripgrep-*/README.md \
    "$stage"/ripgrep-*/CHANGELOG.md

  if is_windows_platform "$plat"; then
    local uv uvx node npm npx rg
    uv="$(first_match "$stage" -type f -name 'uv.exe')"
    uvx="$(first_match "$stage" -type f -name 'uvx.exe')"
    node="$(first_match "$stage" -type f -name 'node.exe')"
    npm="$(first_match "$stage" -type f -name 'npm.cmd')"
    npx="$(first_match "$stage" -type f -name 'npx.cmd')"
    rg="$(first_match "$stage" -type f -name 'rg.exe')"

    [[ -n "$uv" ]] && link_or_copy "$uv" "$stage/bin/uv.exe" "$plat"
    [[ -n "$uvx" ]] && link_or_copy "$uvx" "$stage/bin/uvx.exe" "$plat"
    [[ -n "$node" ]] && link_or_copy "$node" "$stage/bin/node.exe" "$plat"
    [[ -n "$npm" ]] && link_or_copy "$npm" "$stage/bin/npm.cmd" "$plat"
    [[ -n "$npx" ]] && link_or_copy "$npx" "$stage/bin/npx.cmd" "$plat"
    [[ -n "$rg" ]] && link_or_copy "$rg" "$stage/bin/rg.exe" "$plat"
    copy_runtime_paths "$stage" "node"
    return
  fi

  local name found
  for name in uv uvx node rg; do
    found="$(first_match "$stage" \( -type f -o -type l \) -name "$name")"
    [[ -n "$found" ]] && link_or_copy "$found" "$stage/bin/$name" "$plat"
  done

  found="$(first_match "$stage" \( -type f -o -type l \) -path '*/lib/node_modules/npm/bin/npm-cli.js')"
  [[ -n "$found" ]] && link_or_copy "$found" "$stage/bin/npm" "$plat"
  found="$(first_match "$stage" \( -type f -o -type l \) -path '*/lib/node_modules/npm/bin/npx-cli.js')"
  [[ -n "$found" ]] && link_or_copy "$found" "$stage/bin/npx" "$plat"
  copy_runtime_paths "$stage" "node"
  link_node_npm_runtime "$stage"
}

copy_runtime_paths() {
  local stage="$1" tool="$2"
  local pattern
  while IFS= read -r pattern; do
    [[ -n "$pattern" && "$pattern" != "null" ]] || continue
    local matches=()
    mapfile -t matches < <(compgen -G "${stage}/${pattern}" || true)
    local match
    for match in "${matches[@]}"; do
      [[ -e "$match" ]] || continue
      local rel="${match#${stage}/}"
      mkdir -p "$(dirname "${stage}/${rel}")"
    done
  done < <(yq -r ".tools.${tool}.runtime_paths[]?" "$MANIFEST")
}

link_node_npm_runtime() {
  local stage="$1"
  local npm_root
  npm_root="$(first_match "$stage" -type d -path '*/lib/node_modules/npm')"
  [[ -n "$npm_root" ]] || return 0
  local node_root="${npm_root%/lib/node_modules/npm}"
  mkdir -p "${node_root}/bin/node_modules" "${node_root}/node_modules"
  ln -sfn "../lib/node_modules/npm" "${node_root}/node_modules/npm"
  ln -sfn "../../lib/node_modules/npm" "${node_root}/bin/node_modules/npm"
}

write_stage_manifest() {
  local stage="$1" plat="$2"
  local platform_key="${plat/-//}"
  {
    printf 'schema_version: 1\n'
    printf 'version: "%s"\n\n' "$(yq -r '.manifest_version' "$MANIFEST")"
    printf 'tools:\n'
    write_stage_tool "$stage" "$platform_key" "uv" "$(yq -r '.tools.uv.version' "$MANIFEST")" "uv" ""
    write_stage_tool "$stage" "$platform_key" "uvx" "$(yq -r '.tools.uv.version' "$MANIFEST")" "uvx" ""
    write_stage_tool "$stage" "$platform_key" "node" "$(yq -r '.tools.node.version' "$MANIFEST")" "node" ""
    if is_windows_platform "$plat"; then
      write_stage_tool "$stage" "$platform_key" "npm" "$(npm_version "$stage")" "npm" "npm.cmd"
      write_stage_tool "$stage" "$platform_key" "npx" "$(npm_version "$stage")" "npx" "npx.cmd"
    else
      write_stage_tool "$stage" "$platform_key" "npm" "$(npm_version "$stage")" "npm" ""
      write_stage_tool "$stage" "$platform_key" "npx" "$(npm_version "$stage")" "npx" ""
    fi
    write_stage_tool "$stage" "$platform_key" "ripgrep" "$(yq -r '.tools.ripgrep.version' "$MANIFEST")" "rg" ""
    write_stage_tool "$stage" "$platform_key" "jq" "$(yq -r '.tools.jq.version' "$MANIFEST")" "jq" ""
  } > "${stage}/manifest.yaml"
}

npm_version() {
  local stage="$1"
  local package_json
  package_json="$(first_match "$stage" -type f -path '*/node_modules/npm/package.json')"
  if [[ -n "$package_json" ]]; then
    jq -r '.version' "$package_json"
    return
  fi
  printf 'unknown\n'
}

write_stage_tool() {
  local stage="$1" platform_key="$2" name="$3" version="$4" binary_name="$5" windows_binary_name="$6"
  local filename
  filename="$(executable_name "$binary_name" "${platform_key/\//-}")"
  [[ -n "$windows_binary_name" ]] && filename="$windows_binary_name"
  local path="${stage}/bin/${filename}"
  local sha=""
  if [[ -f "$path" || -L "$path" ]]; then
    sha="$(sha256sum "$path" | awk '{print $1}')"
  fi
  printf '  - name: %s\n' "$name"
  printf '    version: "%s"\n' "$version"
  printf '    binary_name: %s\n' "$binary_name"
  if [[ -n "$windows_binary_name" ]]; then
    printf '    windows_binary_name: %s\n' "$windows_binary_name"
  fi
  if [[ "$name" == "npm" ]]; then
    printf '    runtime_paths:\n'
    if [[ "$platform_key" == windows/* ]]; then
      printf '      - node-v%s-win-x64/node_modules/npm\n' "$(yq -r '.tools.node.version' "$MANIFEST")"
    else
      local node_dir
      node_dir="$(first_match "$stage" -type d -path '*/lib/node_modules/npm')"
      if [[ -n "$node_dir" ]]; then
        printf '      - %s\n' "${node_dir#${stage}/}"
        local node_root="${node_dir%/lib/node_modules/npm}"
        printf '      - %s\n' "${node_root#${stage}/}/node_modules/npm"
        printf '      - %s\n' "${node_root#${stage}/}/bin/node_modules/npm"
      fi
    fi
  fi
  printf '    sha256:\n'
  printf '      %s: "%s"\n' "$platform_key" "$sha"
  printf '\n'
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
