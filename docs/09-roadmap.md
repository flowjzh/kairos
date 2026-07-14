# 09 — Roadmap

Built incrementally so each milestone is independently useful. MVP requires **no AI client** and **no special permissions**.

## M1 — Kernel + manual logging + config (stands alone)

The daemon is usable for non-AI timesheets before any Claude integration exists.

- Swift `LSUIElement` app + `LaunchAgent` installer.
- Idle sampler (`CGEventSource`, 60s; `ioreg` fallback; `NSWorkspace` sleep/wake; restart-gap) → `afk_on/off` events with `reason` (`idle`/`sleep`/`offline`).
- SQLite store ([03](./03-data-model.md)), WAL, single-writer, migrations, append-only triggers. Tables: `activities`, `events`, `clients`, `project_client_map`, `snapshots` — no derived tables.
- Unix-socket line-JSON RPC server: ingest, control, config, read; spool drain.
- Attribution library (`KairosCore`, daemon-internal): **explicit-bounds** strategy; `segments.get` computes on demand with client/billable resolved via the mapping. Precedence `pause > explicit > afk > ai` with the holing rule.
- Menu bar: live owner, force-owner, pause.
- **Config window (SwiftUI):** manage clients (name), project→client mapping (append rules), and create meeting / ad-hoc activities (optional project + direct client via `activity_override`).
- `kairos` CLI: `event` / `activity` / `client` / `map` / `pause` / `export`.
- **Exit criteria:** log a day of meetings + manual tasks, tag their clients, and `kairos export --client <id>` yields an accurate AFK-subtracted, client-grouped timesheet.

## M2 — Claude Code client + submit attribution

*Implemented* (attribution + reducer + plugin + read-path hardening); multi-session verification against real Claude work is the remaining exit check.

- `kairos-claude-code` plugin (hooks: `SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`) — a small native binary (the hook→RPC mapping + shared `kairos-client` transport; Rust as of M4p2) that maps hook JSON to generic RPCs and speaks the socket directly (spool fallback), keeping the `kairos` CLI agent-agnostic.
- **AI submit-anchored** strategy in the registry: closed `[activity_open | ai_stop, ai_submit]` windows, resolved by submit-priority (nesting); open tails not counted; AI-execution excluded; afk/pause hole the windows (with the afk-submit-break); explicit-vs-ai holing.
- AI-agent projects auto-appear; tag each to a client once in the config window.
- Multi-session verification (several Ghostty splits); `force_owner` exercised.

### Scale + hardening (deferred from M1)

Skipped in M1 as premature at <~500 events/day; M2's AI-event volume and the ai owner transitions were the trigger. *Implemented in M2.*

- **Unified afk/pause/owner state** behind one `KairosCore` reducer — `GlobalState` consumes the event log once and exposes afk/pause spans + the current owner + open activities; `GlobalSpans`, `OwnerPredictor`, and the menu `DaemonModel` all read from it. Pre-empts the drift that caused the owner-after-pause bug; the `ai_stop` owner transition lands here. (ADR 21.)
- **Scaled reads for AI volume:** batched activity/client resolution in `attributedSegments` (was N+1), range-bounded event loading on the read path (drops history for activities closed before the range; also serves M3 snapshot reproduction), and an event-driven menu refresh (a change signal from the store) replacing the full-table poll. The daemon also periodically checkpoints the WAL and checkpoints on graceful shutdown, so writes survive restarts (a `RETURNING`-statement caching attempt was reverted — it parked write transactions uncommitted; re-parsing is negligible at this volume).

- **Exit criteria:** a day of real Claude work yields per-project/-client human-time matching intuition, with AI-execution excluded and multi-session gaps attributed correctly; the menu/owner state stays consistent across pause/afk/resume (no drift), and a busy day's `segments.get` stays sub-second.

## M3 — Python SDK + reference consumer

- **`sdk/python` (`kairos-sdk`):** a thin, dependency-free consumer wrapper over the line-JSON socket. Exposes `segments(from, to, project?, client?)` → typed `Segment`s joined to their `Activity` (client/billable resolved, `metadata.transcript_path`), one socket round-trip per call. Installable (`-e`).
- **Reference consumer (`effort-report-ex`, external):** a timesheet report driven entirely by Kairos segments — effort = Σ `segment.seconds` (submit-anchored + afk/pause-holed; the predecessor's per-gap cap is gone). Covers all activities (claude-code / meeting / manual), grouped by (day × project; project-less → `General`), split into `--effort-slot` records. AI content is summarized from the transcript slice `[start, end]` via the local `claude -p` CLI (concurrent, asyncio); meeting/manual show their title verbatim. Lives outside the daemon repo (a consumer, ADR 11).
- **Idle/sleep hardening:** the idle sampler now tracks the afk *source* (idle vs sleep), so a `willSleep` span is no longer cancelled by the next idle poll (which sees near-zero idle right after lid close). A suspend/resume gap — a system sleep that delivered no `willSleep` — is backfilled as afk by the poll loop, so sleep time is holed whether or not the notification arrives.
- **Exit criteria:** a consumer reads per-project/-client human-time over the socket and renders a submittable timesheet; lid-close and idle-sleep are captured as afk and excluded from work.

## M4 — AI session focus tracking (PTY wrapper)

Multi-session over-count (docs/01): the submit-anchored "thinking" window
`[ai_stop, ai_submit]` is counted for every open Claude split, even the ones you
aren't looking at. This milestone adds a **focus** signal to hole those windows,
obtained **permissionlessly** (no Accessibility) via in-band terminal focus reports.

- **A transparent PTY wrapper, folded into `kairos` (M4p2).** Launch Claude as
  `kairos claude` (fallback dispatch — any non-subcommand on `PATH` is wrapped); it
  runs Claude on a pty, injects `KAIROS_SESSION_ID`, and copies bytes both ways
  unchanged. Claude enables DECSET **1004** focus reporting itself, so the terminal
  emits `ESC[I`/`ESC[O` on focus/blur; the wrapper taps those (observe-only) and
  reports each to the daemon via `focus.report` (best-effort — dropped if the socket
  is down).
- **Self-healing session map.** Every Claude hook RPC also carries
  `KAIROS_SESSION_ID`, so the daemon holds an in-memory
  `KAIROS_SESSION_ID → (source, external_id)` map. A focus report resolves through
  it to the activity, and the daemon appends `focus`/`blur` to the
  append-only log (reproducible, like afk). The map is ephemeral — a daemon
  restart is repaired by the next hook.
- **Attribution is unchanged in this milestone**: the focus events land in the
  log, inert (the reducer/strategies ignore them), ready to hole the ai windows.
  *How* focus holes the windows — and a possible Rust port of the daemon — are
  follow-up design steps, not part of this milestone.
- **Exit criteria:** several `kairos claude` splits; switching focus lands
  `focus`/`blur` on the correct session in the log, the TUI is visually
  unaffected, and focus during a daemon outage is dropped and recovered on the
  next hook.

### M4p2 — Rust clients + canonical wire + monorepo

The CLI, PTY wrapper, and Claude Code hook binary move from Swift to **Rust**;
the daemon (attribution/SQLite/UI) stays Swift. Rust `libs/codec` becomes the
**canonical** wire definition, with the Swift `KairosRPC` a hand-written
`Codable` mirror (no codegen — the daemonclaw pattern; the wire format is
unchanged). The PTY folds into a single `kairos` binary with **fallback
dispatch** (`kairos claude` Just Works; `kairos pty claude` explicit; a typo or
non-executable → clear error + suggestion). The repo becomes a monorepo:
`daemon/mac/` (Swift package) + a root Cargo workspace (`libs/codec`,
`libs/client`, `cli`, `plugins/claude-code`). `ai_focus`/`ai_blur` are renamed to
generic **`focus`/`blur`** (any future focus reporter can emit them). Dead Swift
targets (`KairosCLI`/`KairosClient`/`KairosClaudeCode` + the two executables) are
deleted; their tests move to Rust.

- **Exit criteria:** `cargo test` + `swift test` green; `make install` ships one
  `kairos` binary; live `kairos client list` / `kairos claude` against the running
  Swift daemon; the Claude plugin (Rust) reinstall reports focus as before.

### M4p3 — focus-driven single-pointer timing

The submit-anchored/precedence model is **replaced** by a simpler one built on the
focus signal M4 landed. The base of all timing is now the **focus interval**, and
`ai_stop`/`ai_submit` demote from *window definitions* to *deduction markers*.

**The model.** At any instant **at most one activity holds focus** (the reducer
invariant: latest `focus` wins; a `blur` clears only the current holder). Timing is
per activity:

```
segments(X) = ⋃ focus-intervals(X)  −  X's own ai_working  −  global afk  −  global pause
  ai_working(X) = ⋃ [ai_submit, ai_stop]      # open grind → [ai_submit, min(now, next blur)]
```

Consequences vs the old model: `sum(seconds) ≤ wall-clock` (no concurrent
double-count); the "reading the final output" **tail** after an `ai_stop` now counts
(focused, non-idle, non-grind — the old tail-loss is fixed); a `vim`/`ssh` session
with no `ai_*` events degrades cleanly to `focus − afk − pause`.

**Layered focus (backdrop + foreground).** `manual` activities (source `manual`)
are **background** context; `auto` activities (`pty`, `claude-code`, …) are transient
**foreground** grabbers. When a foreground activity blurs with no successor focus, the
daemon **auto-catches** to the active manual backdrop (0 → none/stop; 1 → automatic;
>1 → fall back to the most-recently-focused and notify). Every pointer move — terminal,
manual menu click, or auto-catch — is **materialised as a `focus` event**, so timing
stays a pure replay of the log (reproducibility preserved).

**Lifecycle is not timing.** `activity_open`/`activity_close`/`force_owner` events are
**removed**. An activity's `{active, stopped, archived}` state is a **mutable column**
(menu visibility only; not watermarked, never read by timing). `activities.open/close`
become **`activities.start/stop`**: pure identity + lifecycle declarations that write
**no event** (create-or-**resume** the row, flip `state`, register the kid map).
Timing comes entirely from `focus`/`blur`.

**Design B — the wrapper owns creation (kid), hooks enrich (sid).** The PTY wrapper is
the first axis. On launch it emits an initial `focus@t0` (buffered, back-dated) and,
after a **5 s delay**, an idempotent *ensure-create*: if the kid is still unclaimed it
creates a `source=pty` activity — covering `vim`/`ssh` from t0. For `kairos claude`,
`SessionStart` reliably arrives first (probed: DECSET-1004 reports only *changes*, so an
already-focused split emits nothing until t0's synthetic focus), so the hook creates the
`claude-code` activity directly (resume-resolved by `claude_sid`) and the wrapper's 5 s
ensure-create is a no-op. The rare reverse race (hook > 5 s late) falls back to
**enrich** (`pty → claude-code`). Commands that exit before 5 s create nothing. On exit
the wrapper sends `blur` + `activities.stop`.

**Menu.** Lists every `active` activity for manual switching; the focused one shows a
green dot + a stop button (`blur` + `stopped`). **Start Activity …** offers recently
`stopped` **manual** activities to reactivate (auto activities resume only via the
hook's `claude_sid`); a chosen start writes `focus` (+ `blur` on an end time). Archive
(manual only) clears an activity out of that list. A manual activity may start with
**AFK Detection off** (that activity, while focused, produces no `afk` events — for
passive work like meetings).

- **Exit criteria:** a day of mixed `kairos claude` + `kairos vim` + meetings yields
  per-activity human-time with `sum ≤ wall-clock`; switching splits/tabs moves the single
  focus pointer correctly; blur to a running meeting auto-catches; the DB is wiped and
  re-derives identically from `focus`/`blur`/`ai_*`/`afk`/`pause`.

## M5 — Polish & open source

- Packaging: signed/notarized `.app` + installer; optional Homebrew tap.
- Docs site, animated demo, sample timesheet, example third-party consumer.
- Privacy + threat-model write-up.
- Decide license (lean MIT or Apache-2.0).
- README, contribution guide, ADRs (below).

## M6 — Snapshots + reproducibility

Deferred from M3: segments compute on demand and are already reproducible from the append-only log; a snapshot freezes a *submission* (recipe + digest) so it can be re-derived for audit.

- `snapshots.create` / `kairos snapshot create`: recipe (params + per-source watermarks + `segments_digest`); drains the spool first; watermark-bounded reproduce path.
- `snapshots.get`: re-derive segments from the frozen recipe; the digest verifies no code drift for that `attribution_version`.
- **Exit criteria:** an end-of-day timesheet is submittable; re-deriving a snapshot reproduces it byte-for-byte (segments + mapping).

## Open decisions

| Decision | Default leaning | Note |
|---|---|---|
| License | MIT or Apache-2.0 | decide before public release |
| Consumer LLM abstraction | OpenAI-compatible `base_url` + model | consumer-side, not core |
| Daemon distribution | standalone `.app` + `LaunchAgent` plist | notarization eventually |
| Socket auth hardening | same-user file perms (v1) | optional signed-peer check for third-party clients later |
| `clients` invoicing fields | defer (name-only in v1) | add rate/currency when invoicing is in scope |
| Record-list / dashboard UI | defer | reserved read endpoints exist; build later as a consumer |
| Cross-platform backends | defer | keep a clean platform trait for a future Rust/Linux port |

## Key decisions captured (ADRs)

1. **Swift** for the daemon — native `CGEventSource` / `NSStatusItem` / SwiftUI with least code.
2. **Line-JSON RPC over a Unix domain socket, not XPC and not HTTP** — language-agnostic client/consumer ecosystem; fully Swift-native (`Network.framework` + `JSONDecoder`/`JSONEncoder`, no `swift-nio`); one surface for ingest, read, and config. Spool file gives resilience.
3. **Events are the sole source of truth; segments computed on demand, never materialized** — tiny data volume, no cache, no `reprocess`.
4. **Append-only + monotonic-id watermark as the single reproducibility primitive** — applied to `events` *and* `project_client_map`. The id *is* the data version (no extra version column). Enforced by immutability triggers; deletes are tombstones; resolution is latest-row-per-key via a window function. Activity bounds and client override are events (covered by the `events` watermark), so only two watermarks are needed.
5. **Code version (`attribution_version`) is separate from data version (watermark)** — watermarks cannot capture logic; old strategy versions are retained for byte-exact reproduction. Digest verification is watermark-bounded (not by-ts-in-range) so a mismatch means code drift only.
6. **Snapshot = recipe (params + per-source watermarks + digest), not stored segments** — smaller, cannot drift, immutable, auditable. `snapshot create` drains the spool first; late-arriving-in-range events are excluded by design ("frozen at submission").
7. **`project → client` billing is a resolved-at-read mapping, not a field on activities** — ai sessions report only `project` (auto), the client is tagged once and applies retroactively; meetings/manual set a direct client via an `activity_override` event (watermarked, not a mutable column).
8. **`clients` is a mutable identity table (id stable, name editable), not watermarked** — names are cosmetic labels; identity is pinned via the map/override watermarks.
9. **Ownership is intent-based** (submit / explicit start), never window-focus — this is what stays true regardless of which window is focused, and it eliminates the Accessibility dependency. Focus is not discarded, though: **M4** reintroduces it as a *holing* signal (blur removes over-counted "thinking" time across parallel sessions), obtained **permissionlessly in-band** via the terminal's DECSET-1004 focus reports through the `kairos` PTY wrapper (M4p2's fallback dispatch) — so ownership and focus are separate concerns and neither needs Accessibility. (Refined in M4; this ADR originally rejected focus outright.) *(Further evolved in M4p3 ADR 27: focus becomes the **base of timing** itself, not only a holing signal — still permissionless and in-band; there is no longer a separate "ownership" concept, only the single focus pointer.)*
10. **Zero special permissions** as a hard constraint.
11. **Output lives in external consumers** — the core exposes a segments API and does not format or deliver timesheets.
12. **Extension by protocol, not in-process plugins** — new sources and outputs are external processes speaking the socket/CLI.
13. **UI is decoupled by the socket API** — v1 ships a minimal SwiftUI config window in-app; any richer/web viewer is a future consumer, not a core concern.
14. **Idle threshold 60s** — configurable, retroactively re-derivable, pinned for submitted work by snapshots.
15. **Attribution precedence is exclusive** — `pause > explicit > afk > ai`, resolved by a holing rule: a higher-precedence interval holes a lower one (lower loses the overlap, keeps the rest), **except** when the lower is fully contained in the higher (`lower ⊆ higher`), in which case both are recorded concurrently (a genuine embedded sub-effort). `explicit` is immune to `afk`; ai-vs-ai is resolved by submit-priority. Reverses an earlier "concurrent cross-strategy" sketch — exclusivity avoids over-billing, while the embedded exception preserves real concurrent effort. *(Superseded by M4p3 ADR 27: the precedence lattice + holing rule is replaced by the single focus pointer; the embedded-concurrent exception is dropped.)*
16. **ai windows are closed `[activity_open | ai_stop, ai_submit]`, resolved by submit-priority (nesting)** — each window's left bound is its own open|stop (NOT the previous submit), which fixes the flat model's `[t1,t2]` loss. Open tails (an `ai_stop` with no following submit) are not counted. There is no machine-window concept — `[ai_submit, next ai_stop]` is simply not an ai window. *(Superseded by M4p3 ADR 27: ai windows are gone; `ai_*` become deduction markers over the focus base, and the reading tail after `ai_stop` is now counted.)*
17. **`KairosCore` is daemon-internal; the CLI is a thin socket client; no FFI** — the attribution library is linked only into the daemon; external consumers and `kairos export` reach it through the socket (Python/Node SDK). Reverses an earlier "CLI links the lib for offline export" sketch — the dual-role/FFI cost isn't worth it given the daemon is always running (LaunchAgent `KeepAlive`).
18. **afk carries a `reason`** (`idle`/`sleep`/`offline`) — the idle sampler uses `NSWorkspace` sleep/wake notifications and daemon-restart-gap detection so afk spans cover lid-close/shutdown/reboot, enabling `afk > ai` holing across those gaps. A spooled `ai_submit` inside an `offline` gap breaks the afk at that instant.
19. **`sources`, `projects`, `clients` are mutable identity tables** `(id PK, slug UNIQUE, display_name)` (clients: `id, name`), referenced by integer FK everywhere, never hard-deleted, **not watermarked** — identity is pinned by the stable id referenced from the append-only tables; display resolves live. The daemon auto-registers sources/projects by slug on first sight, so adding a new AI agent is pure data.
20. **Event kinds are agent-agnostic (`ai_stop`/`ai_submit`); strategy is inferred from the event signature, not the source.** An activity with `ai_submit` events → ai submit-anchored; else explicit-bounds. The registry is keyed by strategy-name + `attribution_version`, so a new agent (which emits `ai_*` events) needs no code change — only a genuinely new strategy kind does. *(Superseded by M4p3 ADR 27: the strategy registry is gone — one focus-interval model serves all activities; `ai_*` remain agent-agnostic deduction markers.)*
21. **Unified afk/pause/owner state behind one `KairosCore` reducer (M2).** Three derivations answer "am I afk/paused? who owns the current gap?" — previously independent (`GlobalSpans` paired on/off, `OwnerPredictor` released only on `activity_close`, the menu `DaemonModel` was last-write-wins) and they could drift (the owner-after-pause bug was a symptom). A single `GlobalState` reducer now consumes the event log once and exposes afk/pause spans, the current owner, and open activities; `GlobalSpans`, `OwnerPredictor`, and the menu all read from it. Landed in M2 because the `ai_stop` owner transition touches the same model. Deferred from M1, where the on/off stream is canonical and the three agreed.
22. **The PTY wrapper is `kairos`'s fallback dispatch, not a standalone binary (M4→M4p2).** Terminal focus (DECSET 1004) is reported in-band on the pty byte stream, so the wrapper taps it (`ESC[I`/`ESC[O`, observe-only, forwarding every byte unchanged) with zero special permissions — the daemon never introspects windows or terminals. `kairos <cmd>` runs any non-subcommand command under a pty and injects `KAIROS_SESSION_ID`; the agent hook joins it to the session's `external_id`. (M4p1 shipped a standalone `kairos-pty`; M4p2 folded it into `kairos`.) Extension-by-protocol (ADR 12): a new source of focus is an external process speaking the socket, not daemon code.
23. **The `KAIROS_SESSION_ID → external_id` map is ephemeral in-memory soft state, self-healed by every hook (M4).** A `KAIROS_SESSION_ID` is meaningful only while its wrapper lives, so the map is never persisted or searched over history; each hook RPC re-registers it (last-write-wins), so a daemon restart is repaired by the next hook — worst case, focus is lost only in that gap. A focus report that arrives before the first hook is buffered (latest wins) and flushed on registration. `focus`/`blur` (renamed from `ai_focus`/`ai_blur` in M4p2 — generic, any focus reporter can emit them) are appended to the log (like afk) so focus-holed segments stay reproducible; a report that can't be resolved is dropped (best-effort — focus is live telemetry, and a stale replay is worse than a gap).
24. **Rust `libs/codec` is the canonical wire definition; the Swift daemon's `KairosRPC` is a hand-written `Codable` mirror (M4p2).** No codegen — the daemonclaw pattern (Rust canonical, Swift hand-mirrors, kept byte-stable by discipline + tests; "codegen later"). The wire format is unchanged; only the canonical source moved to Rust, since three of the four speakers (CLI, PTY, hook) are now Rust. Wire fidelity is gated by ported unit tests + live e2e against the Swift daemon.
25. **Monorepo layout: `daemon/mac/` (the Swift package, own `Package.swift`) + a root Cargo workspace (`libs/codec`, `libs/client`, `cli`, `plugins/claude-code`) (M4p2).** Native build systems are per-component and path-referenced (SwiftPM under `daemon/mac`, Cargo at root), matching the daemonclaw topology. The daemon's `Support/` (Info.plist, launchd plist) stays at the repo root, referenced by the Makefile.
26. **Clients (CLI, PTY wrapper, Claude Code hook) are Rust; the daemon (attribution, store, menu-bar UI) stays Swift (M4p2).** The boundary is the wire protocol — everything crossing it is line-JSON, so the language split is invisible to callers. The high-frequency hook binary is a separate lean crate (codec + client only); the `kairos` CLI merges the PTY in-process (static link, ~950 KB — negligible; the one place leanness matters stays lean). A future full daemon→Rust port is unconstrained by this split.
27. **Focus-driven single-pointer timing replaces submit-anchored precedence (M4p3).** The base of timing is the `focus` interval; at most one activity holds focus at a time (reducer invariant: latest `focus` wins, `blur` clears only the current holder). `segments(X) = ⋃focus(X) − X's ai_working − global afk − global pause`. This **supersedes** the two-strategy registry + precedence lattice (ADRs 15, 16, 20): `ai_stop`/`ai_submit` demote from window definitions to per-activity deduction markers, `sum(seconds) ≤ wall-clock` (concurrent double-count dropped), and the reading tail after an `ai_stop` is now counted (ADR 16's tail-loss fixed). Chosen because focus (M4) gives a direct, permissionless presence signal that the submit heuristic only approximated.
28. **Layered focus: manual=backdrop, auto=foreground; auto-catch is materialised as events (M4p3).** `manual` (source `manual`) activities are ambient background; `auto` (`pty`/`claude-code`) are transient foreground. A foreground `blur` with no successor focus **auto-catches** to the active manual backdrop (0→none, 1→auto, >1→most-recently-focused + notify). Every pointer move (terminal / manual / auto-catch) is written as a `focus` event, so the daemon reads live lifecycle state to *decide* but the timing stays a pure replay of the log. This is why lifecycle can be non-reproducible mutable state while timing stays reproducible.
29. **Lifecycle is a mutable column, decoupled from timing; `activities.start/stop` write no event (M4p3).** `{active, stopped, archived}` lives on `activities` (menu visibility only; not watermarked, never read by attribution). `activity_open`/`activity_close`/`force_owner` event kinds are **removed**; `activities.open/close` are renamed `start/stop` and become identity + lifecycle declarations (create-or-resume the row, flip `state`, register the kid map) that append nothing. `force_owner` is subsumed by a manual `focus`.
30. **Design B: the wrapper owns activity creation (by kid); agent hooks enrich (by sid) (M4p3).** The wrapper emits an initial `focus@t0` (buffered, back-dated) and after a 5 s delay an idempotent *ensure-create* (`source=pty` if the kid is unclaimed) — so `vim`/`ssh` are covered from t0 and commands exiting < 5 s create nothing. For `kairos claude` the `SessionStart` hook reliably arrives first (DECSET-1004 reports only *changes*) and creates the `claude-code` activity directly, resume-resolved by `claude_sid`; the 5 s ensure-create is then a no-op, and the rare hook-late race falls back to enrich (`pty→claude-code`). Each axis uses its most stable key: lifecycle/creation by the stable `sid` (hook) or the ensure-create (wrapper), focus routing by the ephemeral `kid`.
31. **`source` is an activity-level attribute for the summarizer/display/manual-binary, never for timing (M4p3).** Timing reads only event presence (`ai_*` for the deduction), not `source` — preserving ADR 20's "inferred from signature, not source". `source` survives because the summarizer keys transcript enrichment on it (`claude-code` → `metadata.transcript_path`), the menu labels by it, and `manual` (backdrop-eligible) is `source == manual`. A new built-in `pty` source is added; a `sources.manual` flag carries the binary.
32. **Focus reducer is latest-wins across all reporters; no manual lock (M4p3).** A manual menu `focus` and a terminal `focus` compose by timestamp — whichever is latest wins. This covers the "keep counting while researching in a browser" case (no terminal event fires there, so a manual focus is never stolen) and the "dip into a terminal" case (the terminal legitimately takes focus, then auto-catch returns to the backdrop on blur) without a pin/lock state.
33. **AFK detection is per manual activity, as a write-time gate (M4p3).** Default on for all; a `manual` activity may start with AFK detection **off**, meaning the idle sampler emits no `afk` events while that activity is focused (for passive work like meetings, where "no input" is normal). It is a gate on event *creation*, not a read-time policy — the resulting presence/absence of `afk` events is what the log records, so it stays reproducible without a persisted per-activity flag.
34. **A plugin decides whether to notify the user; the daemon only delivers (`notify.user`).** When a plugin (e.g. claude-code) starts an activity that will lack accurate timing — launched directly, without `kairos`, so no `KAIROS_SESSION_ID` and no focus/blur — it sends `notify.user {source, kind, title, subtitle?, message, cooldown_seconds?}` and the daemon posts a native macOS notification. Throttling is **opt-in per request**, not a daemon default: a `cooldown_seconds` gates at most one delivery per that window per `(source, kind)` (in-memory); omitting it delivers every call. claude-code omits it — relaunching frequently and forgetting the `kairos` prefix is exactly the case to catch every time, so a fixed cooldown would hide the nudge. The orphan check lives in the **plugin**, not the daemon: only the plugin knows whether it actually *needs* a PTY wrap for focus, so a future self-focusing plugin (codex with its own focus detection) must not be nagged for lacking a kid. This keeps the daemon free of source-specific policy (ADRs 12, 31) and upgrades ADR 28's notify seam from a menu message to a real native notification. `notify.user` is never spooled — a stale nudge replayed after an outage is noise, unlike the activity RPC beside it.
