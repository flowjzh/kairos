# 07 — Clients

A client is any external process that reports activity events to the daemon. Clients are **thin** (they do not attribute time or touch the DB) and **short-lived** (fire an event, exit). They integrate by **speaking the protocol** — line-JSON RPC over the Unix socket, or the `kairos` CLI (see [05-protocol.md](./05-protocol.md)) — never by loading code into the daemon.

This is the extension model: **new sources = new external clients speaking the protocol.** Anyone, in any language, can extend what Kairos tracks without touching the core.

## `kairos-claude-code` — Claude Code plugin

Registered as a Claude Code plugin (`plugins/claude-code/`): a `.claude-plugin/plugin.json` plus a `hooks/hooks.json` that wires the four lifecycle hooks (plus the human-input tool hooks `AskUserQuestion`/`ExitPlanMode` — see below) directly to one small **native binary** (`${CLAUDE_PLUGIN_ROOT}/bin/kairos-claude-code`) — no shell shim. The binary reads the hook JSON from stdin, maps it to a generic RPC, and writes the socket directly (reusing the shared Rust `kairos-client` transport + spool) — no `jq`/`python` spawn, no shelling to the `kairos` CLI. It always exits 0. (M4p2: the binary is Rust.) Fire-and-forget: Claude hooks must never block, and the spool fallback covers a down daemon.

Keeping the Claude Code-specific mapping (`Stop → ai_stop`, `project = cwd basename`, …) in the plugin's own binary is deliberate: the `kairos` CLI stays **agent-agnostic** (ADR 12/20). A different agent ships its own binary with its own mapping.

**Install — a bundled local marketplace.** `plugins/claude-code/` is self-contained: its `.claude-plugin/marketplace.json` names one plugin with `source: "."`, so the directory is both the marketplace and the plugin. `make app` bundles this tree — with the freshly built binary — into the app at `Contents/Resources/plugins/claude-code/`. In the app, **Configure → Plugins → Claude Code → Register** writes an `extraKnownMarketplaces` entry pointing there; the user then runs `claude plugin install kairos-claude-code@kairos` (`--scope user|project|local`). For a **local directory** marketplace Claude Code references the plugin **in place** — `${CLAUDE_PLUGIN_ROOT}` resolves to the bundled path inside the app — so it runs offline (no download) straight from the app bundle. `hooks.json` invokes the binary in **exec form** (`command` + `args`), so a bundle path containing a space (e.g. `Kairos Dev.app`) is passed as one argument and never word-split by a shell. Because it runs from the app bundle, deleting the app makes the hook error (non-blocking) until `claude plugin uninstall` clears it — so unregister/uninstall before removing the app. See [Versioning & releases](../CONTRIBUTING.md#versioning--releases).

### Hooks used

| Claude hook | What the client does |
|---|---|
| `SessionStart` | `activities.start` `{source: claude-code, external_id: session_id, project: cwd-basename, title: $KAIROS_ACTIVITY_TITLE, metadata: {transcript_path, cwd}}` (create-or-resume; sets state=active). `title` is set only when the wrapper passed `--title` (see below); otherwise NULL and the menu/statusline falls back to `project ?? source`. |
| `UserPromptSubmit` | `events.post` `{activity, kind: ai_submit}` |
| `Stop` | `events.post` `{activity, kind: ai_stop}` |
| `PreToolUse` (`AskUserQuestion`, `ExitPlanMode`) | `events.post` `{activity, kind: ai_stop}` — the agent finished its turn and is waiting on the human |
| `PostToolUse` (`AskUserQuestion`, `ExitPlanMode`) | `events.post` `{activity, kind: ai_submit}` — the human answered/approved; the agent resumes |
| `SessionEnd` | `activities.stop` `{source, external_id: session_id}` (sets state=stopped) |

The `PreToolUse`/`PostToolUse` entries carry `matcher`s for the **human-input tools** — `AskUserQuestion` (answering a question) and `ExitPlanMode` (approving a plan), the only built-ins whose execution blocks on a human response. (`EnterPlanMode` is excluded: it's an instant mode flip, no human wait.) Each such call is a pause in the grind: a long back-and-forth ("grilling") or plan-review turn would otherwise be a single `[ai_submit, ai_stop]` span that deducts the human's reading/answering/approving time as idle AI wait. Splitting each ask into `ai_stop`…`ai_submit` returns that deliberation to focus, leaving only the real agent-generation bursts as grind. The matchers are an optimisation to avoid spawning the binary on every tool call; the binary re-checks `tool_name` against the same set (`HUMAN_INPUT_TOOLS` in `hook.rs`, which is the source of truth — keep the two in sync).

The hook payload provides `session_id`, `cwd`, and `transcript_path` — exactly what the daemon needs (no window/title introspection, hence no Accessibility). The claude-code client reports **only `project`** (the cwd basename); it never needs to know the billing client — that is resolved later via the project→client mapping. Note (M4p3): `SessionStart`/`SessionEnd` no longer emit timing events — timing is the wrapper's `focus`/`blur`; the hooks only declare identity + lifecycle and the `ai_submit`/`ai_stop` deduction markers.

**Under `kairos` (M4p2 / M4p3).** When Claude is launched as `kairos claude` (the PTY fallback — any non-subcommand on `PATH` is wrapped), the wrapper sets `KAIROS_SESSION_ID` (kid); the hook binary reads it and adds `kairos_session_id` to **every** RPC above. The daemon uses it to keep an ephemeral `kid → activity` map fresh, so it can attribute the wrapper's `focus.report` transitions as `focus`/`blur`. Since **M4p3** the wrapper is also the **first axis for activity creation** (Design B): it emits a launch `focus`, and after ~5 s an `activities.ensure` that creates a `source=pty` activity **only if** no hook has claimed the kid — so wrapping a non-agent command (`kairos vim`) yields an activity, while for `kairos claude` the `SessionStart` hook has already created the `claude-code` activity and the ensure is a no-op (the hook *enriches*, it does not open a competing activity). Unwrapped sessions omit the field and behave as before. See [05](./05-protocol.md), [09](./09-roadmap.md).

**Wrapping non-agent commands (`kairos vim`, `kairos ssh`).** Any command with no hooks is tracked purely by the wrapper: launch `focus` + 5 s `activities.ensure` (`source=pty`) + exit `blur` and `activities.stop`. Its time is `focus − afk − pause` (no `ai_*` deductions).

**Naming the activity — `--title`.** `kairos --title "Foo" <cmd>` (composes with `--project`, in any order) exports `KAIROS_ACTIVITY_TITLE` to the child; the claude-code hook picks it up at `SessionStart` and records it as the activity `title` (first insert only — a resumed session keeps its original title). Without `--title` the env stays unset, so a `claude-code` activity's title is NULL and surfaces fall back to `project ?? source` (unchanged behavior). For a non-agent wrap (`kairos --title Foo vim`) the title names the `pty` activity (defaulting to the command string when no `--title`).

**Status line.** The same binary doubles as a CC status line command via `kairos-claude-code statusline`: it reads the statusline JSON's `session_id` from stdin, queries `activities.status`, and prints one colored line (`身份 | 状态 | 总计:Xh | 今天:Yh`). To use it, add to your Claude Code settings (any scope — `statusLine` has no scope restriction):
```json
"statusLine": { "type": "command", "command": "/Applications/Kairos.app/Contents/Resources/plugins/claude-code/bin/kairos-claude-code statusline", "refreshInterval": 15 }
```
Set `refreshInterval` so idle/gracing state and durations stay current between events (the line otherwise refreshes only on assistant messages / mode changes). The `kairos-statusline` render crate is shared, so other agents can reuse it.

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
