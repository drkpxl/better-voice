#!/bin/bash
# Better Voice 2 release helper: build + notarize the app, EdDSA-sign the Sparkle appcast, and
# publish the marketing site + appcast + downloads to Cloudflare (Worker static assets at
# voice.baselinemakes.com; config in the repo-root wrangler.jsonc). docs/ is the SvelteKit
# site's build output; the appcast, Sparkle zips, and DMGs are static inputs under site/static/
# so they land in docs/ too and ship with the same deploy.
#
# Sparkle auto-updates are wired up as of 1.0: SUFeedURL + SUPublicEDKey are set in
# Sources/Info.plist and SUEnableAutomaticChecks is on. This script must run on the dev machine
# that holds the EdDSA private key (login Keychain) and the Developer ID identity — the same
# machine build-dmg.sh notarizes on. It builds + notarizes the app, then EdDSA-signs the appcast
# entry and deploys, so existing users get the in-app update.
#
# Prereqs (one-time — already done for 1.0, kept here for reference / a fresh machine):
#   1. Generate EdDSA keys with Sparkle's generate_keys; paste the printed public key into
#      Sources/Info.plist <SUPublicEDKey>. The private key stays in your login Keychain
#      (back it up outside the repo — losing it means you can't sign future updates):
#        .build/artifacts/sparkle/Sparkle/bin/generate_keys
#   2. A Developer ID Application cert + a notarytool keychain profile (see build-dmg.sh).
#   3. Cloudflare auth: `npx wrangler login` once (OAuth; the site Worker + custom domain are
#      declared in wrangler.jsonc at the repo root).
#   4. Install the site's deps once: (cd site && npm install).
#
# Each release:
#   - Bump CFBundleShortVersionString AND the integer CFBundleVersion in Sources/Info.plist
#     (CFBundleVersion must strictly increase and match the appcast <sparkle:version>).
#   - Run this script — it builds docs/ and deploys to Cloudflare. The build output (docs/) and
#     the release binaries (site/static/downloads,updates) are gitignored: Cloudflare is the
#     source of truth for what's live, so there's nothing to commit after a release.

set -euo pipefail
cd "$(dirname "$0")/.."          # -> client/

REPO_ROOT="$(cd .. && pwd)"
# docs/ is now BUILD OUTPUT of the SvelteKit marketing site (site/). The appcast + download
# zips are static inputs to that build (site/static/), so they survive the build's clean step
# and get emitted into docs/ alongside the site. Never write directly into docs/ — it's wiped
# on every `npm run build`.
SITE_DIR="$REPO_ROOT/site"
SITE_STATIC="$SITE_DIR/static"
PAGES_DIR="$REPO_ROOT/docs"
# Two separate static dirs by consumer:
#   downloads/ — DMGs for first-time installers (the site's Download button; a stable
#                BetterVoice2-latest.dmg alias always points at the newest one).
#   updates/   — Sparkle zips ONLY. generate_appcast scans this dir and rejects a zip+dmg
#                pair of the same version, which is why the DMGs live elsewhere.
DOWNLOADS_DIR="$SITE_STATIC/downloads"
UPDATES_DIR="$SITE_STATIC/updates"
BUILD_DIR=".build"
PAGES_BASE_URL="https://voice.baselinemakes.com"   # Cloudflare Worker custom domain (wrangler.jsonc)

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

# 3) Publish the artifacts into the site's static inputs: the Sparkle zip into updates/ (flat,
#    one URL prefix), the DMG into downloads/ with a stable -latest alias the site links to.
mkdir -p "$DOWNLOADS_DIR" "$UPDATES_DIR"
cp "$BUILD_DIR/BetterVoice2-$VERSION.zip" "$UPDATES_DIR/"
cp "$BUILD_DIR/BetterVoice2-$VERSION.dmg" "$DOWNLOADS_DIR/"
cp "$BUILD_DIR/BetterVoice2-$VERSION.dmg" "$DOWNLOADS_DIR/BetterVoice2-latest.dmg"

# 4) (Re)generate the appcast over ALL published zips, EdDSA-signing each with the Keychain key.
#    Written into site/static/ so the site build emits it at docs/appcast.xml.
"$GEN" \
    --download-url-prefix "$PAGES_BASE_URL/updates/" \
    -o "$SITE_STATIC/appcast.xml" \
    "$UPDATES_DIR"

# 5) Build the marketing site → docs/ (this copies site/static/, incl. the appcast, updates/,
#    and downloads/, into the deployable output). Requires deps installed once: (cd site && npm install).
echo "Building marketing site into docs/ ..."
npm --prefix "$SITE_DIR" run build

# 6) Deploy docs/ to the Cloudflare Worker (voice.baselinemakes.com).
echo "Deploying to Cloudflare ..."
(cd "$REPO_ROOT" && npx wrangler deploy)

echo ""
echo "=== Release $VERSION published ==="
echo "  Feed URL:  $PAGES_BASE_URL/appcast.xml   (matches Info.plist SUFeedURL)"
echo "  Zip URL:   $PAGES_BASE_URL/updates/BetterVoice2-$VERSION.zip"
echo "  DMG URL:   $PAGES_BASE_URL/downloads/BetterVoice2-$VERSION.dmg  (+ BetterVoice2-latest.dmg)"
echo ""
echo "  Source of truth: site/static/ (NOT docs/, which is built)."
echo "  Then: cd $REPO_ROOT && git add docs site/static && git commit -m \"Release $VERSION\" && git push"
