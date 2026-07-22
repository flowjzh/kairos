<h1 align="center">
  <img src="assets/app-icon.svg" width="128" alt="Kairos"><br>
  Kairos
</h1>

> Measure **kairos** — the time you are genuinely present — not **chronos**, the wall-clock time the machine spends grinding.

In the AI era, a freelancer or employee's day is no longer one app in focus. It's
interleaved — a Claude Code session here, a Cursor turn there, reviewing an agent's
pull request, prompting, waiting, re-prompting. Conventional time trackers can't see
this: they key off the frontmost window or a manual start/stop, so they log either
*machine* time (the agent grinding) or nothing useful, and can never answer *"how
long was I actually engaged with each agent this week?"*

**Kairos** is a local-first daemon that records the time you are genuinely **engaged**
with your work and attributes each block to the activity driving it — a Claude Code
session, a client meeting, an ad-hoc task. It separates *human* effort (reading,
thinking, prompting) from *AI execution* time, and attributes that human time **per
agent**. Today it tracks Claude Code out of the box; the client model means any agent
is a small `kairos-<agent>` hook away.

<img width="972" height="785" alt="Screenshot 2026-07-22 at 22 44 15" src="https://github.com/user-attachments/assets/ff17b182-1953-4aeb-87e0-32f3a7e60b05" />

## Features

- **Per-agent human-time attribution** — the headline. Track genuine engagement with
  each AI agent separately, not the wall-clock the agent ran for.
- **Submit-anchored AI attribution** — for an AI session, the active window is
  `[prompt | agent-stops, you-submit]`: your thinking/reading time counts, the agent's
  autonomous execution does not.
- **Manual activities & meetings** — start/stop from the menu bar; explicit-time
  activities are AFK-immune (a meeting doesn't fragment when you go idle).
- **Any terminal command** — launch it as `kairos <command>` and Kairos records when
  that terminal is in focus, so editors, `ssh`, REPLs, and other interactive CLI work
  are tracked too — not just AI sessions.
- **Dashboard** — a per-source timeline (each agent a translucent area, total
  overlaid), a paged raw-segments table, and a client → project summary tree.
- **Local-first & private** — everything stays on disk (SQLite). No cloud, no account,
  no telemetry. Append-only events guarded by immutability triggers.
- **Zero special permissions** — attribution is intent-based (which session you submit
  to / which activity you start), so Kairos never reads window titles and needs no
  Accessibility or Automation access.
- **Native, not Electron** — a Swift menu-bar app with a small Rust core; even the
  Claude Code plugin is a single native binary (no Node runtime, no shelling out to
  `jq`/`python`). The app is ~3 MB on disk and ~45 MB resident at idle (per Activity
  Monitor); the plugin adds
  nothing resident — it runs only on hook events and exits in milliseconds.

## Installation

### 1. The app

1. Download **Kairos.app** from the latest [Release](https://github.com/flowjzh/kairos/releases).
2. Drag it into **Applications** and launch it. A Kairos icon appears in the menu bar.
3. (Optional) Enable **Launch at login** from the menu-bar menu to autostart.

> No build step, no toolchain — the Release ships a signed, ready-to-run app.

### 2. The `kairos` CLI *(optional)*

From the menu bar → **Configure → General → Command-Line Tool → Install**. This
symlinks `kairos` onto your PATH (one admin prompt), giving you the shell interface:

```sh
kairos --help                  # clients, projects, activities, export, …
```

The CLI also **wraps any terminal command** — launching it as `kairos <command>` lets
Kairos track when that terminal is in focus, so its active time is recorded:

```sh
kairos vim main.rs             # any command you actively work in — focus/blur is captured
kairos ssh prod
```

(See [Timesheets](#timesheets) to export attributed time.)

### 3. The Claude Code plugin *(optional)*

Track AI coding sessions automatically. In the app, open **Configure → Plugins → Claude
Code** and click **Register** (this makes Kairos's bundled plugin known to Claude Code).
Then install it — pick a scope:

```sh
claude plugin install kairos-claude-code@kairos --scope user   # or: project | local
```

The plugin ships **inside the app** (a native binary, no download); Claude Code copies it
into its own cache on install, and you manage it with `claude plugin update` / `uninstall`.
Each session shows up as a project (its folder name); tag that project's client once in
**Configure…** and it applies retroactively.

The plugin's job is to split each session into **AI-execution** time (the agent
running) vs **human** time (you reading, thinking, prompting), using the agent's
submit/stop markers. On its own that split is **coarse**: during the human windows it
can't tell whether you were focused on *this* session or had switched to another
window. For precise attribution, launch Claude through the wrapper so the terminal's
focus on the session is recorded too:

```sh
kairos claude        # pairs the plugin's AI/Human split with real focus on this session
```

Now, within the human window, only the time your terminal was genuinely on that
session counts as interaction with it.

Each session's activity also carries its Claude **session id** as an `external_id`, so a
timesheet can pinpoint exactly which session a block of time belonged to — see
[Timesheets](#timesheets).

## Privacy

Kairos is local-first: all data lives in a SQLite file on your machine
(`~/Library/Application Support/Kairos/kairos.db`). There is no cloud, no account, and
no telemetry — nothing leaves your Mac. It needs **no Accessibility or Automation
permissions**: because attribution is intent-based (which session you submit to, which
activity you start), Kairos never reads window titles or inspects other apps.

## Status

**M1 + M2**: the resident menu-bar daemon, the line-JSON protocol, explicit-bounds and
AI submit-anchored attribution, the `kairos` CLI, a SwiftUI config window, the Claude
Code plugin, and the Dashboard. Snapshots and the reference Python summarizer are next.

**Platform:** macOS today; the data plane (the Rust reducer + the web dashboard) is
built to port, with a Windows host on the roadmap. See [roadmap](./docs/09-roadmap.md).

## How it works

A lean resident daemon samples idle and ingests events from clients over a local socket
into an append-only SQLite log — the sole source of truth. Segments (attributed
active-time blocks) are **computed on demand**, never stored. Clients are external
processes (the Claude Code plugin, the `kairos` CLI, anything you write); consumers read
segments out via the SDK to render timesheets. See
[Architecture](./docs/02-architecture.md) for the full design.

## Timesheets

Attributed time is read out over the same socket the daemon serves — segments are
computed on demand from the event log, never stored, so a timesheet is always live and
exact.

**Quick — `kairos export`:**

```sh
kairos export --from 0 --to 9999999999 | jq .   # client-grouped, attributed segments
```

**Richer — the Python SDK** (`sdk/python`, dependency-free) speaks the line-JSON protocol
directly. A single `segments.get` round-trip returns every segment in the range (no
pagination), each carrying the afk/pause-subtracted human `seconds` and a joined activity:

```python
from kairos_sdk import Kairos

kairos = Kairos()                               # ~/.kairos/daemon.sock
for s in kairos.segments(from_ts, to_ts, client=1):
    print(s.seconds, s.activity.project, s.activity.external_id)
```

Each activity carries an **`external_id`** — for Claude Code sessions, the session id —
so a timesheet can pinpoint exactly which session a block of time belonged to (and, via
the activity's `transcript_path`, what was being done). Any language works: open the
socket, write one `segments.get` request line, read one response line — see
[docs/05-protocol.md](./docs/05-protocol.md).

## Documentation

1. [Overview & principles](./docs/01-overview.md)
2. [Architecture](./docs/02-architecture.md)
3. [Data model](./docs/03-data-model.md)
4. [Attribution](./docs/04-attribution.md) *(the core)*
5. [Protocol](./docs/05-protocol.md)
6. [Daemon design](./docs/06-daemon.md)
7. [Clients](./docs/07-clients.md)
8. [Consumers & summarizer](./docs/08-summarizer.md)
9. [Roadmap](./docs/09-roadmap.md)

## Contributing

Building from source, the dev/release isolation, the dashboard HMR loop, and the release
process are in [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

[MIT](./LICENSE) — © Flow Jiang.
