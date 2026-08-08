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
    -target arm64-apple-macos26.0 \
    -sdk "$SDK" \
    $FRAMEWORKS \
    Sources/*.swift \
    -o "${BINARY}"

echo "==> Compiling CLI harness (counterfoil-cli)"
mkdir -p build/cli
swiftc -O -swift-version 5 \
    -parse-as-library \
    -target arm64-apple-macos26.0 \
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

# Keep every standard macOS icon slot, including the 16px files used by
# menus, Finder, and the Dock. iconutil maps these iconset names to the
# ic04/ic05/ic07/ic08/ic09/ic10/ic11/ic12/ic13/ic14 ICNS entries.
for s in 16 32 128 256 512; do
    double=$((s * 2))
    sips -z "$s" "$s" Assets/AppIcon.png --out "${ICONSET_DIR}/icon_${s}x${s}.png" > /dev/null 2>&1
    sips -z "$double" "$double" Assets/AppIcon.png --out "${ICONSET_DIR}/icon_${s}x${s}@2x.png" > /dev/null 2>&1
    test -s "${ICONSET_DIR}/icon_${s}x${s}.png"
    test -s "${ICONSET_DIR}/icon_${s}x${s}@2x.png"
done

if ! iconutil -c icns "${ICONSET_DIR}" -o "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"; then
    echo "==> iconutil rejected the iconset; assembling the standard ICNS entries"
    ICON_TMP="${PWD}/build/icon-tmp"
    mkdir -p "${ICON_TMP}"
    ICON_1024_JP2="${PWD}/build/AppIcon-1024.jp2"
    TMPDIR="${ICON_TMP}" sips -s format public.jpeg-2000 \
        "${ICONSET_DIR}/icon_512x512@2x.png" --out "${ICON_1024_JP2}" > /dev/null

    # A few current Command Line Tools builds reject otherwise valid
    # iconsets. The ICNS container is small and documented: a four-byte type,
    # a big-endian chunk length, and the image payload. Keep all standard
    # macOS entries without adding a runtime dependency or shipping a
    # single-size fallback.
    perl - "${ICONSET_DIR}" "${ICON_1024_JP2}" \
        "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns" <<'PERL'
use strict;
use warnings;

my ($iconset, $jp2, $output) = @ARGV;
my @items = (
    ["ic04", "icon_16x16.png"],
    ["ic05", "icon_32x32.png"],
    ["ic07", "icon_128x128.png"],
    ["ic08", "icon_256x256.png"],
    ["ic09", "icon_512x512.png"],
    ["ic10", $jp2],
    ["ic11", "icon_16x16\@2x.png"],
    ["ic12", "icon_32x32\@2x.png"],
    ["ic13", "icon_128x128\@2x.png"],
    ["ic14", "icon_256x256\@2x.png"],
);

my @chunks;
my $total = 8;
for my $item (@items) {
    my $path = $item->[1] =~ m{^/} ? $item->[1] : "$iconset/$item->[1]";
    open my $input, '<:raw', $path or die "$path: $!\n";
    local $/;
    my $data = <$input>;
    close $input;
    my $length = 8 + length($data);
    push @chunks, [$item->[0], $length, $data];
    $total += $length;
}

open my $output_file, '>:raw', $output or die "$output: $!\n";
print $output_file 'icns', pack('N', $total);
for my $chunk (@chunks) {
    print $output_file $chunk->[0], pack('N', $chunk->[1]), $chunk->[2];
}
close $output_file;
PERL
fi
test -s "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"

# Round-trip the generated ICNS and decode its manifest so a blank or
# single-size fallback cannot silently ship as the application icon.
ICON_ROUNDTRIP="build/AppIcon-roundtrip.png"
sips -s format png "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns" --out "${ICON_ROUNDTRIP}" > /dev/null
test -s "${ICON_ROUNDTRIP}"
ICON_VERIFY_DIR="build/AppIcon.verify.iconset"
iconutil -c iconset "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns" -o "${ICON_VERIFY_DIR}"
for expected in \
    icon_16x16.png icon_16x16@2x.png \
    icon_32x32.png icon_32x32@2x.png \
    icon_128x128.png icon_128x128@2x.png \
    icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png; do
    test -s "${ICON_VERIFY_DIR}/${expected}"
done

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

touch "${INSTALL_PATH}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "${LSREGISTER}" ]; then
    "${LSREGISTER}" -f "${INSTALL_PATH}" > /dev/null 2>&1 || true
fi

echo "==> Done. App at ${INSTALL_PATH}, CLI at build/cli/counterfoil-cli"
codesign -dv "${INSTALL_PATH}" 2>&1 || true

# If Finder or the Dock still shows the old icon after reinstalling, relaunch
# Finder/Dock once; the install step above already re-registers this bundle.
# killall Finder
# killall Dock
