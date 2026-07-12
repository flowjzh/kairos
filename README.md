# Kairos

> Measure **kairos** — the time you are genuinely present — not **chronos**, the wall-clock time the machine spends grinding.

Kairos is a local-first, macOS **human-time kernel**. It records the time you are actually engaged with your work — reading, thinking, prompting, researching — and attributes each block of active time to the activity (a Claude Code session, a client meeting, an ad-hoc task) you were driving. It is built for freelancers who need an accurate, summarizable timesheet of *human* effort, distinct from AI/tool execution time.

## Status

**Design / spec stage.** No implementation yet. The documents under [`docs/`](./docs) are the blueprint for implementation and the basis of an open-source release.

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
