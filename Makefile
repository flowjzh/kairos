.PHONY: build test app rust install uninstall plugin clean

# The Swift daemon lives under daemon/mac/; the Rust CLI/PTY + Claude Code hook
# are the root Cargo workspace (libs/codec, libs/client, cli, plugins/claude-code).
SWIFT_PKG := daemon/mac
BIN := $(shell swift build --show-bin-path --package-path $(SWIFT_PKG) 2>/dev/null)
APP := build/Kairos.app
INSTALL_APP := /Applications/Kairos.app
LAUNCH_AGENT := $(HOME)/Library/LaunchAgents/dev.kairos.daemon.plist
PLUGIN_DIR := plugins/claude-code

build:
	swift build --package-path $(SWIFT_PKG)

rust:
	cargo build --release

test:
	cargo test
	swift test --package-path $(SWIFT_PKG)

# Build the .app from the Swift menu-bar daemon.
app: build
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS
	cp "$(BIN)/KairosDaemon" $(APP)/Contents/MacOS/Kairos
	cp Support/Info.plist $(APP)/Contents/Info.plist
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force --sign - $(APP)

# Build the Claude Code hook binary and stage it into the plugin. The binary
# must exist before a formal install, since Claude copies the plugin (incl.
# bin/) into its own cache. Dev loop: claude --plugin-dir plugins/claude-code
# Formal install (persists across sessions), run inside Claude Code:
#   /plugin marketplace add $(CURDIR)
#   /plugin install kairos-claude-code@kairos
plugin: rust
	@mkdir -p $(PLUGIN_DIR)/bin
	cp target/release/kairos-claude-code $(PLUGIN_DIR)/bin/kairos-claude-code
	@echo
	@echo "Staged $(PLUGIN_DIR)/bin/kairos-claude-code"
	@echo "Formal install — run inside Claude Code:"
	@echo "  /plugin marketplace add $(CURDIR)"
	@echo "  /plugin install kairos-claude-code@kairos"
	@echo "Rebuilt the binary? Re-run this, then /plugin install again (or /reload-plugins)."

install: app rust
	-launchctl unload $(LAUNCH_AGENT) 2>/dev/null
	rm -rf $(INSTALL_APP)
	cp -R $(APP) $(INSTALL_APP)
	cp Support/dev.kairos.daemon.plist $(LAUNCH_AGENT)
	launchctl load $(LAUNCH_AGENT)
	@mkdir -p $(HOME)/.local/bin
	@ln -sf "$(CURDIR)/target/release/kairos" $(HOME)/.local/bin/kairos

uninstall:
	-launchctl unload $(LAUNCH_AGENT) 2>/dev/null
	rm -f $(LAUNCH_AGENT)
	rm -rf $(INSTALL_APP)
	rm -rf $(APP)
	rm -f $(HOME)/.local/bin/kairos

clean:
	swift package clean --package-path $(SWIFT_PKG)
	cargo clean
	rm -rf build
