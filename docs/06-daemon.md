# 06 — Daemon Design (`kairosd`)

A lean Swift macOS app (`LSUIElement = YES` — menu-bar only, no Dock icon), installed as a user `LaunchAgent`. It is deliberately **small**: its only resident responsibilities are sampling idle, ingesting events over a socket, hosting the menu bar, and presenting a small config window. All derivation (attribution, export, summarization) happens on demand and mostly outside the daemon.

## Subsystems

### 1. Idle sampler

- Poll `CGEventSource.secondsSinceLastEventType(.combinedSessionState, ...)` every **~5s** on a dispatch timer.
- Fallback if ever denied on a future OS: `ioreg -c IOHIDSystem` `HIDIdleTime` (ns → s). Both verified permission-free.
- When idle crosses **60s** upward → append `afk_on`; when it drops back → append `afk_off`. Only *transitions* are written.
- This continuous sampling is **the reason the daemon must be resident** — a point query at submit time cannot recover an AFK interval that occurred mid-gap (lunch between reading and submitting).

> **60s is tight** by design. Mouse movement/scrolling resets idle, so active reading stays non-AFK; motionless staring >60s is cut. Configurable; since events are immutable it can be retuned and any range re-derived — submitted work stays fixed via its snapshot.

### 2. Socket server (ingest + read + config)

- Listens on `~/.kairos/daemon.sock`, serving the endpoints in [05-protocol.md](./05-protocol.md).
- Ingest handlers append to `events` and return immediately — clients are never blocked.
- Read handlers call the attribution library and return computed results.
- Config handlers manage `clients` (mutable) and append to `project_client_map` (append-only).
- On startup and periodically, **drains the spool** (`~/.kairos/spool/`) into `events`.

### 3. Attribution library (linked, read-time)

- A **shared library**, not a daemon service. Linked by the daemon (`GET /segments`, live owner) and the `kairos` CLI (`export`). One implementation, two callers.
- **Strategy registry**: `source → AttributionStrategy` (+ version). Default = explicit-bounds; `cc` = submit-anchored. See [04](./04-attribution.md).
- **Pure and stateless**: events + params → segments in memory; nothing written back. Data volume is tiny (<~500 events/day) so any range computes in milliseconds — no cache, no `reprocess`.
- Old strategy versions are retained so snapshots referencing them reproduce exactly.

### 4. Menu-bar item (`NSStatusItem`)

Live status + quick actions.

```
🟢 daemonclaw                       ← predicted current owner (computed live)
────────────────────────
Active activities
  ● daemonclaw        [cc → Acme]   ← click to force-owner here
  ○ swiftcapital      [cc → Vault]
────────────────────────
New activity…            ⌘N          ← opens the config window (meeting / ad-hoc)
Configure…                           ← opens the config window (clients / mapping)
Pause                    ⌘P
Idle (auto)                         ← shown when AFK detected
────────────────────────
Quit
```

- **Predicted owner** is computed from recent `cc_stop` / explicit opens, display only (submits are ground truth).
- **Force owner / pause** append events (`force_owner`, `pause_*`); attribution honors them. Menu-item shortcuts avoid a global hotkey, so no Accessibility prompt.

### 5. Config window (SwiftUI)

A small SwiftUI window (opened from the menu bar; not a separate app), the built-in surface for the human-owned configuration and for logging non-coding work. Scope for v1:

- **Clients:** list, create, rename (writes `clients`, name is mutable).
- **Project → client mapping:** list current resolved mappings; assign/clear a project's client and billable flag (each save **appends** a `project_client_map` rule).
- **New non-coding activity:** create a `meeting` or `manual` activity with a title, optional `project`, and optional `client_override`; open now / close when done (explicit-bounds attribution).

This is the only UI in scope. Record-list / dashboard viewers are explicitly out of scope for now; the reserved read endpoints (`GET /events|/activities|/snapshots`) leave room for one later, built as an ordinary consumer against the same API — SwiftUI or web, decoupled by the socket.

### 6. Owner state machine (advisory display)

```
            cc_stop(X)              cc_submit(any) / pause
   (none) ─────────────▶ owner=X (predicted) ─────────────▶ (none / waiting)
     ▲                       │  force_owner(Y)                 │
     │                       ▼                                 │
     └──────── afk_on ◀── owner=Y (manual) ◀──────────────────┘
```

Drives the menu-bar label only; authoritative attribution is always the read-time computation.

## Install / lifecycle

- **Bundle:** a `.app` with the daemon binary; `Info.plist` sets `LSUIElement`. Installer writes `~/Library/LaunchAgents/dev.kairos.daemon.plist` and `launchctl load`s it.
- **LaunchAgent plist:** `RunAtLoad = true`, `KeepAlive = true`. No `MachServices` — the daemon opens its own Unix socket.
- **Paths:** DB at `~/Library/Application Support/Kairos/kairos.db`; socket + spool + config under `~/.kairos/`.

## Snapshots (reproducibility, not caching)

`POST /snapshots` / `kairos snapshot create` freezes a **recipe** — range, params, `attribution_version`, and one **watermark per append-only source** (`{events, project_client_map}`), plus a digest of the computed segments. Reproduction re-derives from each source `where id <= its watermark`. No segments are stored; client *names* resolve live (mutable). See [03-data-model.md](./03-data-model.md).
