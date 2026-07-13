# 06 — Daemon Design (`kairosd`)

A lean Swift macOS app (`LSUIElement = YES` — menu-bar only, no Dock icon), installed as a user `LaunchAgent`. It is deliberately **small**: its only resident responsibilities are sampling idle, ingesting events over a socket, hosting the menu bar, and presenting a small config window. All derivation (attribution, export, summarization) happens on demand and mostly outside the daemon.

## Subsystems

### 1. Idle sampler

- Poll `CGEventSource.secondsSinceLastEventType(.combinedSessionState, ...)` every **~5s** on a dispatch timer.
- Fallback if ever denied on a future OS: `ioreg -c IOHIDSystem` `HIDIdleTime` (ns → s). Both verified permission-free.
- When idle crosses **60s** upward → append `afk_on`; when it drops back → append `afk_off`. Only *transitions* are written. `afk_on` carries a `reason` (see below).
- **System sleep / wake:** subscribe to `NSWorkspaceWillSleepNotification` / `NSWorkspaceDidWakeNotification`. On sleep, append `afk_on` immediately with `ts` = sleep moment and `reason = sleep` — the poller can't sample while asleep, so without this the `afk_on` would land at wake time and lose the `[lid-close, wake]` span.
- **Daemon restart gap:** on startup, if the last persisted sample is older than the poll interval, append an `afk_on…afk_off` pair spanning `[last_sample, now]` with `reason = offline` (machine was off or the daemon was down). This ensures an `ai_stop` → close-lid/shutdown → reboot → `ai_submit` window gets holed across the gap (see [04](./04-attribution.md)).
- **`reason` values:** `idle` (idle timeout, machine on), `sleep` (system sleep / lid close), `offline` (machine off / daemon down). All hole ai identically; the reason is for reporting.
- **Spooled-submit breaks offline afk:** if an `ai_submit` was spooled during an `offline` gap (the hook ran while the daemon was down), its `ts` is evidence you were active — attribution breaks the afk at that instant instead of treating the whole gap as a hole.
- This continuous sampling is **the reason the daemon must be resident** — a point query at submit time cannot recover an AFK interval that occurred mid-gap (lunch between reading and submitting).

> **60s is tight** by design. Mouse movement/scrolling resets idle, so active reading stays non-AFK; motionless staring >60s is cut. Configurable; since events are immutable it can be retuned and any range re-derived — submitted work stays fixed via its snapshot.

### 2. Socket server (ingest + read + config)

- Listens on `~/.kairos/daemon.sock` via `Network.framework` (`NWListener`), serving the line-JSON RPC methods in [05-protocol.md](./05-protocol.md). `chmod 0600` on the socket — same-user only.
- Ingest handlers append to `events` and return immediately — clients are never blocked (one request per connection).
- Read handlers (`segments.get`, `snapshots.*`, `owner.get`) call the attribution library and return computed results — this is how non-Swift external consumers (via the SDK) and `kairos export` read.
- Config handlers manage `clients` (mutable) and append to `project_client_map` (append-only).
- On startup and periodically, **drains the spool** (`~/.kairos/spool/`) into `events`; `snapshots.create` and `export` trigger a drain first.

### 3. Attribution library (`KairosCore`, daemon-internal)

- A Swift library linked **only into the daemon** (not the CLI, not exposed via FFI). The daemon uses it for `segments.get` / `snapshots.*` reads and for the live menu-bar owner. External consumers and `kairos export` reach it **through the socket**, not by linking it.
- **Strategy dispatch** is inferred per-activity from its event signature (has `ai_submit` → ai submit-anchored; else explicit-bounds), **not** keyed by `source` — so adding a new AI agent is zero code. The registry maps strategy-name (+ `attribution_version`) → implementation. See [04](./04-attribution.md).
- **Pure and stateless**: events + params → segments in memory; nothing written back. Data volume is tiny (<~500 events/day) so any range computes in milliseconds — no cache, no `reprocess`.
- Old strategy versions are retained so snapshots referencing them reproduce exactly.

### 4. Menu-bar item (`NSStatusItem`)

Live status + quick actions.

```
🟢 daemonclaw                       ← predicted current owner (computed live)
────────────────────────
Active activities
  ● daemonclaw        [claude-code → Acme]   ← click to force-owner here
  ○ swiftcapital      [claude-code → Vault]
────────────────────────
New activity…            ⌘N          ← opens the config window (meeting / ad-hoc)
Configure…                           ← opens the config window (clients / mapping)
Pause                    ⌘P
Idle (auto)                         ← shown when AFK detected
────────────────────────
Quit
```

- **Predicted owner** is computed from recent `ai_stop` / explicit opens, display only (submits are ground truth).
- **Force owner / pause** append events (`force_owner`, `pause_*`); attribution honors them. Menu-item shortcuts avoid a global hotkey, so no Accessibility prompt.

### 5. Config window (SwiftUI)

A small SwiftUI window (opened from the menu bar; not a separate app), the built-in surface for the human-owned configuration and for logging non-coding work. Scope for v1:

- **Clients:** list, create, rename (writes `clients`, name is mutable).
- **Project → client mapping:** list current resolved mappings; assign/clear a project's client and billable flag (each save **appends** a `project_client_map` rule).
- **New non-coding activity:** create a `meeting` or `manual` activity with a title, optional `project`, and an optional direct client (emitted as an `activity_override` event); open now / close when done (explicit-bounds attribution).

This is the only UI in scope. Record-list / dashboard viewers are explicitly out of scope for now; the reserved read methods (`events.list` / `activities.list` / `snapshots.list`) leave room for one later, built as an ordinary consumer against the same protocol — SwiftUI or web, decoupled by the socket.

### 6. Owner prediction (advisory display)

The predicted owner is the most recently claimed activity — the latest `activity_open` / `ai_stop` / `force_owner` whose activity has no later `activity_close`. `afk` and `pause` do **not** clear it: they are temporary states surfaced separately (the menu shows "Idle" / "Paused"), and `owner.get` still returns the active activity. An `ai_stop` claims the gap (the agent finished; you are now working on that session); `ai_submit` does not change the owner (you handed work back to the agent, but the session is still yours). All three menu derivations — afk/pause spans, the owner, and the open-activity set — come from one `GlobalState` reducer (ADR 21), so they cannot drift.

```
   activity_open(X) / ai_stop(X) / force_owner(X)   activity_close(X)
   ──────────────────────────────────────▶ owner=X ─────────────────▶ (none)
```

Drives the menu-bar label only; authoritative attribution is always the read-time computation.

## Install / lifecycle

- **Bundle:** a `.app` with the daemon binary; `Info.plist` sets `LSUIElement`. Installer writes `~/Library/LaunchAgents/dev.kairos.daemon.plist` and `launchctl load`s it.
- **LaunchAgent plist:** `RunAtLoad = true`, `KeepAlive = true`. No `MachServices` — the daemon opens its own Unix socket.
- **Paths:** DB at `~/Library/Application Support/Kairos/kairos.db`; socket + spool + config under `~/.kairos/`.

## Snapshots (reproducibility, not caching)

`snapshots.create` / `kairos snapshot create` freezes a **recipe** — range, params, `attribution_version`, and one **watermark per append-only source** (`{events, project_client_map}`), plus a digest of the computed segments. It drains the spool first. Reproduction re-derives from each source `where id <= its watermark`. No segments are stored; client *names* resolve live (mutable). See [03-data-model.md](./03-data-model.md).
