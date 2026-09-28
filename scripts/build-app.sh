#!/usr/bin/env bash
# Builds a release TokenWatch.app bundle from the SwiftPM executable.
#
# Signing:
#   - SIGN_IDENTITY env var, if set, is used verbatim (e.g. "Developer ID Application: MetaPouch (TEAMID)").
#   - Otherwise, the first "Developer ID Application" identity in the keychain is used automatically.
#   - If neither is available, the bundle is ad-hoc signed (codesign --sign -). Ad-hoc builds are
#     for local testing only: Gatekeeper blocks them on any other Mac, and they cannot be notarized.
#
# Usage:
#   ./scripts/build-app.sh                 # auto-detect signing identity
#   SIGN_IDENTITY="Developer ID Application: MetaPouch (ABCDE12345)" ./scripts/build-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="TokenWatch"
BUNDLE_ID="dev.tokenwatch.TokenWatch"
BUILD_DIR=".build/release"
APP_BUNDLE="dist/${APP_NAME}.app"

echo "==> Building release binary"
# @loader_path (SwiftPM's default rpath for an executable target with a binary framework
# dependency) resolves to Contents/MacOS -- add @executable_path/../Frameworks too so dyld also
# finds Sparkle.framework in the conventional Contents/Frameworks location it's copied to below.
swift build -c release --product "$APP_NAME" -Xlinker -rpath -Xlinker @executable_path/../Frameworks

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "dist"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources" "${APP_BUNDLE}/Contents/Frameworks"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
# Sparkle ships as a versioned framework bundle (internal Versions/Current symlinks, plus a
# nested Updater.app helper and XPC services unused outside the App Sandbox) -- `cp -R` without
# `-L` preserves those symlinks as symlinks, which both codesign and Sparkle itself require.
cp -R "${BUILD_DIR}/Sparkle.framework" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
# SwiftPM's generated Bundle.module accessor only ever looks next to Bundle.main.bundleURL (the
# .app's own top level) or the build directory -- neither is compatible with proper codesign
# sealing (content outside Contents/ fails "code has no resources but signature indicates they
# must be present"). So the provider logo SVGs ship as plain files under Contents/Resources/
# instead, and ProviderIcon.swift checks that location before falling back to Bundle.module for
# `swift run`/dev builds.
cp -R "${BUILD_DIR}/TokenWatch_TokenWatch.bundle/Icons" "${APP_BUNDLE}/Contents/Resources/Icons"

# PkgInfo is optional but conventional for APPL bundles.
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

echo "==> Signing"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.+)"$/\1/' || true)
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "    identity: ${SIGN_IDENTITY}"
    codesign --force --deep --options runtime --timestamp \
        --sign "${SIGN_IDENTITY}" \
        --identifier "${BUNDLE_ID}" \
        "${APP_BUNDLE}"
    echo "==> Signed with Developer ID. Ready for notarization (see scripts/notarize.sh)."
else
    echo "    no Developer ID Application identity found -- ad-hoc signing for local testing only"
    codesign --force --deep --sign - "${APP_BUNDLE}"
    echo "==> WARNING: ad-hoc signed. This build will NOT run on any other Mac without"
    echo "    right-click > Open, and cannot be notarized. Set SIGN_IDENTITY or install a"
    echo "    Developer ID Application certificate to produce a distributable build."
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE}"
