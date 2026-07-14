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
| `SessionStart` | `activities.open` `{source: claude-code, external_id: session_id, project: cwd-basename, metadata: {transcript_path, cwd}}` (idempotent) |
| `UserPromptSubmit` | `events.post` `{activity, kind: ai_submit}` |
| `Stop` | `events.post` `{activity, kind: ai_stop}` |
| `SessionEnd` | `activities.close` `{source, external_id: session_id}` |

The hook payload provides `session_id`, `cwd`, and `transcript_path` — exactly what the daemon needs (no window/title introspection, hence no Accessibility). The claude-code client reports **only `project`** (the cwd basename); it never needs to know the billing client — that is resolved later via the project→client mapping.

**Under `kairos` (M4p2).** When Claude is launched as `kairos claude` (the PTY fallback — any non-subcommand on `PATH` is wrapped), the wrapper sets `KAIROS_SESSION_ID` in the environment; the hook binary reads it and adds `kairos_session_id` to **every** RPC above. The daemon uses it to keep an ephemeral `kairos_session_id → (source, external_id)` map fresh, so it can attribute the wrapper's `focus.report` transitions to this session as `focus`/`blur` (see [05](./05-protocol.md), [09](./09-roadmap.md)). Unwrapped sessions simply omit the field and behave exactly as before.

### Responsibilities & non-responsibilities

- **Does:** map hook payload → protocol call; fire-and-forget.
- **Does not:** compute time, attribute, resolve clients, or touch SQLite.
- **Resilience:** the binary spools to `~/.kairos/spool/` if the daemon is down.

## Non-coding work: the config window (built-in)

Meetings and ad-hoc tasks are logged through the daemon's **SwiftUI config window** (see [06-daemon.md](./06-daemon.md)), not a separate client:

- **Meeting / ad-hoc:** create a `meeting` or `manual` activity with a title, an optional `project`, and an optional direct client (emitted as an `activity_override` event — pick a client directly, since meetings often aren't tied to a code project). Open now, close when done; explicit-bounds attribution.

So Kairos produces a useful timesheet — coding *and* meetings/admin — with only the daemon installed, before any AI client exists.

## Future clients (enabled by the protocol, no core changes)

| source | how it reports | attribution |
|---|---|---|
| `git` | post-commit hook → `kairos activity open/close` per branch/project | explicit-bounds |
| `editor` | editor plugin reporting focus/edit windows | explicit-bounds, or a bundled strategy |
| `calendar` | import today's events as `meeting` activities with explicit bounds | explicit-bounds |
| `web` (optional) | browser extension tagging research tabs to the active ai activity | annotates existing ai segments |

Each is an independent process speaking the protocol. A source needing inference beyond explicit bounds ships its strategy in the registry (keyed by strategy-name + version, dispatched by event signature — see [04](./04-attribution.md)); the DB schema and daemon need no changes.
