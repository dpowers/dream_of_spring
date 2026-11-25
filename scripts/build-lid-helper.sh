#!/bin/bash
# Xcode build phase: compile the small daemon and embed it before app signing.
set -euo pipefail
APP_SOURCES="$SRCROOT/Dream Of Spring"
HELPER_SOURCES="$SRCROOT/LidHelper"
OUTPUT="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS/DreamOfSpringLidHelper"
LAUNCH_DIR="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchDaemons"
mkdir -p "$(dirname "$OUTPUT")" "$LAUNCH_DIR" "$DERIVED_FILE_DIR/lid-helper-modules"
ARCH_OUTPUTS=()
for HELPER_ARCH in $ARCHS; do
    ARCH_OUTPUT="$DERIVED_FILE_DIR/DreamOfSpringLidHelper-$HELPER_ARCH"
    xcrun swiftc -swift-version 5 -O -sdk "$SDKROOT" \
        -target "$HELPER_ARCH-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
        -module-cache-path "$DERIVED_FILE_DIR/lid-helper-modules" \
        "$HELPER_SOURCES/main.swift" \
        "$APP_SOURCES/ClosedLidService.swift" "$APP_SOURCES/ClosedLidLease.swift" \
        "$APP_SOURCES/PowerSafetyReadings.swift" "$APP_SOURCES/BatteryState.swift" \
        "$APP_SOURCES/BatteryProtection.swift" "$APP_SOURCES/SleepTimerSettings.swift" \
        "$APP_SOURCES/HelperUpdateMonitor.swift" \
        -o "$ARCH_OUTPUT"
    ARCH_OUTPUTS+=("$ARCH_OUTPUT")
done
xcrun lipo -create "${ARCH_OUTPUTS[@]}" -output "$OUTPUT"
cp "$HELPER_SOURCES/art.gardenplanner.Dream-Of-Spring.LidHelper.plist" "$LAUNCH_DIR/"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    codesign --force --options runtime --timestamp=none \
        --identifier art.gardenplanner.Dream-Of-Spring.LidHelper \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$OUTPUT"
fi
