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

## M3 — Snapshots + reference summarizer

- `snapshots.create` / `kairos snapshot create`: recipe (params + per-source watermarks + digest); drains spool first; reproduce path.
- Reference summarizer consumer (Python SDK): `core.segments` → transcript slicing → pluggable LLM → Markdown, grouped by client/project.
- **Exit criteria:** end-of-day timesheet is submittable; re-deriving a snapshot reproduces it (segments + mapping).

## M4 — Polish & open source

- Packaging: signed/notarized `.app` + installer; optional Homebrew tap.
- Docs site, animated demo, sample timesheet, example third-party consumer.
- Privacy + threat-model write-up.
- Decide license (lean MIT or Apache-2.0).
- README, contribution guide, ADRs (below).

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
9. **Intent-based attribution** (submit / explicit start) over window-focus tracking — eliminates the Accessibility dependency.
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
