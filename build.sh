#!/bin/bash
# Compiles Toolbelt into build/Toolbelt.app. install.sh runs this for you.
# Also used by the automatic build check on GitHub.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Toolbelt"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

# Apple's free command line developer tools provide the Swift compiler.
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apple's developer tools aren't installed yet."
    echo "A window will open: click Install and wait for it to finish (a few minutes),"
    echo "then run this script again."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

echo "Building… (takes about a minute)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

# Every .swift file in Sources and its subfolders
SOURCES=()
while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find Sources -name '*.swift' | sort)

# -O with whole-module optimisation: the fastest, most energy-efficient code on Apple silicon (M-series).
xcrun swiftc \
    -O -whole-module-optimization \
    -parse-as-library \
    -swift-version 5 \
    -target "${ARCH}-apple-macos14.0" \
    -sdk "$SDK" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework ServiceManagement \
    -framework IOKit \
    -framework Quartz \
    -framework Vision \
    -framework CoreWLAN \
    -framework CoreLocation \
    -framework CoreAudio \
    -framework Network \
    "${SOURCES[@]}" \
    -o "$APP/Contents/MacOS/$APP_NAME"

# The small helper Chrome talks to (see Bridge/main.swift), and the Chrome extension.
xcrun swiftc \
    -O \
    -swift-version 5 \
    -target "${ARCH}-apple-macos14.0" \
    -sdk "$SDK" \
    -framework AppKit \
    Bridge/main.swift \
    -o "$APP/Contents/MacOS/ToolbeltBridge"
cp -R Chrome "$APP/Contents/Resources/ChromeExtension"

cp Info.plist "$APP/Contents/Info.plist"

# Sign it for this Mac only (no Apple developer account needed)
codesign --force --sign - "$APP/Contents/MacOS/ToolbeltBridge" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $APP"
