#!/bin/bash
# Real-use tests on GitHub's Mac: builds the test app (E2E/RealUse.swift) into build/ToolbeltE2E.app,
# gives it and Toolbelt the permissions a person would switch on in System Settings, then lets the
# test app use Toolbelt: shortcuts, held keys, typing, mouse, pretend trackpad touches, snippets,
# macros, the web server, the clipboard, the launcher, window moves and screenshots.
#
#   bash .github/scripts/real-use.sh                  the real-use tests (a few minutes)
#   bash .github/scripts/real-use.sh stability 20     20 minutes of nonstop use
#
# Run after build.sh. Only for GitHub's Macs: it writes to macOS's permission database, which
# needs SIP switched off (as it is there) and must never be done on your own Mac.

set -uo pipefail
cd "$(dirname "$0")/../.."

MODE="${1:-real-use}"
MINUTES="${2:-20}"
APP="$PWD/build/Toolbelt.app"
E2E="$PWD/build/ToolbeltE2E.app"
RESULTS="$PWD/build/$MODE-results.txt"

if [ -z "${CI:-}" ]; then
    echo "This changes macOS's permission database, so it only runs on GitHub's Macs (CI=true)."
    exit 1
fi

# 1. The test app, compiled with all of Toolbelt's sources except its startup file.
echo "Building the test app…"
rm -rf "$E2E"
mkdir -p "$E2E/Contents/MacOS"
ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=()
while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find Sources E2E -name '*.swift' ! -path 'Sources/App/App.swift' | sort)
xcrun swiftc -parse-as-library -swift-version 5 -target "${ARCH}-apple-macos14.0" -sdk "$SDK" \
    -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement -framework IOKit \
    -framework Quartz -framework Vision -framework CoreWLAN -framework CoreLocation -framework CoreAudio \
    -framework Network -framework AVFoundation -framework CoreMedia -framework IOBluetooth \
    "${SOURCES[@]}" -o "$E2E/Contents/MacOS/ToolbeltE2E" || exit 1
cat > "$E2E/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.toolbelt.e2e</string>
    <key>CFBundleName</key><string>ToolbeltE2E</string>
    <key>CFBundleExecutable</key><string>ToolbeltE2E</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>Toolbelt test search</string>
        <key>CFBundleURLSchemes</key><array><string>toolbelte2e</string></array>
    </dict></array>
</dict>
</plist>
PLIST
codesign --force --sign - "$E2E" >/dev/null 2>&1

# 2. Permissions: Accessibility, Input Monitoring, sending key presses, and Screen Recording, for both
#    apps (by bundle identifier, tied to their code signature, and by path).
echo "SIP: $(csrutil status 2>/dev/null)"
SYSTEM_DB="/Library/Application Support/com.apple.TCC/TCC.db"
USER_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
echo "Permission table: $(sudo sqlite3 "$SYSTEM_DB" "PRAGMA table_info(access);" | cut -d'|' -f2 | tr '\n' ' ')"
grant() {
    local app="$1" id requirement hex executable now service db
    id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")"
    executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")"
    requirement="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
    hex=""
    if [ -n "$requirement" ] && echo "$requirement" | csreq -r- -b /tmp/toolbelt-req.bin 2>/dev/null; then
        hex="$(xxd -p /tmp/toolbelt-req.bin | tr -d '\n')"
    fi
    local csreq="NULL"
    [ -n "$hex" ] && csreq="X'$hex'"
    now="$(date +%s)"
    for service in kTCCServiceAccessibility kTCCServiceListenEvent kTCCServicePostEvent kTCCServiceScreenCapture kTCCServiceSystemPolicyAllFiles; do
        for db in "$SYSTEM_DB" "$USER_DB"; do
            sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, last_modified) VALUES ('$service', '$id', 0, 2, 4, 1, $csreq, 0, $now);" 2>/dev/null
            sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, last_modified) VALUES ('$service', '$executable', 1, 2, 4, 1, NULL, 0, $now);" 2>/dev/null
        done
    done
    echo "Permissions given to $id ($( [ -n "$hex" ] && echo "tied to its signature" || echo "no signature requirement" ))"
}
grant "$APP"
grant "$E2E"
# macOS 15 and later also confirm screen recording from time to time ("…requesting to bypass the system
# private window picker"); nobody can click that here, and it stays on screen. Record it as approved, as
# macOS does once you've clicked Allow.
APPROVALS="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
mkdir -p "$(dirname "$APPROVALS")"
for executable in "$APP/Contents/MacOS/Toolbelt" "$E2E/Contents/MacOS/ToolbeltE2E"; do
    defaults write "$APPROVALS" "$executable" -date "3024-01-01 00:00:00 +0000"
done
killall -HUP replayd 2>/dev/null
# Toolbelt may control Finder (for "Empty the Trash"), as if you'd clicked OK when macOS asked.
FINDER_REQ="$(codesign -d -r- /System/Library/CoreServices/Finder.app 2>&1 | sed -n 's/^designated => //p')"
FINDER_HEX=""
if [ -n "$FINDER_REQ" ] && echo "$FINDER_REQ" | csreq -r- -b /tmp/finder-req.bin 2>/dev/null; then
    FINDER_HEX="$(xxd -p /tmp/finder-req.bin | tr -d '\n')"
fi
FINDER_ID="NULL"
[ -n "$FINDER_HEX" ] && FINDER_ID="X'$FINDER_HEX'"
for db in "$SYSTEM_DB" "$USER_DB"; do
    for client in "local.personal.toolbelt|0" "/usr/bin/osascript|1"; do
        sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) VALUES ('kTCCServiceAppleEvents', '${client%|*}', ${client#*|}, 2, 3, 1, NULL, 0, 'com.apple.finder', $FINDER_ID, 0, $(date +%s));" \
            || echo "Couldn't save the Finder permission in $db"
    done
done
echo "Finder permission rows: $(sqlite3 "$USER_DB" "SELECT client, auth_value FROM access WHERE service='kTCCServiceAppleEvents';" 2>&1 | tr '\n' ' ')"
# Make the test app the handler for its toolbelte2e: links (the web-search test's search site).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$E2E"
# Make macOS read the database again.
sudo killall tccd 2>/dev/null
killall tccd 2>/dev/null
sleep 2

# 3. Run it. `open` makes each app responsible for itself, which is what macOS checks permissions against.
DATA_DIR="$(mktemp -d -t toolbelt-e2e)"
rm -f "$RESULTS"
CRASHES_BEFORE="$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -ci toolbelt)"
echo "Running the $MODE test…"
open -W -n "$E2E" --args "$DATA_DIR" "$APP" "$RESULTS" "$MODE" "$MINUTES" &
OPEN_PID=$!
[ "$MODE" = "stability" ] && LIMIT=$(( (MINUTES + 5) * 60 )) || LIMIT=600
waited=0
shown=0
while kill -0 "$OPEN_PID" 2>/dev/null && [ "$waited" -lt "$LIMIT" ]; do
    sleep 5
    waited=$((waited + 5))
    # Show progress as it happens.
    if [ -f "$RESULTS" ]; then
        total="$(wc -l < "$RESULTS")"
        if [ "$total" -gt "$shown" ]; then
            tail -n +"$((shown + 1))" "$RESULTS" | head -n "$((total - shown))"
            shown="$total"
        fi
    fi
done
if kill -0 "$OPEN_PID" 2>/dev/null; then
    echo "✗ the test didn't finish within $((LIMIT / 60)) minutes"
    pkill -f ToolbeltE2E
    pkill -x Toolbelt
    kill "$OPEN_PID" 2>/dev/null
fi
[ -f "$RESULTS" ] && tail -n +"$((shown + 1))" "$RESULTS"
pkill -x Toolbelt 2>/dev/null

failed=0
if ! grep -q "^STATUS: ok" "$RESULTS" 2>/dev/null; then
    failed=1
fi
CRASHES_AFTER="$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -ci toolbelt)"
if [ "$CRASHES_AFTER" -gt "$CRASHES_BEFORE" ]; then
    echo "✗ macOS wrote a crash report for Toolbelt:"
    report="$(ls -t "$HOME/Library/Logs/DiagnosticReports" | grep -i toolbelt | head -1)"
    head -80 "$HOME/Library/Logs/DiagnosticReports/$report"
    failed=1
fi
if true; then
    echo "Toolbelt's log:"
    log show --last 15m --predicate 'process == "Toolbelt"' --style compact 2>/dev/null | grep -i "toolbelt:\|finder" | tail -40
fi
rm -rf "$DATA_DIR"

# Take back the permissions given above, so later steps (the screenshots) see the Mac as it was. Left in
# place, macOS asks to confirm Toolbelt's screen recording over the screenshots.
for db in "$SYSTEM_DB" "$USER_DB"; do
    sudo sqlite3 "$db" "DELETE FROM access WHERE client IN ('local.personal.toolbelt', 'local.toolbelt.e2e', '$APP/Contents/MacOS/Toolbelt', '$E2E/Contents/MacOS/ToolbeltE2E');" 2>/dev/null
done
sudo killall tccd 2>/dev/null
killall tccd 2>/dev/null
pkill -x Toolbelt 2>/dev/null
exit "$failed"
