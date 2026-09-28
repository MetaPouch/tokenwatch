#!/usr/bin/env bash
# Builds, signs, notarizes, and publishes a TokenWatch release to GitHub in one shot, then
# regenerates and publishes the Sparkle appcast so in-app auto-update picks it up.
#
# Prerequisites:
#   - Developer ID Application certificate installed (see DISTRIBUTION.md)
#   - notarytool credentials stored under the "TokenWatch Notary" profile (see DISTRIBUTION.md)
#   - `gh` authenticated with push/release access to the repo
#   - Sparkle's EdDSA key generated and SUPublicEDKey set in Resources/Info.plist, and the
#     Sparkle command-line tools available -- see DISTRIBUTION.md's "Auto-update (Sparkle)"
#     section. Without these, the release still publishes; this script just warns and skips the
#     appcast step, so existing installs won't see an update until it's set up.
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

# CFBundleVersion is the machine-readable build number Sparkle actually compares to decide "is
# there a newer version" -- CFBundleShortVersionString is just what's displayed. The commit
# count is monotonic for as long as history only grows, needs no manual bookkeeping, and can
# never regress or collide between releases cut from a normal fast-forward history.
BUILD_NUMBER=$(git rev-list --count HEAD)

echo "==> Setting version to ${VERSION} (build ${BUILD_NUMBER})"
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" Resources/Info.plist
if ! git diff --quiet -- Resources/Info.plist; then
    git add Resources/Info.plist
    git commit -m "Release v${VERSION}"
    git push
fi

echo "==> Build, sign, package, notarize"
./scripts/build-app.sh
./scripts/build-dmg.sh
./scripts/notarize.sh "dist/TokenWatch-${VERSION}.dmg"

DMG_PATH="dist/TokenWatch-${VERSION}.dmg"
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "==> SHA256: ${SHA256}"

echo "==> Publishing GitHub release v${VERSION}"
gh release create "v${VERSION}" "$DMG_PATH" \
    --title "TokenWatch ${VERSION}" \
    --generate-notes

echo "==> Updating Homebrew cask mirror"
sed -i '' -E "s/^  version \"[^\"]*\"/  version \"${VERSION}\"/" homebrew-cask/tokenwatch.rb
sed -i '' -E "s/^  sha256 \"[^\"]*\"/  sha256 \"${SHA256}\"/" homebrew-cask/tokenwatch.rb
if ! git diff --quiet -- homebrew-cask/tokenwatch.rb; then
    git add homebrew-cask/tokenwatch.rb
    git commit -m "Bump cask mirror to v${VERSION}"
    git push
fi

DOWNLOAD_URL_PREFIX="https://github.com/MetaPouch/tokenwatch/releases/download/v${VERSION}/"

echo "==> Updating Sparkle appcast"
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-$HOME/.sparkle-tools/bin}"
# Every released DMG accumulates here permanently (outside dist/, which build-app.sh wipes each
# run) so generate_appcast always sees the full release history when it regenerates
# docs/appcast.xml from scratch.
ARCHIVE_DIR="${TOKENWATCH_RELEASE_ARCHIVE:-$HOME/.tokenwatch-release-archive}"
if [ -x "${SPARKLE_BIN_DIR}/generate_appcast" ]; then
    mkdir -p "$ARCHIVE_DIR"
    cp "$DMG_PATH" "$ARCHIVE_DIR/"
    "${SPARKLE_BIN_DIR}/generate_appcast" \
        --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
        --maximum-deltas 0 \
        -o docs/appcast.xml \
        "$ARCHIVE_DIR"
    if ! git diff --quiet -- docs/appcast.xml; then
        git add docs/appcast.xml
        git commit -m "Update appcast for v${VERSION}"
        git push
        echo "==> docs/appcast.xml updated and pushed -- existing installs will see this update"
        echo "    within a day (or immediately via Check for Updates…)."
    else
        echo "==> docs/appcast.xml unchanged -- nothing to push."
    fi
else
    echo "==> WARNING: ${SPARKLE_BIN_DIR}/generate_appcast not found -- skipping appcast update."
    echo "    This release published to GitHub normally, but existing installs will NOT see it"
    echo "    as an in-app update until docs/appcast.xml is regenerated. See DISTRIBUTION.md's"
    echo "    'Auto-update (Sparkle)' section for the one-time tool download."
fi

echo "==> Done. Download URL:"
echo "    ${DOWNLOAD_URL_PREFIX}TokenWatch-${VERSION}.dmg"
