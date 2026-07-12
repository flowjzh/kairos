# 04 — Attribution

Attribution answers: *given a stretch of time, which activity does it belong to, and how much of it was genuine human presence?* This is the conceptual core of Kairos — a **pure, read-time computation** over the immutable event log. Segments are produced in memory when asked for and never stored (see [03](./03-data-model.md)).

## Inputs (all from the one event log)

- **Activity windows:** ai closed windows `[activity_open | ai_stop, ai_submit]`; explicit `[activity_open, activity_close]` (meetings, manual).
- **Global exclusions:** `afk` spans (`afk_on`→`afk_off`, carrying a `reason`) and manual `pause` spans (`pause_on`→`pause_off`).
- **Overrides:** `force_owner`.

## Strategy dispatch — inferred from the event signature, not the source

The strategy is chosen **per activity from its events**, not from its `source`:

- An activity that has `ai_submit` events → **ai submit-anchored**.
- Otherwise (only `activity_open`/`activity_close`) → **explicit-bounds**.

The registry maps **strategy-name (+ `attribution_version`)** → implementation. Adding a new AI agent (`cursor`) requires **no code change**: it emits `ai_stop`/`ai_submit` with `source_id` → `sources.slug = 'cursor'`, and the ai strategy handles any activity with `ai_*` events. (Adding a genuinely *new* strategy kind is a code change — warranted.)

## The precedence model (exclusive, with one concurrent exception)

Attribution is governed by a strict precedence. At any moment, time belongs to the highest-precedence claimant present; lower-precedence claimants are **holed** (displaced) by higher ones — **except** when a hole would erase a lower interval entirely, in which case both are recorded concurrently.

```
manual pause  >  explicit [open,close]  >  afk  >  ai closed window
```

### The holing rule

For two overlapping intervals of **different precedence** (higher `H`, lower `L`), both being activities:

- **If `L ⊆ H`** (L fully contained in H — punching would erase L entirely → *the hole does not hold*): record **both concurrently**. L is a genuine sub-effort embedded in H.
- **Otherwise** (partial overlap, or `H ⊆ L`): **H punches a hole in L** — H is recorded in full; L loses the overlap and keeps its parts outside H.

For **afk / pause** (holes, not activities): they always punch lower-precedence activities; they are never "concurrent." (`explicit` is **immune to afk** — a meeting counts its full span even if you were idle; only `pause` holes it. ai windows cannot be fully inside an afk span because an `ai_submit` is a human action, hence non-afk.)

For **same-precedence activities**: see per-strategy resolution below (ai-vs-ai by submit-priority; explicit-vs-explicit concurrent).

## Strategies

Two ship in v1.

### A. Explicit-bounds (default; meeting / manual / generic)

An activity opened at `activity_open` and closed at `activity_close`. Its window is `[activity_open, activity_close]`, holed **only by `pause`** (immune to afk and ai):

```
explicit_segments(activity) = [activity_open, activity_close] − pause_spans
```

Zero inference. Any future client that knows its own start/stop gets correct attribution for free. Explicit-vs-explicit overlap (two meetings) is concurrent (both kept; rare — consumer resolves). Explicit-vs-ai uses the holing rule above.

### B. AI submit-anchored (AI coding agents)

An AI agent session's *human-work window* is **between the agent finishing (`ai_stop`, or `activity_open` for the first turn) and the user submitting the next prompt (`ai_submit`)** — including browser research, reading, and thinking. The window need **not** be focused.

**Only closed windows are counted.** An `ai_stop` with no following `ai_submit` (the open tail) is **not counted** — most likely the task was finished and the stop was the natural end. If you resume and submit, the window closes normally.

```
ai_window(turn) = [activity_open | ai_stop, ai_submit]     # the submit closes it
```

**Overlap resolution (ai-vs-ai, same precedence) = submit-priority.** When two ai windows overlap, the one **submitted earlier** owns the overlap; the other is trimmed. This nesting fixes the flat model's left-bound bug (see worked example).

**No machine-window concept.** `[ai_submit, next ai_stop]` (the agent grinding) is simply *not an ai window* — it is unattributed to that session, and time there is claimed only if another session's window covers it (you can work on A while B grinds). There is no separate "machine window excludes everyone" rule.

### force_owner (manual override)

`force_owner(activity)` asserts that this activity owns the current gap regardless of heuristics. It produces a window `[force_owner.ts, next ai_submit | next force_owner | activity_close]` that wins ai-vs-ai overlaps (highest precedence within ai). Escape hatch for intra-gap ambiguity (see limits).

## Attribution procedure (layered)

1. **Build explicit windows** `[activity_open, activity_close] − pause` (immune to afk, ai).
2. **Build ai closed windows** `[activity_open | ai_stop, ai_submit]`.
3. **Resolve ai-vs-ai** by submit-priority (earlier submit wins overlaps) → a set of non-overlapping ai claims. Each claim's left bound is its **own** `activity_open | ai_stop` (NOT the previous submit — this is the bug fix).
4. **Hole ai by afk and pause:** subtract afk spans and pause spans from each ai claim (an `ai_submit` inside an `offline` afk span breaks the afk at that instant — the submit is evidence you were active).
5. **Apply the holing rule between explicit (H) and ai (L), per overlapping pair:** if the ai claim ⊆ that explicit → keep ai (concurrent); else subtract the explicit overlap from ai. (Explicit is never holed by ai.)
6. Emit explicit windows and surviving ai claims as segments.

## Worked examples

**Nesting fixes the `[t1,t2]` loss** (A stop t1, B stop t2, B submit t3, B stop t4, A submit t5):
- A's window = `[t1, t5]` (A's own stop → A's submit). B's window = `[t2, t3]`.
- Overlap `[t2,t3]`; B submitted earlier (`t3 < t5`) → B wins it. A trimmed to `[t1,t2] ∪ [t3,t5]`.
- Result: **A = [t1,t2] ∪ [t3,t5], B = [t2,t3].** `[t1,t2]` (A's reading window before B stopped) is recovered — the flat `start = max(prev_submit, lastStop)` model lost it by using the global previous-submit as the left bound. A resumes at `t3` (B's submit), not `t4` — you can work on A the moment you submit B.

**Single session, with research & lunch:**
```
10:00 ai_stop         agent done; you start reading
10:05 (browser tab)   researching — non-AFK, counts
10:15 afk_on          lunch (idle > 60s)
10:40 afk_off         back
10:42 ai_submit       ── A = [10:00–10:15] ∪ [10:40–10:42]   (afk holes the window)
```

**Holing rule — straddle vs embedded** (meeting `[2:00, 3:00]`):
```
ai [1:50, 2:10]  →  ai ⊄ meeting (1:50 < 2:00)  → hole holds
                   ai = [1:50, 2:00],  meeting = [2:00, 3:00]   (overlap absorbed by meeting)

ai [2:10, 2:15]  →  ai ⊆ meeting                  → hole does NOT hold → concurrent
                   ai = [2:10, 2:15],  meeting = [2:00, 3:00]   (both recorded)
```
Intuition: ai straddling the meeting boundary → the meeting interrupts ai (the during-meeting part is absorbed). ai entirely within the meeting → genuine concurrent sub-effort (you did ai work during the meeting) → both count.

**Explicit immune to afk:** a meeting `[14:00, 15:00]` counts the full hour even if you were idle `14:30–14:40` (a video call where you're listening, not typing). Only a manual `pause` would hole it.

## Known limits (honest)

- **Intra-gap interleaving:** if within one ai window you genuinely work on two sessions but submit to only one, that whole window goes to the submitted one. `force_owner` is the escape hatch.
- **Tail loss (accepted):** an `ai_stop` with no following `ai_submit` is not counted (task likely done). Reading the final output then closing without submitting loses that window — recoverable via `force_owner` or a manual activity.
- **Ambiguous micro-windows** between an `ai_stop` and the winning submit's start can go unattributed. Minor; manual override covers it.
- **Concurrent segments can overlap** (the embedded case), so `sum(seconds)` may exceed wall-clock. The consumer applies its billing policy (e.g. prefer explicit).

Attribution is recomputed on every read, so improving the heuristic improves *all* past ranges at once — while already-submitted timesheets stay pinned by their snapshot recipe.
