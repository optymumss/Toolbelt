#!/bin/bash
# Launches the built app once per screen, checks it stays running,
# and saves a screenshot of each screen to screenshots/.
# Run after build.sh, on a Mac with a logged-in screen (GitHub's macOS runners have one).

set -uo pipefail
cd "$(dirname "$0")/../.."

APP_BIN="build/Toolbelt.app/Contents/MacOS/Toolbelt"
OUT="screenshots"
DATA_DIR="$(mktemp -d -t toolbelt-shots)"
rm -rf "$OUT" && mkdir -p "$OUT"
export TOOLBELT_DATA_DIR="$DATA_DIR"
failed=0

# 1. Start once and copy a few things so the clipboard panel has something to show.
"$APP_BIN" &
pid=$!
sleep 3
for text in "Meeting notes: send the report by Friday" "https://www.apple.com/macos" "42 Example Street, London" "Hello from Toolbelt"; do
    printf '%s' "$text" | pbcopy
    sleep 1
done
sleep 2
if kill -0 "$pid" 2>/dev/null; then
    echo "✓ app starts and records copies"
else
    echo "✗ app quit or crashed on startup"
    failed=1
fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
echo "History file: $(ls "$DATA_DIR")"

# 2. One launch per screen
for screen in menu settings-general settings-shortcuts settings-permissions settings-clipboard clipboard; do
    TOOLBELT_SHOW="$screen" "$APP_BIN" &
    pid=$!
    sleep 4
    if kill -0 "$pid" 2>/dev/null; then
        screencapture -x "$OUT/$screen.png"
        echo "✓ $screen"
    else
        echo "✗ $screen: app quit or crashed"
        failed=1
    fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    sleep 1
done

# Smaller copies that are quick to look at
for f in "$OUT"/*.png; do
    sips -Z 1600 "$f" >/dev/null 2>&1 || true
done

if [ "$failed" -ne 0 ]; then
    echo "Recent crash reports:"
    ls -t ~/Library/Logs/DiagnosticReports/Toolbelt* 2>/dev/null | head -1 | xargs -I{} head -80 {}
fi
rm -rf "$DATA_DIR"
exit "$failed"
