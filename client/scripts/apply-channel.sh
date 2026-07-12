#!/usr/bin/env bash
# Patch an assembled .app bundle's Info.plist for a given release CHANNEL, so that DEV builds and
# the shipping RELEASE are distinct macOS apps. They then get SEPARATE TCC permissions (Input
# Monitoring / Accessibility / Microphone) and SEPARATE UserDefaults — which means:
#   - granting a permission to one never collides with the other (no "toggled on but not working"),
#   - you can run "Better Voice Dev" next to the real "Better Voice" at the same time, and
#   - you can wipe the release app's state to test a genuine first-run WITHOUT losing your dev setup.
#
# The divergence is keyed ONLY on the bundle identifier + name; the .app FOLDER name is untouched.
#
# Usage: apply-channel.sh <app-bundle-path> <channel>       channel = dev | release
#   release : leave the production Info.plist exactly as shipped.
#   dev     : bundle id -> <id>.dev, name -> "Better Voice Dev", Sparkle auto-update disabled
#             (a dev build must never silently replace itself with the production release).
#
# Idempotent: re-running on an already-patched dev bundle is a no-op (the id keeps its single .dev).
# Must run BEFORE codesign so the signature seals the patched Info.plist.
set -euo pipefail

APP="${1:?usage: apply-channel.sh <app-bundle> <dev|release>}"
CHANNEL="${2:?usage: apply-channel.sh <app-bundle> <dev|release>}"
PLIST="$APP/Contents/Info.plist"

if [ ! -f "$PLIST" ]; then
    echo "apply-channel: ERROR — no Info.plist at $PLIST" >&2
    exit 1
fi

pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }

# Set a key, or Add it if absent (PlistBuddy's Set fails on a missing key).
set_or_add() {  # <key> <type> <value...>
    local key="$1" type="$2"; shift 2
    pb "Set :$key $*" 2>/dev/null || pb "Add :$key $type $*"
}

case "$CHANNEL" in
release)
    echo "apply-channel: release → production Info.plist unchanged"
    ;;
dev)
    base_id="$(pb "Print :CFBundleIdentifier")"
    case "$base_id" in
        *.dev) dev_id="$base_id" ;;          # already patched — stay idempotent
        *)     dev_id="${base_id}.dev" ;;
    esac
    pb "Set :CFBundleIdentifier $dev_id"
    set_or_add CFBundleName        string Better Voice Dev
    set_or_add CFBundleDisplayName string Better Voice Dev
    # Sever the Sparkle auto-update path for dev builds.
    set_or_add SUEnableAutomaticChecks bool false
    pb "Delete :SUFeedURL" 2>/dev/null || true
    echo "apply-channel: dev → id=$dev_id, name=\"Better Voice Dev\", Sparkle auto-update off"
    ;;
*)
    echo "apply-channel: ERROR — unknown channel '$CHANNEL' (expected dev|release)" >&2
    exit 1
    ;;
esac
