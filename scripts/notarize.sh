#!/usr/bin/env bash
# Submits a built DMG to Apple's notary service, waits for approval, and staples the ticket.
# Requires a stored notarytool credential profile (see DISTRIBUTION.md for one-time setup).
#
# Usage:
#   ./scripts/notarize.sh                              # notarizes dist/TokenWatch-<version>.dmg
#   ./scripts/notarize.sh dist/TokenWatch-1.0.0.dmg
#   NOTARY_PROFILE=my-profile ./scripts/notarize.sh

set -euo pipefail
cd "$(dirname "$0")/.."

DMG_PATH="${1:-$(ls -t dist/TokenWatch-*.dmg 2>/dev/null | head -1)}"
PROFILE="${NOTARY_PROFILE:-tokenwatch-notary}"

if [ -z "$DMG_PATH" ] || [ ! -f "$DMG_PATH" ]; then
    echo "error: no DMG found -- run scripts/build-dmg.sh first, or pass a path" >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "error: no stored notarytool credential profile named '${PROFILE}'." >&2
    echo "       See DISTRIBUTION.md for one-time setup (store-credentials)." >&2
    exit 1
fi

echo "==> Submitting ${DMG_PATH} for notarization (profile: ${PROFILE})"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Validating staple"
xcrun stapler validate "$DMG_PATH"

echo "==> Gatekeeper assessment"
spctl -a -t open --context context:primary-signature -v "$DMG_PATH"

echo "==> Done: ${DMG_PATH} is notarized, stapled, and Gatekeeper-clean"
