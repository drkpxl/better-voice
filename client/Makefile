.PHONY: build bundle run run-raw clean setup install uninstall check-data check-log

APP_BUNDLE = .build/BetterVoice.app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_FRAMEWORKS = $(APP_CONTENTS)/Frameworks
BIN_PATH = .build/debug

# 签名身份：默认用稳定的自签名证书，让 TCC 权限（麦克风/输入监控/系统音频）跨重新编译保留。
# ad-hoc 签名每次 hash 变化 -> 系统视为新 app -> 已授权的权限被重置。
# 覆盖: SIGN_IDENTITY="Apple Development: ..." make run   （先 `make setup` 创建证书）
SIGN_IDENTITY ?= Better Voice Development

# 安装相关变量
INSTALL_DIR = $(HOME)/Applications
INSTALL_APP = $(INSTALL_DIR)/BetterVoice.app
LAUNCHD_LABEL = com.drkpxl.bettervoice
LAUNCHD_PLIST = ~/Library/LaunchAgents/$(LAUNCHD_LABEL).plist

build:
	swift build

# 构建已签名的 app bundle（内嵌 Sparkle.framework）——run/install 共用，与 build-dmg.sh 保持一致。
# SPM 只产出 Sparkle.framework，不会自动嵌入 .app，需手动拷贝 + 加 rpath + 签名（rpath 必须在签名前改）。
bundle: build
	@mkdir -p $(APP_MACOS) $(APP_FRAMEWORKS) $(APP_CONTENTS)/Resources
	@cp $(BIN_PATH)/BetterVoice $(APP_MACOS)/BetterVoice
	@cp Sources/Info.plist $(APP_CONTENTS)/Info.plist
	@# SPM resource bundle (Bundle.module). Target declares resources: [.process("Resources")],
	@# so swift build emits it next to the binary but does NOT embed it into the .app. Without it
	@# the app fatal-errors on launch ("could not load resource bundle"). Must precede codesign.
	@cp -R $(BIN_PATH)/BetterVoice_BetterVoice.bundle $(APP_CONTENTS)/Resources/
	@rm -rf $(APP_FRAMEWORKS)/Sparkle.framework
	@cp -R $(BIN_PATH)/Sparkle.framework $(APP_FRAMEWORKS)/Sparkle.framework
	@otool -l $(APP_MACOS)/BetterVoice | grep -q "@executable_path/../Frameworks" \
		|| install_name_tool -add_rpath "@executable_path/../Frameworks" $(APP_MACOS)/BetterVoice
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_IDENTITY)"; then \
		echo "Signing: $(SIGN_IDENTITY) (stable — TCC survives rebuilds)"; SIGN="$(SIGN_IDENTITY)"; \
	else \
		echo "WARNING: signing identity '$(SIGN_IDENTITY)' not found; falling back to ad-hoc (-)."; \
		echo "         Run 'make setup' first so permissions survive rebuilds."; SIGN="-"; \
	fi; \
	codesign --force --deep --sign "$$SIGN" $(APP_FRAMEWORKS)/Sparkle.framework; \
	codesign --force --sign "$$SIGN" $(APP_BUNDLE)

# 构建 app bundle 并通过 LaunchServices 启动（TCC 权限归属 BetterVoice 而非 Terminal）
run: bundle
	@killall BetterVoice 2>/dev/null; sleep 0.5; true
	@echo "Launching BetterVoice.app... (logs: tail -f ~/.better-voice/debug.log)"
	@open $(APP_BUNDLE)
	@sleep 1 && tail -f ~/.better-voice/debug.log

# 直接运行裸二进制（调试用，麦克风可能不工作）
run-raw: build
	.build/debug/BetterVoice

clean:
	swift package clean
	rm -rf .build/BetterVoice.app

# 创建自签名代码签名证书（TCC 权限跨编译持久化）
setup:
	@bash scripts/setup-cert.sh

# 安装到 ~/Applications 并设置开机自启
install: bundle
	@echo "=== 安装到 $(INSTALL_DIR) ==="
	@mkdir -p $(INSTALL_DIR)
	@rm -rf $(INSTALL_APP)
	@cp -R $(APP_BUNDLE) $(INSTALL_APP)
	@echo "=== 配置开机自启 ==="
	@mkdir -p ~/Library/LaunchAgents
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>Label</key>' \
		'    <string>$(LAUNCHD_LABEL)</string>' \
		'    <key>ProgramArguments</key>' \
		'    <array>' \
		'        <string>open</string>' \
		'        <string>-a</string>' \
		'        <string>'"$$HOME/Applications/BetterVoice.app"'</string>' \
		'    </array>' \
		'    <key>RunAtLoad</key>' \
		'    <true/>' \
		'    <key>KeepAlive</key>' \
		'    <false/>' \
		'</dict>' \
		'</plist>' > $(LAUNCHD_PLIST)
	@launchctl unload $(LAUNCHD_PLIST) 2>/dev/null || true
	@launchctl load $(LAUNCHD_PLIST)
	@echo ""
	@echo "✅ 安装完成！"
	@echo "   应用位置: $(INSTALL_APP)"
	@echo "   开机自启: 已启用"
	@echo ""
	@echo "   手动启动: open $(INSTALL_APP)"
	@echo "   查看日志: tail -f ~/.better-voice/debug.log"
	@echo "   卸载:     make uninstall"

# 卸载应用并移除开机自启
uninstall:
	@echo "=== 停止开机自启 ==="
	@launchctl unload $(LAUNCHD_PLIST) 2>/dev/null || true
	@rm -f $(LAUNCHD_PLIST)
	@echo "=== 停止运行中的 BetterVoice ==="
	@killall BetterVoice 2>/dev/null || true
	@echo "=== 移除应用 ==="
	@rm -rf $(INSTALL_APP)
	@echo ""
	@echo "✅ 卸载完成！"
	@echo ""
	@echo "   如需清除用户数据，请手动执行:"
	@echo "   rm -rf ~/.better-voice/"

# 检查数据落盘（本地调试用历史 + 录音）
check-data:
	@echo "=== ~/.better-voice/ data files ==="
	@ls -lh ~/.better-voice/voice-history.jsonl 2>/dev/null || echo "  voice-history.jsonl: not yet"
	@ls -lh ~/.better-voice/meeting-history.jsonl 2>/dev/null || echo "  meeting-history.jsonl: not yet"
	@echo "=== audio files ==="
	@ls ~/.better-voice/audio/ 2>/dev/null | head -5 || echo "  no audio files yet"
	@echo "=== personal context ==="
	@ls -lh ~/.better-voice/personal-context.md 2>/dev/null || echo "  personal-context.md: not set (optional)"
	@echo "=== config ==="
	@cat ~/.better-voice/config.json 2>/dev/null || echo "  no config yet (will be created on first run)"

# 查看最近日志
check-log:
	@tail -30 ~/.better-voice/debug.log 2>/dev/null || echo "  no log yet"
