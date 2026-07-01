#!/bin/bash
# BetterVoice DMG 打包脚本
#
# 用法:
#   ./scripts/build-dmg.sh           # 用 Info.plist version
#   ./scripts/build-dmg.sh 0.2.0     # 显式覆盖版本号
#
# 输出: .build/BetterVoice-<version>.dmg
#
# 签名策略: ad-hoc 签名（codesign -s -）
# 用户首次安装需要执行 xattr -cr /Applications/BetterVoice.app 绕过 Gatekeeper
# 详细安装步骤见 scripts/INSTALL.txt

set -euo pipefail

# 切到 client 目录（脚本可能在任何位置被调用）
cd "$(dirname "$0")/.."

INFO_PLIST="Sources/Info.plist"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/BetterVoice.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"

# 签名身份：优先使用稳定的自签名证书，让 TCC 权限在 Sparkle 原地更新后依然有效
# （ad-hoc 每次 hash 变化 -> designated requirement 变化 -> 更新后 4 项权限被重置需重新授权）。
# 覆盖方式: SIGN_IDENTITY="Apple Development: ..." ./scripts/build-dmg.sh
SIGN_IDENTITY="${SIGN_IDENTITY:-Better Voice Development}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "Signing identity: $SIGN_IDENTITY (stable — TCC survives in-place updates)"
else
    echo "WARNING: signing identity '$SIGN_IDENTITY' not found; falling back to ad-hoc (-)."
    echo "         Run 'make setup' first so permissions survive Sparkle updates."
    SIGN_IDENTITY="-"
fi

# 1) 解析版本号
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

# 2) Release 构建
echo "[1/5] swift build -c release..."
swift build -c release

# 3) 组装 .app bundle
echo "[2/6] Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_DIR/release/BetterVoice" "$APP_MACOS/BetterVoice"
cp "$INFO_PLIST" "$APP_CONTENTS/Info.plist"
# PkgInfo: macOS LaunchServices 用它识别 bundle 类型（type=APPL/creator=????）
# 没有这个文件 LaunchServices 可能不注册 bundle id，导致 TCC 找不到 app，
# 麦克风/语音识别等权限弹窗永远不出现。
printf 'APPL????' > "$APP_CONTENTS/PkgInfo"

# 3b) 内嵌 Sparkle.framework（SPM 只产出框架，不会自动嵌入 .app，需手动拷贝+签名）
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
# 让可执行文件能在 @executable_path/../Frameworks 找到框架（必须在签名之前修改二进制）
if ! otool -l "$APP_MACOS/BetterVoice" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_MACOS/BetterVoice"
fi

# 4) 签名（inside-out：先框架含内嵌 XPCServices/Autoupdate/Updater.app，再外层 app）
# 注意：不加 --options runtime（hardened runtime）。理由：
#   ad-hoc 签名无法附带 entitlements，hardened runtime 会强制要求
#   com.apple.security.device.audio-input 等 entitlement，否则直接拒绝
#   麦克风访问（连权限弹窗都不弹）。Info.plist 的 NSMicrophoneUsageDescription
#   在 hardened runtime 下不够用。未来要做 notarization 时配合 entitlements 一起加回。
echo "[4/6] Codesigning ($SIGN_IDENTITY)..."
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_FRAMEWORKS/Sparkle.framework"
codesign --force --sign "$SIGN_IDENTITY" "$APP_MACOS/BetterVoice"
codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE" || {
    echo "ERROR: codesign verification failed"
    exit 1
}

# 5) 准备 DMG staging 目录
echo "[5/6] Staging DMG content..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/BetterVoice.app"
ln -s /Applications "$STAGING/Applications"
cp scripts/INSTALL.txt "$STAGING/INSTALL.txt"

# 6) 制作 DMG（首次手动安装用）+ zip（Sparkle appcast 用，generate_appcast 处理更简单）
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

# 清理 staging
rm -rf "$STAGING"

# 输出
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
