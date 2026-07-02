#!/bin/bash
# BetterVoice DMG packaging script
#
# Usage:
#   ./scripts/build-dmg.sh           # use the version from Info.plist
#   ./scripts/build-dmg.sh 0.2.0     # explicitly override the version
#
# Output: .build/BetterVoice-<version>.dmg
#
# Signing strategy: ad-hoc signing (codesign -s -).
# On first install the user must run `xattr -cr /Applications/BetterVoice.app` to
# bypass Gatekeeper. See scripts/INSTALL.txt for the full install steps.

set -euo pipefail

# cd into the client dir (the script may be invoked from anywhere)
cd "$(dirname "$0")/.."

INFO_PLIST="Sources/Info.plist"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/BetterVoice.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"

# Signing identity: prefer a stable self-signed cert so TCC permissions survive
# Sparkle in-place updates. (Ad-hoc changes hash every build -> designated requirement
# changes -> the 4 permissions get reset and must be re-granted after each update.)
# Override with: SIGN_IDENTITY="Apple Development: ..." ./scripts/build-dmg.sh
SIGN_IDENTITY="${SIGN_IDENTITY:-Better Voice Development}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "Signing identity: $SIGN_IDENTITY (stable — TCC survives in-place updates)"
else
    echo "WARNING: signing identity '$SIGN_IDENTITY' not found; falling back to ad-hoc (-)."
    echo "         Run 'make setup' first so permissions survive Sparkle updates."
    SIGN_IDENTITY="-"
fi

# 1) Resolve the version
if [ $# -ge 1 ]; then
    VERSION="$1"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
fi
DMG_NAME="BetterVoice-${VERSION}.dmg"
VOL_NAME="Better Voice ${VERSION}"
STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "=== Building Better Voice ${VERSION} ==="

# 2) Release build
echo "[1/5] swift build -c release..."
swift build -c release

# 3) Assemble the .app bundle
echo "[2/6] Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_DIR/release/BetterVoice" "$APP_MACOS/BetterVoice"
cp "$INFO_PLIST" "$APP_CONTENTS/Info.plist"
# App icon (Contents/Resources/AppIcon.icns, referenced by CFBundleIconFile).
# LSUIElement app -> shows in Finder / Get Info / System Settings, not the Dock.
mkdir -p "$APP_CONTENTS/Resources"
cp icon/AppIcon.icns "$APP_CONTENTS/Resources/AppIcon.icns"
# SwiftPM resource bundle (Bundle.module). The BetterVoice target declares
# resources: [.process("Resources")], so `swift build` emits BetterVoice_BetterVoice.bundle
# next to the binary. SPM does NOT embed it into the .app — without it the app fatal-errors on
# launch ("could not load resource bundle") and dies before showing its menu-bar item. Copy it
# into Contents/Resources so Bundle.main.resourceURL resolves it. MUST precede codesign so the
# outer signature seals it.
RESOURCE_BUNDLE="$BUILD_DIR/release/BetterVoice_BetterVoice.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "ERROR: SwiftPM resource bundle not found at $RESOURCE_BUNDLE"
    echo "       (expected from 'swift build -c release'; confirm the target still declares"
    echo "        resources: [.process(\"Resources\")] in Package.swift)"
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP_CONTENTS/Resources/"
# PkgInfo: macOS LaunchServices uses it to identify the bundle type (type=APPL/creator=????).
# Without this file LaunchServices may not register the bundle id, so TCC can't find the
# app and permission prompts (mic / speech recognition) never appear.
printf 'APPL????' > "$APP_CONTENTS/PkgInfo"

# 3b) Embed Sparkle.framework (SPM only produces the framework; it isn't auto-embedded
#     into the .app, so copy + sign it manually).
echo "[3/6] Embedding Sparkle.framework..."
BIN_PATH="$(swift build -c release --show-bin-path)"
SPARKLE_SRC="$BIN_PATH/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "ERROR: Sparkle.framework not found at $SPARKLE_SRC"
    echo "       (confirm the Sparkle SPM dependency resolved: swift build -c release)"
    exit 1
fi
mkdir -p "$APP_FRAMEWORKS"
rm -rf "$APP_FRAMEWORKS/Sparkle.framework"
cp -R "$SPARKLE_SRC" "$APP_FRAMEWORKS/Sparkle.framework"
# Let the executable find the framework at @executable_path/../Frameworks
# (must modify the binary before signing).
if ! otool -l "$APP_MACOS/BetterVoice" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_MACOS/BetterVoice"
fi

# 4) Codesign (inside-out: framework first — it contains embedded
#    XPCServices/Autoupdate/Updater.app — then the outer app).
# NOTE: no --options runtime (hardened runtime). Reason:
#   ad-hoc signing can't carry entitlements, and hardened runtime would require
#   entitlements like com.apple.security.device.audio-input, otherwise mic access is
#   denied outright (no permission prompt at all). Info.plist's NSMicrophoneUsageDescription
#   isn't enough under hardened runtime. Add both back together when we do notarization.
echo "[4/6] Codesigning ($SIGN_IDENTITY)..."
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_FRAMEWORKS/Sparkle.framework"
codesign --force --sign "$SIGN_IDENTITY" "$APP_MACOS/BetterVoice"
codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE" || {
    echo "ERROR: codesign verification failed"
    exit 1
}

# 5) Prepare the DMG staging directory
echo "[5/6] Staging DMG content..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/BetterVoice.app"
ln -s /Applications "$STAGING/Applications"
cp scripts/INSTALL.txt "$STAGING/INSTALL.txt"

# 6) Build the DMG (for the first manual install) + zip (for the Sparkle appcast,
#    which generate_appcast handles more easily).
echo "[6/6] Creating DMG + appcast zip..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

ZIP_PATH="$BUILD_DIR/BetterVoice-$VERSION.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# clean up staging
rm -rf "$STAGING"

# output
SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo ""
echo "=== Done ==="
echo "  DMG:     $DMG_PATH"
echo "  Zip:     $ZIP_PATH  (upload to the GitHub Release; referenced by appcast.xml)"
echo "  Volume:  $VOL_NAME"
echo "  Size:    $SIZE"
echo "  Version: $VERSION"
echo ""
echo "Next (release): ./scripts/release.sh   # signs the appcast entry via generate_appcast"
echo "Test:    open $DMG_PATH"
echo "Install: drag BetterVoice.app to /Applications, then run:"
echo "         xattr -cr /Applications/BetterVoice.app"
