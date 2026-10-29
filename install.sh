#!/bin/bash
# Builds Toolbelt from source and installs it in your Applications folder.
# Run it from Terminal:  bash install.sh   (or type "bash " and drag this file in)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Toolbelt"
APP="build/$APP_NAME.app"

echo ""
echo "=== Toolbelt installer ==="
echo ""

# 1. Build
bash ./build.sh

# 2. Install to Applications
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
echo "Starting Toolbelt — look for the toolbox icon (a wrench and screwdriver) in your menu bar."
echo "Press ⌘⇧V (Command-Shift-V) anywhere to open your clipboard history."
echo ""
echo "Updated from an earlier version? macOS forgets Toolbelt's permissions after each update."
echo "If auto-paste stops working: System Settings → Privacy & Security → Accessibility,"
echo "select Toolbelt, click –, and Toolbelt will ask again the next time it pastes."
echo ""

open "$DEST/$APP_NAME.app"
