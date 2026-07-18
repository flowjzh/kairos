# 06 — Daemon Design (`kairosd`)

A lean Swift macOS app (`LSUIElement = YES` — menu-bar only, no Dock icon), installed as a user `LaunchAgent`. It is deliberately **small**: its only resident responsibilities are sampling idle, ingesting events over a socket, hosting the menu bar, and presenting a small config window. All derivation (attribution, export, summarization) happens on demand and mostly outside the daemon.

## Subsystems

### 1. Idle sampler

- Poll `CGEventSource.secondsSinceLastEventType(.combinedSessionState, ...)` every **~5s** on a dispatch timer.
- Fallback if ever denied on a future OS: `ioreg -c IOHIDSystem` `HIDIdleTime` (ns → s). Both verified permission-free.
- When idle crosses **60s** upward → append `afk_on`; when it drops back → append `afk_off`. Only *transitions* are written. `afk_on` carries a `reason` (see below).
- **System sleep / wake:** subscribe to `NSWorkspaceWillSleepNotification` / `NSWorkspaceDidWakeNotification`. On sleep, append `afk_on` immediately with `ts` = sleep moment and `reason = sleep` — the poller can't sample while asleep, so without this the `afk_on` would land at wake time and lose the `[lid-close, wake]` span.
- **Daemon restart gap:** on startup, if the last persisted sample is older than the poll interval, append an `afk_on…afk_off` pair spanning `[last_sample, now]` with `reason = offline` (machine was off or the daemon was down). This ensures an `ai_stop` → close-lid/shutdown → reboot → `ai_submit` window gets holed across the gap (see [04](./04-attribution.md)).
- **`reason` values** (stored as an integer code, slug for display): `0` idle (idle timeout, machine on), `1` sleep (system sleep / lid close), `2` offline (machine off / daemon down). All hole ai identically; the reason is for reporting.
- **Spooled-submit breaks offline afk:** if an `ai_submit` was spooled during an `offline` gap (the hook ran while the daemon was down), its `ts` is evidence you were active — attribution breaks the afk at that instant instead of treating the whole gap as a hole.
- This continuous sampling is **the reason the daemon must be resident** — a point query at submit time cannot recover an AFK interval that occurred mid-gap (lunch between reading and submitting).

> **60s is tight** by design. Mouse movement/scrolling resets idle, so active reading stays non-AFK; motionless staring >60s is cut. Configurable; since events are immutable it can be retuned and any range re-derived — submitted work stays fixed via its snapshot.

### 2. Socket server (ingest + read + config)

- Listens on `~/.kairos/daemon.sock` via `Network.framework` (`NWListener`), serving the line-JSON RPC methods in [05-protocol.md](./05-protocol.md). `chmod 0600` on the socket — same-user only.
- Ingest handlers append to `events` and return immediately — clients are never blocked (one request per connection).
- Read handlers (`segments.get`, `snapshots.*`, `focused.get`) call the attribution library and return computed results — this is how non-Swift external consumers (via the SDK) and `kairos export` read.
- Config handlers manage `clients` (mutable) and append to `project_client_map` (append-only).
- On startup, **drains the spool** (`~/.kairos/spool/`) into `events`; `snapshots.create` and `export` trigger a drain first.

### 3. Attribution library (`KairosCore`, daemon-internal)

- A Swift library linked **only into the daemon** (not the CLI, not exposed via FFI). The daemon uses it for `segments.get` / `snapshots.*` reads and for the live menu-bar focus state. External consumers and `kairos export` reach it **through the socket**, not by linking it.
- **One focus-interval model (M4p3)**, no per-source strategy and no registry: `segments(X) = ⋃focus(X) − X's ai_working − afk − pause`, where `ai_*` deductions are gated by event presence (not `source`), so adding a new agent is still zero code. See [04](./04-attribution.md).
- **Pure and stateless**: events + params → segments in memory; nothing written back. Data volume is tiny (<~500 events/day) so any range computes in milliseconds — no cache, no `reprocess`.
- The `attribution_version` still pins the code version so snapshots reproduce exactly.

### 4. Menu-bar item (`NSStatusItem`)

Live status + quick actions.

```
🟢 daemonclaw                       ← the single focused activity (green dot; computed live)
────────────────────────
Active activities
  🟢 daemonclaw  [claude-code → Acme]  ✕   ← focused; ✕ = stop (blur + stopped)
  ○  swiftcapital [claude-code → Vault]     ← active, blurred; click to focus (manual switch)
────────────────────────
Start Activity…          ⌘N          ← meeting / ad-hoc, or reactivate a recent stopped manual
Configure…                           ← opens the config window (clients / mapping)
Pause                    ⌘P
Idle (auto)                         ← shown when AFK detected
────────────────────────
Quit
```

- **Focused activity** is the reduction over `focus`/`blur` (latest focus without a later blur), display + green dot.
- **Manual switch** (clicking a blurred activity) sends `focus.set` (→ a `focus` event, `source=manual`); the **stop** button sends `activities.stop` (+ `blur`). Menu-item shortcuts avoid a global hotkey, so no Accessibility prompt.

### 5. Config window (SwiftUI)

A small SwiftUI window (opened from the menu bar; not a separate app), the built-in surface for the human-owned configuration and for logging non-coding work. Scope for v1:

- **Clients:** list, create, rename (writes `clients`, name is mutable).
- **Project → client mapping:** list current resolved mappings; assign/clear a project's client and billable flag (each save **appends** a `project_client_map` rule).
- **Start Activity:** create a `manual` activity with a title, optional `project`, and an optional direct client (emitted as an `activity_override` event), or reactivate a recent `stopped` manual activity; starting it writes a `focus` (`activities.start`), stopping writes a `blur` (`activities.stop`). May run with **AFK detection off** for passive work.

This is the only UI in scope. Record-list / dashboard viewers are explicitly out of scope for now; the reserved read methods (`events.list` / `activities.list` / `snapshots.list`) leave room for one later, built as an ordinary consumer against the same protocol — SwiftUI or web, decoupled by the socket.

### 6. Focused activity (live display)

The focused activity is the reduction over `focus`/`blur`: the latest `focus` with no later `blur` clearing it (a `blur` clears only the current holder; a `focus` for another activity supersedes). `afk` and `pause` do **not** clear it — they are temporary states surfaced separately (the menu shows "Idle" / "Paused"), and `focused.get` still returns it. The afk/pause spans, the focused activity, and the active-activity set all come from one `GlobalState` reducer (ADR 21) reading the log + the `state` column, so they cannot drift.

```
   focus(X)                         blur(X)  /  focus(other)
   ────────────────────▶ focused=X ──────────────────────────▶ (none / other)
```

Drives the menu-bar label only; authoritative attribution is always the read-time computation.

## Install / lifecycle

- **Bundle:** a `.app` with the daemon binary; `Info.plist` sets `LSUIElement`. Installer writes `~/Library/LaunchAgents/dev.kairos.daemon.plist` and `launchctl load`s it.
- **LaunchAgent plist:** `RunAtLoad = true`, `KeepAlive = true`. No `MachServices` — the daemon opens its own Unix socket.
- **Paths:** DB at `~/Library/Application Support/Kairos/kairos.db`; socket + spool + config under `~/.kairos/`.

## Snapshots (reproducibility, not caching)

`snapshots.create` / `kairos snapshot create` freezes a **recipe** — range, params, `attribution_version`, and one **watermark per append-only source** (`{events, project_client_map}`), plus a digest of the computed segments. It drains the spool first. Reproduction re-derives from each source `where id <= its watermark`. No segments are stored; client *names* resolve live (mutable). See [03-data-model.md](./03-data-model.md).
