#!/bin/bash
# BetterVoice2 DMG packaging script
#
# Usage:
#   ./scripts/build-dmg.sh           # use the version from Info.plist
#   ./scripts/build-dmg.sh 0.2.0     # explicitly override the version
#
# Output: .build/BetterVoice2-<version>.dmg
#
# Signing strategy: ad-hoc signing (codesign -s -).
# On first install the user must run `xattr -cr /Applications/BetterVoice2.app` to
# bypass Gatekeeper. See scripts/INSTALL.txt for the full install steps.

set -euo pipefail

# cd into the client dir (the script may be invoked from anywhere)
cd "$(dirname "$0")/.."

INFO_PLIST="Sources/Info.plist"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/BetterVoice2.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"

# Signing strategy — two channels:
#
#   RELEASE (notarized): if a "Developer ID Application" identity is present we sign with it
#     under the Hardened Runtime (+ entitlements + secure timestamp) and notarize + staple.
#     This is the 1.0+ public channel: users just drag-to-install, no `xattr` hack. The
#     Developer ID identity is stable, so Sparkle in-place updates keep TCC permissions.
#
#   DEV/BETA (self-signed or ad-hoc): if no Developer ID identity exists (e.g. CI, or a dev
#     machine before `make setup`) we fall back to the stable self-signed "Better Voice
#     Development" cert, or ad-hoc as a last resort. No hardened runtime, no notarization —
#     testers still need the `xattr -cr` step. Force this channel with NOTARIZE=0.
#
# Overrides:
#   DEVID_IDENTITY="Developer ID Application: NAME (TEAMID)"  # pick a specific Developer ID cert
#   SIGN_IDENTITY="Apple Development: ..."                    # force a specific dev identity
#   NOTARIZE=0                                                # skip notarization even if DevID present
#   NOTARY_PROFILE="BaselineMakes-Notary"                    # notarytool keychain profile name

NOTARY_PROFILE="${NOTARY_PROFILE:-BaselineMakes-Notary}"
ENTITLEMENTS="BetterVoice2.entitlements"

# Auto-detect a Developer ID Application identity unless one was passed explicitly.
# `|| true` keeps `set -e`/pipefail from aborting when there's no such cert (CI/beta machines):
# grep exits non-zero on no match, which would otherwise kill the script here.
if [ -z "${DEVID_IDENTITY:-}" ]; then
    DEVID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' | head -1 | sed -E 's/^[^"]*"([^"]+)".*/\1/')" || true
fi

HARDENED_RUNTIME=0
NOTARIZE="${NOTARIZE:-1}"
CHANNEL="dev"
if [ -n "$DEVID_IDENTITY" ] && [ "$NOTARIZE" != "0" ]; then
    # ---- Release channel ----
    CHANNEL="release"
    SIGN_IDENTITY="$DEVID_IDENTITY"
    HARDENED_RUNTIME=1
    echo "Signing identity: $SIGN_IDENTITY (Developer ID — hardened runtime + notarization)"
    if [ ! -f "$ENTITLEMENTS" ]; then
        echo "ERROR: entitlements file '$ENTITLEMENTS' not found (needed for hardened-runtime mic access)."
        exit 1
    fi
else
    # ---- Dev/beta channel ----
    NOTARIZE=0
    SIGN_IDENTITY="${SIGN_IDENTITY:-Better Voice Development}"
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
        echo "Signing identity: $SIGN_IDENTITY (self-signed — not notarized; testers need 'xattr -cr')"
    else
        echo "WARNING: signing identity '$SIGN_IDENTITY' not found; falling back to ad-hoc (-)."
        echo "         Run 'make setup' first so permissions survive Sparkle updates."
        SIGN_IDENTITY="-"
    fi
fi

# 1) Resolve the version
if [ $# -ge 1 ]; then
    VERSION="$1"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
fi
DMG_NAME="BetterVoice2-${VERSION}.dmg"
VOL_NAME="Better Voice ${VERSION}"
STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "=== Building Better Voice ${VERSION} ==="

# Resume mode: SKIP_BUILD=1 reuses an existing signed+stapled .app (and DMG) from a prior run
# instead of recompiling/re-signing — so a release that died in the slow notarization or publish
# tail can be finished WITHOUT redoing the build or re-notarizing what's already done. The
# notarize/staple steps below are each idempotent (they skip when the artifact is already stapled),
# which is what makes `SKIP_BUILD=1 ./scripts/release.sh` a safe "finish the interrupted release".
SKIP_BUILD="${SKIP_BUILD:-0}"
if [ "$SKIP_BUILD" != "1" ]; then

# 2) Release build
echo "[1/5] swift build -c release..."
swift build -c release

# 3) Assemble the .app bundle
echo "[2/6] Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_DIR/release/BetterVoice2" "$APP_MACOS/BetterVoice2"
cp "$INFO_PLIST" "$APP_CONTENTS/Info.plist"
# Give non-production builds a distinct bundle id + name ("Better Voice Dev") so they don't
# collide with the shipping app's TCC permissions / UserDefaults. Must precede codesign.
./scripts/apply-channel.sh "$APP_BUNDLE" "$CHANNEL"
# App icon (Contents/Resources/AppIcon.icns, referenced by CFBundleIconFile).
# v2 is a regular Dock app (no LSUIElement), so the icon shows in the Dock too.
mkdir -p "$APP_CONTENTS/Resources"
cp icon/AppIcon.icns "$APP_CONTENTS/Resources/AppIcon.icns"
# SwiftPM resource bundle (Bundle.module). The BetterVoice2 target declares
# resources: [.process("Resources")], so `swift build` emits BetterVoice2_BetterVoice2.bundle
# next to the binary. SPM does NOT embed it into the .app — without it the app fatal-errors on
# launch ("could not load resource bundle") and dies before showing its menu-bar item. Copy it
# into Contents/Resources so Bundle.main.resourceURL resolves it. MUST precede codesign so the
# outer signature seals it.
RESOURCE_BUNDLE="$BUILD_DIR/release/BetterVoice2_BetterVoice2.bundle"
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
if ! otool -l "$APP_MACOS/BetterVoice2" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_MACOS/BetterVoice2"
fi

# 4) Codesign (inside-out: framework first — it contains embedded
#    XPCServices/Autoupdate/Updater.app — then the main executable, then the outer app).
#
# Release channel (HARDENED_RUNTIME=1): sign under the Hardened Runtime with a secure
#   timestamp. The mic entitlement goes ONLY on the outer app bundle (applied to the main
#   executable's signature) — NOT on Sparkle's helpers, which have their own requirements
#   and must not inherit audio-input. Hardened runtime + entitlements are both required for
#   notarization to pass and for the mic prompt to appear.
# Dev/beta channel: no hardened runtime, no timestamp (self-signed/ad-hoc can't timestamp).
echo "[4/7] Codesigning ($SIGN_IDENTITY)..."
CS_OPTS=(--force)
if [ "$HARDENED_RUNTIME" = "1" ]; then
    CS_OPTS+=(--options runtime --timestamp)
fi
# Framework + its embedded XPCServices/Autoupdate/Updater.app (inside-out via --deep), no entitlements.
codesign "${CS_OPTS[@]}" --deep --sign "$SIGN_IDENTITY" "$APP_FRAMEWORKS/Sparkle.framework"
# Main executable.
codesign "${CS_OPTS[@]}" --sign "$SIGN_IDENTITY" "$APP_MACOS/BetterVoice2"
# Outer app bundle — mic entitlement applied here in the release channel.
if [ "$HARDENED_RUNTIME" = "1" ]; then
    codesign "${CS_OPTS[@]}" --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    codesign "${CS_OPTS[@]}" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE" || {
    echo "ERROR: codesign verification failed"
    exit 1
}

else
    echo "SKIP_BUILD=1: reusing existing $APP_BUNDLE (no recompile/re-sign)."
    [ -d "$APP_BUNDLE" ] || { echo "ERROR: SKIP_BUILD=1 but $APP_BUNDLE is missing — run a full build first."; exit 1; }
fi

# 4b) Notarize the app, then staple the ticket into the .app so BOTH the DMG and the Sparkle
#     zip (built next, from this same stapled bundle) launch offline without a Gatekeeper prompt.
#     Idempotent: skips when the .app is already stapled (a resumed run, SKIP_BUILD=1).
if [ "$NOTARIZE" = "1" ]; then
    if xcrun stapler validate "$APP_BUNDLE" >/dev/null 2>&1; then
        echo "[4b/7] App already notarized + stapled — skipping."
    else
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "ERROR: notarytool keychain profile '$NOTARY_PROFILE' not found. Create it once with:"
        echo "    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
        echo "      --apple-id <APPLE_ID> --team-id <TEAM_ID> --password <APP_SPECIFIC_PASSWORD>"
        exit 1
    fi
    echo "[4b/7] Notarizing app (submitting to Apple — this can take a few minutes)..."
    NOTARIZE_ZIP="$BUILD_DIR/BetterVoice2-notarize.zip"
    rm -f "$NOTARIZE_ZIP"
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
    APP_SUBMIT="$(xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
    echo "$APP_SUBMIT"
    rm -f "$NOTARIZE_ZIP"
    if ! echo "$APP_SUBMIT" | grep -q "status: Accepted"; then
        echo "ERROR: app notarization was not Accepted. Inspect the log with:"
        echo "    xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\""
        exit 1
    fi
    echo "[4b/7] Stapling ticket to the app..."
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    fi
fi

# 5+6) Prepare staging and build the DMG (for first-time installs). Both draw from $APP_BUNDLE,
#     which is already stapled, so the app inside launches offline either way.
#     On resume (SKIP_BUILD=1) reuse an existing DMG as-is — recreating it would change the bytes
#     and invalidate a notarization ticket that's already been (or is being) issued for the old
#     bytes, so a mid-notarization DMG must NOT be rebuilt.
if [ "$SKIP_BUILD" = "1" ] && [ -f "$DMG_PATH" ]; then
    echo "[5-6/7] SKIP_BUILD=1: reusing existing $DMG_PATH (not rebuilding — preserves notarized bytes)."
else
    echo "[5/7] Staging DMG content..."
    rm -rf "$STAGING"
    mkdir -p "$STAGING"
    cp -R "$APP_BUNDLE" "$STAGING/BetterVoice2.app"
    ln -s /Applications "$STAGING/Applications"
    cp scripts/INSTALL.txt "$STAGING/INSTALL.txt"

    echo "[6/7] Creating DMG..."
    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "$VOL_NAME" \
        -srcfolder "$STAGING" \
        -ov -format UDZO \
        "$DMG_PATH" >/dev/null
fi

# 6b) Notarize + staple the DMG itself so the disk image also passes Gatekeeper offline
#     (the app inside is already stapled; the DMG needs its own ticket to be stapled).
#     Idempotent: skips when the DMG is already stapled (a resumed run after the ticket landed).
if [ "$NOTARIZE" = "1" ]; then
    if xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
        echo "[6b/7] DMG already notarized + stapled — skipping."
    else
        echo "[6b/7] Notarizing DMG..."
        DMG_SUBMIT="$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
        echo "$DMG_SUBMIT"
        if ! echo "$DMG_SUBMIT" | grep -q "status: Accepted"; then
            echo "ERROR: DMG notarization was not Accepted. Inspect the log with:"
            echo "    xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\""
            exit 1
        fi
        xcrun stapler staple "$DMG_PATH"
        xcrun stapler validate "$DMG_PATH"
    fi
fi

echo "[7/7] Creating appcast zip..."
ZIP_PATH="$BUILD_DIR/BetterVoice2-$VERSION.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# clean up staging
rm -rf "$STAGING"

# output
SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo ""
echo "=== Done ==="
echo "  DMG:     $DMG_PATH"
echo "  Zip:     $ZIP_PATH  (release.sh publishes it to site/static/updates/ for the appcast)"
echo "  Volume:  $VOL_NAME"
echo "  Size:    $SIZE"
echo "  Version: $VERSION"
if [ "$NOTARIZE" = "1" ]; then
    echo "  Signing: $SIGN_IDENTITY (notarized + stapled)"
else
    echo "  Signing: $SIGN_IDENTITY (NOT notarized — beta/dev channel)"
fi
echo ""
echo "Next (release): ./scripts/release.sh   # signs the appcast entry via generate_appcast"
echo "Test:    open $DMG_PATH"
if [ "$NOTARIZE" = "1" ]; then
    echo "Install: drag BetterVoice2.app to /Applications — no Terminal step needed (notarized)."
else
    echo "Install: drag BetterVoice2.app to /Applications, then run (beta build only):"
    echo "         xattr -cr /Applications/BetterVoice2.app"
fi
