# 01 — Overview & Principles

## The problem

A freelancer's timesheet must capture **real human work time** per project, per client, with a one-line description of each block. Existing tools get this wrong in two ways:

1. **They measure the wrong phase.** AI-coding trackers (e.g. the wakatime Claude plugin) record heartbeats from *AI file operations* — i.e. the time the AI is grinding. The time you spend **reading output, thinking, researching in a browser, and writing the next prompt** is treated as idle and discarded. That is exactly backwards: you want to bill your thinking time, not the machine's.
2. **They can't tell engagement from absence.** A terminal can stay focused while you go to lunch, or you may read in another window. Without focus + idle signals, "time in window" over-counts; without granularity, multi-session work is ambiguous.

## The thesis

> Measure **kairos**, not **chronos**.

- *Chronos* — quantitative, clock time (the wall clock while the AI runs).
- *Kairos* — qualitative, human, the right moment: the time **you** are present and driving the work.

Kairos records kairos. Active time is defined as **at the keyboard (not AFK) and attributable to some activity you are intentionally pursuing** — regardless of which window happens to be focused (browser research for a task counts for that task).

## Goals

- Accurate **human-active** time per activity (Claude session, meeting, ad-hoc task).
- **Attribution by intent**, not by focused window: which session you *submit* to, or which activity you *start*, owns the preceding active time.
- **Idle-aware**: walking away is detected and excluded automatically.
- **Pluggable sources**: Claude Code today; meetings, manual tasks, git/editor tomorrow. The daemon is source-agnostic.
- **Timesheet output**: per project/client/day, with an LLM one-line summary per block (using Claude transcripts where available).
- **Local-first & private**: all data stays on-device; the only network egress is the optional LLM call you configure.

## Non-goals (for v1)

- Real-time billing integrations, invoicing, payment.
- Team/server multi-user sync.
- Cross-platform (macOS only for now; the architecture permits Linux/Windows backends later).

## Design principles

1. **Human time, not machine time.** The default question is "was a person engaged?", never "was the CPU busy?".
2. **Attribution by commitment.** A `UserPromptSubmit` (or an explicit activity start) is ground truth that you were working on that activity. The preceding active time belongs to it.
3. **Raw events are immutable truth; segments are a derived projection.** Idle threshold and heuristics can be re-tuned and the whole history re-derived without data loss.
4. **Zero special permissions.** No Accessibility, no Automation, no Input Monitoring. See below.
5. **One resident process, event-driven.** The daemon is the only long-lived component; clients are short-lived reporters. No polling-spawn loops, no per-session residents.

## Permissions & privacy

This is a hard design constraint, not a nice-to-have.

| Capability | API used | Permission required |
|---|---|---|
| System-wide idle (AFK) | `CGEventSource.secondsSinceLastEventType` (fallback `ioreg HIDIdleTime`) | **None** (verified on this machine) |
| Menu-bar status item | `NSStatusItem` (AppKit) | **None** |
| Per-source events | line-JSON RPC over a Unix domain socket | **None** (local IPC, same-user file perms) |

Because attribution is **intent-based** (submit / explicit start), Kairos never needs to read window titles or inspect other apps — so it avoids the Accessibility/Automation permissions that a focus-tracking approach would require. Multi-session precision within one terminal app (e.g. several Claude splits in one Ghostty window) is resolved by the submit-heuristic and manual override, **not** by window introspection.

- **Privacy:** all data is local (`~/.kairos/` / `~/Library/Application Support/Kairos/`). The daemon makes no network calls. The summarizer makes one optional call to an LLM provider you configure.
- **Opt-in precision (future):** if a user ever wants window-level granularity, an Automation-based terminal-tty lookup can be added as an explicit, separately-granted module. Out of the box, Kairos needs no prompts.
