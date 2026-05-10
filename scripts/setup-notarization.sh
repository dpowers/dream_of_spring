#!/usr/bin/env bash
# One-time: store Apple notary credentials in a keychain profile that
# `xcrun notarytool` can use without prompting. Run this once per machine.
#
# Prerequisites:
#   1. A paid Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in your login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID
#      Application). The team ID below should match yours.
#   3. An app-specific password generated at:
#        https://account.apple.com → Sign-In and Security → App-Specific Passwords
#      Apple requires this for `notarytool` instead of your normal password.
set -euo pipefail

PROFILE_NAME="${NOTARY_PROFILE:-DreamOfSpringNotary}"
TEAM_ID="${TEAM_ID:-HZPG29W5S5}"

echo "Storing notarytool credentials in keychain profile: $PROFILE_NAME"
echo "Team ID: $TEAM_ID"
echo

IDENTITIES="$(security find-identity -p codesigning -v 2>/dev/null || true)"
if ! grep -q "Developer ID Application" <<< "$IDENTITIES"; then
    echo "warning: no 'Developer ID Application' certificate found in your keychain." >&2
    echo "         You can still complete this setup, but package.sh will fail until" >&2
    echo "         you create one in Xcode → Settings → Accounts → Manage Certificates." >&2
    echo
fi

read -p "Apple ID email: " APPLE_ID
read -s -p "App-specific password: " APP_PASSWORD
echo
echo

xcrun notarytool store-credentials "$PROFILE_NAME" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD"

echo
echo "Done. scripts/package.sh will now use profile '$PROFILE_NAME'."
echo "Override with NOTARY_PROFILE=other-name if you ever want a different one."
