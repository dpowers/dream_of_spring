#!/usr/bin/env bash
# Duplicate certificate names must not prevent signing the helper and app.
# All signing/build/notary commands are mocked; no keychain or network access.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d -t dos-package-signing)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat > "$WORK/bin/security" <<'MOCK'
#!/usr/bin/env bash
echo '1) FIRST "Developer ID Application: Test (TESTTEAM42)"'
echo '2) SECOND "Developer ID Application: Test (TESTTEAM42)"'
MOCK

cat > "$WORK/bin/xcodebuild" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == archive ]] && exit 0
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -exportPath ]]; then
        mkdir -p "$2/Dream Of Spring.app/Contents/MacOS"
        touch "$2/Dream Of Spring.app/Contents/MacOS/DreamOfSpringLidHelper"
        exit 0
    fi
    shift
done
exit 1
MOCK

cat > "$WORK/bin/codesign" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    -dvv)
        echo 'Authority=Developer ID Application: Test (TESTTEAM42)' >&2
        ;;
    -d)
        [[ "$2" == --extract-certificates=* ]]
        printf 'exported certificate' > "${2#--extract-certificates=}0"
        ;;
    --force)
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == --sign ]]; then
                [[ "$2" == "$EXPECTED_IDENTITY" ]] || {
                    echo 'FAIL: signing must use the exported certificate fingerprint' >&2
                    exit 1
                }
                echo "signed:${@: -1}" >> "$SIGNING_LOG"
                exit 0
            fi
            shift
        done
        exit 1
        ;;
    --verify) ;;
    *) exit 1 ;;
esac
MOCK

cat > "$WORK/bin/xcrun" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    'notarytool history --keychain-profile TestNotary') exit 0 ;;
    'notarytool submit '*) echo 'notarization-reached'; exit 73 ;;
    *) exit 1 ;;
esac
MOCK

cat > "$WORK/bin/ditto" <<'MOCK'
#!/usr/bin/env bash
touch "${@: -1}"
MOCK
chmod +x "$WORK/bin/"*

EXPECTED_IDENTITY="$(printf 'exported certificate' | shasum -a 1 | awk '{print $1}')"
status=0
env PATH="$WORK/bin:$PATH" DEVELOPER_DIR="$WORK" TMPDIR="$WORK/" \
    TEAM_ID=TESTTEAM42 NOTARY_PROFILE=TestNotary \
    EXPECTED_IDENTITY="$EXPECTED_IDENTITY" SIGNING_LOG="$WORK/signing.log" \
    bash "$SCRIPT_DIR/../package.sh" > "$WORK/output" 2>&1 || status=$?

if [[ "$status" != 73 ]] || ! grep -Fq notarization-reached "$WORK/output"; then
    cat "$WORK/output" >&2
    echo "FAIL: packaging did not reach notarization (exit $status)" >&2
    exit 1
fi
[[ "$(wc -l < "$WORK/signing.log" | tr -d ' ')" == 2 ]]
grep -q '/DreamOfSpringLidHelper$' "$WORK/signing.log"
grep -q '/Dream Of Spring.app$' "$WORK/signing.log"
echo 'PASS: helper and app use the exported certificate fingerprint despite duplicate names'
