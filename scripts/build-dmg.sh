#!/usr/bin/env bash
# Packages dist/TokenWatch.app into a drag-to-install DMG. Run scripts/build-app.sh first.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="TokenWatch"
APP_BUNDLE="dist/${APP_NAME}.app"
VERSION=$(defaults read "$(pwd)/${APP_BUNDLE}/Contents/Info" CFBundleShortVersionString)
DMG_PATH="dist/${APP_NAME}-${VERSION}.dmg"
STAGING="dist/.dmg-staging"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "error: ${APP_BUNDLE} not found -- run scripts/build-app.sh first" >&2
    exit 1
fi

echo "==> Staging DMG contents"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Building ${DMG_PATH}"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING"

if [ -n "${SIGN_IDENTITY:-}" ] || security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.+)"$/\1/')}"
    echo "==> Signing DMG with ${identity}"
    codesign --force --sign "$identity" --timestamp "$DMG_PATH"
else
    echo "==> No Developer ID identity found -- DMG left unsigned (fine for local testing, not for distribution)"
fi

echo "==> Done: ${DMG_PATH}"
