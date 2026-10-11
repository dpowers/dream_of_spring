#!/usr/bin/env bash
# Builds, signs with Developer ID, notarizes via Apple, staples the ticket,
# and packages the app for distribution. The resulting .zip can be sent to
# anyone — their Mac will recognise it as a notarized developer-signed app
# with no Gatekeeper prompts.
#
# Prerequisites: scripts/setup-notarization.sh has been run on this machine.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/Dream Of Spring"
PROJECT="$PROJECT_DIR/Dream Of Spring.xcodeproj"
SCHEME="Dream Of Spring"
APP_NAME="Dream Of Spring.app"
DIST_DIR="$REPO_ROOT/dist"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NOTARY_PROFILE="${NOTARY_PROFILE:-DreamOfSpringNotary}"
TEAM_ID="${TEAM_ID:-HZPG29W5S5}"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
    echo "error: Xcode not found at $DEVELOPER_DIR" >&2
    exit 1
fi

echo "==> Checking for Developer ID Application certificate…"
IDENTITIES="$(security find-identity -p codesigning -v 2>/dev/null || true)"
if ! grep -q "Developer ID Application" <<< "$IDENTITIES"; then
    echo "error: no 'Developer ID Application' certificate found in keychain." >&2
    echo "       Create one in Xcode → Settings → Accounts → Manage Certificates" >&2
    echo "       (the '+' menu, pick 'Developer ID Application')." >&2
    exit 1
fi

echo "==> Checking for stored notarytool credentials…"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool keychain profile '$NOTARY_PROFILE' isn't set up." >&2
    echo "       Run: scripts/setup-notarization.sh" >&2
    echo "       (or set NOTARY_PROFILE to a profile you've already configured)." >&2
    exit 1
fi

DERIVED="$(mktemp -d -t dos-build)"
STAGE="$(mktemp -d -t dos-stage)"
trap 'rm -rf "$DERIVED" "$STAGE"' EXIT

ARCHIVE="$DERIVED/Dream Of Spring.xcarchive"
EXPORT_DIR="$STAGE/exported"
EXPORT_OPTS="$STAGE/ExportOptions.plist"
mkdir -p "$EXPORT_DIR"

echo "==> Archiving Release configuration…"
DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$DERIVED" \
    -quiet

cat > "$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

echo "==> Exporting with Developer ID Application signing…"
DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTS" \
    -quiet

EXPORTED_APP="$EXPORT_DIR/$APP_NAME"
if [[ ! -d "$EXPORTED_APP" ]]; then
    echo "error: export did not produce $EXPORTED_APP" >&2
    exit 1
fi

# Confirm what we actually got is signed with Developer ID, not Apple Development.
# Capture the full codesign dump first; piping into `grep -m 1` would
# otherwise SIGPIPE codesign and trip pipefail.
echo "==> Confirming signature…"
SIG_DUMP="$(codesign -dvv "$EXPORTED_APP" 2>&1)"
SIG_AUTHORITY="$(grep 'Authority=' <<< "$SIG_DUMP" | head -1)"
echo "    $SIG_AUTHORITY"
if ! grep -q "Developer ID Application" <<< "$SIG_AUTHORITY"; then
    echo "error: exported app is not signed with Developer ID Application" >&2
    echo "       (got: $SIG_AUTHORITY)" >&2
    exit 1
fi

NOTARY_ZIP="$STAGE/for-notarization.zip"
echo "==> Zipping for notarization…"
ditto -c -k --keepParent "$EXPORTED_APP" "$NOTARY_ZIP"

echo "==> Submitting to Apple notary service (this typically takes 1–15 min)…"
xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket to the .app…"
xcrun stapler staple "$EXPORTED_APP"

echo "==> Verifying the stapled .app passes Gatekeeper…"
spctl --assess --type execute --verbose "$EXPORTED_APP" 2>&1 | head -3
xcrun stapler validate "$EXPORTED_APP" | tail -1

# VERSION is the build date (calver) stamped by the "Stamp version with
# build date" phase, so it already names the artifact unambiguously.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXPORTED_APP/Contents/Info.plist")"
FOLDER_NAME="Dream Of Spring"
PACKAGE_BASENAME="Dream-Of-Spring-${VERSION}"

PACKAGE_DIR="$STAGE/$FOLDER_NAME"
mkdir -p "$PACKAGE_DIR"

echo "==> Staging notarized app…"
cp -R "$EXPORTED_APP" "$PACKAGE_DIR/"

echo "==> Writing recipient installer (Install.command)…"
cat > "$PACKAGE_DIR/Install.command" <<'INSTALL_EOF'
#!/usr/bin/env bash
# Optional convenience installer. The .app is notarized, so you can also
# just drag it into /Applications by hand.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Dream Of Spring.app"
DEST="/Applications/$APP_NAME"

if [[ ! -d "$APP_NAME" ]]; then
    echo "error: $APP_NAME not found next to Install.command" >&2
    exit 1
fi

# Defensive — notarized apps don't really need this, but it's a no-op if
# there's no quarantine flag, and it costs nothing.
xattr -dr com.apple.quarantine "$APP_NAME" 2>/dev/null || true

echo "==> Quitting any running instance…"
pkill -x "Dream Of Spring" 2>/dev/null || true

if [[ -d "$DEST" ]]; then
    echo "==> Replacing existing $DEST"
    rm -rf "$DEST"
fi

echo "==> Installing to $DEST"
cp -R "$APP_NAME" "$DEST"

echo "==> Launching…"
open "$DEST"

echo
echo "Done. Look for the moon icon in the menu bar."
echo
read -n 1 -s -r -p "Press any key to close this window…"
echo
INSTALL_EOF
chmod +x "$PACKAGE_DIR/Install.command"

echo "==> Writing recipient uninstaller (Uninstall.command)…"
cat > "$PACKAGE_DIR/Uninstall.command" <<'UNINSTALL_EOF'
#!/usr/bin/env bash
set -euo pipefail

DEST="/Applications/Dream Of Spring.app"

echo "==> Quitting any running instance…"
pkill -x "Dream Of Spring" 2>/dev/null || true

if [[ -d "$DEST" ]]; then
    echo "==> Removing $DEST"
    rm -rf "$DEST"
    echo "Removed."
else
    echo "Not installed at $DEST."
fi

echo
read -n 1 -s -r -p "Press any key to close this window…"
echo
UNINSTALL_EOF
chmod +x "$PACKAGE_DIR/Uninstall.command"

echo "==> Writing README…"
cat > "$PACKAGE_DIR/README.txt" <<'README_EOF'
Dream Of Spring
===============

A tiny menu-bar app that forces the Mac to sleep at the time you've configured
in System Settings, even when other apps try to keep it awake.


To install
----------

The simplest way:

  1. Drag "Dream Of Spring.app" into your /Applications folder.
  2. Double-click it (or launch from Spotlight: Cmd-Space, "Dream Of Spring").
  3. A moon appears in your menu bar.

Or use the convenience installer:

  Double-click "Install.command" — it copies the app to /Applications, then
  launches it.

The app is signed and notarized, so macOS won't complain on launch.


Once it's running
-----------------

Click the moon in the menu bar to:

  - See which apps are keeping the Mac awake right now.
  - Whitelist an app — three options per app:
      * Always allow — never force sleep on its account.
      * Allow up to N minutes — exempt it for that long, then force sleep
        anyway (good for video sites: legit during playback, but you don't
        want a paused video keeping the Mac awake overnight).
      * Don't whitelist — default; force sleep at the configured timeout.
  - Pause it temporarily (15 min / 1 hour / until you resume).
  - Toggle "Launch at Login" so it starts on every reboot.


To uninstall
------------

Drag "Dream Of Spring.app" from /Applications to the Trash. Or double-click
"Uninstall.command".
README_EOF

mkdir -p "$DIST_DIR"
ZIP="$DIST_DIR/$PACKAGE_BASENAME.zip"
rm -f "$ZIP"

echo "==> Creating $ZIP"
(cd "$STAGE" && ditto -c -k --keepParent "$FOLDER_NAME" "$ZIP")

SIZE_HUMAN="$(du -h "$ZIP" | cut -f1)"
echo
echo "Package created (signed + notarized):"
echo "  $ZIP   ($SIZE_HUMAN)"
echo
echo "Send via AirDrop / iMessage / email / USB. Recipient unzips and either"
echo "drags the .app to /Applications or double-clicks Install.command."
