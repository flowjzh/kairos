# Kairos

> Measure **kairos** — the time you are genuinely present — not **chronos**, the wall-clock time the machine spends grinding.

Kairos is a local-first, macOS **human-time kernel**. It records the time you are actually engaged with your work — reading, thinking, prompting, researching — and attributes each block of active time to the activity (a Claude Code session, a client meeting, an ad-hoc task) you were driving. It is built for freelancers who need an accurate, summarizable timesheet of *human* effort, distinct from AI/tool execution time.

## Status

**M1 + M2 implemented** (macOS 14+): the resident menu-bar daemon, the line-JSON protocol, explicit-bounds **and** AI submit-anchored attribution, the `kairos` CLI, a SwiftUI config window, and the `kairos-claude-code` Claude Code plugin. Snapshots and the reference Python summarizer are M3. See [roadmap](./docs/09-roadmap.md).

## Quickstart

```sh
make test                 # Swift Testing suite (no Xcode required)
make app                  # build + assemble Kairos.app (release, stripped, ad-hoc signed)
make app ARCH=arm64       # cross-build for Apple Silicon → build/arm64/ (won't run on Intel)
swift run KairosDaemon    # run the daemon directly — a menu-bar item appears
make install              # install Kairos.app + an opt-in LaunchAgent (not started)
make start                # start the release daemon on demand (make stop to stop)
```

The daemon opens `~/Library/Application Support/Kairos/kairos.db`, listens on `~/.kairos/daemon.sock`, and samples idle (60s threshold). Ingest requests that arrive while it is down are spooled to `~/.kairos/spool/` and drained on startup. The runtime dir is overridable via `$KAIROS_RUNTIME_DIR` (socket + spool); the store path is baked into the app bundle (the daemon reads a `KairosDataDir` Info.plist key, defaulting to `~/Library/Application Support/Kairos`). This is how the dev and release instances stay isolated (below).

The `kairos` CLI ships inside `Kairos.app`; enable it on your shell PATH from **Configure → General → Command-Line Tool** (symlinks `/usr/local/bin/kairos`, one admin prompt). `make install` also links `~/.local/bin/kairos` to the repo build for local development.

### Dev vs release

Develop against a **separate daemon, socket, and database** so wiping the dev DB never touches real freelance data — and run both instances at once:

```sh
make install-dev          # install Kairos Dev.app (distinct bundle id)
make start-dev            # start the dev daemon (uses ~/.kairos-dev + …/Kairos-dev)
make dev                  # or: rebuild + open the dev app directly (quick debug loop)
make clean-dev            # wipe ONLY the dev runtime + DB — release is untouched
```

The daemon code has no notion of "dev" — it reads `$KAIROS_RUNTIME_DIR` (runtime) and the bundle's `KairosDataDir` key (data), else the release defaults. The dev/release difference lives entirely in the build: `make install-dev` bakes the `-dev` dirs into the dev app's bundle (`KAIROS_RUNTIME_DIR` via `LSEnvironment`; the data dir as a `KairosDataDir` Info.plist key), so double-click / `make dev` / `make start-dev` all reach the dev instance. To point *this repo's* Claude plugin + `kairos claude` at the dev daemon, set the runtime dir for the session (the hook reads only `$KAIROS_RUNTIME_DIR` — it never touches the DB):

```jsonc
// .claude/settings.local.json (gitignored) — routes direct `claude` here to dev
{ "env": {
    "KAIROS_RUNTIME_DIR": "/Users/you/.kairos-dev"
} }
```

```sh
# and export the same for `kairos claude` in a dev shell
export KAIROS_RUNTIME_DIR=~/.kairos-dev
```

Both LaunchAgents are opt-in (`RunAtLoad=false`): the daemon runs only when you `make start`. Flip `RunAtLoad` to `true` in the plist to autostart at login.

```sh
kairos client add "Acme"                            # prints the new client id
kairos map set --project daemonclaw --client 1      # tag a project's client (retroactive)
kairos activity open --source manual --id api-review --project daemonclaw --title "API review"
kairos activity close --source manual --id api-review
kairos export --from 0 --to 9999999999 | jq .       # client-grouped, attributed segments
```

Meetings and ad-hoc tasks can also be logged from the menu bar → **Configure…** (start/stop, direct client). Attribution is recomputed on every read: a manual `pause` holes explicit time, while `afk` does not (explicit is afk-immune). AI sessions use submit-anchored windows (`[open | ai_stop, ai_submit]`), which afk *does* hole.

## Claude Code plugin

Track AI coding sessions by installing the bundled plugin. It hooks `SessionStart` / `UserPromptSubmit` / `Stop` / `SessionEnd` and shells out to a small native binary that reports to the daemon (fire-and-forget, spooled if the daemon is down).

```sh
make plugin                                   # build + stage bin/kairos-claude-code
```

**Dev (per session):** `claude --plugin-dir plugins/claude-code`

**Formal (persists across sessions)** via the bundled local marketplace:

```sh
claude plugin marketplace add "$(pwd)"        # register this repo as a marketplace
claude plugin install kairos-claude-code@kairos
```

The formal install copies the plugin (binary included) into Claude's own cache — separate from `Kairos.app`, which holds the daemon. After rebuilding the binary, re-run `make plugin` then `claude plugin install …` again (or `/reload-plugins`) to refresh the cached copy.

Each session auto-appears as a project (its cwd basename); tag that project's client once in **Configure…** and it applies retroactively. Human-work time (reading, thinking, prompting between the agent stopping and your next submit) is attributed to the session; AI-execution time is excluded.


## Dashboard

**Dashboard…** (menu bar) opens a window over your attributed time: a per-source timeline (each source a translucent area, with the total overlaid as a line) above two tabs — raw segments (paged) and a client → project summary tree. The range picker (Today / This Week / This Month / Custom) drives one in-process attribution pass, memoized so the chart, summary, and paged rows share it.

The data plane is cross-platform: a pure Rust reducer (`libs/report`) folds already-attributed segments into the chart/summary/page shapes, surfaced to the Swift daemon through one general C-ABI boundary (`ffi/` → `libkairos_ffi.a`). The rendering is a Vite + React + shadcn web app (`dashboard/`) hosted in a WKWebView; the same web bundle + reducer are reused unchanged when a Windows host (`wry`/Tauri) is added later.

**Front-end dev loop** (HMR, no re-bundle): the dashboard's default URL is the bundled `kairos://dashboard/index.html`, so it always renders. To debug against the Vite dev server instead, set `KAIROS_DASHBOARD_URL` and launch the binary directly (launching the binary — not `open` — is what lets the env reach the process). Works for whichever bundle's data you want to debug:

```sh
cd dashboard && pnpm install && pnpm dev    # Vite at http://localhost:5173

# Debug the dev bundle (reads ~/.kairos-dev data). KAIROS_RUNTIME_DIR keeps the
# dev socket/spool isolated when launching the binary directly (normally baked
# into the bundle's LSEnvironment, which only `open` applies).
KAIROS_DASHBOARD_URL=http://localhost:5173 KAIROS_RUNTIME_DIR=~/.kairos-dev \
  "build/$(uname -m)/Kairos Dev.app/Contents/MacOS/Kairos"

# Or the release bundle (reads the real ~/.kairos data):
KAIROS_DASHBOARD_URL=http://localhost:5173 /Applications/Kairos.app/Contents/MacOS/Kairos
```

The dev app's WKWebView is inspectable: Safari → Develop → [machine] → Kairos (Dev) → Dashboard.


## Architecture in one breath

```
   resident daemon (lean)                          events (append-only,
   ┌────────────────────────┐   events.post         sole source of truth)
   │ idle sampler ──────────┼──────────────────▶  ┌──────────────────────┐
   │ socket ingest ◀────────┼── clients (any lang)│  ~/.kairos/kairos.db  │
   │ menu-bar (owner view)  │                      └──────────┬───────────┘
   └────────────────────────┘                                 │ read-time
                                                              ▼
                                              KairosCore (daemon-internal;
                                              computes segments on demand —
                                              nothing materialized)
                                                              │
              segments.get  ──or──  `kairos export`  ────────┘  → JSON
                                                              │
   external consumers (Python/Node SDK): per-client timesheets,
   API delivery, LLM summaries — all outside the core.
```

- **`kairosd`** — a lean Swift `LaunchAgent` daemon. Its *only* resident jobs: sample system idle → append AFK events, accept client events over a local socket, host a menu-bar status item. **Zero special permissions** (no Accessibility, no Automation).
- **Events are the sole source of truth.** Segments (attributed active-time blocks) are **computed on demand** by the daemon-internal attribution library (`KairosCore`) — never stored/materialized, and not exposed via FFI.
- **Clients** are external processes that speak the protocol (line-JSON RPC over a Unix socket, or the `kairos` CLI). `kairos-claude-code` is a Claude Code plugin reporting `Stop` / `UserPromptSubmit`. Writing a new client in any language extends what Kairos tracks.
- **Consumers** read segments via the **Python/Node SDK** (or `kairos export`) and render timesheets. Formatting, per-client templates, and API delivery live **outside the core**.

## Documentation

1. [Overview & principles](./docs/01-overview.md) — the problem, the thesis, permissions & privacy
2. [Architecture](./docs/02-architecture.md) — components, data flow, process model
3. [Data model](./docs/03-data-model.md) — SQLite schema; events as truth, segments computed, snapshot recipes
4. [Attribution](./docs/04-attribution.md) — how active time is assigned to activities *(the core)*
5. [Protocol](./docs/05-protocol.md) — the language-agnostic client/consumer interface (socket + CLI)
6. [Daemon design](./docs/06-daemon.md) — idle kernel, socket server, menu bar, launchd
7. [Clients](./docs/07-clients.md) — `kairos-claude-code`, manual/meeting, the extension model
8. [Consumers & summarizer](./docs/08-summarizer.md) — timesheet generation as an external concern
9. [Roadmap](./docs/09-roadmap.md) — milestones, MVP scope, open decisions, ADRs

## License

TBD (see [roadmap](./docs/09-roadmap.md)).
