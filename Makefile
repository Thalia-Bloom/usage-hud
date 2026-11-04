APP_NAME = CodexUsageHUD
DISPLAY_NAME = Codex Usage HUD
BUNDLE_ID = com.codexusagehud.app
APP_VERSION = 1.3.4
APP_BUILD = 14
INSTALL_DIR = $(HOME)/Applications
DIST_DIR = dist
APP_BUNDLE = $(DIST_DIR)/$(APP_NAME).app
INSTALL_APP_BUNDLE = $(INSTALL_DIR)/$(APP_NAME).app
LEGACY_APP_BUNDLE = $(INSTALL_DIR)/BloomUsageHUD.app
# Universal: Intel Macs get the same app as Apple silicon ones.
ARCHS = arm64 x86_64
BUILD_DIR = .build/apple/Products/Release
BIN = $(BUILD_DIR)/$(APP_NAME)
SPARKLE_FRAMEWORK = $(BUILD_DIR)/Sparkle.framework
SUPPORT_DIR = $(HOME)/Library/Application Support/Codex Usage HUD
STATE_DIR = $(HOME)/.codex-usage-hud
LAUNCHD_RENDER_DIR = $(SUPPORT_DIR)/launchd
LAUNCHD_BIN_DIR = $(HOME)/.local/bin
APP_EXECUTABLE = $(INSTALL_APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_HELPERS = $(shell cat Resources/bundled-helpers.txt)
CORE_LAUNCHD_LABELS = com.codexusagehud.app com.codexusagehud.codex-writer com.codexusagehud.claude-writer com.codexusagehud.grok-writer com.codexusagehud.refresh
# Retired: the PTY live scraper (removed). Listed so `make launchd` cleans up old installs.
RETIRED_LAUNCHD_LABELS = com.codexusagehud.live-scraper
LAUNCHD_LABELS = $(CORE_LAUNCHD_LABELS)
ALL_LAUNCHD_LABELS = $(CORE_LAUNCHD_LABELS)
SERVICE_LAUNCHD_LABELS = $(filter-out com.codexusagehud.app,$(LAUNCHD_LABELS))
LEGACY_LAUNCHD_LABELS = com.bloom.usage-hud com.bloom.usage-codex-writer com.bloom.usage-claude-writer com.bloom.usage-refresh

.PHONY: icon build app install-app install support-dirs install-bin launchd launchd-services claude-scraper-stop claude-refresh-now run package uninstall clean test test-mini

# Regenerate the compiled app icon (needs Xcode's actool) after editing
# Resources/AppIcon.icon. The outputs are committed so plain builds need no Xcode.
icon:
	@rm -rf "$(BUILD_DIR)/icon" && mkdir -p "$(BUILD_DIR)/icon"
	@xcrun actool Resources/AppIcon.icon --compile "$(BUILD_DIR)/icon" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$(BUILD_DIR)/icon/partial.plist" >/dev/null
	@cp "$(BUILD_DIR)/icon/AppIcon.icns" "$(BUILD_DIR)/icon/Assets.car" Resources/Icon/
	@echo "wrote Resources/Icon/AppIcon.icns and Assets.car"

build:
	swift build -c release $(addprefix --arch ,$(ARCHS))

app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources/bin"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources/launchd"
	@cp "$(BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@# Sparkle (auto-updates). ditto keeps the framework's symlinks intact; the
	@# executable finds it through its @executable_path/../Frameworks rpath.
	@/usr/bin/ditto "$(SPARKLE_FRAMEWORK)" "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@cp Resources/Icon/AppIcon.icns Resources/Icon/Assets.car "$(APP_BUNDLE)/Contents/Resources/"
	@cp INSTALL.md "$(APP_BUNDLE)/Contents/Resources/INSTALL.md"
	@cp LICENSE "$(APP_BUNDLE)/Contents/Resources/LICENSE"
	@cp Resources/bundled-helpers.txt "$(APP_BUNDLE)/Contents/Resources/bundled-helpers.txt"
	@for f in $(APP_HELPERS); do \
		cp "bin/$$f" "$(APP_BUNDLE)/Contents/Resources/bin/$$f"; \
		chmod +x "$(APP_BUNDLE)/Contents/Resources/bin/$$f"; \
	done
	@for label in $(ALL_LAUNCHD_LABELS); do \
		cp "launchd/$$label.plist" "$(APP_BUNDLE)/Contents/Resources/launchd/$$label.plist"; \
	done
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(APP_VERSION)" "$(APP_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(APP_BUILD)" "$(APP_BUNDLE)/Contents/Info.plist"
	@touch "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@# A Developer ID signature lets macOS register the app for notifications;
	@# an ad-hoc one is refused and never shows in System Settings.
	@# sign_app.sh signs Sparkle's helpers, the framework, then the app (no --deep).
	@SIGN_TIMESTAMP=none ./script/sign_app.sh "$(APP_BUNDLE)" "$(DEVELOPER_ID_APPLICATION)"
	@echo "wrote $(APP_BUNDLE)"

install-app: app
	@rm -rf "$(LEGACY_APP_BUNDLE)"
	@rm -rf "$(INSTALL_APP_BUNDLE)"
	@mkdir -p "$(INSTALL_DIR)"
	@/usr/bin/ditto "$(APP_BUNDLE)" "$(INSTALL_APP_BUNDLE)"
	@echo "installed $(INSTALL_APP_BUNDLE)"

support-dirs:
	@mkdir -p "$(SUPPORT_DIR)/state" "$(SUPPORT_DIR)/logs" "$(LAUNCHD_RENDER_DIR)" "$(STATE_DIR)" "$(HOME)/.local/bin"
	@chmod 700 "$(SUPPORT_DIR)" "$(SUPPORT_DIR)/state" "$(SUPPORT_DIR)/logs" "$(LAUNCHD_RENDER_DIR)" "$(STATE_DIR)"
	@for f in hud.log hud.err.log codex-writer.log codex-writer.err.log claude-writer.log claude-writer.err.log grok-writer.log grok-writer.err.log usage-refresh.log usage-refresh.err.log live-scraper.log live-scraper.err.log; do \
		[ -f "$(SUPPORT_DIR)/logs/$$f" ] || touch "$(SUPPORT_DIR)/logs/$$f"; \
		chmod 600 "$(SUPPORT_DIR)/logs/$$f"; \
	done
	@echo "support dirs ready"

install-bin: support-dirs
	@for f in bloom-budget-notify bloom-budget-update bloom-node bloom-usage-capture.sh bloom-usage-fetch-claude-official bloom-usage-statusline-tap bloom-usage-write-claude bloom-usage-write-codex bloom-usage-write-gemini-agy bloom-usage-write-grok codex-usage-doctor codex-usage-refresh codex-usage-write; do \
		cp "bin/$$f" "$(HOME)/.local/bin/$$f"; \
		chmod +x "$(HOME)/.local/bin/$$f"; \
		echo "installed $$f"; \
	done
	@mkdir -p "$(HOME)/.claude/hooks"
	@cp bin/bloom-usage-capture.sh "$(HOME)/.claude/hooks/bloom-usage-capture.sh"
	@chmod +x "$(HOME)/.claude/hooks/bloom-usage-capture.sh"
	@cp hooks/bloom-budget-guard.js "$(HOME)/.claude/hooks/bloom-budget-guard.js"
	@chmod +x "$(HOME)/.claude/hooks/bloom-budget-guard.js"
	@echo "installed Claude capture + budget hooks"



launchd: install-app support-dirs
	@for label in $(ALL_LAUNCHD_LABELS) $(RETIRED_LAUNCHD_LABELS) $(LEGACY_LAUNCHD_LABELS); do \
		launchctl bootout gui/$$(id -u)/$$label 2>/dev/null || true; \
	done
	@for label in $(RETIRED_LAUNCHD_LABELS) $(LEGACY_LAUNCHD_LABELS); do \
		rm -f "$(HOME)/Library/LaunchAgents/$$label.plist"; \
	done
	@for plist in $(LAUNCHD_LABELS); do \
		sed \
			-e 's|%%HOME%%|$(HOME)|g' \
			-e 's|%%STATE_DIR%%|$(STATE_DIR)|g' \
			-e 's|%%BIN_DIR%%|$(LAUNCHD_BIN_DIR)|g' \
			-e 's|%%SUPPORT_DIR%%|$(SUPPORT_DIR)|g' \
			-e 's|%%APP_EXECUTABLE%%|$(APP_EXECUTABLE)|g' \
			"launchd/$$plist.plist" > "$(LAUNCHD_RENDER_DIR)/$$plist.plist"; \
		cp "$(LAUNCHD_RENDER_DIR)/$$plist.plist" "$(HOME)/Library/LaunchAgents/$$plist.plist"; \
		launchctl bootstrap gui/$$(id -u) "$(HOME)/Library/LaunchAgents/$$plist.plist"; \
		if [ "$$plist" = "com.codexusagehud.app" ]; then \
			launchctl kickstart -k gui/$$(id -u)/$$plist; \
		else \
			launchctl start gui/$$(id -u)/$$plist 2>/dev/null || true; \
		fi; \
		echo "launched $$plist"; \
	done

install: install-bin launchd

# Re-render and reload only the background services (writers + refresh) from
# the templates in launchd/, leaving the installed app bundle and its signature
# alone. Use after a bin or template change when the app itself did not change.
launchd-services: support-dirs
	@for plist in $(SERVICE_LAUNCHD_LABELS); do \
		launchctl bootout gui/$$(id -u)/$$plist 2>/dev/null || true; \
		sed \
			-e 's|%%HOME%%|$(HOME)|g' \
			-e 's|%%STATE_DIR%%|$(STATE_DIR)|g' \
			-e 's|%%BIN_DIR%%|$(LAUNCHD_BIN_DIR)|g' \
			-e 's|%%SUPPORT_DIR%%|$(SUPPORT_DIR)|g' \
			-e 's|%%APP_EXECUTABLE%%|$(APP_EXECUTABLE)|g' \
			"launchd/$$plist.plist" > "$(LAUNCHD_RENDER_DIR)/$$plist.plist"; \
		cp "$(LAUNCHD_RENDER_DIR)/$$plist.plist" "$(HOME)/Library/LaunchAgents/$$plist.plist"; \
		launchctl bootstrap gui/$$(id -u) "$(HOME)/Library/LaunchAgents/$$plist.plist"; \
		launchctl start gui/$$(id -u)/$$plist 2>/dev/null || true; \
		echo "reloaded $$plist"; \
	done

claude-scraper-stop:
	launchctl bootout gui/$$(id -u)/com.codexusagehud.live-scraper 2>/dev/null || true
	rm -f "$(HOME)/Library/LaunchAgents/com.codexusagehud.live-scraper.plist"

claude-refresh-now:
	"$(HOME)/.local/bin/bloom-usage-fetch-claude-official" --mode api --force
	"$(HOME)/.local/bin/bloom-node" "$(HOME)/.local/bin/bloom-usage-write-claude"

run:
	./script/build_and_run.sh

package:
	./script/package_release.sh --skip-notary

uninstall:
	./script/uninstall.sh

# One shared non-app check; the full app check adds Swift.
test-mini:
	./script/check-mini.sh

test:
	swift test
	$(MAKE) test-mini

# Export one committed tree; no Git history or private operations are included.
.PHONY: source
source:
	python3 script/export-source.py

clean:
	swift package clean
	rm -rf "$(APP_BUNDLE)"
