#!/bin/bash
# Packs build/Toolbelt.app into build/Toolbelt.dmg: a disk image with the app and a shortcut
# to Applications, so installing is "drag the icon onto Applications".
# Run after build.sh. The automatic build on GitHub does this and attaches the DMG to a release.

set -euo pipefail
cd "$(dirname "$0")"

APP="build/Toolbelt.app"
DMG="build/Toolbelt.dmg"
[ -d "$APP" ] || { echo "Run build.sh first."; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGE="$(mktemp -d -t toolbelt-dmg)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/Toolbelt.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Toolbelt $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
if ! hdiutil verify -quiet "$DMG"; then
    echo "✗ the new disk image doesn't verify"
    du -sh "$STAGE"; find "$STAGE" -type f -size +5M -exec ls -l {} \;
    xxd "$DMG" | head -4; tail -c 512 "$DMG" | xxd | head -4
    exit 1
fi
echo "✓ $DMG (Toolbelt $VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' '))"
