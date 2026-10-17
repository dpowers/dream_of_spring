#!/usr/bin/env bash
# Builds the Release configuration and installs to /Applications.
# Personal-use only — no notarisation, no DMG.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)/Dream Of Spring"
PROJECT="$PROJECT_DIR/Dream Of Spring.xcodeproj"
SCHEME="Dream Of Spring"
APP_NAME="Dream Of Spring.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
    echo "error: Xcode not found at $DEVELOPER_DIR" >&2
    echo "       set DEVELOPER_DIR or install Xcode" >&2
    exit 1
fi

if [[ ! -d "$PROJECT" ]]; then
    echo "error: Xcode project not found at $PROJECT" >&2
    exit 1
fi

DERIVED="$(mktemp -d -t dream-of-spring)"
trap 'rm -rf "$DERIVED"' EXIT

echo "==> Building Release…"
DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -quiet \
    build

BUILT_APP="$DERIVED/Build/Products/Release/$APP_NAME"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "error: build did not produce $BUILT_APP" >&2
    exit 1
fi

echo "==> Quitting any running instance…"
bash "$(dirname "$0")/quit-app.sh"

DEST="$INSTALL_DIR/$APP_NAME"
if [[ -d "$DEST" ]]; then
    echo "==> Removing existing $DEST"
    rm -rf "$DEST"
fi

echo "==> Installing to $DEST"
cp -R "$BUILT_APP" "$DEST"

# Quarantine isn't usually applied to locally-built apps, but strip just in case.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo
echo "Installed."
echo "  Launch with: open '$DEST'"
echo "  Logs:        log stream --predicate 'subsystem == \"art.gardenplanner.dream-of-spring\"' --info"
echo "  Uninstall:   $(cd "$(dirname "$0")" && pwd)/uninstall.sh"
