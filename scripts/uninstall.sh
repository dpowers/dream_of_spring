#!/usr/bin/env bash
# Removes the installed app. Does NOT clear UserDefaults (whitelist) — those
# stay across reinstalls on purpose. Use `defaults delete art.gardenplanner.Dream-Of-Spring`
# to wipe them.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP="$INSTALL_DIR/Dream Of Spring.app"

echo "==> Quitting any running instance…"
bash "$(dirname "$0")/quit-app.sh"

if [[ -d "$APP" ]]; then
    echo "==> Removing $APP"
    rm -rf "$APP"
    echo "Removed."
else
    echo "Not installed at $APP."
fi

echo
echo "If Launch-at-Login was enabled, the entry under"
echo "  System Settings → General → Login Items"
echo "should clear automatically once macOS notices the bundle is gone, but"
echo "you can remove it manually if it lingers."
