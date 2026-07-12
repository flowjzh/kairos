# 03 — Data Model

Single SQLite database, **WAL mode**, **single writer (the daemon)**, many readers (CLI, consumers, future UI). Location: `~/Library/Application Support/Kairos/kairos.db`; config under `~/.kairos/config.toml`. Only the daemon writes; clients send events over the socket, consumers read.

## Two kinds of state

Kairos separates **immutable, append-only truth** (reproducible via a watermark) from **mutable cosmetics** (resolved live):

- **Append-only + watermark:** `events` (what happened) and `project_client_map` (how projects bill). Never updated/deleted; latest-by-`id` wins; a single `max(id)` watermark reproduces any point in time. This is the reproducibility primitive.
- **Mutable, resolved live:** `clients` (a client's display *name*). Identity (`clients.id`) is stable and pinned by the map watermark; the name is cosmetic and always shown current. A rename therefore surfaces even in old snapshots — accepted, because names are labels, not identity.
- **Computed, never stored:** segments (attributed time) — derived on demand from `events` (see [04](./04-attribution.md)).

## Schema

```sql
-- A unit of work context: a Claude session, a meeting, an ad-hoc task.
CREATE TABLE activities (
  id              INTEGER PRIMARY KEY,
  source          TEXT NOT NULL,          -- 'cc' | 'meeting' | 'manual' | ...
  external_id     TEXT,                   -- CC session_id / calendar id / NULL
  project         TEXT,                   -- cwd basename for cc; topic/NULL for meeting
  title           TEXT,
  client_override INTEGER REFERENCES clients(id),  -- set directly for meetings/manual
  started_at      REAL NOT NULL,
  ended_at        REAL,                   -- NULL while open
  status          TEXT NOT NULL DEFAULT 'open',    -- 'open' | 'closed'
  metadata        TEXT,                   -- JSON (transcript_path, cwd, ...)
  UNIQUE (source, external_id)
);

-- The append-only event timeline. Source of truth for time, incl. overrides.
CREATE TABLE events (
  id            INTEGER PRIMARY KEY,       -- monotonic; snapshot watermark
  ts            REAL NOT NULL,             -- epoch seconds (client-provided; may be backdated)
  activity_id   INTEGER REFERENCES activities(id),
  kind          TEXT NOT NULL,             -- afk_on/off, cc_stop/submit, activity_open/close, pause_*, force_owner
  payload       TEXT,
  source        TEXT NOT NULL              -- 'idle' | 'cc' | 'manual' | ...
);

-- Clients: mutable identity table. Referenced by id everywhere; name is cosmetic.
CREATE TABLE clients (
  id      INTEGER PRIMARY KEY,
  name    TEXT NOT NULL
  -- future: rate, currency (invoicing) — out of scope for v1
);

-- Project -> client billing rule. APPEND-ONLY. Latest row per project (by id) wins.
-- client_id NULL = tombstone (project explicitly unmapped).
CREATE TABLE project_client_map (
  id         INTEGER PRIMARY KEY,          -- monotonic; snapshot watermark
  project    TEXT NOT NULL,
  client_id  INTEGER REFERENCES clients(id),   -- NULL = unmapped
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

CREATE INDEX idx_events_ts       ON events(ts);
CREATE INDEX idx_events_activity ON events(activity_id, ts);
CREATE INDEX idx_map_project     ON project_client_map(project, id);

-- Enforce append-only at the DB level for the two source-of-truth tables.
CREATE TRIGGER events_immutable_u BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT,'append-only'); END;
CREATE TRIGGER events_immutable_d BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT,'append-only'); END;
CREATE TRIGGER map_immutable_u BEFORE UPDATE ON project_client_map BEGIN SELECT RAISE(ABORT,'append-only'); END;
CREATE TRIGGER map_immutable_d BEFORE DELETE ON project_client_map BEGIN SELECT RAISE(ABORT,'append-only'); END;
```

## Project ↔ client resolution

`project` is reported by the client (auto = cwd basename for cc; the daemon needs no mapping to record it). The billing client is resolved **at read time**, watermark-bounded:

```sql
-- effective (client_id, billable) for each project, at a given map watermark
SELECT project, client_id, billable FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY project ORDER BY id DESC) rn
  FROM project_client_map WHERE id <= :map_watermark
) WHERE rn = 1;
```

For any activity:

```
client(activity) = coalesce(
    activity.client_override,                         -- meetings/manual set this directly
    effective_map[activity.project].client_id,        -- cc & mapped projects
    NULL )                                             -- else "unassigned"
```

- **cc** reports only `project`; you tag that project's client **once** via the config UI/CLI, and it applies retroactively (and to every session in that project).
- **meeting / manual** may set `client_override` directly (and optionally a `project`) at creation.
- Unmapping a project = append a tombstone row (`client_id = NULL`); the resolver returns "unassigned".

## The computed segment (not a table)

```swift
struct Segment: Codable {
    let activityId: Int64
    let start: Double        // epoch seconds
    let end: Double
    let seconds: Double      // AFK/pause-subtracted
    let rule: String         // attribution rule that produced it
}
```

Client/project are not on the segment — they are resolved from the referenced activity when a consumer groups or filters.

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
- `segments_digest` lets a re-derivation be **verified** (recompute, hash, compare) — a mismatch flags code drift for that version.
- **Client names are deliberately not watermarked** (per the mutable-clients decision): reproduction pins client *identity* via the map watermark, but resolves the current *name*. Renames are cosmetic corrections and are meant to propagate.

## Migrations

Schema versioned in a `schema_version` meta table; forward-only migrations on startup. Nothing derived is stored, so migrations only ever touch these base tables — never a cache.
