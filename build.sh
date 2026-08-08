#!/bin/bash
set -euo pipefail

APP_NAME="Counterfoil"
BUNDLE_DIR="build/${APP_NAME}.app"
BINARY="${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
SDK="$(xcrun --show-sdk-path)"
FRAMEWORKS="-framework SwiftUI -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework CoreML -framework Combine"

echo "==> Cleaning build/"
rm -rf build
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

echo "==> Compiling app (Sources/*.swift)"
swiftc -O -swift-version 5 \
    -parse-as-library \
    -target arm64-apple-macos15.0 \
    -sdk "$SDK" \
    $FRAMEWORKS \
    Sources/*.swift \
    -o "${BINARY}"

echo "==> Compiling CLI harness (counterfoil-cli)"
mkdir -p build/cli
swiftc -O -swift-version 5 \
    -parse-as-library \
    -target arm64-apple-macos15.0 \
    -sdk "$SDK" \
    -framework AVFoundation -framework CoreML \
    Sources/Transcribe.swift cli/CLIMain.swift \
    -o build/cli/counterfoil-cli

echo "==> Copying Info.plist"
cp Info.plist "${BUNDLE_DIR}/Contents/Info.plist"

echo "==> Converting AppIcon.png -> AppIcon.icns"
ICONSET_DIR="build/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"

SIZES=(16 32 64 128 256 512)
for s in "${SIZES[@]}"; do
    sips -z $s $s Assets/AppIcon.png --out "${ICONSET_DIR}/icon_${s}x${s}.png" > /dev/null 2>&1
done
cp "${ICONSET_DIR}/icon_512x512.png" "${ICONSET_DIR}/icon_512x512@2x.png"

iconutil -c icns "${ICONSET_DIR}" -o "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing"
codesign --force --sign - "${BUNDLE_DIR}"

echo "==> Installing to /Applications"
cp -R "${BUNDLE_DIR}" /Applications/

echo "==> Done. App at /Applications/${APP_NAME}.app, CLI at build/cli/counterfoil-cli"
codesign -dv "/Applications/${APP_NAME}.app" 2>&1 || true
