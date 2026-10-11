#!/usr/bin/env bash
# Exercise packaging's signing-team selection without building or contacting Apple.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_SCRIPT="$SCRIPT_DIR/../package.sh"
WORK="$(mktemp -d -t dos-package-team)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat > "$WORK/bin/security" <<'MOCK'
#!/usr/bin/env bash
echo '1) TEST_ID "Developer ID Application: Test"'
MOCK

cat > "$WORK/bin/xcrun" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == 'notarytool history --keychain-profile TestNotary' ]]
MOCK

cat > "$WORK/bin/xcodebuild" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    archive)
        for argument in "$@"; do
            if [[ "$argument" == "DEVELOPMENT_TEAM=$EXPECTED_TEAM" ]]; then
                exit 0
            fi
        done
        echo "error: archive did not select DEVELOPMENT_TEAM=$EXPECTED_TEAM" >&2
        exit 1
        ;;
    -exportArchive)
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == -exportOptionsPlist ]]; then
                grep -Fq "<string>$EXPECTED_TEAM</string>" "$2"
                echo "export-team-verified:$EXPECTED_TEAM"
                # Stop before packaging can sign, notarize, or create artifacts.
                exit 73
            fi
            shift
        done
        ;;
esac
exit 1
MOCK
chmod +x "$WORK/bin/security" "$WORK/bin/xcrun" "$WORK/bin/xcodebuild"

check_team() {
    local expected_team="$1"
    shift
    local status
    if env -u TEAM_ID PATH="$WORK/bin:$PATH" DEVELOPER_DIR="$WORK" \
        NOTARY_PROFILE=TestNotary EXPECTED_TEAM="$expected_team" \
        "$@" bash "$PACKAGE_SCRIPT" > "$WORK/output" 2>&1; then
        status=0
    else
        status=$?
    fi
    if [[ "$status" != 73 ]] || ! grep -Fq "export-team-verified:$expected_team" "$WORK/output"; then
        cat "$WORK/output" >&2
        echo "FAIL: archive and export must both use $expected_team (exit $status)" >&2
        exit 1
    fi
    echo "PASS: archive and export both use $expected_team"
}

check_team TESTTEAM42 TEAM_ID=TESTTEAM42
check_team HZPG29W5S5
