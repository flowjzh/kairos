.PHONY: build test app app-dev rust install install-dev uninstall \
        start stop start-dev stop-dev dev plugin clean clean-dev

# The Swift daemon lives under daemon/mac/; the Rust CLI/PTY + Claude Code hook
# are the root Cargo workspace (libs/codec, libs/client, cli, plugins/claude-code).
# BIN_* are the SwiftPM per-config symlinks (`.build/release`, `.build/debug`) — a
# stable layout, so we avoid a `swift build --show-bin-path` shell-out on every
# make invocation (it added ~1s even to targets that never build the daemon).
SWIFT_PKG   := daemon/mac
BIN_RELEASE := $(SWIFT_PKG)/.build/release
BIN_DEBUG   := $(SWIFT_PKG)/.build/debug
UID         := $(shell id -u)

APP         := build/Kairos.app
APP_DEV     := build/Kairos Dev.app
INSTALL_APP := /Applications/Kairos.app
INSTALL_DEV := /Applications/Kairos Dev.app
AGENTS      := $(HOME)/Library/LaunchAgents
LABEL       := dev.kairos.daemon
LABEL_DEV   := dev.kairos.daemon.dev
PLUGIN_DIR  := plugins/claude-code

# The dev instance's isolated dirs. Baked (as absolute paths) into the dev app's
# LSEnvironment at build time — the ONLY place dev/release diverges. The running daemon just reads
# $KAIROS_RUNTIME_DIR/$KAIROS_DATA_DIR (or the release defaults); it has no
# dev/release branch.
DEV_RUNTIME_DIR := $(HOME)/.kairos-dev
DEV_DATA_DIR    := $(HOME)/Library/Application Support/Kairos-dev

build:
	swift build --package-path $(SWIFT_PKG)

# Build the shared release CLI (`kairos`) and the plugin hook binary. Each is built
# once under its own profile: the CLI unwinds on panic (restoring the terminal from
# raw mode), the hook aborts (no state to unwind → a smaller binary in target/hook).
rust:
	cargo build --release --bin kairos
	cargo build --profile hook --bin kairos-claude-code

test:
	cargo test
	swift test -c release --package-path $(SWIFT_PKG)

# Build the release .app: strip the binary (Rust already strips via the release
# profile; this is the Swift half), stage the release Info.plist, ad-hoc sign.
app:
	swift build -c release --package-path $(SWIFT_PKG)
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BIN_RELEASE)/KairosDaemon" "$(APP)/Contents/MacOS/Kairos"
	strip -x "$(APP)/Contents/MacOS/Kairos"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	@mkdir -p "$(APP)/Contents/Resources"
	cp Support/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --sign - "$(APP)"

# Build the dev .app: debug build (symbols kept, not stripped) + the dev
# Info.plist (distinct bundle id/name). The dev dirs are baked in as
# LSEnvironment so a double-click / `make dev` reaches the dev instance; the code
# stays env-driven and dev-agnostic.
app-dev: build
	@rm -rf "$(APP_DEV)"
	@mkdir -p "$(APP_DEV)/Contents/MacOS"
	cp "$(BIN_DEBUG)/KairosDaemon" "$(APP_DEV)/Contents/MacOS/Kairos"
	cp Support/Info-Dev.plist "$(APP_DEV)/Contents/Info.plist"
	@mkdir -p "$(APP_DEV)/Contents/Resources"
	cp Support/AppIcon.icns "$(APP_DEV)/Contents/Resources/AppIcon.icns"
	/usr/libexec/PlistBuddy \
	  -c "Add :LSEnvironment dict" \
	  -c "Add :LSEnvironment:KAIROS_RUNTIME_DIR string $(DEV_RUNTIME_DIR)" \
	  -c "Add :LSEnvironment:KAIROS_DATA_DIR string $(DEV_DATA_DIR)" \
	  "$(APP_DEV)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP_DEV)/Contents/PkgInfo"
	codesign --force --sign - "$(APP_DEV)"

# Build the Claude Code hook binary and stage it into the plugin. The binary
# must exist before a formal install, since Claude copies the plugin (incl.
# bin/) into its own cache. Dev loop: claude --plugin-dir plugins/claude-code
# Formal install (persists across sessions), run inside Claude Code:
#   /plugin marketplace add $(CURDIR)
#   /plugin install kairos-claude-code@kairos
plugin: rust
	@mkdir -p $(PLUGIN_DIR)/bin
	cp target/hook/kairos-claude-code $(PLUGIN_DIR)/bin/kairos-claude-code
	@echo
	@echo "Staged $(PLUGIN_DIR)/bin/kairos-claude-code"
	@echo "Formal install — run inside Claude Code:"
	@echo "  /plugin marketplace add $(CURDIR)"
	@echo "  /plugin install kairos-claude-code@kairos"
	@echo "Rebuilt the binary? Re-run this, then /plugin install again (or /reload-plugins)."

# Install the release app + the shared CLI. The daemon does NOT start here — run
# `make start`, or flip "Launch Kairos at login" in the app (SMAppService.mainApp
# registers the app as a login item).
install: app rust
	rm -rf "$(INSTALL_APP)"
	cp -R "$(APP)" "$(INSTALL_APP)"
	@mkdir -p $(HOME)/.local/bin
	@ln -sf "$(CURDIR)/target/release/kairos" $(HOME)/.local/bin/kairos
	@echo "Installed. Start on demand: make start"

# Install the dev app. Its bundled LSEnvironment bakes the dev dirs
# (KAIROS_RUNTIME_DIR / KAIROS_DATA_DIR), so login-launch and double-click alike
# reach the dev instance. Shares the one CLI + plugin binary.
install-dev: app-dev
	rm -rf "$(INSTALL_DEV)"
	cp -R "$(APP_DEV)" "$(INSTALL_DEV)"
	@echo "Installed dev. Start on demand: make start-dev (or make dev)"

# On-demand start/stop by launching / SIGTERM-ing the installed app (a menu-bar
# accessory). `open` propagates the calling shell's environment, so scrub KAIROS_*
# first — otherwise a dev-configured shell would leak its dirs into the release
# instance (both would target the dev DB). Release then falls back to its ~/.kairos
# defaults; dev gets its dirs from the bundle's baked LSEnvironment either way.
# The single-instance guard keeps a duplicate from a concurrent login-launch out;
# SIGTERM triggers the graceful WAL checkpoint on the way down.
SCRUB := env -u KAIROS_RUNTIME_DIR -u KAIROS_DATA_DIR -u KAIROS_SESSION_ID

start:
	$(SCRUB) open "$(INSTALL_APP)"

stop:
	-pkill -f "$(INSTALL_APP)/Contents/MacOS/Kairos"

start-dev:
	$(SCRUB) open "$(INSTALL_DEV)"

stop-dev:
	-pkill -f "$(INSTALL_DEV)/Contents/MacOS/Kairos"

# Quick debug loop: rebuild the dev app and launch it (its bundle bakes the dev
# dirs as LSEnvironment, so it uses the isolated dev instance). Logs go to unified
# logging (Console.app / `log stream --predicate 'process == "Kairos"'`); for file
# logs use `make start-dev` (writes /tmp/kairos-daemon-dev.log).
dev: app-dev
	$(SCRUB) open "$(APP_DEV)"

uninstall:
	-pkill -f "$(INSTALL_APP)/Contents/MacOS/Kairos"
	-pkill -f "$(INSTALL_DEV)/Contents/MacOS/Kairos"
	# Legacy cleanup: older installs registered agents in ~/Library/LaunchAgents.
	-launchctl bootout gui/$(UID)/$(LABEL)
	-launchctl bootout gui/$(UID)/$(LABEL_DEV)
	rm -f $(AGENTS)/$(LABEL).plist $(AGENTS)/$(LABEL_DEV).plist
	rm -rf "$(INSTALL_APP)" "$(INSTALL_DEV)"
	rm -rf build
	rm -f $(HOME)/.local/bin/kairos

# Wipe ONLY the dev instance's runtime + data (socket/spool + db). The release
# instance's ~/.kairos and Application Support/Kairos are never touched.
clean-dev:
	rm -rf "$(DEV_RUNTIME_DIR)" "$(DEV_DATA_DIR)"

clean:
	swift package clean --package-path $(SWIFT_PKG)
	cargo clean
	rm -rf build