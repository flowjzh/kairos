import Foundation

/// The v1 schema (docs/03). Identity tables (sources/projects/clients) are
/// mutable and not watermarked; events and project_client_map are append-only
/// (enforced by triggers); snapshots stores recipes, not segments.
enum Schema {
    static let v1 = #"""
        CREATE TABLE sources (
          id           INTEGER PRIMARY KEY,
          slug         TEXT NOT NULL UNIQUE,
          display_name TEXT NOT NULL,
          manual       INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE projects (
          id           INTEGER PRIMARY KEY,
          slug         TEXT NOT NULL UNIQUE,
          display_name TEXT NOT NULL
        );

        CREATE TABLE clients (
          id   INTEGER PRIMARY KEY,
          name TEXT NOT NULL
        );

        CREATE TABLE activities (
          id           INTEGER PRIMARY KEY,
          source_id    INTEGER NOT NULL REFERENCES sources(id),
          external_id  TEXT,
          project_id   INTEGER REFERENCES projects(id),
          title        TEXT,
          metadata     TEXT,
          state        INTEGER NOT NULL DEFAULT 0,  -- 0=visible, 1=archived (ADR 37; placement is derived from events)
          UNIQUE (source_id, external_id)
        );

        CREATE TABLE events (
          id           INTEGER PRIMARY KEY,
          ts           REAL NOT NULL,
          activity_id  INTEGER REFERENCES activities(id),
          source_id    INTEGER NOT NULL REFERENCES sources(id),
          kind         INTEGER NOT NULL,
          payload      TEXT
        );

        CREATE TABLE project_client_map (
          id         INTEGER PRIMARY KEY,
          project_id INTEGER NOT NULL REFERENCES projects(id),
          client_id  INTEGER REFERENCES clients(id),
          billable   INTEGER NOT NULL DEFAULT 1,
          created_at REAL NOT NULL
        );

        CREATE TABLE snapshots (
          id                  INTEGER PRIMARY KEY,
          label               TEXT,
          range_start         REAL NOT NULL,
          range_end           REAL NOT NULL,
          params              TEXT NOT NULL,
          attribution_version TEXT NOT NULL,
          watermarks          TEXT NOT NULL,
          segments_digest     TEXT,
          generated_at        REAL NOT NULL
        );

        CREATE INDEX idx_events_ts       ON events(ts);
        CREATE INDEX idx_events_activity ON events(activity_id, ts);
        CREATE INDEX idx_events_source   ON events(source_id);
        CREATE INDEX idx_activities_source ON activities(source_id);
        CREATE INDEX idx_map_project     ON project_client_map(project_id, id);

        CREATE TRIGGER events_immutable_u BEFORE UPDATE ON events
          BEGIN SELECT RAISE(ABORT,'append-only'); END;
        CREATE TRIGGER events_immutable_d BEFORE DELETE ON events
          BEGIN SELECT RAISE(ABORT,'append-only'); END;
        CREATE TRIGGER map_immutable_u BEFORE UPDATE ON project_client_map
          BEGIN SELECT RAISE(ABORT,'append-only'); END;
        CREATE TRIGGER map_immutable_d BEFORE DELETE ON project_client_map
          BEGIN SELECT RAISE(ABORT,'append-only'); END;

        -- Built-in sources. `manual` (user-managed, backdrop-eligible) is the one
        -- manual source; auto sources (claude-code, pty, ...) default to
        -- manual=0. Display names here are English placeholders — the v4 migration
        -- rewrites them to the host locale's labels (`SourceLabels`).
        INSERT INTO sources (slug, display_name, manual) VALUES ('manual', 'Manual', 1);
        INSERT INTO sources (slug, display_name, manual) VALUES ('pty', 'Terminal', 0);
    """#
}
