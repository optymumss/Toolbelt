#!/bin/bash
# Opens build/Toolbelt.dmg the way Finder does, checks what's inside, launches the app from it
# (with a scratch data folder) and checks it keeps running. Run after package.sh.

set -uo pipefail
cd "$(dirname "$0")/../.."

DMG="build/Toolbelt.dmg"
MOUNT="$(mktemp -d -t toolbelt-mount)"
failed=0
pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; failed=1; }

if hdiutil verify -quiet "$DMG"; then
    pass "the disk image isn't damaged"
else
    fail "the disk image is damaged"
    # Say why, so a failure can be looked into.
    ls -l "$DMG"; df -h "$(dirname "$DMG")"
    hdiutil verify "$DMG" 2>&1 | tail -20
    hdiutil imageinfo "$DMG" 2>&1 | head -30
    xxd "$DMG" | head -4; tail -c 512 "$DMG" | xxd | head -4
fi
if ! hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"; then
    echo "✗ the disk image couldn't be opened"
    exit 1
fi
pass "the disk image opens"

APP="$MOUNT/Toolbelt.app"
[ -d "$APP" ] && pass "it holds Toolbelt.app" || fail "Toolbelt.app is missing"
[ "$(readlink "$MOUNT/Applications")" = "/Applications" ] && pass "it has the Applications shortcut" || fail "the Applications shortcut is missing"
[ -x "$APP/Contents/MacOS/ToolbeltBridge" ] && pass "the Chrome helper is inside" || fail "the Chrome helper is missing"
[ -f "$APP/Contents/Resources/ChromeExtension/manifest.json" ] && pass "the Chrome extension is inside" || fail "the Chrome extension is missing"
codesign --verify --deep --strict "$APP" 2>&1 && pass "the app's signature is intact" || fail "the app's signature is broken"

DATA_DIR="$(mktemp -d -t toolbelt-dmg-data)"
TOOLBELT_DATA_DIR="$DATA_DIR" "$APP/Contents/MacOS/Toolbelt" &
pid=$!
sleep 5
if kill -0 "$pid" 2>/dev/null; then
    pass "the app starts from the disk image and keeps running"
else
    fail "the app quit or crashed when started from the disk image"
fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

hdiutil detach -quiet "$MOUNT" || hdiutil detach -quiet -force "$MOUNT"
rm -rf "$DATA_DIR"
exit $failed
