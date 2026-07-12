# 07 — Clients

A client is any external process that reports activity events to the daemon. Clients are **thin** (they do not attribute time or touch the DB) and **short-lived** (fire an event, exit). They integrate by **speaking the protocol** — HTTP over the Unix socket, or the `kairos` CLI (see [05-protocol.md](./05-protocol.md)) — never by loading code into the daemon.

This is the extension model: **new sources = new external clients speaking the protocol.** Anyone, in any language, can extend what Kairos tracks without touching the core.

## `kairos-cc` — Claude Code plugin

Registered as a Claude Code plugin (same hook mechanism as the existing wakatime plugin). Its `scripts/run` reads the hook JSON from stdin and shells out to `kairos` (or POSTs to the socket). Fire-and-forget with a short timeout — Claude hooks must never block; the CLI's spool fallback covers a down daemon.

### Hooks used

| Claude hook | What the client does |
|---|---|
| `SessionStart` (or first hook) | `kairos activity open --source cc --id <session_id> --project <cwd-basename> --meta transcript_path=… --meta cwd=…` (idempotent) |
| `UserPromptSubmit` | ensure activity open, then `kairos event --source cc --id <session_id> --kind cc_submit` |
| `Stop` | `kairos event --source cc --id <session_id> --kind cc_stop` |
| `SessionEnd` | `kairos activity close --source cc --id <session_id>` |

The hook payload provides `session_id`, `cwd`, and `transcript_path` — exactly what the daemon needs (no window/title introspection, hence no Accessibility). The CC client reports **only `project`** (the cwd basename); it never needs to know the billing client — that is resolved later via the project→client mapping.

### Responsibilities & non-responsibilities

- **Does:** map hook payload → protocol call; fire-and-forget.
- **Does not:** compute time, attribute, resolve clients, or touch SQLite.
- **Resilience:** the `kairos` CLI spools to `~/.kairos/spool/` if the daemon is down.

## Non-coding work: the config window (built-in)

Meetings and ad-hoc tasks are logged through the daemon's **SwiftUI config window** (see [06-daemon.md](./06-daemon.md)), not a separate client:

- **Meeting / ad-hoc:** create a `meeting` or `manual` activity with a title, an optional `project`, and an optional `client_override` (pick a client directly — meetings often aren't tied to a code project). Open now, close when done; explicit-bounds attribution.

So Kairos produces a useful timesheet — coding *and* meetings/admin — with only the daemon installed, before any AI client exists.

## Future clients (enabled by the protocol, no core changes)

| source | how it reports | attribution |
|---|---|---|
| `git` | post-commit hook → `kairos activity open/close` per branch/project | explicit-bounds |
| `editor` | editor plugin reporting focus/edit windows | explicit-bounds, or a bundled strategy |
| `calendar` | import today's events as `meeting` activities with explicit bounds | explicit-bounds |
| `web` (optional) | browser extension tagging research tabs to the active cc activity | annotates existing cc segments |

Each is an independent process speaking the protocol. A source needing inference beyond explicit bounds ships its `AttributionStrategy` version in the registry; the DB schema and daemon need no changes.
