#!/bin/bash
# Builds Toolbelt from source and installs it in your Applications folder.
# Run it from Terminal:  bash install.sh   (or type "bash " and drag this file in)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Toolbelt"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo ""
echo "=== Toolbelt installer ==="
echo ""

# 1. Apple's free command line developer tools provide the Swift compiler.
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apple's developer tools aren't installed yet."
    echo "A window will open: click Install and wait for it to finish (a few minutes),"
    echo "then run this script again."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

# 2. Compile
echo "Building… (takes about a minute the first time)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

xcrun swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -target "${ARCH}-apple-macos14.0" \
    -sdk "$SDK" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework ServiceManagement \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"

cp Info.plist "$APP/Contents/Info.plist"

# 3. Sign it for this Mac only (no Apple developer account needed)
codesign --force --sign - "$APP" >/dev/null 2>&1

# 4. Install to Applications
DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/$APP_NAME.app"
cp -R "$APP" "$DEST/"

echo ""
echo "Installed to $DEST/$APP_NAME.app"
echo "Starting Toolbelt — look for the clipboard icon in your menu bar."
echo "Press ⌘⇧V (Command-Shift-V) anywhere to open your history."
echo ""

open "$DEST/$APP_NAME.app"
