#!/usr/bin/env bash
# Let the app restore sleep before replacing/removing its embedded daemon.
set -euo pipefail
if ! pgrep -x 'Dream Of Spring' >/dev/null; then exit 0; fi
if ! osascript -e 'tell application id "art.gardenplanner.Dream-Of-Spring" to quit' >/dev/null 2>&1; then
    pkill -x 'Dream Of Spring' 2>/dev/null || true
    # The helper releases on XPC disconnect, with a ten-second lease as backup.
    sleep 12
fi
for attempt in {1..20}; do
    if ! pgrep -x 'Dream Of Spring' >/dev/null; then exit 0; fi
    sleep 1
done
echo 'error: Dream Of Spring is still restoring sleep. Quit it before installing or removing it.' >&2
exit 1
