#!/usr/bin/env bash
# Create the labels used by .github/workflows/auto-label.yml.
# Safe to re-run: existing labels are left untouched.
# Usage: ./scripts/create-auto-labels.sh [owner/repo]
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "gh (GitHub CLI) is required" >&2
  exit 1
fi

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

create() {
  local name="$1" color="$2" description="$3"
  if gh label view "$name" --repo "$REPO" >/dev/null 2>&1; then
    echo "skip    $name"
  else
    gh label create "$name" --repo "$REPO" --color "$color" --description "$description" >/dev/null
    echo "created $name"
  fi
}

echo "Repository: $REPO"

create "type: feature"       a2eeef "New feature or capability"
create "type: fix"           d73a4a "Bug fix or broken behaviour"
create "type: chore"         85598b "Maintenance, packaging, build or version upkeep"
create "type: docs"          0075ca "Documentation and wording changes"

create "area: ui"            7057ff "Slint UI and window layout"
create "area: git-config"    1d76db "git config read/write backend and options"
create "area: packaging"     fbca04 "deb, snap, MSI/MSIX, AppImage and installers"
create "area: build-ci"      f9d0c4 "Cargo, build scripts and GitHub Actions"

create "platform: windows"   0052cc "Windows-specific behaviour or packaging"
create "platform: linux"     0e8a16 "Linux-specific behaviour or packaging"
create "platform: macos"     bfd4f2 "macOS-specific behaviour or packaging"

create "skip-auto-label"     ededed "Opt out of automatic labelling on this item"

echo "Done."
