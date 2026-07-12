# 09 — Roadmap

Built incrementally so each milestone is independently useful. MVP requires **no AI client** and **no special permissions**.

## M1 — Kernel + manual logging + config (stands alone)

The daemon is usable for non-AI timesheets before any Claude integration exists.

- Swift `LSUIElement` app + `LaunchAgent` installer.
- Idle sampler (`CGEventSource`, 60s; `ioreg` fallback) → `afk_on/off` events.
- SQLite store ([03](./03-data-model.md)), WAL, single-writer, migrations, append-only triggers. Tables: `activities`, `events`, `clients`, `project_client_map`, `snapshots` — no derived tables.
- Unix-socket HTTP server: ingest, control, config, read; spool drain.
- Attribution library: **explicit-bounds** strategy; `GET /segments` computes on demand with client/billable resolved via the mapping.
- Menu bar: live owner, force-owner, pause.
- **Config window (SwiftUI):** manage clients (name), project→client mapping (append rules), and create meeting / ad-hoc activities (optional project + client override).
- `kairos` CLI: `event` / `activity` / `client` / `map` / `pause` / `export`.
- **Exit criteria:** log a day of meetings + manual tasks, tag their clients, and `kairos export --client <id>` yields an accurate AFK-subtracted, client-grouped timesheet.

## M2 — Claude Code client + submit attribution

- `kairos-cc` plugin (hooks: `SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`) shelling out to `kairos`.
- **CC submit-anchored** strategy added to the registry.
- CC projects auto-appear; tag each to a client once in the config window.
- Multi-session verification (several Ghostty splits); `force_owner` exercised.
- **Exit criteria:** a day of real Claude work yields per-project/-client human-time matching intuition, with AI-execution time excluded and multi-session gaps attributed correctly.

## M3 — Snapshots + reference summarizer

- `POST /snapshots` / `kairos snapshot create`: recipe (params + per-source watermarks + digest); reproduce path.
- Reference summarizer consumer: `kairos export` → transcript slicing → pluggable LLM → Markdown, grouped by client/project.
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
2. **HTTP over a Unix domain socket, not XPC** — language-agnostic client/consumer ecosystem; one surface for ingest, read, and config. The `kairos` CLI is the stable contract; spool file gives resilience.
3. **Events are the sole source of truth; segments computed on demand, never materialized** — tiny data volume, no cache, no `reprocess`.
4. **Append-only + monotonic-id watermark as the single reproducibility primitive** — applied to `events` *and* `project_client_map`. The id *is* the data version (no extra version column). Enforced by immutability triggers; deletes are tombstones; resolution is latest-row-per-key via a window function.
5. **Code version (`attribution_version`) is separate from data version (watermark)** — watermarks cannot capture logic; old strategy versions are retained for byte-exact reproduction.
6. **Snapshot = recipe (params + per-source watermarks + digest), not stored segments** — smaller, cannot drift, immutable, auditable.
7. **`project → client` billing is a resolved-at-read mapping, not a field on activities** — cc reports only `project` (auto), the client is tagged once and applies retroactively; meetings/manual may set a direct `client_override`.
8. **`clients` is a mutable identity table (id stable, name editable), not watermarked** — names are cosmetic labels; identity is pinned via the map watermark.
9. **Intent-based attribution** (submit / explicit start) over window-focus tracking — eliminates the Accessibility dependency.
10. **Zero special permissions** as a hard constraint.
11. **Output lives in external consumers** — the core exposes a segments API and does not format or deliver timesheets.
12. **Extension by protocol, not in-process plugins** — new sources and outputs are external processes speaking the socket/CLI.
13. **UI is decoupled by the socket API** — v1 ships a minimal SwiftUI config window in-app; any richer/web viewer is a future consumer, not a core concern.
14. **Idle threshold 60s** — configurable, retroactively re-derivable, pinned for submitted work by snapshots.
