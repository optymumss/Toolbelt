#!/bin/bash
# Tests the Chrome extension in a real Chrome (Chrome for Testing) with the real app running:
# a download started in Chrome, the Download button on a video, and the toolbar popup.
# Run after build.sh, on a Mac with a logged-in screen.

set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"

DATA="$(mktemp -d -t toolbelt-chrome)"
DOWNLOADS="$(mktemp -d -t toolbelt-chrome-downloads)"
SITE="$(mktemp -d -t toolbelt-chrome-site)"
PROFILE="$(mktemp -d -t toolbelt-chrome-profile)"
trap 'kill $APP $SERVER 2>/dev/null; rm -rf "$DATA" "$DOWNLOADS" "$SITE" "$PROFILE"' EXIT

# Toolbelt saves downloads straight into a scratch folder.
cat > "$DATA/settings.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>downloads.folder</key><string>$DOWNLOADS</string>
  <key>downloads.sort</key><false/>
</dict></plist>
PLIST
TOOLBELT_DATA_DIR="$DATA" build/Toolbelt.app/Contents/MacOS/Toolbelt &
APP=$!

# A small website: a page with a download link and a video.
head -c 1500000 /dev/urandom > "$SITE/report.zip"
head -c 900000 /dev/urandom > "$SITE/clip.mp4"
cat > "$SITE/index.html" <<'HTML'
<!doctype html><html><body>
<h1>Toolbelt test page</h1>
<a id="link" href="report.zip" download>Download the report</a>
<p><video id="video" src="clip.mp4" width="400" height="225" controls></video></p>
</body></html>
HTML
python3 -m http.server 8765 --bind 127.0.0.1 --directory "$SITE" >/dev/null 2>&1 &
SERVER=$!

# Tell Chrome for Testing where ToolbeltBridge is (the same note Settings › Set Up Chrome writes for Chrome).
EXTENSION_ID=$(python3 - <<'PY'
import base64, hashlib, json
key = json.load(open("Chrome/manifest.json"))["key"]
digest = hashlib.sha256(base64.b64decode(key)).hexdigest()[:32]
print("".join(chr(ord("a") + int(c, 16)) for c in digest))
PY
)
for HOSTS in "$HOME/Library/Application Support/Google/Chrome for Testing/NativeMessagingHosts" \
             "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts" \
             "$HOME/Library/Application Support/Chromium/NativeMessagingHosts" \
             "$PROFILE/NativeMessagingHosts"; do
    mkdir -p "$HOSTS"
    cat > "$HOSTS/local.personal.toolbelt.json" <<JSON
{"name": "local.personal.toolbelt", "description": "Toolbelt download manager", "type": "stdio",
 "path": "$ROOT/build/Toolbelt.app/Contents/MacOS/ToolbeltBridge",
 "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]}
JSON
done

TOOL="$(mktemp -d -t toolbelt-puppeteer)"
(cd "$TOOL" && npm install --silent --no-audit --no-fund puppeteer@23.11.1 >/dev/null 2>&1) || { echo "✗ couldn't install Chrome for Testing"; exit 1; }
sleep 2
TOOLBELT_DATA_DIR="$DATA" TOOLBELT_BRIDGE_NO_LAUNCH=1 NODE_PATH="$TOOL/node_modules" \
    node .github/scripts/chrome-e2e.cjs "$ROOT/Chrome" "$EXTENSION_ID" "$DOWNLOADS" "http://127.0.0.1:8765/" "$PROFILE"
