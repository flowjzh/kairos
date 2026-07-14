# 07 — Clients

A client is any external process that reports activity events to the daemon. Clients are **thin** (they do not attribute time or touch the DB) and **short-lived** (fire an event, exit). They integrate by **speaking the protocol** — line-JSON RPC over the Unix socket, or the `kairos` CLI (see [05-protocol.md](./05-protocol.md)) — never by loading code into the daemon.

This is the extension model: **new sources = new external clients speaking the protocol.** Anyone, in any language, can extend what Kairos tracks without touching the core.

## `kairos-claude-code` — Claude Code plugin

Registered as a Claude Code plugin (`plugins/claude-code/`): a `.claude-plugin/plugin.json` plus a `hooks/hooks.json` that wires the four lifecycle hooks to one small **native binary** (`kairos-claude-code`). The binary reads the hook JSON from stdin, maps it to a generic RPC, and writes the socket directly (reusing the shared Rust `kairos-client` transport + spool) — no `jq`/`python` spawn, no shelling to the `kairos` CLI. It always exits 0. (M4p2: the binary is Rust.) Fire-and-forget: Claude hooks must never block, and the spool fallback covers a down daemon.

Keeping the Claude Code-specific mapping (`Stop → ai_stop`, `project = cwd basename`, …) in the plugin's own binary is deliberate: the `kairos` CLI stays **agent-agnostic** (ADR 12/20). A different agent ships its own binary with its own mapping.

**Install** is separate from the daemon's `Kairos.app` (the plugin is just a socket client). `make plugin` builds and stages `bin/kairos-claude-code`; then either `claude --plugin-dir plugins/claude-code` (dev, per session) or, for a persistent install, register the repo's bundled local marketplace (`.claude-plugin/marketplace.json`) with `claude plugin marketplace add <repo>` and `claude plugin install kairos-claude-code@kairos`. The formal install copies the plugin (binary included) into Claude Code's own cache, where `${CLAUDE_PLUGIN_ROOT}` resolves.

### Hooks used

| Claude hook | What the client does |
|---|---|
| `SessionStart` | `activities.start` `{source: claude-code, external_id: session_id, project: cwd-basename, metadata: {transcript_path, cwd}}` (create-or-resume; sets state=active) |
| `UserPromptSubmit` | `events.post` `{activity, kind: ai_submit}` |
| `Stop` | `events.post` `{activity, kind: ai_stop}` |
| `SessionEnd` | `activities.stop` `{source, external_id: session_id}` (sets state=stopped) |

The hook payload provides `session_id`, `cwd`, and `transcript_path` — exactly what the daemon needs (no window/title introspection, hence no Accessibility). The claude-code client reports **only `project`** (the cwd basename); it never needs to know the billing client — that is resolved later via the project→client mapping. Note (M4p3): `SessionStart`/`SessionEnd` no longer emit timing events — timing is the wrapper's `focus`/`blur`; the hooks only declare identity + lifecycle and the `ai_submit`/`ai_stop` deduction markers.

**Under `kairos` (M4p2 / M4p3).** When Claude is launched as `kairos claude` (the PTY fallback — any non-subcommand on `PATH` is wrapped), the wrapper sets `KAIROS_SESSION_ID` (kid); the hook binary reads it and adds `kairos_session_id` to **every** RPC above. The daemon uses it to keep an ephemeral `kid → activity` map fresh, so it can attribute the wrapper's `focus.report` transitions as `focus`/`blur`. Since **M4p3** the wrapper is also the **first axis for activity creation** (Design B): it emits a launch `focus`, and after ~5 s an `activities.ensure` that creates a `source=pty` activity **only if** no hook has claimed the kid — so wrapping a non-agent command (`kairos vim`) yields an activity, while for `kairos claude` the `SessionStart` hook has already created the `claude-code` activity and the ensure is a no-op (the hook *enriches*, it does not open a competing activity). Unwrapped sessions omit the field and behave as before. See [05](./05-protocol.md), [09](./09-roadmap.md).

**Wrapping non-agent commands (`kairos vim`, `kairos ssh`).** Any command with no hooks is tracked purely by the wrapper: launch `focus` + 5 s `activities.ensure` (`source=pty`) + exit `blur` and `activities.stop`. Its time is `focus − afk − pause` (no `ai_*` deductions).

### Responsibilities & non-responsibilities

- **Does:** map hook payload → protocol call; fire-and-forget.
- **Does not:** compute time, attribute, resolve clients, or touch SQLite.
- **Resilience:** the binary spools to `~/.kairos/spool/` if the daemon is down.

## Non-coding work: the config window (built-in)

Meetings and ad-hoc tasks are logged through the daemon's **SwiftUI config window** (see [06-daemon.md](./06-daemon.md)), not a separate client:

- **Meeting / ad-hoc:** create a `manual` activity (the built-in **manual** source) with a title, an optional `project`, and an optional direct client (emitted as an `activity_override` event). Starting it writes a `focus` (`activities.start`, state=active) and makes it a **backdrop**; stop it when done (`activities.stop`, state=stopped, plus a `blur`). It may run with **AFK detection off** for passive work. See [04](./04-attribution.md).

So Kairos produces a useful timesheet — coding *and* meetings/admin — with only the daemon installed, before any AI client exists.

## Future clients (enabled by the protocol, no core changes)

| source | how it reports | attribution |
|---|---|---|
| `git` | post-commit hook → a `manual`/tagged activity per branch/project | focus while active |
| `editor` | editor plugin wrapped under `kairos` (or reporting `focus`/`blur`) | focus base |
| `calendar` | import today's events as `manual` backdrop activities | focus while active (AFK-off) |
| `web` (optional) | browser extension reporting `focus`/`blur` for research tabs | focus base (routes to the tab's activity) |

Each is an independent process speaking the protocol. Any source that can emit `focus`/`blur` (directly or by running under the `kairos` PTY wrapper) participates in the single focus-pointer model with no daemon change — there is no per-source strategy anymore (see [04](./04-attribution.md)); the DB schema and daemon need no changes.
