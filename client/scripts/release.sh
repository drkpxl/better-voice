#!/bin/bash
# Better Voice release helper: build the app, then sign + publish the Sparkle appcast into the
# GitHub Pages site (docs/), so `https://drkpxl.github.io/better-voice/appcast.xml` updates.
#
# Prereqs (one-time):
#   1. Generate EdDSA keys with Sparkle's generate_keys; paste the printed public key into
#      Sources/Info.plist <SUPublicEDKey>. The private key stays in your login Keychain
#      (back it up outside the repo — losing it means you can't sign future updates):
#        .build/artifacts/sparkle/Sparkle/bin/generate_keys
#   2. Run 'make setup' so builds use the stable "Better Voice Development" identity
#      (keeps TCC permissions across in-place updates).
#   3. Enable GitHub Pages: repo Settings → Pages → Deploy from branch → main → /docs.
#
# Each release:
#   - Bump CFBundleShortVersionString AND the integer CFBundleVersion in Sources/Info.plist
#     (CFBundleVersion must strictly increase and match the appcast <sparkle:version>).
#   - Run this script, then commit + push docs/ (Pages serves it) and — optionally — create a
#     GitHub Release with notes + the .dmg for first-time installers.

set -euo pipefail
cd "$(dirname "$0")/.."          # -> client/

REPO_ROOT="$(cd .. && pwd)"
PAGES_DIR="$REPO_ROOT/docs"
DOWNLOADS_DIR="$PAGES_DIR/downloads"
BUILD_DIR=".build"
PAGES_BASE_URL="https://drkpxl.github.io/better-voice"

# Resolve version the same way build-dmg.sh does, so we know the artifact names.
if [ $# -ge 1 ]; then
    VERSION="$1"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "Sources/Info.plist")
fi

# 1) Build the signed app bundle + zip (+ dmg for first-time installs).
./scripts/build-dmg.sh "$@"

# 2) Locate generate_appcast from the resolved Sparkle SPM artifact.
GEN="$(find "$BUILD_DIR/artifacts" -name generate_appcast -type f 2>/dev/null | head -1)"
if [ -z "$GEN" ]; then
    echo "ERROR: generate_appcast not found under $BUILD_DIR/artifacts (run 'swift build' first)."
    exit 1
fi

# 3) Publish the zip into the Pages downloads folder (kept flat so one URL prefix always works).
#    Only the .zip goes here — Sparkle's generate_appcast rejects two archives (zip + dmg) with the
#    same version. The .dmg is for first-time installs and is attached to the GitHub Release instead.
mkdir -p "$DOWNLOADS_DIR"
cp "$BUILD_DIR/BetterVoice-$VERSION.zip" "$DOWNLOADS_DIR/"

# 4) (Re)generate the appcast over ALL published zips, EdDSA-signing each with the Keychain key.
#    Flat --download-url-prefix works because every zip lives under the same downloads/ path.
"$GEN" \
    --download-url-prefix "$PAGES_BASE_URL/downloads/" \
    -o "$PAGES_DIR/appcast.xml" \
    "$DOWNLOADS_DIR"

echo ""
echo "=== Appcast published to $PAGES_DIR/appcast.xml ==="
echo "  Feed URL:  $PAGES_BASE_URL/appcast.xml   (matches Info.plist SUFeedURL)"
echo "  Zip URL:   $PAGES_BASE_URL/downloads/BetterVoice-$VERSION.zip"
echo ""
echo "  Optional: add release notes for this version to docs/appcast.xml"
echo "            (<sparkle:releaseNotesLink> or an inline <description>)."
echo "  Then:     cd $REPO_ROOT && git add docs && git commit -m \"Release $VERSION\" && git push"
echo "            (GitHub Pages redeploys automatically.)"
