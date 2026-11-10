#!/bin/bash
# Publishes a new version for Tony. His app notices within a day (or right away from
# Appauled > Check for Updates…) and installs it with one click.
#
#   1. Put the new number in the VERSION file (e.g. 1.1). It must be higher than the last one.
#   2. scripts/release.sh "What's new, in a sentence or two. Tony sees this."
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="pwolpe/tony-awards-releases"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
NOTES="${1:-Improvements and fixes.}"
APP="$ROOT/build/Appauled.app"

if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "✗ Version $VERSION is already published. Put a higher number in the VERSION file first."
  exit 1
fi

"$ROOT/scripts/build.sh"

# Tony's app only accepts updates signed with the same certificate it was signed with.
if ! codesign -dr - "$APP" 2>&1 | grep -q "certificate leaf"; then
  echo "✗ This build isn't signed with the 'Tony Awards Signing' certificate, so Tony's app would refuse it."
  echo "  The certificate lives in this Mac's login keychain; see README (Sending updates)."
  exit 1
fi
codesign --verify --deep --strict "$APP"

gh release create "v$VERSION" "$ROOT/build/Appauled.zip" --repo "$REPO" \
  --title "Appauled $VERSION" --notes "$NOTES"
echo "✓ Published version $VERSION. Tony's app will offer it within a day."
