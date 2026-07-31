.PHONY: build bundle run run-raw clean setup install uninstall check-data check-log

APP_NAME = BetterVoice2
APP_BUNDLE = .build/$(APP_NAME).app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_FRAMEWORKS = $(APP_CONTENTS)/Frameworks
APP_RESOURCES = $(APP_CONTENTS)/Resources
BIN_PATH = .build/debug
# `make` builds the DEV channel (distinct .dev bundle id, see scripts/apply-channel.sh), and the
# app logs to a channel-specific dir so dev + release logs don't interleave when both run.
LOG_DIR = $(HOME)/Library/Logs/$(APP_NAME)-Dev
LOG_FILE = $(LOG_DIR)/debug.log

# Signing identity: default to a stable self-signed certificate so TCC permissions
# (Microphone, Input Monitoring) survive across rebuilds.
# Ad-hoc signing changes the hash every time -> the system treats it as a new app ->
# already-granted permissions are reset.
# Override: SIGN_IDENTITY="Apple Development: ..." make run   (run `make setup` first)
SIGN_IDENTITY ?= Better Voice Development

# Install variables
INSTALL_DIR = $(HOME)/Applications
INSTALL_APP = $(INSTALL_DIR)/$(APP_NAME).app
LAUNCHD_LABEL = com.baselinemakes.bettervoice2
LAUNCHD_PLIST = ~/Library/LaunchAgents/$(LAUNCHD_LABEL).plist
# Old label (before the Baseline Makes rebrand). install/uninstall must both clean it up,
# otherwise machines that installed before the rename will have a stale LaunchAgent pointing
# at the deleted app (error on every login / double launch after reinstall).
LEGACY_LAUNCHD_PLIST = ~/Library/LaunchAgents/com.drkpxl.bettervoice2.plist

build:
	swift build

# Build a signed app bundle (embeds Sparkle.framework) — shared by run/install, same as build-dmg.sh.
# SPM only produces Sparkle.framework, it doesn't embed it into the .app automatically.
# Must copy manually + add rpath + sign (rpath must be set before signing).
bundle: build
	@mkdir -p $(APP_MACOS) $(APP_FRAMEWORKS) $(APP_RESOURCES)
	@cp $(BIN_PATH)/$(APP_NAME) $(APP_MACOS)/$(APP_NAME)
	@cp Sources/Info.plist $(APP_CONTENTS)/Info.plist
	@cp icon/AppIcon.icns $(APP_RESOURCES)/AppIcon.icns
	@# SPM resource bundle (Bundle.module). Target declares resources: [.process("Resources")],
	@# so swift build emits it next to the binary but does NOT embed it into the .app. Without it
	@# the app fatal-errors on launch ("could not load resource bundle"). Must precede codesign.
	@cp -R $(BIN_PATH)/$(APP_NAME)_$(APP_NAME).bundle $(APP_RESOURCES)/
	@rm -rf $(APP_FRAMEWORKS)/Sparkle.framework
	@cp -R $(BIN_PATH)/Sparkle.framework $(APP_FRAMEWORKS)/Sparkle.framework
	@otool -l $(APP_MACOS)/$(APP_NAME) | grep -q "@executable_path/../Frameworks" \
		|| install_name_tool -add_rpath "@executable_path/../Frameworks" $(APP_MACOS)/$(APP_NAME)
	@# Dev identity: distinct bundle id + name ("Better Voice Dev") so TCC/UserDefaults don't
	@# collide with the shipping release app. Must precede codesign so the signature seals it.
	@./scripts/apply-channel.sh $(APP_BUNDLE) dev
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_IDENTITY)"; then \
		echo "Signing: $(SIGN_IDENTITY) (stable — TCC survives rebuilds)"; SIGN="$(SIGN_IDENTITY)"; \
	else \
		echo "WARNING: signing identity '$(SIGN_IDENTITY)' not found; falling back to ad-hoc (-)."; \
		echo "         Run 'make setup' first so permissions survive rebuilds."; SIGN="-"; \
	fi; \
	codesign --force --deep --sign "$$SIGN" $(APP_FRAMEWORKS)/Sparkle.framework; \
	codesign --force --sign "$$SIGN" $(APP_BUNDLE)

# Build the app bundle and launch via LaunchServices (TCC permissions belong to $(APP_NAME), not Terminal)
run: bundle
	@killall $(APP_NAME) 2>/dev/null; sleep 0.5; true
	@mkdir -p $(LOG_DIR)
	@echo "Launching $(APP_NAME).app... (logs: tail -f $(LOG_FILE))"
	@open $(APP_BUNDLE)
	@sleep 1 && touch $(LOG_FILE) && tail -f $(LOG_FILE)

# Run the raw binary directly (debugging only — microphone may not work)
run-raw: build
	.build/debug/$(APP_NAME)

clean:
	swift package clean
	rm -rf .build/$(APP_NAME).app

# Create a self-signed code signing certificate (TCC permissions persist across rebuilds)
setup:
	@bash scripts/setup-cert.sh

# Install to ~/Applications and enable launch-on-login
install: bundle
	@echo "=== Installing to $(INSTALL_DIR) ==="
	@mkdir -p $(INSTALL_DIR)
	@rm -rf $(INSTALL_APP)
	@cp -R $(APP_BUNDLE) $(INSTALL_APP)
	@echo "=== Configuring launch-on-login ==="
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
		'        <string>'"$$HOME/Applications/$(APP_NAME).app"'</string>' \
		'    </array>' \
		'    <key>RunAtLoad</key>' \
		'    <true/>' \
		'    <key>KeepAlive</key>' \
		'    <false/>' \
		'</dict>' \
		'</plist>' > $(LAUNCHD_PLIST)
	@launchctl unload $(LAUNCHD_PLIST) 2>/dev/null || true
	@launchctl load $(LAUNCHD_PLIST)
	@# Migration: unload the old pre-rebrand LaunchAgent to avoid double launch-on-login
	@launchctl unload $(LEGACY_LAUNCHD_PLIST) 2>/dev/null || true
	@rm -f $(LEGACY_LAUNCHD_PLIST)
	@echo ""
	@echo "Install complete!"
	@echo "   App location: $(INSTALL_APP)"
	@echo "   Launch on login: enabled"
	@echo ""
	@echo "   Manual launch: open $(INSTALL_APP)"
	@echo "   View logs: tail -f $(LOG_FILE)"
	@echo "   Uninstall: make uninstall"

# Uninstall the app and remove launch-on-login
uninstall:
	@echo "=== Stopping launch-on-login ==="
	@launchctl unload $(LAUNCHD_PLIST) 2>/dev/null || true
	@rm -f $(LAUNCHD_PLIST)
	@launchctl unload $(LEGACY_LAUNCHD_PLIST) 2>/dev/null || true
	@rm -f $(LEGACY_LAUNCHD_PLIST)
	@echo "=== Stopping running $(APP_NAME) ==="
	@killall $(APP_NAME) 2>/dev/null || true
	@echo "=== Removing app ==="
	@rm -rf $(INSTALL_APP)
	@echo ""
	@echo "Uninstall complete!"
	@echo ""
	@echo "   User data is in the workspace folder you chose during setup; delete manually if needed."

# View recent logs
check-log:
	@tail -30 $(LOG_FILE) 2>/dev/null || echo "  no log yet at $(LOG_FILE)"

# Data is now in the user-chosen workspace folder (not a fixed path); this only shows the log dir
check-data:
	@echo "=== Log dir $(LOG_DIR) ==="
	@ls -lh $(LOG_FILE) 2>/dev/null || echo "  debug.log: not yet"
	@echo "=== Data ==="
	@echo "  Transcripts/summaries/speaker data is in the workspace folder you chose during setup."
