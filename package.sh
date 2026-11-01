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
# In two steps (a plain image, then compressed): making the compressed image in one go sometimes
# gives a file macOS can't open.
RAW="$STAGE-raw.dmg"
trap 'rm -rf "$STAGE" "$RAW"' EXIT
hdiutil create -volname "Toolbelt $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RAW" >/dev/null
hdiutil convert "$RAW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
if ! hdiutil verify -quiet "$DMG"; then
    echo "✗ the new disk image doesn't verify"
    du -sh "$STAGE"; find "$STAGE" -type f -size +5M -exec ls -l {} \;
    hdiutil verify "$DMG" 2>&1 | tail -5 || true
    exit 1
fi
echo "✓ $DMG (Toolbelt $VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' '))"
