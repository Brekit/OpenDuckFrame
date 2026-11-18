#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc "$ROOT/Apps/Mac/Capture/CaptureCardPolicy.swift" "$ROOT/Tests/CaptureCard/main.swift" -o "$TEST_DIR/policy"
"$TEST_DIR/policy"
if [[ "${1:-}" == "--bundle" ]]; then
    APP="${2:?supply a built .app}"
    for key in NSCameraUsageDescription NSMicrophoneUsageDescription; do
        value="$(plutil -extract "$key" raw -o - "$APP/Contents/Info.plist")"
        [[ -n "$value" ]] || { echo "Missing privacy description: $key" >&2; exit 1; }
    done
    echo "Capture card privacy descriptions are present in the actual bundle."
fi
if [[ "${1:-}" == "--gpu" ]]; then
    PRODUCTS="$ROOT/.build/Build/Products/Debug"
    xcrun clang++ -std=c++17 -fobjc-arc -I "$ROOT/Apps/Mac/Capture" \
        "$ROOT/Tests/CaptureCard/LiveProcessor.mm" -framework AppKit -framework Foundation \
        -framework CoreVideo -framework CoreMedia -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/live"
    "$TEST_DIR/live" "$PRODUCTS/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame.debug.dylib"
fi
