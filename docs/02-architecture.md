# 02 — Architecture

## Components

| Component | Form | Lifecycle | Role |
|---|---|---|---|
| **`kairosd`** | Swift app (`LSUIElement`, no Dock icon) | Resident `LaunchAgent`, restarted by launchd | **Idle sampler** + **socket ingest** + **menu-bar host**. Nothing else. |
| **Attribution library (`KairosCore`)** | Swift library | Linked only into the daemon | Computes segments from events at read time. Daemon-internal — not linked into the CLI, not exposed via FFI. Reached by external consumers and `kairos export` **through the socket**. |
| **Client** | Any process, any language | Short-lived per event | Reports activity/events to the daemon over a local socket (or via the `kairos` CLI). |
| **Consumer** | Any process, any language | On-demand | Reads computed segments via the **Python/Node SDK** (or `kairos export`) and produces timesheets/deliverables. |

The daemon is deliberately small. Two things *require* residency and justify it:

1. **The idle timeline.** `CGEventSource.secondsSinceLastEventType` is a point query — asking "how idle right now?" at submit time cannot reconstruct an AFK interval that happened *in the middle* of a thinking gap (e.g. you left for lunch, came back, then submitted). Reconstructing the non-AFK timeline requires **continuous sampling throughout** the gap. That needs a run loop.
2. **The menu bar.** `NSStatusItem` needs a resident accessory app.

Everything else — event recording, attribution, export, summarization — is stateless and computed on demand. Attribution is a **daemon-internal library** (`KairosCore`): only the daemon links it (for the live owner and for serving reads). The CLI and external consumers reach it **through the socket**, never by linking it — so the CLI stays a thin, dependency-free socket client, and no FFI is needed.

## Data flow

```
   input (keyboard/mouse)            client events (any source)
            │                              │ (events.post, or `kairos event`)
            ▼                              ▼
   ┌─────────────────────┐        ┌──────────────────────┐
   │  idle sampler (~5s)  │        │  socket server       │
   │  afk_on/afk_off      │        │  append to events    │
   └─────────┬───────────┘        └─────────┬────────────┘
             │                              │
             └───────────┬──────────────────┘
                         ▼
              events (append-only, immutable)  ── sole source of truth
                         │
                         │  read time (no materialization)
                         ▼
              KairosCore (daemon-internal) ──▶ segments (computed, in-memory)
                         │                    │
        menu-bar owner ◀─┘                    ▼
                              segments.get · `kairos export` · snapshots
                                              │
                              external consumers → timesheets / API delivery
```

1. The **idle sampler** samples every ~5s and appends only `afk_on`/`afk_off` *transitions* (not every sample) to `events`.
2. **Clients** send events (`ai_stop`, `ai_submit`, `focus`/`blur`, manual `pause`) as line-JSON RPC to the socket; the daemon appends them to `events`. Activity identity/lifecycle (`activities.start`/`stop`) is a mutable column, not an event. Overrides are just events too.
3. **Nothing derived is stored.** When someone asks for segments (menu bar, export, a consumer), the **attribution library** computes them from `events` on the spot. Data volume is tiny (<~500 events/day), so this is milliseconds.
4. The **menu bar** shows the predicted current owner (computed) and is itself the manual client (start/stop meeting, force owner, pause).
5. **Consumers** read segments and render output. A **snapshot** freezes *the recipe* (params + event watermark) so a submitted timesheet stays reproducible — see [03](./03-data-model.md).

## Process model

- **Daemon:** a user-session `LaunchAgent` (`~/Library/LaunchAgents/dev.kairos.daemon.plist`), `KeepAlive` for crash/login restart. Accessory app (menu bar only). Owns the SQLite handle (WAL) as the single writer, and listens on a Unix domain socket.
- **Clients & consumers:** external processes in any language. They speak line-JSON RPC over the Unix socket (directly or via the Python/Node SDK), or shell out to the `kairos` CLI (which wraps the socket and falls back to a spool file if the daemon is down). None are resident.

## IPC: a local socket, not XPC (and not HTTP)

Client↔daemon uses a **custom line-delimited JSON RPC over a Unix domain socket** (`~/.kairos/daemon.sock`) — not XPC (ties clients to Swift) and not HTTP (Swift has no built-in HTTP server; a custom protocol is fully native via `Network.framework` + `JSONDecoder`/`JSONEncoder`, no `swift-nio`). The goal is an **open ecosystem** where anyone writes a client in any language: line-JSON is trivially consumable, needs no TCP port, and is access-controlled by file permissions (same user, `chmod 0600`). The same surface serves both **ingest** (`events.post`) and **read** (`segments.get`). See [05-protocol.md](./05-protocol.md).

## Why this split

- The **idle clock** and **focus-independent attribution** need a resident run loop → the daemon (and *only* the daemon is resident).
- Claude **sessions are separate processes**; a per-session client can't see its siblings, so cross-session attribution (which depends on global submit ordering) is computed where all events converge → the daemon-internal library over the single event log, reached via the socket.
- Keeping the daemon generic (it has no Claude-specific symbols) and pushing attribution to a read-time library and output to external consumers makes new sources and new timesheet formats cheap to add — **by speaking the protocol, not by loading code into the daemon**.
