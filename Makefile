.PHONY: build test app app-dev cli rust install install-dev uninstall \
        start stop start-dev stop-dev dev plugin clean clean-dev

# The Swift daemon lives under daemon/mac/; the Rust CLI/PTY + Claude Code hook
# are the root Cargo workspace (libs/codec, libs/client, cli, plugins/claude-code).
# BIN_* resolve the SwiftPM build dir directly from the target arch (below) instead
# of a `swift build --show-bin-path` shell-out on every make invocation (~1s even
# for targets that never build the daemon).
# Target architecture: defaults to the host machine's arch (uname -m). Override to
# cross-build for distribution — e.g. `make app ARCH=arm64` on an Intel Mac. A pure
# arm64 build won't run on x86_64: use it to ship to an Apple-Silicon host, not to
# run locally. SPM speaks arm64/x86_64 directly; Cargo wants a full triple and calls
# arm64 `aarch64`, so map once and thread the flag through every native target.
HOST_ARCH    := $(shell uname -m)
ARCH         ?= $(HOST_ARCH)
ifeq ($(ARCH),arm64)
  RUST_TARGET := aarch64-apple-darwin
else ifeq ($(ARCH),x86_64)
  RUST_TARGET := x86_64-apple-darwin
else
  $(error Unsupported ARCH '$(ARCH)'; use arm64 or x86_64)
endif

SWIFT_PKG    := daemon/mac
SWIFT_ARCH   := --arch $(ARCH)
CARGO_ARCH   := --target $(RUST_TARGET)
BIN_RELEASE  := $(SWIFT_PKG)/.build/$(ARCH)-apple-macosx/release
BIN_DEBUG    := $(SWIFT_PKG)/.build/$(ARCH)-apple-macosx/debug
BIN_KAIROS   := target/$(RUST_TARGET)/release/kairos
BIN_HOOK     := target/$(RUST_TARGET)/hook/kairos-claude-code
UID          := $(shell id -u)

# Per-arch products so a cross-build never clobbers host artifacts.
BUILD_DIR    := build/$(ARCH)
APP          := $(BUILD_DIR)/Kairos.app
APP_DEV      := $(BUILD_DIR)/Kairos Dev.app
INSTALL_APP  := /Applications/Kairos.app
INSTALL_DEV  := /Applications/Kairos Dev.app
AGENTS       := $(HOME)/Library/LaunchAgents
LABEL        := dev.kairos.daemon
LABEL_DEV    := dev.kairos.daemon.dev
PLUGIN_DIR   := plugins/claude-code

# The dev instance's isolated dirs. Baked (as absolute paths) into the dev app's
# bundle at build time — the ONLY place dev/release diverges. KAIROS_RUNTIME_DIR
# stays env-driven (the non-bundle CLI/hook read it to target the socket); the
# data dir is a KairosDataDir Info.plist key (only the daemon reads it). The
# running daemon has no dev/release branch.
DEV_RUNTIME_DIR := $(HOME)/.kairos-dev
DEV_DATA_DIR    := $(HOME)/Library/Application Support/Kairos-dev

build:
	swift build --package-path $(SWIFT_PKG) $(SWIFT_ARCH)

# The shared release CLI (`kairos`), built once per arch. The release profile
# unwinds on panic so the PTY wrapper can restore the terminal from raw mode.
# A prerequisite of `app`/`app-dev` (bundled) and `install` (symlinked onto PATH).
cli:
	cargo build --release --bin kairos $(CARGO_ARCH)

# The CLI plus the plugin hook binary. The hook aborts on panic (no state to
# unwind → a smaller binary in target/hook).
rust: cli
	cargo build --profile hook --bin kairos-claude-code $(CARGO_ARCH)

test:
	cargo test $(CARGO_ARCH)
	swift test -c release --package-path $(SWIFT_PKG) $(SWIFT_ARCH)

# Build the release .app: strip the binary (Rust already strips via the release
# profile; this is the Swift half), stage the release Info.plist, ad-hoc sign.
app: cli
	swift build -c release --package-path $(SWIFT_PKG) $(SWIFT_ARCH)
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BIN_RELEASE)/KairosDaemon" "$(APP)/Contents/MacOS/Kairos"
	strip -x "$(APP)/Contents/MacOS/Kairos"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	@mkdir -p "$(APP)/Contents/Resources"
	cp Support/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	plutil -lint Support/zh-Hans.lproj/Localizable.strings
	cp -R Support/zh-Hans.lproj "$(APP)/Contents/Resources/zh-Hans.lproj"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	# The CLI ships inside the bundle (renamed to avoid a case-insensitive clash
	# with the Kairos daemon exec); the user opts into a /usr/local/bin symlink
	# via Configure. Ad-hoc sign the inner binary BEFORE sealing the bundle.
	cp "$(BIN_KAIROS)" "$(APP)/Contents/MacOS/kairos-cli"
	codesign --force --sign - "$(APP)/Contents/MacOS/kairos-cli"
	codesign --force --sign - "$(APP)"

# Build the dev .app: debug build (symbols kept, not stripped) + the dev
# Info.plist (distinct bundle id/name). The dev dirs are baked in as
# LSEnvironment so a double-click / `make dev` reaches the dev instance; the code
# stays env-driven and dev-agnostic.
app-dev: build cli
	@rm -rf "$(APP_DEV)"
	@mkdir -p "$(APP_DEV)/Contents/MacOS"
	cp "$(BIN_DEBUG)/KairosDaemon" "$(APP_DEV)/Contents/MacOS/Kairos"
	cp Support/Info-Dev.plist "$(APP_DEV)/Contents/Info.plist"
	@mkdir -p "$(APP_DEV)/Contents/Resources"
	cp Support/AppIcon.icns "$(APP_DEV)/Contents/Resources/AppIcon.icns"
	plutil -lint Support/zh-Hans.lproj/Localizable.strings
	cp -R Support/zh-Hans.lproj "$(APP_DEV)/Contents/Resources/zh-Hans.lproj"
	/usr/libexec/PlistBuddy \
	  -c "Add :LSEnvironment dict" \
	  -c "Add :LSEnvironment:KAIROS_RUNTIME_DIR string $(DEV_RUNTIME_DIR)" \
	  -c "Add :KairosDataDir string $(DEV_DATA_DIR)" \
	  "$(APP_DEV)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP_DEV)/Contents/PkgInfo"
	# Bundle the CLI here too (one build path; lets the in-app installer be tested
	# against the dev app). Sign the inner binary before sealing the bundle.
	cp "$(BIN_KAIROS)" "$(APP_DEV)/Contents/MacOS/kairos-cli"
	codesign --force --sign - "$(APP_DEV)/Contents/MacOS/kairos-cli"
	codesign --force --sign - "$(APP_DEV)"

# Build the Claude Code hook binary and stage it into the plugin. The binary
# must exist before a formal install, since Claude copies the plugin (incl.
# bin/) into its own cache. Dev loop: claude --plugin-dir plugins/claude-code
# Formal install (persists across sessions), run inside Claude Code:
#   /plugin marketplace add $(CURDIR)
#   /plugin install kairos-claude-code@kairos
plugin: rust
	@mkdir -p $(PLUGIN_DIR)/bin
	cp $(BIN_HOOK) $(PLUGIN_DIR)/bin/kairos-claude-code
	@echo
	@echo "Staged $(PLUGIN_DIR)/bin/kairos-claude-code"
	@echo "Formal install — run inside Claude Code:"
	@echo "  /plugin marketplace add $(CURDIR)"
	@echo "  /plugin install kairos-claude-code@kairos"
	@echo "Rebuilt the binary? Re-run this, then /plugin install again (or /reload-plugins)."

# Install the release app + the shared CLI. The daemon does NOT start here — run
# `make start`, or flip "Launch Kairos at login" in the app (SMAppService.mainApp
# registers the app as a login item).
install: app
	rm -rf "$(INSTALL_APP)"
	cp -R "$(APP)" "$(INSTALL_APP)"
	@mkdir -p $(HOME)/.local/bin
	@ln -sf "$(CURDIR)/$(BIN_KAIROS)" $(HOME)/.local/bin/kairos
	@echo "Installed. Start on demand: make start"

# Install the dev app. Its bundle bakes the dev dirs — KAIROS_RUNTIME_DIR in
# LSEnvironment, the data dir as a KairosDataDir Info.plist key — so login-launch
# and double-click alike reach the dev instance. Shares the one CLI + plugin.
install-dev: app-dev
	rm -rf "$(INSTALL_DEV)"
	cp -R "$(APP_DEV)" "$(INSTALL_DEV)"
	@echo "Installed dev. Start on demand: make start-dev (or make dev)"

# On-demand start/stop by launching / SIGTERM-ing the installed app (a menu-bar
# accessory). `open` propagates the calling shell's environment, so scrub
# KAIROS_RUNTIME_DIR first — otherwise a dev-configured shell would leak its
# runtime dir into the release instance. The data dir is immune (bundle-baked,
# not read from env). Release then falls back to its ~/.kairos default; dev gets
# its dirs from the bundle either way. The single-instance guard keeps a duplicate
# from a concurrent login-launch out; SIGTERM triggers the graceful WAL checkpoint.
SCRUB := env -u KAIROS_RUNTIME_DIR -u KAIROS_SESSION_ID

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