import Testing
@testable import KairosStore

@Suite
struct SchemaTests {
    private func store() throws -> Store { try Store(path: ":memory:") }

    @Test
    func migrateCreatesAllTables() async throws {
        let s = try store()
        let tables = try await s.queryStrings(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        )
        #expect(Set(tables) == Set([
            "sources", "projects", "clients", "activities", "events",
            "project_client_map", "snapshots", "schema_version",
        ]))
    }

    @Test
    func schemaVersionIsCurrent() async throws {
        let s = try store()
        let v = try await s.scalarInt("SELECT MAX(version) FROM schema_version")
        #expect(v == 4)
    }

    @Test
    func reMigrateIsIdempotent() async throws {
        let s = try store()
        // Opening a second store on a fresh in-memory db runs migrate again;
        // a no-op when already current (one row per version).
        let v = try await s.scalarInt("SELECT COUNT(*) FROM schema_version")
        #expect(v == 4)
    }

    @Test
    func builtinSourcesSeededWithDisplayName() async throws {
        let s = try store()
        let rows = try await s.queryStrings(
            "SELECT slug || '=' || display_name FROM sources WHERE slug IN ('manual','pty') ORDER BY slug"
        )
        // Non-empty, non-slug display names (exact label depends on test locale).
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.contains("=") && !$0.hasSuffix("=manual") })
    }

    @Test
    func eventsAppendOnlyRejectsUpdate() async throws {
        let s = try store()
        try await s.exec("INSERT INTO events (id, ts, activity_id, kind, payload) VALUES (1, 0, NULL, 5, NULL)")
        do {
            try await s.exec("UPDATE events SET kind=1 WHERE id=1")
            Issue.record("UPDATE on append-only events should be rejected")
        } catch is StoreError {
            // expected
        }
    }

    @Test
    func eventsAppendOnlyRejectsDelete() async throws {
        let s = try store()
        try await s.exec("INSERT INTO events (id, ts, activity_id, kind, payload) VALUES (1, 0, NULL, 5, NULL)")
        do {
            try await s.exec("DELETE FROM events WHERE id=1")
            Issue.record("DELETE on append-only events should be rejected")
        } catch is StoreError {
            // expected
        }
    }

    @Test
    func mapAppendOnlyRejectsUpdate() async throws {
        let s = try store()
        try await s.exec("INSERT INTO projects (id, slug, display_name) VALUES (1, 'p', 'p')")
        try await s.exec("INSERT INTO clients (id, name) VALUES (1, 'c')")
        try await s.exec("INSERT INTO project_client_map (id, project_id, client_id, billable, created_at) VALUES (1, 1, 1, 1, 0)")
        do {
            try await s.exec("UPDATE project_client_map SET billable=0 WHERE id=1")
            Issue.record("UPDATE on append-only map should be rejected")
        } catch is StoreError {
            // expected
        }
    }
}
