#!/usr/bin/env bash
# Builds, signs, notarizes, and publishes a TokenWatch release to GitHub in one shot.
#
# Prerequisites:
#   - Developer ID Application certificate installed (see DISTRIBUTION.md)
#   - notarytool credentials stored under the "TokenWatch Notary" profile (see DISTRIBUTION.md)
#   - `gh` authenticated with push/release access to the repo
#
# Usage:
#   ./scripts/release.sh 1.0.0

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version, e.g. 1.0.0>" >&2
    exit 1
fi

echo "==> Setting version to ${VERSION}"
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist

echo "==> Build, sign, package, notarize"
./scripts/build-app.sh
./scripts/build-dmg.sh
./scripts/notarize.sh "dist/TokenWatch-${VERSION}.dmg"

DMG_PATH="dist/TokenWatch-${VERSION}.dmg"
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "==> SHA256: ${SHA256}"
echo "    (update homebrew-cask/tokenwatch.rb's sha256 field with this value)"

echo "==> Publishing GitHub release v${VERSION}"
gh release create "v${VERSION}" "$DMG_PATH" \
    --title "TokenWatch ${VERSION}" \
    --generate-notes

echo "==> Done. Download URL:"
echo "    https://github.com/MetaPouch/tokenwatch/releases/download/v${VERSION}/TokenWatch-${VERSION}.dmg"
