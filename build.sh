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

# Keep compiler caches inside the disposable build tree. This also makes the
# script work in locked-down environments where the default user cache is not
# writable.
COUNTERFOIL_MODULE_CACHE="${PWD}/build/module-cache"
mkdir -p "${COUNTERFOIL_MODULE_CACHE}"
export SWIFT_MODULECACHE_PATH="${COUNTERFOIL_MODULE_CACHE}"
export CLANG_MODULE_CACHE_PATH="${COUNTERFOIL_MODULE_CACHE}"

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
    Sources/Transcribe.swift Sources/SettingsStore.swift cli/CLIMain.swift \
    -o build/cli/counterfoil-cli

echo "==> Copying Info.plist"
cp Info.plist "${BUNDLE_DIR}/Contents/Info.plist"

echo "==> Converting AppIcon.png -> AppIcon.icns"
ICONSET_DIR="build/AppIcon.iconset"
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

for s in 16 32 128 256 512; do
    double=$((s * 2))
    sips -z "$s" "$s" Assets/AppIcon.png --out "${ICONSET_DIR}/icon_${s}x${s}.png" > /dev/null 2>&1
    sips -z "$double" "$double" Assets/AppIcon.png --out "${ICONSET_DIR}/icon_${s}x${s}@2x.png" > /dev/null 2>&1
done

if ! iconutil -c icns "${ICONSET_DIR}" -o "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"; then
    # Some Command Line Tools releases reject otherwise valid iconsets. Keep
    # the bundle's icon valid by letting the system image converter write a
    # high-resolution single-size ICNS rather than shipping no icon at all.
    echo "==> iconutil rejected the iconset; using sips ICNS fallback"
    SIPS_TMP="${PWD}/build/sips-tmp"
    mkdir -p "${SIPS_TMP}"
    TMPDIR="${SIPS_TMP}" sips -s format icns "${ICONSET_DIR}/icon_512x512.png" \
        --out "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns" > /dev/null
fi
test -s "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"

echo "==> Signing (stable identity if available, else ad-hoc)"
if security find-identity -p codesigning -v ~/Library/Keychains/cfoil-dev.keychain-db 2>/dev/null | grep -q "Counterfoil Dev"; then
    security unlock-keychain -p devpass ~/Library/Keychains/cfoil-dev.keychain-db > /dev/null 2>&1
    codesign --force --sign "Counterfoil Dev" --keychain ~/Library/Keychains/cfoil-dev.keychain-db "${BUNDLE_DIR}" \
        || codesign --force --sign - "${BUNDLE_DIR}"
else
    codesign --force --sign - "${BUNDLE_DIR}"
fi

echo "==> Installing to /Applications"
if cp -R "${BUNDLE_DIR}" /Applications/; then
    INSTALL_PATH="/Applications/${APP_NAME}.app"
else
    echo "==> /Applications is not writable; leaving the verified app at ${BUNDLE_DIR}"
    INSTALL_PATH="${BUNDLE_DIR}"
fi

echo "==> Done. App at ${INSTALL_PATH}, CLI at build/cli/counterfoil-cli"
codesign -dv "${INSTALL_PATH}" 2>&1 || true

# If Finder or the Dock still shows the old generic icon after reinstalling,
# re-register the app once, then relaunch Finder/Dock:
# /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
#     -kill -r -domain local -domain system -domain user
# killall Finder
# killall Dock
