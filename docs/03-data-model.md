# 03 — Data Model

Single SQLite database, **WAL mode**, **single writer (the daemon)**, and the daemon is also the sole holder of the attribution library — it serves reads to external consumers over the socket. Location: `~/Library/Application Support/Kairos/kairos.db`; config under `~/.kairos/config.toml`. Only the daemon writes; clients and consumers speak the socket protocol (see [05](./05-protocol.md)).

## Three kinds of state

Kairos separates **immutable, append-only truth** (reproducible via a watermark) from **mutable identity** (resolved live) from **computed** (never stored):

- **Append-only + watermark:** `events` (what happened — activity bounds, overrides, afk, ai stops/submits, pauses) and `project_client_map` (how projects bill). Never updated/deleted; latest-by-`id` wins; a single `max(id)` watermark per table reproduces any point in time. This is the reproducibility primitive.
- **Mutable identity (not watermarked):** `sources`, `projects`, `clients`. Each has a stable integer `id` (referenced everywhere via FK) and an editable display field (`display_name` / `name`). The `slug` (sources/projects) is the stable human-readable identifier. These are never hard-deleted (identity is permanent); display fields resolve live, so a rename surfaces even in old snapshots — accepted, because they are labels, not identity.
- **Identity, created once:** `activities` (a unit of work context — an AI-agent session, a wrapped `vim`/`ssh`, a meeting, an ad-hoc task). Holds stable identity/metadata plus a **mutable `state`** (lifecycle/visibility only). **All time-bearing facts live in `events`** (`focus`/`blur` + deductions), and the client override is an event — neither is stored here.
- **Computed, never stored:** segments (attributed time) — derived on demand from `events` (see [04](./04-attribution.md)).

## Schema

```sql
-- Identity tables: mutable, NOT watermarked. id stable; display editable; never hard-deleted.
CREATE TABLE sources (
  id           INTEGER PRIMARY KEY,
  slug         TEXT NOT NULL UNIQUE,     -- 'claude-code' | 'cursor' | 'pty' | 'manual' | 'idle' | ...
  display_name TEXT NOT NULL,            -- editable; defaults to slug
  manual       INTEGER NOT NULL DEFAULT 0 -- 1 = a user-managed, backdrop-eligible source (seeded 1 for 'manual'; auto sources are 0)
);

CREATE TABLE projects (
  id           INTEGER PRIMARY KEY,
  slug         TEXT NOT NULL UNIQUE,     -- cwd basename for ai sessions; topic for meetings
  display_name TEXT NOT NULL             -- editable; defaults to slug
);

CREATE TABLE clients (
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL                     -- editable (mutable)
  -- future: rate, currency (invoicing) — out of scope for v1
);

-- A unit of work context: an AI-agent session, a wrapped command (vim/ssh), a meeting, an ad-hoc task.
-- Identity only. `state` is a mutable lifecycle/visibility flag (M4p3) — NOT time-bearing, NOT watermarked.
CREATE TABLE activities (
  id           INTEGER PRIMARY KEY,
  source_id    INTEGER NOT NULL REFERENCES sources(id),   -- the agent/originator
  external_id  TEXT,                                      -- the agent's session id (opaque to Kairos; NULL for meeting/manual)
  project_id   INTEGER REFERENCES projects(id),
  title        TEXT,
  metadata     TEXT,                                      -- JSON (transcript_path, cwd, ...)
  state        INTEGER NOT NULL DEFAULT 0,                -- 0 active | 1 stopped | 2 archived (menu visibility; mutable; M4p3)
  UNIQUE (source_id, external_id)
);

-- The append-only event timeline. Source of truth for time, bounds, overrides.
CREATE TABLE events (
  id           INTEGER PRIMARY KEY,                       -- monotonic; snapshot watermark
  ts           REAL NOT NULL,                             -- epoch seconds (client-supplied; may be backdated)
  activity_id  INTEGER REFERENCES activities(id),         -- NULL for global events (afk, pause)
  source_id    INTEGER NOT NULL REFERENCES sources(id),   -- originator
  kind         INTEGER NOT NULL,                          -- event-kind code (see below); wire form is the slug
  payload      TEXT                                       -- JSON
);

-- Project -> client billing rule. APPEND-ONLY. Latest row per project (by id) wins.
-- client_id NULL = tombstone (project explicitly unmapped).
CREATE TABLE project_client_map (
  id         INTEGER PRIMARY KEY,                         -- monotonic; snapshot watermark
  project_id INTEGER NOT NULL REFERENCES projects(id),
  client_id  INTEGER REFERENCES clients(id),              -- NULL = unmapped
  billable   INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL
);

-- A reproducible timesheet recipe: stores HOW segments were computed, not them.
CREATE TABLE snapshots (
  id                  INTEGER PRIMARY KEY,
  label               TEXT,
  range_start         REAL NOT NULL,
  range_end           REAL NOT NULL,
  params              TEXT NOT NULL,       -- JSON: idle_threshold, timezone, ...
  attribution_version TEXT NOT NULL,       -- CODE version of the strategy (see below)
  watermarks          TEXT NOT NULL,       -- JSON: {"events": N, "project_client_map": M}
  segments_digest     TEXT,
  generated_at        REAL NOT NULL
);

CREATE INDEX idx_events_ts         ON events(ts);
CREATE INDEX idx_events_activity   ON events(activity_id, ts);
CREATE INDEX idx_events_source     ON events(source_id);
CREATE INDEX idx_activities_source ON activities(source_id);
CREATE INDEX idx_map_project       ON project_client_map(project_id, id);

-- Enforce append-only at the DB level for the two source-of-truth tables.
CREATE TRIGGER events_immutable_u BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT,'append-only'); END;
CREATE TRIGGER events_immutable_d BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT,'append-only'); END;
CREATE TRIGGER map_immutable_u BEFORE UPDATE ON project_client_map BEGIN SELECT RAISE(ABORT,'append-only'); END;
CREATE TRIGGER map_immutable_d BEFORE DELETE ON project_client_map BEGIN SELECT RAISE(ABORT,'append-only'); END;
```

### Event kinds

| kind | activity_id | payload | meaning |
|---|---|---|---|
| `focus` / `blur` | set | — | the activity gained / lost focus — **the sole timing base** (M4p3). Emitted by the PTY wrapper (DECSET-1004), a manual menu click, or the daemon's auto-catch |
| `ai_stop` | set | — | an AI agent finished its turn (start of a *deduction* marker) |
| `ai_submit` | set | — | user submitted a prompt to an AI agent (end of the `[ai_submit, ai_stop]` grind deduction) |
| `activity_override` | set | `{client_id?, billable?}` | set/replace the activity's direct client (latest by id wins; `client_id:null` = clear) |
| `afk_on` | NULL | `{reason}` | user went away; `reason` = integer code `0` idle \| `1` sleep \| `2` offline |
| `afk_off` | NULL | — | user returned |
| `pause_on` / `pause_off` | NULL | — | manual global pause |

Since **M4p3** `kind` and `activities.state` are stored as compact **integer codes** (the closed, code-defined vocabulary is efficient for a future client↔server scale), while the **wire/CLI form stays a human-readable slug** (`{"kind":"ai_submit"}`, `--kind ai_submit`) — the same wire-slug ↔ stored-id split as sources/projects. Timing is a pure function of `focus`/`blur` (base) minus `ai_*` (per-activity grind), `afk`, and `pause` (see [04](./04-attribution.md)). The former `activity_open` / `activity_close` / `force_owner` kinds are **removed**: activity lifecycle is the mutable `activities.state` column (not an event), and a manual `focus` replaces `force_owner`. `ai_stop`/`ai_submit` stay **agent-agnostic** — which agent is identified by `source_id` → `sources.slug`, never keyed on by attribution. `afk_on` `reason` is likewise a compact **integer code** (`0` idle — idle timeout, machine on; `1` sleep — system sleep / lid close; `2` offline — machine off / daemon-down gap), with a slug display form. `focus`/`blur` are generic — any focus reporter can emit them.

## Activity time, lifecycle & client override

Since **M4p3** an activity carries three orthogonal things, kept separate:

- **Time (event-sourced):** derived entirely from `focus`/`blur` events minus deductions (`ai_*`, `afk`, `pause`) — see [04](./04-attribution.md). There are no `activity_open`/`activity_close` bounds anymore.
- **Lifecycle (mutable column, not watermarked):** `activities.state` ∈ `{active, stopped, archived}` drives menu visibility only — `active` shows in the live switch list, `stopped` shows in *Start Activity …* (manual only, reactivatable), `archived` (manual only) is hidden. Set by `activities.start` (→ `active`, create-or-resume) and `activities.stop` (→ `stopped`); never read by attribution, so it is deliberately *not* an event.
- **Client override (event-sourced):** `activity_override` events; latest by `id` for the activity wins (`client_id:null` = tombstone). Meetings/manual set this; ai sessions use the project→client map.

Keeping the override as an event (not a column) keeps the reproducibility primitive to **two watermarks** (`events`, `project_client_map`). `state` is intentionally outside that primitive — it is display state (like a `display_name`), not a time-bearing fact.

## Identity tables: sources, projects, clients

All three follow the same pattern: stable integer `id` (the FK target everywhere), editable display field, never hard-deleted. They are **not watermarked** — identity is pinned by the stable `id` referenced from the append-only tables; the display field resolves live.

- **`sources`** — the originator of events (`claude-code`, `cursor`, `pty`, `manual`, `idle`, …). The daemon **auto-registers** a source by slug on first sight (upsert into `sources`), so adding a new AI agent is pure data — no code, no schema change. The `manual` flag (seeded `1` for `manual`) marks **user-managed, backdrop-eligible** sources; the wrapped-command source `pty` and agent sources are `auto` (`manual = 0`). See [04](./04-attribution.md).
- **`projects`** — `slug` = cwd basename (ai sessions) or topic (meetings); `display_name` editable. Auto-registered by slug on first sight.
- **`clients`** — user-created; `name` editable.

## Project ↔ client resolution

`project` is reported by the client as a slug (auto = cwd basename for ai sessions); the daemon resolves it to `projects.id`. The billing client is resolved **at read time**, watermark-bounded:

```sql
-- effective (client_id, billable) for each project, at a given map watermark
SELECT p.slug AS project, m.client_id, m.billable
FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY id DESC) rn
  FROM project_client_map WHERE id <= :map_watermark
) m
JOIN projects p ON p.id = m.project_id
WHERE rn = 1;
```

For any activity:

```
client(activity) = coalesce(
    latest activity_override event (id <= events_watermark) for activity → payload.client_id,
    effective_map[activity.project_id].client_id,        -- ai sessions & mapped projects
    NULL )                                             -- else "unassigned"
```

- **ai sessions** report only `project`; you tag that project's client **once** via the config UI/CLI, and it applies retroactively (and to every session in that project).
- **meeting / manual** may set `activity_override` directly (and optionally a `project`) at creation.
- Unmapping a project = append a tombstone row (`client_id = NULL`); the resolver returns "unassigned".

## The computed segment (not a table)

```swift
struct Segment: Codable {
    let activityId: Int64
    let start: Double        // epoch seconds
    let end: Double
    let seconds: Double      // afk/pause-subtracted per the attribution rules
    let rule: String         // attribution rule that produced it
}
```

Client/project are not on the segment — they are resolved from the referenced activity when a consumer groups or filters. Segments **may overlap** across activities (the concurrent case in [04](./04-attribution.md)); summing `seconds` can therefore exceed wall-clock — expected, and the consumer applies its own billing policy.

## Reproducibility: one primitive, per append-only source

A computation is fully determined by **(the append-only inputs, the params, the code version)**. Immutability + monotonic ids means each append-only source is captured by a single watermark:

```
reproduce(snapshot) = attribute(
    events              where id <= snapshot.watermarks.events,
    project_client_map  where id <= snapshot.watermarks.project_client_map,
    params  = snapshot.params,
    version = snapshot.attribution_version)
```

- **Two orthogonal "versions", do not conflate:**
  - **Data version** — the state of `events` / the map. Captured *entirely by the watermarks*; **no explicit version column is needed** (the monotonic id *is* the version).
  - **Code version** — the attribution strategy logic. Watermarks cannot capture code, so `attribution_version` is retained separately. Old strategy versions stay in the registry (tens of lines each) so a snapshot reproduces byte-for-byte.
- `segments_digest` verifies a re-derivation: recompute with **`id <= watermark`** (NOT "all events with `ts` in range"), hash, compare. A mismatch flags code drift for that version only — it never conflates code drift with late-arriving data.
- **Identity display fields (`sources.display_name`, `projects.display_name`, `clients.name`) are deliberately not watermarked**: reproduction pins *identity* via the stable ids referenced from the append-only tables, but resolves the current *display*. Renames are cosmetic corrections and are meant to propagate.

### Late-arrival caveat

A snapshot excludes events appended after it, **even if their `ts` is in `[range_start, range_end]`** (e.g. an event spooled while the daemon was down, drained after the snapshot). This is correct — *"frozen at submission"*: you cannot bill for an event you didn't know about when you submitted the timesheet. `snapshot create` **drains the spool first** and warns if the spool is non-empty after drain, so a snapshot never freezes over undelivered in-range work.

## Migrations

Schema versioned in a `schema_version` meta table; forward-only migrations on startup. Nothing derived is stored, so migrations only ever touch these base tables — never a cache.
