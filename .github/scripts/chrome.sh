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
# TOOLBELT_E2E=1: Toolbelt writes e2e-status.json, where the test reads the list of links it shows.
TOOLBELT_DATA_DIR="$DATA" TOOLBELT_E2E=1 build/Toolbelt.app/Contents/MacOS/Toolbelt &
APP=$!

# A small website: a page with a download link and videos, and a page that streams a video the way
# video sites do (a playlist listing it at 360p, 720p and 1080p, played through a blob: address).
head -c 1500000 /dev/urandom > "$SITE/report.zip"
head -c 900000 /dev/urandom > "$SITE/clip.mp4"
head -c 700000 /dev/urandom > "$SITE/clip-720.mp4"
head -c 300000 /dev/urandom > "$SITE/clip-360.mp4"
cp -R Tests/Fixtures/hls "$SITE/hls"
cat > "$SITE/hls/protected.m3u8" <<'M3U8'
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
protected-720.m3u8
M3U8
cat > "$SITE/hls/protected-720.m3u8" <<'M3U8'
#EXTM3U
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key",KEYFORMAT="com.apple.streamingkeydelivery"
#EXTINF:2.0,
seg0.ts
#EXT-X-ENDLIST
M3U8
cat > "$SITE/index.html" <<'HTML'
<!doctype html><html><head><title>Toolbelt test page</title></head><body>
<h1>Toolbelt test page</h1>
<a id="link" href="report.zip" download>Download the report</a>
<p><video id="video" src="clip.mp4" width="400" height="225" controls></video></p>
<p><video id="multi" width="400" height="225" controls>
  <source src="clip-720.mp4" type="video/mp4" label="720p">
  <source src="clip-360.mp4" type="video/mp4" label="360p">
</video></p>
</body></html>
HTML
cat > "$SITE/links.html" <<'HTML'
<!doctype html><html><head><title>Toolbelt links test</title></head><body>
<a href="report.zip">The report</a> <a href="guide.pdf">Guide</a> <a href="other.html">Another page</a>
<img src="pic.png" alt="A picture"> <a href="mailto:someone@example.com">Mail</a>
</body></html>
HTML
for page in stream protected; do
  playlist=$([ $page = stream ] && echo master || echo protected)
  cat > "$SITE/$page.html" <<HTML
<!doctype html><html><head><title>Toolbelt $page test</title></head><body>
<video id="stream" width="640" height="360" controls></video>
<script>
  const video = document.getElementById("stream");
  video.src = URL.createObjectURL(new MediaSource());
  fetch("hls/$playlist.m3u8").then((r) => r.text()).then(() => (document.body.dataset.loaded = "yes"));
</script>
</body></html>
HTML
done
# Served with node (already needed for the test). Python's server timed out here once the real-use
# tests had run their own Python server earlier in the same job.
node .github/scripts/static-server.cjs "$(cd "$SITE" && pwd -P)" 8765 &
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
# Wait until the test site answers; if it never does, say why rather than failing inside Chrome.
for _ in $(seq 1 40); do
    curl -fsS -m 2 -o /dev/null http://127.0.0.1:8765/ && break
    sleep 0.5
done
if ! curl -fsS -m 5 -o /dev/null http://127.0.0.1:8765/; then
    echo "✗ the test web site on 127.0.0.1:8765 doesn't answer"
    echo "firewall: $(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>&1)"
    lsof -nP -iTCP:8765 2>&1 | head -5
    exit 1
fi
TOOLBELT_DATA_DIR="$DATA" TOOLBELT_BRIDGE_NO_LAUNCH=1 NODE_PATH="$TOOL/node_modules" \
    node .github/scripts/chrome-e2e.cjs "$ROOT/Chrome" "$EXTENSION_ID" "$DOWNLOADS" "http://127.0.0.1:8765/" "$PROFILE"
