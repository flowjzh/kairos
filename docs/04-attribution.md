# 04 — Attribution

Attribution answers: *given a stretch of time, which activity does it belong to, and how much of it was genuine human presence?* This is the conceptual core of Kairos — a **pure, read-time computation** over the immutable event log. Segments are produced in memory when asked for and never stored (see [03](./03-data-model.md)).

Since **M4p3** the model is **focus-driven and single-pointer**: at any instant **at most one activity holds focus**, and time is attributed to whichever activity holds it, minus deductions. This replaced an earlier two-strategy precedence model (submit-anchored ai windows vs explicit bounds, holed by a `pause > explicit > afk > ai` lattice); see roadmap ADR 27 for the reversal.

## Inputs (all from the one event log)

- **Base — focus intervals:** `focus` / `blur` events. `focus` moves the single pointer to an activity; `blur` clears it (to none, or to a backdrop — see below). These are the *only* timing events.
- **Deductions:**
  - **ai_working (per activity):** `[ai_submit, ai_stop]` spans — the agent grinding while you wait. Subtracted from *that activity's* base only.
  - **afk (global):** `afk_on`→`afk_off` spans (`reason` = `idle`/`sleep`/`offline`).
  - **pause (global):** `pause_on`→`pause_off` spans (manual).

`ai_submit`/`ai_stop` are **agent-agnostic** — which agent produced them is identified by the activity's `source` (`claude-code`, `cursor`, …) but attribution never keys on it. `focus`/`blur` are equally generic: any reporter (the PTY wrapper, a manual menu click, the daemon's auto-catch) can emit them.

## The focus pointer — a reduction over `focus`/`blur`

The "currently focused activity" is **not** runtime state; it is a reduction over the `focus`/`blur` events, exactly reproducible at any watermark:

- **Latest `focus` wins.** A `focus(X)` event supersedes any prior focus — so the invariant "at most one activity is focused" holds by construction, with no write-time transaction.
- **`blur` clears only the current holder.** A `blur(X)` moves the pointer to none *iff* X currently holds it; a `blur` for a non-holder is a no-op. This makes the reduction robust to event reordering (switching split A→B produces `blur(A)` from A's wrapper and `focus(B)` from B's wrapper independently; either arrival order yields "B focused").
- **All reporters compose by timestamp** (latest-wins, no lock): a manual menu `focus` and a terminal `focus` are resolved purely by `ts` (ADR 32).

The base intervals of an activity X are the maximal stretches where the reduction says X is focused:

```
focus-intervals(X) = the spans between a focus(X) and the next event that removes X
                     (a blur(X), a focus(other), or `now` for the still-focused tail)
```

## Layered focus: backdrop + foreground (auto-catch)

Activities split by `source` into two roles:

- **manual** (`source = manual`, i.e. `sources.manual = 1`) — **background** context (a meeting, an ad-hoc task). A running one is a *backdrop*.
- **auto** (`pty`, `claude-code`, …) — transient **foreground** grabbers (a terminal split, an agent session).

When a foreground activity **blurs with no successor focus**, the daemon **auto-catches** the pointer to an active manual backdrop rather than dropping to none:

- **0 active manual** → pointer to none (the clock stops — you tabbed to a browser to slack off, or quit).
- **exactly 1** → focus it automatically.
- **>1** → fall back to the **most-recently-focused** backdrop and post a notification ("multiple active activities; focus switched to X").

Auto-catch is **materialised as a `focus` event** (not a read-time inference), so the daemon reads live lifecycle state only to *decide*, while the timing stays a pure replay of the log (ADR 28). This is how "I dipped into Claude during a meeting, then tabbed back" attributes the dip to Claude and the rest to the meeting.

## The per-activity segment formula

```
segments(X) = ⋃ focus-intervals(X)  −  ai_working(X)  −  afk  −  pause

  ai_working(X) = ⋃ [ai_submit, ai_stop]         # X's own; open grind → [ai_submit, min(now, next blur of X)]
  afk, pause    = global spans (apply to whichever activity is focused during them)
```

Because only one activity is focused at a time, `afk`/`pause` — though global — only ever hole the single focused activity; there is no cross-activity interaction to resolve. `ai_working` is strictly per activity: an activity grinding in the background while you work in another does **not** hole the other (the other isn't focused there anyway).

**AFK immunity.** A `manual` activity may run with **AFK detection off** (chosen at start — for passive work like a meeting where "no input" is normal). While such an activity is focused, the idle sampler emits **no `afk` events** (a write-time gate, ADR 33), so there is simply nothing to subtract.

## Consequences vs the old model

- **No concurrent double-count.** One pointer ⇒ `sum(seconds) ≤ wall-clock`. The old "embedded sub-effort counts for both" case is gone (a freelancer cannot bill two clients for the same minute).
- **The reading tail is recovered.** After an `ai_stop` with no following `ai_submit`, if you stay focused reading the output (non-idle, non-grind) that time now **counts** — the old model's accepted "tail-loss" is fixed.
- **`vim`/`ssh` degrade cleanly.** An activity with no `ai_*` events has `ai_working = ∅`, so its time is just `focus − afk − pause`.
- **`force_owner` is gone** — a manual `focus` is the override.

## Worked examples

**Single Claude session, research & lunch** (you keep the split focused; you tab to a browser for the task via a **manual** focus so it keeps counting):
```
10:00 focus(A)         you launch `kairos claude`, split focused (t0 focus, back-dated)
10:00 ai_submit        first prompt → grind starts
10:03 ai_stop          agent done; you read (focused, counts)
10:05 (tab to browser) terminal blurs → menu-click focus(A, manual) to keep A counting
10:15 afk_on(idle)     lunch
10:40 afk_off          back (still manually focused on A)
10:42 ai_submit        ── A = [10:00,10:00]∪[10:03,10:15]∪[10:40,10:42]  (grind + afk holed)
```

**Vibe-coding during a meeting** (backdrop + auto-catch):
```
13:00 focus(M)         Start Activity "Team sync" (manual backdrop, AFK-off)
13:20 focus(A)         you dip into a Claude split (foreground; M blurred)
13:25 blur(A)          you tab back to the call → auto-catch focus(M)
                       ── A = [13:20,13:25] − A's grind;  M = [13:00,13:20]∪[13:25, …]
```
The meeting counts its full span except the 5-minute Claude dip; Claude counts only the dip. No double-count.

**Two splits, switching:**
```
focus(A) … you work in A … focus(B)   → A ends at focus(B); B begins. blur(A) (from A's wrapper) is a no-op.
```

**Grilling / plan review — human-input tools (`AskUserQuestion`, `ExitPlanMode`):** these are the only tools whose execution blocks on a human response, so the claude-code client emits `ai_stop` on their `PreToolUse` (agent done, waiting) and `ai_submit` on their `PostToolUse` (human answered/approved, agent resumes). Without those markers a single turn that asks 100 questions — or awaits plan approval — is one `[ai_submit, ai_stop]` grind, deducting hours you spent reading and answering as if you were idle. With them, only each real agent-generation burst is grind; your deliberation stays in focus:
```
10:00 ai_submit          you prompt → grind starts
10:00 ai_stop            agent asks Q1 / shows plan (PreToolUse) → grind closes
10:03 ai_submit          you answer / approve (PostToolUse) → grind reopens
10:03 ai_stop            agent asks Q2 → … (your 10:00–10:03 reading/answering counts as focus)
```

## Known limits (honest)

- **Permission-prompt wait is not separated from grind.** When a tool call requires human approval (the permission dialog), the time you spend deciding is human deliberation but is NOT marked — `PreToolUse` fires *before* the prompt and there is no post-decision hook, so it stays inside the grind. Only the explicit human-input tools (`AskUserQuestion`, `ExitPlanMode`) are split. Moot under `--dangerously-skip-permissions` (no prompts).
- **Un-asserted background work is not counted.** Tab to a browser without a manual focus (and with no manual backdrop) → the pointer drops to none and that time is unattributed. This is deliberate: "default don't count unless focused or manually asserted" (ADR 32) — the system cannot tell research from slacking, so the burden of asserting research is on you.
- **A `kill -9`'d wrapper can briefly over-count.** If a wrapper dies without its exit `blur`, and you neither focus something else nor go idle, its activity keeps counting until the next focus/afk. Narrow and afk-bounded; not worth a heartbeat (ADR, M4p3 Q7).
- **Auto-catch to the wrong backdrop.** With >1 active manual, auto-catch guesses the most-recently-focused and notifies; a wrong guess is one manual click to correct (which is itself a `focus` event).

Attribution is recomputed on every read, so improving the model improves *all* past ranges at once — while already-submitted timesheets stay pinned by their snapshot recipe.
