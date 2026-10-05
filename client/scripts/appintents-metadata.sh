#!/bin/bash
# Generate Contents/Resources/Metadata.appintents for the app bundle, so Shortcuts / Spotlight /
# Siri can see Better Voice's App Intents (Sources/Intents/).
#
# Xcode does this as a build phase; `swift build` doesn't. But the Swift Build engine already makes
# the compiler emit the per-file `.swiftconstvalues` the metadata processor needs, so this runs the
# same `appintentsmetadataprocessor` Xcode would, against those files.
#
# Never fatal: if the inputs aren't there (older toolchain, different build engine), it warns and
# the app ships without Shortcuts actions rather than failing the build.
#
# Usage: scripts/appintents-metadata.sh <debug|release> <path/to/App.app/Contents/Resources>
set -uo pipefail

CONFIG="${1:?config (debug|release)}"
RESOURCES="${2:?app Resources dir}"
MODULE="BetterVoice2"
CONFIG_DIR="$(echo "${CONFIG:0:1}" | tr '[:lower:]' '[:upper:]')${CONFIG:1}"   # debug -> Debug
OBJ=".build/out/Intermediates.noindex/$MODULE.build/$CONFIG_DIR/$MODULE-p.build/Objects-normal/arm64"

warn() { echo "WARNING: App Intents metadata skipped — $1 (Shortcuts actions won't appear)"; exit 0; }

[ -d "$OBJ" ] || warn "no build intermediates at $OBJ"
ls "$OBJ"/*.swiftconstvalues >/dev/null 2>&1 || warn "compiler produced no .swiftconstvalues"
PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null)" || warn "appintentsmetadataprocessor not found (needs Xcode, not just CommandLineTools)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
find "$PWD/Sources" -name '*.swift' -not -path '*/BetterVoiceCore/*' > "$WORK/sources.txt"
ls "$PWD/$OBJ"/*.swiftconstvalues > "$WORK/consts.txt"
DEV_DIR="$(xcode-select -p 2>/dev/null)"
[ -n "${DEVELOPER_DIR:-}" ] && DEV_DIR="$DEVELOPER_DIR"
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')"
[ -n "$XCODE_VERSION" ] || warn "can't read the Xcode build version"

"$PROCESSOR" \
    --output "$WORK/out" \
    --toolchain-dir "$DEV_DIR/Toolchains/XcodeDefault.xctoolchain" \
    --module-name "$MODULE" \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$XCODE_VERSION" \
    --platform-family macOS \
    --deployment-target 26.0 \
    --target-triple arm64-apple-macos26.0 \
    --source-file-list "$WORK/sources.txt" \
    --swift-const-vals-list "$WORK/consts.txt" \
    --force >"$WORK/log.txt" 2>&1 || { cat "$WORK/log.txt"; warn "the processor failed"; }

[ -d "$WORK/out/Metadata.appintents" ] || warn "the processor wrote no Metadata.appintents"
mkdir -p "$RESOURCES"
rm -rf "$RESOURCES/Metadata.appintents"
cp -R "$WORK/out/Metadata.appintents" "$RESOURCES/"
echo "App Intents metadata: $(python3 -c "import json,sys; d=json.load(open('$RESOURCES/Metadata.appintents/extract.actionsdata')); print(len(d.get('actions',{})), 'actions,', len(d.get('autoShortcuts',[])), 'app shortcuts')" 2>/dev/null)"
