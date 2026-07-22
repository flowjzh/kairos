# Developing Kairos

Kairos is a polyglot macOS app — a Swift menu-bar daemon, a Rust workspace (FFI + CLI
+ Claude Code hook), and a React dashboard. This is the developer guide: how to build,
run the two isolated instances, develop each part, and cut a release. The
[README](./README.md) is end-user-facing (download + install); design lives in
[docs/](./docs).

## Prerequisites

- **macOS 14+** (Sonoma).
- **Swift 6.0** toolchain — for the daemon. `swift test` uses Swift Testing; **no Xcode
  required**.
- **Rust** (stable, `cargo`) — FFI staticlib, `kairos` CLI, Claude Code hook.
- **Node + [pnpm](https://pnpm.io)** — the dashboard web app.

## Build & test

```sh
make test                 # Swift Testing + Rust suites (no Xcode)
make app                  # release Kairos.app (stripped, ad-hoc signed)
make app ARCH=arm64       # cross-build for Apple Silicon → build/arm64/ (won't run on Intel)
make install              # install Kairos.app + symlink ~/.local/bin/kairos (not started)
make start                # start the release daemon on demand (make stop to stop)
```

The daemon opens `~/Library/Application Support/Kairos/kairos.db`, listens on
`~/.kairos/daemon.sock`, and samples idle (60s threshold). Ingest that arrives while
it's down is spooled to `~/.kairos/spool/` and drained on startup. `$KAIROS_RUNTIME_DIR`
overrides socket + spool; the store path is baked into the app bundle (a `KairosDataDir`
Info.plist key, defaulting to `~/Library/Application Support/Kairos`).

**Autostart at login** is an in-app toggle (Configure → Launch at login) backed by
`SMAppService.mainApp` — no `launchd`. `make start`/`stop` `open` and `SIGTERM` the app.

## Dev vs release isolation

Develop against a **separate daemon, socket, and database** so wiping the dev DB never
touches real data — and run both instances at once:

```sh
make install-dev          # install Kairos Dev.app (distinct bundle id)
make start-dev            # start the dev daemon (uses ~/.kairos-dev + …/Kairos-dev)
make dev                  # or: rebuild + open the dev app directly (quick debug loop)
make clean-dev            # wipe ONLY the dev runtime + DB — release is untouched
```

The daemon has no notion of "dev" — it reads `$KAIROS_RUNTIME_DIR` (runtime) and the
bundle's `KairosDataDir` key (data), else the release defaults. `make install-dev` bakes
the `-dev` dirs into the dev app's bundle (`KAIROS_RUNTIME_DIR` via `LSEnvironment`;
the data dir as a `KairosDataDir` Info.plist key), so double-click / `make dev` /
`make start-dev` all reach the dev instance. To point *this repo's* Claude plugin +
`kairos claude` at the dev daemon, set the runtime dir for the session (the hook reads
only `$KAIROS_RUNTIME_DIR` — it never touches the DB):

```jsonc
// .claude/settings.local.json (gitignored) — routes direct `claude` here to dev
{ "env": { "KAIROS_RUNTIME_DIR": "/Users/you/.kairos-dev" } }
```

```sh
# and export the same for `kairos claude` in a dev shell
export KAIROS_RUNTIME_DIR=~/.kairos-dev
```

## Repository layout

| Path | What |
| --- | --- |
| `daemon/mac/` | The Swift menu-bar daemon (SwiftPM) |
| `libs/` | Shared Rust: `codec` (wire types), `client` (socket transport), `report` (pure reducer) |
| `ffi/` | The C-ABI staticlib — the one link boundary between Swift and Rust |
| `cli/` | The `kairos` CLI + transparent PTY wrapper |
| `plugins/claude-code/` | The `kairos-claude-code` hook binary + self-contained plugin marketplace |
| `dashboard/` | Vite + React + shadcn web app (hosted in a WKWebView) |
| `sdk/python/` | Reference consumer SDK |
| `docs/` | Design docs (architecture, data model, attribution, protocol, roadmap) |

## The `kairos` CLI

```sh
kairos client add "Acme"                            # prints the new client id
kairos map set --project daemonclaw --client 1      # tag a project's client (retroactive)
kairos activity open --source manual --id api-review --project daemonclaw --title "API review"
kairos activity close --source manual --id api-review
kairos export --from 0 --to 9999999999 | jq .       # client-grouped, attributed segments
kairos claude                                        # wrap `claude` under a PTY (focus attribution)
```

Meetings and ad-hoc tasks are also logged from the menu bar → **Configure…**
(start/stop, direct client). Attribution is recomputed on every read: a manual `pause`
holes explicit time, while `afk` does not (explicit is afk-immune). AI sessions use
submit-anchored windows (`[open | ai_stop, ai_submit]`), which afk *does* hole. See
[docs/05-protocol.md](./docs/05-protocol.md).

## Claude Code plugin

`plugins/claude-code/` is a **self-contained local marketplace**: its
`.claude-plugin/marketplace.json` names one plugin with `source: "."`, so the directory
*is* both the marketplace and the plugin (`plugin.json` + `hooks/hooks.json`). The hooks
(`SessionStart` / `UserPromptSubmit` / `Stop` / `SessionEnd`) call the native binary
directly at `${CLAUDE_PLUGIN_ROOT}/bin/kairos-claude-code` — no shell shim, no download.

`make app`/`make app-dev` bundle this tree (with the freshly built binary) into the app at
`Contents/Resources/plugins/claude-code/`. The **release** app registers it as the `kairos`
marketplace; the **dev** app stamps the name to `kairos-dev` so the two never collide in
`~/.claude/settings.json` (dev and release register, install, and enable independently). In
the app, **Configure → Plugins → Claude Code → Register** writes the `extraKnownMarketplaces`
entry; the user then `claude plugin install`s it. For a local **directory** marketplace Claude
Code runs the plugin **in place** (`${CLAUDE_PLUGIN_ROOT}` = the bundled path in the app), so
it runs offline from the app bundle — no download. `hooks.json` uses **exec form** so a bundle
path with a space (`Kairos Dev.app`) isn't word-split. Deleting the app makes the hook error
(non-blocking) until `claude plugin uninstall` — so uninstall before removing the app.

**Dev loop** — the dev app owns the `kairos-dev` marketplace; iterate through it (no direct
install from the repo dir):

```sh
make install-dev                                         # rebuild + reinstall the dev app (bundles the fresh hook)
claude plugin marketplace add "/Applications/Kairos Dev.app/Contents/Resources/plugins/claude-code"
claude plugin install kairos-claude-code@kairos-dev --scope local
```

```jsonc
// .claude/settings.local.json (gitignored) — routes this repo's sessions to the dev daemon
{ "env": { "KAIROS_RUNTIME_DIR": "/Users/you/.kairos-dev" } }
```

Rebuilt the hook? Re-run `make install-dev` then `claude plugin install kairos-claude-code@kairos-dev`
to refresh the cached copy. (Or click **Register** in the Dev app's Plugins pane instead of the
`marketplace add` line.)

## Dashboard front-end dev

The dashboard's default URL is the bundled `kairos://dashboard/index.html`, so it always
renders. For HMR against the Vite dev server, set `KAIROS_DASHBOARD_URL` and launch the
binary **directly** (not `open` — only a direct launch lets the env reach the process):

```sh
cd dashboard && pnpm install && pnpm dev    # Vite at http://localhost:5173

# Debug the dev bundle (reads ~/.kairos-dev data). KAIROS_RUNTIME_DIR keeps the
# dev socket/spool isolated when launching the binary directly.
KAIROS_DASHBOARD_URL=http://localhost:5173 KAIROS_RUNTIME_DIR=~/.kairos-dev \
  "build/$(uname -m)/Kairos Dev.app/Contents/MacOS/Kairos"

# Or the release bundle (reads the real ~/.kairos data):
KAIROS_DASHBOARD_URL=http://localhost:5173 /Applications/Kairos.app/Contents/MacOS/Kairos
```

The data plane is cross-platform: a pure Rust reducer (`libs/report`) folds
already-attributed segments into chart/summary/page shapes, surfaced to Swift through one
C-ABI boundary (`ffi/` → `libkairos_ffi.a`). The rendering is Vite + React + shadcn hosted
in a WKWebView. The dev app's WKWebView is inspectable: Safari → Develop → [machine] →
Kairos (Dev) → Dashboard. Architecture detail: [docs/02-architecture.md](./docs/02-architecture.md).

## Adding a tracked client

Kairos is agent-agnostic: anything speaking the line-JSON protocol over the socket (or
shelling out via the `kairos` CLI) is a client. `kairos-claude-code` is the template — see
[docs/07-clients.md](./docs/07-clients.md) and [docs/05-protocol.md](./docs/05-protocol.md).

## Commits

Follow the 50/72 rule (≤50-char subject, body wrapped at 72). Keep `main` buildable.

## Versioning & releases

Two independently-versioned artifacts:

**The app + CLI — tag-as-source.** The git tag `vX.Y.Z` is the single source of truth.
`make app`/`make app-dev` derive the version from the latest tag
(`git describe --tags --abbrev=0` → `CFBundleShortVersionString`) and the commit count
(`CFBundleVersion`), and pass it to the Rust CLI build so `kairos -V` matches. The
`Cargo.toml` / `package.json` version strings are non-authoritative floors (Cargo requires
the field; the crates aren't published). No tag yet → the build reports a `0.1.0-dev`
fallback. To cut an app release: `git tag vX.Y.Z`, then create the GitHub Release for that
tag and attach a zipped `build/<arch>/Kairos.app`. The next `make app` bakes `X.Y.Z` in.

**The plugin — its own version, shipped in the app.** The plugin isn't released
separately: its native binary is bundled into the app by `make app` (§ Claude Code plugin),
so it always matches the daemon it talks to. `plugins/claude-code/.claude-plugin/plugin.json`'s
`version` is what Claude Code uses to detect updates — bump it whenever the plugin changes, and
an in-place app update (same install path, new bundled version) makes `claude plugin update`
pull the new copy from the bundled marketplace. No GitHub Release asset, no download.

## License

By contributing you agree your changes are licensed under the project's
[MIT license](./LICENSE).
