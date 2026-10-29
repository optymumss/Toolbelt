#!/bin/bash
# Runs Toolbelt's automated checks on this Mac (also run by the automatic check on GitHub).
# Uses a scratch data folder, so your own history and settings are never touched.
# Note: it uses the real clipboard, so anything you've copied will be replaced.

set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apple's developer tools aren't installed. Run install.sh first."
    exit 1
fi

mkdir -p build
ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

# Everything in Sources except the app's startup file, plus the tests
SOURCES=()
while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find Sources Tests -name '*.swift' ! -path 'Sources/App/App.swift' | sort)

echo "Building tests…"
xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -target "${ARCH}-apple-macos14.0" \
    -sdk "$SDK" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework ServiceManagement \
    -framework IOKit \
    "${SOURCES[@]}" \
    -o build/ToolbeltTests

DATA_DIR="$(mktemp -d -t toolbelt-test)"
trap 'rm -rf "$DATA_DIR"' EXIT

echo "Running tests…"
TOOLBELT_DATA_DIR="$DATA_DIR" ./build/ToolbeltTests
