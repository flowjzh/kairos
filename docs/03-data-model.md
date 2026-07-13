# 03 — Data Model

Single SQLite database, **WAL mode**, **single writer (the daemon)**, and the daemon is also the sole holder of the attribution library — it serves reads to external consumers over the socket. Location: `~/Library/Application Support/Kairos/kairos.db`; config under `~/.kairos/config.toml`. Only the daemon writes; clients and consumers speak the socket protocol (see [05](./05-protocol.md)).

## Three kinds of state

Kairos separates **immutable, append-only truth** (reproducible via a watermark) from **mutable identity** (resolved live) from **computed** (never stored):

- **Append-only + watermark:** `events` (what happened — activity bounds, overrides, afk, ai stops/submits, pauses) and `project_client_map` (how projects bill). Never updated/deleted; latest-by-`id` wins; a single `max(id)` watermark per table reproduces any point in time. This is the reproducibility primitive.
- **Mutable identity (not watermarked):** `sources`, `projects`, `clients`. Each has a stable integer `id` (referenced everywhere via FK) and an editable display field (`display_name` / `name`). The `slug` (sources/projects) is the stable human-readable identifier. These are never hard-deleted (identity is permanent); display fields resolve live, so a rename surfaces even in old snapshots — accepted, because they are labels, not identity.
- **Identity, created once:** `activities` (a unit of work context — an AI-agent session, a meeting, an ad-hoc task). Holds only stable identity/metadata; **all time-bearing and billing-bearing facts (bounds, client override) live in `events`, not here.**
- **Computed, never stored:** segments (attributed time) — derived on demand from `events` (see [04](./04-attribution.md)).

## Schema

```sql
-- Identity tables: mutable, NOT watermarked. id stable; display editable; never hard-deleted.
CREATE TABLE sources (
  id           INTEGER PRIMARY KEY,
  slug         TEXT NOT NULL UNIQUE,     -- 'claude-code' | 'cursor' | 'meeting' | 'manual' | 'idle' | ...
  display_name TEXT NOT NULL             -- editable; defaults to slug
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

-- A unit of work context: an AI-agent session, a meeting, an ad-hoc task.
-- Identity only — created once on activity_open; NO bounds, NO billing columns here.
CREATE TABLE activities (
  id           INTEGER PRIMARY KEY,
  source_id    INTEGER NOT NULL REFERENCES sources(id),   -- the agent/originator
  external_id  TEXT,                                      -- the agent's session id (opaque to Kairos; NULL for meeting/manual)
  project_id   INTEGER REFERENCES projects(id),
  title        TEXT,
  metadata     TEXT,                                      -- JSON (transcript_path, cwd, ...)
  UNIQUE (source_id, external_id)
);

-- The append-only event timeline. Source of truth for time, bounds, overrides.
CREATE TABLE events (
  id           INTEGER PRIMARY KEY,                       -- monotonic; snapshot watermark
  ts           REAL NOT NULL,                             -- epoch seconds (client-supplied; may be backdated)
  activity_id  INTEGER REFERENCES activities(id),         -- NULL for global events (afk, pause)
  source_id    INTEGER NOT NULL REFERENCES sources(id),   -- originator
  kind         TEXT NOT NULL,                             -- see event kinds below
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
| `activity_open` | set | — | activity starts (open bound); title/project/metadata live on the immutable `activities` row |
| `activity_close` | set | — | activity ends (close bound) |
| `activity_override` | set | `{client_id?, billable?}` | set/replace the activity's direct client (latest by id wins; `client_id:null` = clear) |
| `ai_stop` | set | — | an AI agent finished its turn |
| `ai_submit` | set | — | user submitted a prompt to an AI agent |
| `afk_on` | NULL | `{reason}` | user went away; `reason` = `idle` \| `sleep` \| `offline` |
| `afk_off` | NULL | `{reason?}` | user returned |
| `pause_on` / `pause_off` | NULL | — | manual global pause |
| `force_owner` | set | — | assert this activity owns the current gap |

`ai_stop`/`ai_submit` are **agent-agnostic** — which agent (Claude Code, Cursor, …) is identified by `source_id` → `sources.slug` (e.g. `claude-code`). The attribution strategy is inferred from the event *signature* (an activity with `ai_submit` events → ai submit-anchored; else explicit-bounds), **not** keyed by source — so adding a new AI agent requires no code change (see [04](./04-attribution.md)). `afk_on` `reason`: `idle` (idle timeout, machine on), `sleep` (system sleep / lid close), `offline` (machine off / daemon-down gap).

## Activity bounds & client override — both event-sourced

An activity's time bounds and its direct client override are **not columns on `activities`** — they are events, so they are watermarked and reproducible:

- **Bounds:** `activity_open` (ts = start) and `activity_close` (ts = end). The ai strategy uses `[activity_open | ai_stop, ai_submit]` windows; explicit-bounds uses `[activity_open, activity_close]` (see [04](./04-attribution.md)).
- **Client override:** `activity_override` events; latest by `id` for the activity wins (`client_id:null` = tombstone). Meetings/manual set this directly; ai sessions never set it (they use the map).

Storing the override as an event (rather than a third append-only table) keeps the reproducibility primitive to **two watermarks** (`events`, `project_client_map`) — bounds and override are both covered by the `events` watermark.

## Identity tables: sources, projects, clients

All three follow the same pattern: stable integer `id` (the FK target everywhere), editable display field, never hard-deleted. They are **not watermarked** — identity is pinned by the stable `id` referenced from the append-only tables; the display field resolves live.

- **`sources`** — the originator of events (`claude-code`, `cursor`, `meeting`, `manual`, `idle`, …). The daemon **auto-registers** a source by slug on first sight (upsert into `sources`), so adding a new AI agent is pure data — no code, no schema change.
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
