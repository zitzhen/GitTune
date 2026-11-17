#!/usr/bin/env bash
# GitTune version synchronizer (Linux / macOS / Git Bash)
#
# Usage:
#   scripts/set-version.sh <version>            Set all version declarations to <version>
#   scripts/set-version.sh <version> --check    Verify without modifying any file
#   scripts/set-version.sh --help
#
# <version> must be a three-part numeric version: major.minor.patch.
#
# Files kept in sync:
#   Cargo.toml                 version = "X.Y.Z"
#   Cargo.lock                 version of the [[package]] named "GitTune"
#   snap/snapcraft.yaml        version: 'X.Y.Z'
#   debian/changelog           first line: git-tune (X.Y.Z-<debian revision>)
#   AppxManifest.xml           Identity Version="X.Y.Z.0" plus the doc comment
#   Package.appxmanifest       same as above (kept byte-identical)
#   wix/GitTune.wxs            version in the documented build command
#
# MSIX requires a four-part version, so "X.Y.Z.0" is derived automatically.
# README.md's "Version 1.0.0 - first release" is a historical note, not the
# current version, and is intentionally left alone.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO="$ROOT/Cargo.toml"
LOCK="$ROOT/Cargo.lock"
SNAPCRAFT="$ROOT/snap/snapcraft.yaml"
CHANGELOG="$ROOT/debian/changelog"
APPX="$ROOT/AppxManifest.xml"
APPX_PACKAGE="$ROOT/Package.appxmanifest"
WIX="$ROOT/wix/GitTune.wxs"

MODE="sync"
VERSION=""
END_OPTIONS=0
CHECK_OK=0
CHANGED=()

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}"
}

while [ "$#" -gt 0 ]; do
  if [ "$END_OPTIONS" -eq 1 ]; then
    if [ -n "$VERSION" ]; then
      echo "Error: only one version argument is allowed" >&2
      exit 2
    fi
    VERSION="$1"
    shift
    continue
  fi
  case "$1" in
    -c|--check) MODE="check"; shift ;;
    -h|--help)  usage; exit 0 ;;
    --)         END_OPTIONS=1; shift ;;
    -*)         echo "Error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$VERSION" ]; then
        echo "Error: only one version argument is allowed" >&2
        exit 2
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Error: a version argument is required, e.g. scripts/set-version.sh 1.7.0" >&2
  usage >&2
  exit 2
fi
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Error: version must be three numeric fields (major.minor.patch), got: $VERSION" >&2
  exit 2
fi

MSIX_VERSION="$VERSION.0"

# Rewrite a file with awk, but only replace it when the content actually changes
# so unchanged files keep their mtime. Return 0 = modified, 1 = unchanged.
patch_awk() {
  local file="$1" program="$2" tmp
  if [ ! -f "$file" ]; then
    echo "Error: missing file $file" >&2
    return 1
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/gittune-version.XXXXXX")"
  if ! awk -v v="$VERSION" -v v4="$MSIX_VERSION" "$program" "$file" > "$tmp"; then
    rm -f "$tmp"
    echo "Error: failed to process $file" >&2
    exit 1
  fi
  # awk always appends a newline; keep the original "no trailing newline" state.
  if [ "$(tail -c 1 "$file" | wc -l)" -eq 0 ]; then
    content="$(cat "$tmp")"
    printf '%s' "$content" > "$tmp"
  fi
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # Overwrite in place instead of mv, preserving permissions, owner and inode.
  cat "$tmp" > "$file"
  rm -f "$tmp"
  return 0
}

# ---- Check mode ----------------------------------------------------------
if [ "$MODE" = "check" ]; then
  echo "Checking version $VERSION (MSIX: $MSIX_VERSION):"

  check_fixed() {
    local file="$1" text="$2" label="$3"
    if grep -Fq -- "$text" "$file"; then
      echo "  [OK]   $label"
    else
      echo "  [FAIL] $label  expected: $text"
      CHECK_OK=1
    fi
  }

  check_fixed "$CARGO"     "version = \"$VERSION\""   "Cargo.toml"
  check_fixed "$SNAPCRAFT" "version: '$VERSION'"      "snap/snapcraft.yaml"

  LOCK_VERSION="$(awk '/^name[[:space:]]*=[[:space:]]*"GitTune"/ { found = 1; next }
                       found && /^version[[:space:]]*=/ { gsub(/"/, "", $3); print $3; exit }' "$LOCK")"
  if [ "$LOCK_VERSION" = "$VERSION" ]; then
    echo "  [OK]   Cargo.lock"
  else
    echo "  [FAIL] Cargo.lock  expected $VERSION, found ${LOCK_VERSION:-<not found>}"
    CHECK_OK=1
  fi

  CHANGELOG_HEAD="$(sed -n '1p' "$CHANGELOG")"
  if printf '%s' "$CHANGELOG_HEAD" | grep -Fq "($VERSION-"; then
    echo "  [OK]   debian/changelog"
  else
    echo "  [FAIL] debian/changelog  first line should be git-tune ($VERSION-<revision>)"
    CHECK_OK=1
  fi

  for manifest in "$APPX" "$APPX_PACKAGE"; do
    label="$(basename "$manifest")"
    check_fixed "$manifest" "Version=\"$MSIX_VERSION\"" "Identity Version @ $label"
    check_fixed "$manifest" "Cargo.toml $VERSION"      "version comment @ $label"
  done

  check_fixed "$WIX" "-d Version=$VERSION"  "wix/GitTune.wxs build example"
  check_fixed "$WIX" "GitTune-$VERSION-x64" "wix/GitTune.wxs output filename example"

  if [ "$CHECK_OK" -eq 0 ]; then
    echo "All files are in sync."
  else
    echo "Out of sync. Run scripts/set-version.sh $VERSION to fix it." >&2
  fi
  exit "$CHECK_OK"
fi

# ---- Sync mode -----------------------------------------------------------
patch_awk "$CARGO" '
  /^version[[:space:]]*=/ { print "version = \"" v "\""; next }
  { print }
' && CHANGED+=("Cargo.toml")

patch_awk "$LOCK" '
  /^\[\[package\]\]/ { in_package = 0 }
  /^name[[:space:]]*=[[:space:]]*"GitTune"[[:space:]]*$/ { in_package = 1; print; next }
  in_package && /^version[[:space:]]*=/ { print "version = \"" v "\""; in_package = 0; next }
  { print }
' && CHANGED+=("Cargo.lock")

patch_awk "$SNAPCRAFT" '
  /^version:[[:space:]]*/ { print "version: \047" v "\047"; next }
  { print }
' && CHANGED+=("snap/snapcraft.yaml")

patch_awk "$CHANGELOG" '
  NR == 1 {
    if (match($0, /\([^)]*\)/)) {
      spec = substr($0, RSTART + 1, RLENGTH - 2)
      revision = "1"
      if (match(spec, /-[^-]+$/)) revision = substr(spec, RSTART + 1)
      sub(/\([^)]*\)/, "(" v "-" revision ")")
    }
  }
  { print }
' && CHANGED+=("debian/changelog")

for manifest in "$APPX" "$APPX_PACKAGE"; do
  if patch_awk "$manifest" '
    { sub(/[ \t]Version="[0-9]+\.[0-9]+\.[0-9]+\.0"/, " Version=\"" v4 "\"") }
    /Cargo\.toml[ \t]+[0-9]+\.[0-9]+\.[0-9]+/ {
      sub(/Cargo\.toml[ \t]+[0-9]+\.[0-9]+\.[0-9]+/, "Cargo.toml " v)
      sub(/[ \t]Version="[0-9]+\.[0-9]+\.[0-9]+\.0"/, " Version=\"" v4 "\"")
    }
    { print }
  '; then
    CHANGED+=("$(basename "$manifest")")
  fi
done

patch_awk "$WIX" '
  { gsub(/-d[ \t]+Version=[0-9]+\.[0-9]+\.[0-9]+/, "-d Version=" v) }
  { gsub(/GitTune-[0-9]+\.[0-9]+\.[0-9]+-x64/, "GitTune-" v "-x64") }
  { print }
' && CHANGED+=("wix/GitTune.wxs")

echo "Version set to $VERSION (MSIX: $MSIX_VERSION)"
if [ "${#CHANGED[@]}" -eq 0 ]; then
  echo "All files already at the target version; nothing to change."
else
  printf 'Updated %d files:\n' "${#CHANGED[@]}"
  printf '  - %s\n' "${CHANGED[@]}"
fi
