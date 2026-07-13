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

- `kairos-claude-code` plugin (hooks: `SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`) — a small native binary (`KairosClaudeCode` mapping + shared `KairosClient` transport) that maps hook JSON to generic RPCs and speaks the socket directly (spool fallback), keeping the `kairos` CLI agent-agnostic.
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

- **`kairos-pty` (Rust) — a transparent PTY wrapper.** Launch Claude as
  `kairos-pty claude`; it runs Claude on a pty, injects `KAIROS_SESSION_ID`, and
  copies bytes both ways unchanged. Claude enables DECSET **1004** focus reporting
  itself, so the terminal emits `ESC[I`/`ESC[O` on focus/blur; the wrapper taps
  those (observe-only) and reports each to the daemon via `focus.report`
  (best-effort — dropped if the socket is down).
- **Self-healing session map.** Every Claude hook RPC also carries
  `KAIROS_SESSION_ID`, so the daemon holds an in-memory
  `KAIROS_SESSION_ID → (source, external_id)` map. A focus report resolves through
  it to the activity, and the daemon appends `ai_focus`/`ai_blur` to the
  append-only log (reproducible, like afk). The map is ephemeral — a daemon
  restart is repaired by the next hook.
- **Attribution is unchanged in this milestone**: the focus events land in the
  log, inert (the reducer/strategies ignore them), ready to hole the ai windows.
  *How* focus holes the windows — and a possible Rust port of the daemon — are
  follow-up design steps, not part of this milestone.
- **Exit criteria:** several `kairos-pty claude` splits; switching focus lands
  `ai_focus`/`ai_blur` on the correct session in the log, the TUI is visually
  unaffected, and focus during a daemon outage is dropped and recovered on the
  next hook.

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
9. **Ownership is intent-based** (submit / explicit start), never window-focus — this is what stays true regardless of which window is focused, and it eliminates the Accessibility dependency. Focus is not discarded, though: **M4** reintroduces it as a *holing* signal (blur removes over-counted "thinking" time across parallel sessions), obtained **permissionlessly in-band** via the terminal's DECSET-1004 focus reports through the `kairos-pty` wrapper — so ownership and focus are separate concerns and neither needs Accessibility. (Refined in M4; this ADR originally rejected focus outright.)
10. **Zero special permissions** as a hard constraint.
11. **Output lives in external consumers** — the core exposes a segments API and does not format or deliver timesheets.
12. **Extension by protocol, not in-process plugins** — new sources and outputs are external processes speaking the socket/CLI.
13. **UI is decoupled by the socket API** — v1 ships a minimal SwiftUI config window in-app; any richer/web viewer is a future consumer, not a core concern.
14. **Idle threshold 60s** — configurable, retroactively re-derivable, pinned for submitted work by snapshots.
15. **Attribution precedence is exclusive** — `pause > explicit > afk > ai`, resolved by a holing rule: a higher-precedence interval holes a lower one (lower loses the overlap, keeps the rest), **except** when the lower is fully contained in the higher (`lower ⊆ higher`), in which case both are recorded concurrently (a genuine embedded sub-effort). `explicit` is immune to `afk`; ai-vs-ai is resolved by submit-priority. Reverses an earlier "concurrent cross-strategy" sketch — exclusivity avoids over-billing, while the embedded exception preserves real concurrent effort.
16. **ai windows are closed `[activity_open | ai_stop, ai_submit]`, resolved by submit-priority (nesting)** — each window's left bound is its own open|stop (NOT the previous submit), which fixes the flat model's `[t1,t2]` loss. Open tails (an `ai_stop` with no following submit) are not counted. There is no machine-window concept — `[ai_submit, next ai_stop]` is simply not an ai window.
17. **`KairosCore` is daemon-internal; the CLI is a thin socket client; no FFI** — the attribution library is linked only into the daemon; external consumers and `kairos export` reach it through the socket (Python/Node SDK). Reverses an earlier "CLI links the lib for offline export" sketch — the dual-role/FFI cost isn't worth it given the daemon is always running (LaunchAgent `KeepAlive`).
18. **afk carries a `reason`** (`idle`/`sleep`/`offline`) — the idle sampler uses `NSWorkspace` sleep/wake notifications and daemon-restart-gap detection so afk spans cover lid-close/shutdown/reboot, enabling `afk > ai` holing across those gaps. A spooled `ai_submit` inside an `offline` gap breaks the afk at that instant.
19. **`sources`, `projects`, `clients` are mutable identity tables** `(id PK, slug UNIQUE, display_name)` (clients: `id, name`), referenced by integer FK everywhere, never hard-deleted, **not watermarked** — identity is pinned by the stable id referenced from the append-only tables; display resolves live. The daemon auto-registers sources/projects by slug on first sight, so adding a new AI agent is pure data.
20. **Event kinds are agent-agnostic (`ai_stop`/`ai_submit`); strategy is inferred from the event signature, not the source.** An activity with `ai_submit` events → ai submit-anchored; else explicit-bounds. The registry is keyed by strategy-name + `attribution_version`, so a new agent (which emits `ai_*` events) needs no code change — only a genuinely new strategy kind does.
21. **Unified afk/pause/owner state behind one `KairosCore` reducer (M2).** Three derivations answer "am I afk/paused? who owns the current gap?" — previously independent (`GlobalSpans` paired on/off, `OwnerPredictor` released only on `activity_close`, the menu `DaemonModel` was last-write-wins) and they could drift (the owner-after-pause bug was a symptom). A single `GlobalState` reducer now consumes the event log once and exposes afk/pause spans, the current owner, and open activities; `GlobalSpans`, `OwnerPredictor`, and the menu all read from it. Landed in M2 because the `ai_stop` owner transition touches the same model. Deferred from M1, where the on/off stream is canonical and the three agreed.
22. **`kairos-pty` is a transparent PTY wrapper, not an in-daemon focus watcher (M4).** Terminal focus (DECSET 1004) is reported in-band on the pty byte stream, so a thin external wrapper taps it (`ESC[I`/`ESC[O`, observe-only, forwarding every byte unchanged) with zero special permissions — the daemon never introspects windows or terminals. The wrapper injects `KAIROS_SESSION_ID`; the Claude hook joins it to the session's `external_id`. Extension-by-protocol (ADR 12): a new source of focus is an external process speaking the socket, not daemon code.
23. **The `KAIROS_SESSION_ID → external_id` map is ephemeral in-memory soft state, self-healed by every hook (M4).** A `KAIROS_SESSION_ID` is meaningful only while its wrapper lives, so the map is never persisted or searched over history; each hook RPC re-registers it (last-write-wins), so a daemon restart is repaired by the next hook — worst case, focus is lost only in that gap. A focus report that arrives before the first hook is buffered (latest wins) and flushed on registration. `ai_focus`/`ai_blur` are appended to the log (like afk) so focus-holed segments stay reproducible; a report that can't be resolved is dropped (best-effort — focus is live telemetry, and a stale replay is worse than a gap).
