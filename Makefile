.PHONY: build test app install uninstall plugin clean

BIN := $(shell swift build --show-bin-path 2>/dev/null)
APP := build/Kairos.app
INSTALL_APP := /Applications/Kairos.app
LAUNCH_AGENT := $(HOME)/Library/LaunchAgents/dev.kairos.daemon.plist
PLUGIN_DIR := plugins/claude-code

build:
	swift build

test:
	swift test

# Build the Claude Code hook binary and stage it into the plugin. The binary
# must exist before a formal install, since Claude copies the plugin (incl.
# bin/) into its own cache. Dev loop: claude --plugin-dir plugins/claude-code
# Formal install (persists across sessions), run inside Claude Code:
#   /plugin marketplace add $(CURDIR)
#   /plugin install kairos-claude-code@kairos
plugin: build
	@mkdir -p $(PLUGIN_DIR)/bin
	cp "$(BIN)/kairos-claude-code" $(PLUGIN_DIR)/bin/kairos-claude-code
	@echo
	@echo "Staged $(PLUGIN_DIR)/bin/kairos-claude-code"
	@echo "Formal install — run inside Claude Code:"
	@echo "  /plugin marketplace add $(CURDIR)"
	@echo "  /plugin install kairos-claude-code@kairos"
	@echo "Rebuilt the binary? Re-run this, then /plugin install again (or /reload-plugins)."

app: build
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS
	cp "$(BIN)/KairosDaemon" $(APP)/Contents/MacOS/Kairos
	cp Support/Info.plist $(APP)/Contents/Info.plist
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force --sign - $(APP)

install: app
	-launchctl unload $(LAUNCH_AGENT) 2>/dev/null
	rm -rf $(INSTALL_APP)
	cp -R $(APP) $(INSTALL_APP)
	cp Support/dev.kairos.daemon.plist $(LAUNCH_AGENT)
	launchctl load $(LAUNCH_AGENT)
	@ln -sf "$(BIN)/kairos" /usr/local/bin/kairos 2>/dev/null || echo "kairos CLI binary: $(BIN)/kairos (add to PATH)"

uninstall:
	-launchctl unload $(LAUNCH_AGENT) 2>/dev/null
	rm -f $(LAUNCH_AGENT)
	rm -rf $(INSTALL_APP)
	rm -rf $(APP)

clean:
	swift package clean
	rm -rf build
