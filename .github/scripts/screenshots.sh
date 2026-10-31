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
# A real screenshot copied to the clipboard, like pressing ⌃⇧⌘3
screencapture -c -x
sleep 2
if kill -0 "$pid" 2>/dev/null; then
    echo "✓ app starts and records copies"
else
    echo "✗ app quit or crashed on startup"
    failed=1
fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
echo "History file: $(ls "$DATA_DIR")"

# Two example snippets, as if you'd made them in Settings → Snippets
cat > "$DATA_DIR/snippets.json" <<'JSON'
[
  {"id": "5D3C1E2A-0000-4000-8000-000000000001", "keyword": ";addr", "name": "Home address", "text": "42 Example Street\nLondon N1 1AA"},
  {"id": "5D3C1E2A-0000-4000-8000-000000000002", "keyword": ";sig", "name": "Email sign-off", "text": "Best wishes,\n{cursor}\n\nSent {date}", "folder": "Email"},
  {"id": "5D3C1E2A-0000-4000-8000-000000000003", "keyword": ";thx", "name": "Thank you", "text": "Hi {input:Name}, thanks for {input:What|your help}!", "folder": "Email"}
]
JSON

# Files to put on a shelf
mkdir -p "$HOME/Desktop"
printf 'Agenda\n1. Budget\n2. Launch date\n' > "$HOME/Desktop/Meeting notes.txt"
screencapture -x "$HOME/Desktop/Screenshot.png"

# Downloads in each state: paused part-way, finished, and failed
mkdir -p "$HOME/Downloads/Programs"
mkfile -n 50m "$HOME/Downloads/Programs/macOS-Tools.dmg"
cat > "$DATA_DIR/downloads.json" <<JSON
[
  {"id": "6E3C1E2A-0000-4000-8000-000000000001", "url": "https://example.com/files/Holiday-video.mp4", "name": "Holiday-video.mp4",
   "state": "paused", "received": 157286400, "total": 367001600, "segments": [], "acceptsRanges": true, "added": 0},
  {"id": "6E3C1E2A-0000-4000-8000-000000000002", "url": "https://example.com/macOS-Tools.dmg", "name": "macOS-Tools.dmg",
   "state": "completed", "received": 52428800, "total": 52428800, "segments": [], "acceptsRanges": true,
   "finalPath": "$HOME/Downloads/Programs/macOS-Tools.dmg", "added": 0, "finished": 0},
  {"id": "6E3C1E2A-0000-4000-8000-000000000003", "url": "https://example.com/report.pdf", "name": "Quarterly report.pdf",
   "state": "failed", "received": 0, "segments": [], "acceptsRanges": false,
   "error": "The server answered 404 (not found).", "added": 0},
  {"id": "6E3C1E2A-0000-4000-8000-000000000004", "url": "https://example.com/files/Big-update.pkg", "name": "Big-update.pkg",
   "state": "queued", "received": 0, "segments": [], "acceptsRanges": false, "added": 0,
   "queueID": "7F3C1E2A-0000-4000-8000-000000000002"}
]
JSON
# A second queue for overnight downloads, stopped until it's due
cat > "$DATA_DIR/download-queues.json" <<'JSON'
[
  {"id": "7F3C1E2A-0000-4000-8000-000000000001", "name": "Main", "maxAtOnce": 3, "isRunning": true},
  {"id": "7F3C1E2A-0000-4000-8000-000000000002", "name": "Overnight", "maxAtOnce": 2, "isRunning": false, "stopAt": 420}
]
JSON

# 2. One launch per screen: "file name=what TOOLBELT_SHOW opens"
SCREENS=(
    "menu=menu"
    "settings-general=settings-general"
    "settings-shortcuts=settings-shortcuts"
    "settings-permissions=settings-permissions"
    "settings-clipboard=settings-clipboard"
    "clipboard=clipboard"
    "clipboard-preview=clipboard-preview"
    "clipboard-grid=clipboard-grid"
    "clipboard-strip=clipboard-strip"
    "clipboard-extras=clipboard-extras"
    "settings-launcher=settings-launcher"
    "launcher-empty=launcher:"
    "launcher-apps=launcher:saf"
    "launcher-calculator=launcher:(12 + 8) * 15%"
    "launcher-convert=launcher:5 km in miles"
    "launcher-quicklink=launcher:g cats"
    "launcher-command=launcher:lock"
    "launcher-clipboard=launcher:example street"
    "launcher-windows=launcher:left half"
    "settings-windows=settings-windows"
    "windows-left-half=windows-left-half"
    "windows-top-right=windows-top-right"
    "windows-center=windows-center"
    "windows-snap-preview=windows-snap-preview"
    "snap-areas-editor=snap-areas-editor"
    "settings-snippets=settings-snippets"
    "launcher-snippet=launcher:address"
    "snippet-picker=snippet-picker"
    "snippet-form=snippet-form"
    "settings-shelf=settings-shelf"
    "shelf-demo=shelf-demo"
    "drop-grid=drop-grid"
    "settings-downloads=settings-downloads"
    "downloads=downloads"
    "launcher-download=launcher:https://example.com/files/big-file.zip"
    "settings-screenshots=settings-screenshots"
    "screenshot-editor=screenshot-editor"
    "launcher-screenshot=launcher:screenshot"
    "settings-gestures=settings-gestures"
    "macros=macros"
    "settings-automation=settings-automation"
    "launcher-switcher=launcher-switcher"
    "notes-demo=notes-demo"
)
for entry in "${SCREENS[@]}"; do
    screen="${entry%%=*}"
    TOOLBELT_SHOW="${entry#*=}" "$APP_BIN" &
    pid=$!
    sleep 5
    if kill -0 "$pid" 2>/dev/null; then
        screencapture -x "$OUT/$screen.png"
        echo "✓ $screen"
    else
        echo "✗ $screen: app quit or crashed"
        failed=1
    fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    # Notes stay on screen by design; remove the demo ones so later screens are clear.
    [ "$screen" = "notes-demo" ] && rm -f "$DATA_DIR/notes.json"
    [ "$screen" = "snap-areas-editor" ] && rm -f "$DATA_DIR/snapareas.json"
    [ "$screen" = "shelf-demo" ] && rm -f "$DATA_DIR/shelves.json"
    [ "$screen" = "settings-gestures" ] && rm -f "$DATA_DIR/gestures.json"
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
