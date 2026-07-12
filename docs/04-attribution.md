# 04 — Attribution

Attribution answers: *given a stretch of active (non-AFK) time, which activity does it belong to?* This is the conceptual core of Kairos. It is a **pure, read-time computation** over the immutable event log — segments are produced in memory when asked for and never stored (see [03](./03-data-model.md)).

## Inputs (all from the one event log)

- The **global non-AFK timeline**: intervals between `afk_off` and the next `afk_on`, minus `pause_on/off` spans.
- **Activity events**: explicit bounds (`activity_open/close`, for manual/meeting) or interpreted signals (`cc_stop`/`cc_submit`).
- **Overrides**: `force_owner`, `pause_*` — ordinary events in the same log, so they are captured by the same computation (and the same snapshot watermark).

## Two strategies

Attribution is a **pluggable strategy registry** keyed by `source` (+ version). Two ship in v1.

### A. Explicit-bounds (default; covers meeting / manual / generic)

An activity is opened at `t_open` and closed at `t_close`. Its segments are the intersection with the non-AFK timeline:

```
segments(activity) = nonAFK ∩ [t_open, t_close]
```

Zero inference. Any future client that knows its own start/stop gets correct attribution for free.

### B. CC submit-anchored (Claude Code)

A Claude session's *human-work window* is **between the AI finishing (`cc_stop`) and the user submitting the next prompt (`cc_submit`)** — including browser research, reading, and thinking. Claude's window need **not** be focused.

The disambiguator across concurrent sessions is the submit itself: **active time preceding a submit belongs to the submitted session.** Submits across all sessions are processed in global time order, which partitions time with no overlaps.

```
let submits = all cc_submit events, sorted ascending by ts
let prev = -inf
for each submit s in submits:           # s.session = X, s.ts = T
    lastStop_X = most recent cc_stop(X) before T   # (session start if none)
    start = max(prev, lastStop_X)        # trim AI-execution that preceded X's Stop
    for each nonAFK interval I overlapping [start, T]:
        yield Segment(activity = X,
                     start = max(I.start, start),
                     end   = min(I.end,   T),
                     rule  = "cc_submit")
    prev = T
```

**Correct-by-construction:**
- **No double-counting:** consecutive submits partition the timeline; each chunk goes to exactly one session.
- **AI time excluded:** `start = max(prev, lastStop_X)` drops the window where X's AI was still executing.
- **Away time excluded:** only `nonAFK` intervals are attributed.
- **Off-app research counted:** browsing between `cc_stop` and `cc_submit` without going AFK is attributed to the session — exactly as intended.

### Manual overrides

- `pause_on/off` → treated identically to AFK (entertainment/unrelated excluded).
- `force_owner(X)` → within the current open gap (since the last submit), attribute active time to X regardless of heuristics, until the next submit or override.

## Worked examples

**Single session, with research & lunch:**
```
10:00 cc_stop        AI done; you start reading
10:05 (browser tab)  researching the problem — non-AFK, counts
10:15 afk_on         you stepped away for lunch (idle > 60s)
10:40 afk_off        back
10:42 cc_submit      ── attributed to this session: [10:00–10:15] ∪ [10:40–10:42]
```

**Two interleaved sessions (S, R) in Ghostty splits:**
```
10:00 cc_stop(S)
10:02 cc_stop(R)        both AIs done; you're working on one of them
10:05 cc_submit(S)      → [max(-inf, 10:00)=10:00 .. 10:05] → S
10:06 cc_submit(R)      → [max(10:05, 10:02)=10:05 .. 10:06] → R
```
No overlap; the `[10:00–10:05]` block you spent (in any window) went to S because that's what you committed to first.

**AI execution correctly excluded:**
```
10:00 cc_submit(S)     you send a prompt
10:00–10:20            S's AI runs tools (you do nothing)
10:20 cc_stop(S)
10:25 cc_submit(S)     → start = max(10:00, 10:20) = 10:20 → [10:20–10:25] → S
                        the [10:00–10:20] AI grind is NOT attributed.
```

## Known limits (honest)

- **Intra-gap interleaving:** if within one submit-gap you genuinely work on two sessions but submit to only one, that whole gap is attributed to the submitted one. Unavoidable without focus signals; `force_owner` is the escape hatch.
- **Tail loss:** activity time after the last event up to AFK/session-close may be under-counted. Bounded and small.
- **Ambiguous micro-windows** between a `cc_stop` and the winning submit's `start` can go unattributed. Minor; manual override covers it.

Acceptable for a timesheet: minute-level granularity, human-reviewable, manually correctable. And because attribution is recomputed on every read, improving the heuristic improves *all* past ranges at once — while already-submitted timesheets stay pinned by their snapshot recipe.
