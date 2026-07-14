import CSQLite
import Foundation
import KairosCore

/// The single writer and sole holder of the SQLite handle. An actor: all
/// access is serialized, satisfying the single-writer constraint (docs/03).
/// The daemon, idle sampler, and config window all route through this.
public actor Store {
    private let db: SQLiteConnection
    private var changeContinuation: AsyncStream<Void>.Continuation?

    public init(path: String) throws {
        self.db = try SQLiteConnection(path: path)
        try self.db.migrate()
    }

    // MARK: Change signal (event-driven menu refresh)

    /// A stream that yields once after every write, so the menu bar can refresh
    /// on change instead of polling. One active consumer (the daemon); a new
    /// call supersedes the previous stream.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        changeContinuation = continuation
        return stream
    }

    private func signalChange() {
        changeContinuation?.yield()
    }

    /// Fold the WAL back into the main database file. WAL frames are durable on
    /// disk, but an abrupt daemon exit (launchd SIGTERM/SIGKILL, no clean
    /// `sqlite3_close`) can leave them uncheckpointed; a periodic checkpoint
    /// keeps the main file current so data survives restarts. Cheap at this
    /// volume. TRUNCATE also stops the WAL growing unbounded.
    public func checkpoint() throws {
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Diagnostic: the active journal mode (expect "wal").
    public func journalMode() throws -> String {
        let stmt = try db.prepare("PRAGMA journal_mode;")
        return try stmt.step() ? (stmt.columnText(0) ?? "?") : "?"
    }

    // MARK: Low-level (internal, for migration/tests)

    internal func exec(_ sql: String) throws {
        try db.exec(sql)
    }

    internal func scalarInt(_ sql: String) throws -> Int64 {
        try db.scalarInt(sql)
    }

    internal func queryStrings(_ sql: String) throws -> [String] {
        let stmt = try db.prepare(sql)
        var result: [String] = []
        while try stmt.step() {
            if let s = stmt.columnText(0) { result.append(s) }
        }
        return result
    }

    // MARK: Sources & projects (auto-register by slug)

    public func resolveSource(slug: String) throws -> Int64 {
        try upsertIdentity(table: "sources", slug: slug)
    }

    public func resolveProject(slug: String) throws -> Int64 {
        try upsertIdentity(table: "projects", slug: slug)
    }

    private func upsertIdentity(table: String, slug: String) throws -> Int64 {
        let stmt = try db.prepare("INSERT INTO \(table) (slug, display_name) VALUES (?, ?) ON CONFLICT(slug) DO UPDATE SET slug=slug RETURNING id")
        try stmt.bind([.text(slug), .text(slug)])
        if try stmt.step() { return stmt.columnInt64(0) }
        throw StoreError.sqlite(message: "upsert \(table) returned no row")
    }

    private func lookupSource(slug: String) throws -> Int64? {
        let stmt = try db.prepare("SELECT id FROM sources WHERE slug=?")
        try stmt.bind([.text(slug)])
        if try stmt.step() { return stmt.columnInt64(0) }
        return nil
    }

    // MARK: Events

    public func appendEvent(activityId: Int64?, sourceId: Int64, kind: EventKind, ts: Double, payload: Data? = nil) throws -> Int64 {
        let stmt = try db.prepare("INSERT INTO events (ts, activity_id, source_id, kind, payload) VALUES (?, ?, ?, ?, ?) RETURNING id")
        try stmt.bind([
            .double(ts),
            activityId.map { .int($0) } ?? .null,
            .int(sourceId),
            .text(kind.rawValue),
            try jsonTextValue(payload),
        ])
        if try stmt.step() {
            let id = stmt.columnInt64(0)
            signalChange()
            return id
        }
        throw StoreError.sqlite(message: "insert event returned no row")
    }

    public func eventsWatermark() throws -> Int64 {
        try db.scalarInt("SELECT COALESCE(MAX(id), 0) FROM events")
    }

    /// Timestamp of the most recent event (for restart-gap detection).
    public func lastEventTs() throws -> Double? {
        let stmt = try db.prepare("SELECT MAX(ts) FROM events")
        if try stmt.step() {
            return stmt.columnIsNull(0) ? nil : stmt.columnDouble(0)
        }
        return nil
    }

    public func mapWatermark() throws -> Int64 {
        try db.scalarInt("SELECT COALESCE(MAX(id), 0) FROM project_client_map")
    }

    // MARK: Activities

    public func findActivity(source: String, externalId: String) throws -> Int64? {
        guard let sourceId = try lookupSource(slug: source) else { return nil }
        let stmt = try db.prepare("SELECT id FROM activities WHERE source_id=? AND external_id=?")
        try stmt.bind([.int(sourceId), .text(externalId)])
        if try stmt.step() { return stmt.columnInt64(0) }
        return nil
    }

    /// Idempotent on `(source, external_id)` when `externalId` is non-nil:
    /// re-opening returns the existing id and emits no new `activity_open`
    /// event. A NULL `externalId` (meeting/manual) always creates a new row.
    public func openActivity(source: String, externalId: String?, project: String?, title: String?, metadata: Data?, ts: Double) throws -> Int64 {
        let sourceId = try resolveSource(slug: source)
        let projectId = try project.map { try resolveProject(slug: $0) }
        if let externalId, let existing = try findActivity(source: source, externalId: externalId) {
            return existing
        }
        let id = try insertActivity(sourceId: sourceId, externalId: externalId, projectId: projectId, title: title, metadata: metadata)
        _ = try appendEvent(activityId: id, sourceId: sourceId, kind: .activityOpen, ts: ts, payload: nil)
        return id
    }

    private func insertActivity(sourceId: Int64, externalId: String?, projectId: Int64?, title: String?, metadata: Data?) throws -> Int64 {
        let stmt = try db.prepare("INSERT INTO activities (source_id, external_id, project_id, title, metadata) VALUES (?, ?, ?, ?, ?) RETURNING id")
        try stmt.bind([
            .int(sourceId),
            externalId.map { .text($0) } ?? .null,
            projectId.map { .int($0) } ?? .null,
            title.map { .text($0) } ?? .null,
            try jsonTextValue(metadata),
        ])
        if try stmt.step() { return stmt.columnInt64(0) }
        throw StoreError.sqlite(message: "insert activity returned no row")
    }

    public func closeActivity(activityId: Int64, ts: Double) throws {
        let stmt = try db.prepare("SELECT source_id FROM activities WHERE id=?")
        try stmt.bind([.int(activityId)])
        guard try stmt.step() else { throw StoreError.notFound("activity \(activityId)") }
        let sourceId = stmt.columnInt64(0)
        _ = try appendEvent(activityId: activityId, sourceId: sourceId, kind: .activityClose, ts: ts, payload: nil)
    }

    // MARK: Helpers

    private static let activitySelect = """
        SELECT a.id, s.slug, a.external_id, p.slug, a.title, a.metadata, a.project_id
        FROM activities a
        JOIN sources s ON s.id = a.source_id
        LEFT JOIN projects p ON p.id = a.project_id
        """

    private func readActivityRow(_ stmt: SQLiteStatement) -> ActivityRecord {
        ActivityRecord(
            id: stmt.columnInt64(0),
            source: stmt.columnText(1) ?? "",
            externalId: stmt.columnText(2),
            project: stmt.columnText(3),
            title: stmt.columnText(4),
            metadata: stmt.columnUTF8Data(5)
        )
    }

    /// Hydrate one event from a `SELECT id, ts, activity_id, source_id, kind,
    /// payload` row; nil for an unknown kind (forward-compat with new event
    /// kinds a reader doesn't recognise).
    private func readEventRow(_ stmt: SQLiteStatement) -> Event? {
        guard let kind = EventKind(rawValue: stmt.columnText(4) ?? "") else { return nil }
        return Event(
            id: stmt.columnInt64(0),
            ts: stmt.columnDouble(1),
            activityId: stmt.columnIsNull(2) ? nil : stmt.columnInt64(2),
            kind: kind,
            sourceId: stmt.columnInt64(3),
            payload: stmt.columnUTF8Data(5)
        )
    }

    private func readClientBillable(_ stmt: SQLiteStatement, clientAt: Int32, billableAt: Int32) -> (clientId: Int64?, billable: Bool) {
        let clientId: Int64? = stmt.columnIsNull(clientAt) ? nil : stmt.columnInt64(clientAt)
        return (clientId, stmt.columnInt64(billableAt) != 0)
    }

    private func jsonTextValue(_ data: Data?) throws -> SQLValue {
        guard let data else { return .null }
        guard let text = String(data: data, encoding: .utf8) else {
            throw StoreError.sqlite(message: "JSON value is not valid UTF-8")
        }
        return .text(text)
    }

    // MARK: Clients (mutable identity)

    public func addClient(name: String) throws -> Int64 {
        let stmt = try db.prepare("INSERT INTO clients (name) VALUES (?) RETURNING id")
        try stmt.bind([.text(name)])
        guard try stmt.step() else { throw StoreError.sqlite(message: "insert client returned no row") }
        signalChange()
        return stmt.columnInt64(0)
    }

    public func renameClient(id: Int64, name: String) throws {
        let stmt = try db.prepare("UPDATE clients SET name=? WHERE id=?")
        try stmt.bind([.text(name), .int(id)])
        _ = try stmt.step()
        if db.changes == 0 { throw StoreError.notFound("client \(id)") }
        signalChange()
    }

    public func listClients() throws -> [Client] {
        let stmt = try db.prepare("SELECT id, name FROM clients ORDER BY id")
        var result: [Client] = []
        while try stmt.step() {
            result.append(Client(id: stmt.columnInt64(0), name: stmt.columnText(1) ?? ""))
        }
        return result
    }

    /// All registered project slugs (for the config window's mapping picker).
    public func listProjects() throws -> [String] {
        let stmt = try db.prepare("SELECT slug FROM projects ORDER BY slug")
        var result: [String] = []
        while try stmt.step() { if let s = stmt.columnText(0) { result.append(s) } }
        return result
    }

    // MARK: Project → client mapping (append-only; latest row per project wins)

    public func setMapping(project: String, clientId: Int64?, billable: Bool) throws {
        let projectId = try resolveProject(slug: project)
        let stmt = try db.prepare("INSERT INTO project_client_map (project_id, client_id, billable, created_at) VALUES (?, ?, ?, ?)")
        try stmt.bind([
            .int(projectId),
            clientId.map { .int($0) } ?? .null,
            .int(billable ? 1 : 0),
            .double(Date().timeIntervalSince1970),
        ])
        _ = try stmt.step()
        signalChange()
    }

    public func listMapping() throws -> [ProjectMapping] {
        let sql = """
            SELECT p.slug, m.client_id, m.billable
            FROM (
              SELECT project_id, client_id, billable,
                     ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY id DESC) rn
              FROM project_client_map
            ) m JOIN projects p ON p.id = m.project_id
            WHERE rn = 1 ORDER BY p.slug
            """
        let stmt = try db.prepare(sql)
        var result: [ProjectMapping] = []
        while try stmt.step() {
            let cb = readClientBillable(stmt, clientAt: 1, billableAt: 2)
            result.append(ProjectMapping(project: stmt.columnText(0) ?? "", clientId: cb.clientId, billable: cb.billable))
        }
        return result
    }

    // MARK: Client resolution (override > map > unassigned), watermark-bounded

    public func resolveClient(activityId: Int64, eventsWatermark: Int64, mapWatermark: Int64) throws -> ResolvedClient {
        if let override = try latestOverrides(activityIds: [activityId], watermark: eventsWatermark)[activityId] {
            return override
        }
        guard let projectId = try loadActivities(ids: [activityId])[activityId]?.projectId else {
            return ResolvedClient(clientId: nil, billable: true)
        }
        return try effectiveMap(watermark: mapWatermark)[projectId] ?? ResolvedClient(clientId: nil, billable: true)
    }

    private static let overrideDecoder = JSONDecoder()

    private func parseOverride(_ payloadText: String) -> OverridePayload? {
        guard let data = payloadText.data(using: .utf8) else { return nil }
        return try? Self.overrideDecoder.decode(OverridePayload.self, from: data)
    }

    // MARK: Event reads (for attribution + watermark-bounded reproduction)

    public func loadEvents(upToWatermark wm: Int64? = nil, beforeTs: Double? = nil) throws -> [Event] {
        var sql = "SELECT id, ts, activity_id, source_id, kind, payload FROM events"
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let wm { clauses.append("id <= ?"); values.append(.int(wm)) }
        if let ts = beforeTs { clauses.append("ts <= ?"); values.append(.double(ts)) }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY id"

        let stmt = try db.prepare(sql)
        try stmt.bind(values)
        var events: [Event] = []
        while try stmt.step() { if let e = readEventRow(stmt) { events.append(e) } }
        return events
    }

    /// Events relevant to attributing `[from, to]`, bounded on the low end so
    /// the read scales with the range, not all history. Loads:
    /// - **every** event of any activity NOT closed before `from` (any `ts`) —
    ///   the whole set is needed to compute that activity's windows and even
    ///   its strategy signature; e.g. an ai window's closing `ai_submit` can
    ///   land after `to`, and dropping it would misclassify the session as
    ///   explicit (afk-immune) and mis-bill it;
    /// - all global (afk/pause) events `ts <= to` — low-volume, and an on-span
    ///   opened before `from` must still hole the range.
    /// Activities closed before `from` (their time is entirely past) are
    /// dropped — the history win. Over-inclusion is safe; under-inclusion is not.
    public func loadEventsInRange(from: Double, to: Double) throws -> [Event] {
        let sql = """
            SELECT id, ts, activity_id, source_id, kind, payload FROM events
            WHERE (activity_id IS NULL AND ts <= ?)
               OR (activity_id IN (
                     SELECT a.id FROM activities a
                     WHERE NOT EXISTS (
                       SELECT 1 FROM events c
                       WHERE c.activity_id = a.id AND c.kind = 'activity_close' AND c.ts < ?)))
            ORDER BY id
            """
        let stmt = try db.prepare(sql)
        try stmt.bind([.double(to), .double(from)])
        var events: [Event] = []
        while try stmt.step() { if let e = readEventRow(stmt) { events.append(e) } }
        return events
    }

    // MARK: Activity / client reads

    public func loadActivity(id: Int64) throws -> ActivityRecord? {
        let stmt = try db.prepare("\(Self.activitySelect) WHERE a.id = ?")
        try stmt.bind([.int(id)])
        guard try stmt.step() else { return nil }
        return readActivityRow(stmt)
    }

    public func loadClient(id: Int64) throws -> Client? {
        let stmt = try db.prepare("SELECT id, name FROM clients WHERE id=?")
        try stmt.bind([.int(id)])
        guard try stmt.step() else { return nil }
        return Client(id: stmt.columnInt64(0), name: stmt.columnText(1) ?? "")
    }

    /// Activities opened but not yet closed (for the menu bar / config window).
    public func openActivities() throws -> [ActivityRecord] {
        let stmt = try db.prepare("""
            \(Self.activitySelect)
            WHERE EXISTS (SELECT 1 FROM events e WHERE e.activity_id = a.id AND e.kind = 'activity_open')
              AND NOT EXISTS (SELECT 1 FROM events e WHERE e.activity_id = a.id AND e.kind = 'activity_close')
            ORDER BY a.id
            """)
        var result: [ActivityRecord] = []
        while try stmt.step() { result.append(readActivityRow(stmt)) }
        return result
    }

    /// Full records for the given activity ids (order preserved). Hydrates the
    /// open-activity set that `GlobalState` derives, so the menu reads one
    /// reduced state instead of re-deriving open-ness in SQL (ADR 21).
    public func activityRecords(ids: [Int64]) throws -> [ActivityRecord] {
        guard !ids.isEmpty else { return [] }
        let byId = try loadActivities(ids: ids)
        return ids.compactMap { byId[$0]?.record }
    }

    // MARK: segments.get pipeline (store → attribution → resolved clients)

    /// Load range-relevant events, compute attributed segments, batch-resolve
    /// each distinct activity's record + client/billable in a handful of
    /// queries (not N+1), and optionally filter by project/client.
    public func attributedSegments(from: Double, to: Double, project: String? = nil, client: Int64? = nil) throws -> AttributedSegments {
        let events = try loadEventsInRange(from: from, to: to)
        let computed = Attribution.compute(events: events, from: from, to: to)
        let ids = Array(Set(computed.map(\.activityId)))
        let details = try resolveDetails(activityIds: ids)

        var segments: [Segment] = []
        var activities: [Int64: ActivityDetail] = [:]
        for segment in computed {
            guard let d = details[segment.activityId] else { continue }
            if let project, d.record.project != project { continue }
            if let client, d.client.clientId != client { continue }
            segments.append(segment)
            activities[segment.activityId] = d
        }
        return AttributedSegments(segments: segments, activities: activities)
    }

    /// Resolve a set of activities to full detail (record + client) in bulk:
    /// one activity query, one override query, the effective map, and one client
    /// query — preserving `override > map > unassigned` and watermark bounds.
    private func resolveDetails(activityIds ids: [Int64]) throws -> [Int64: ActivityDetail] {
        guard !ids.isEmpty else { return [:] }
        let ewm = try eventsWatermark()
        let mwm = try mapWatermark()

        let records = try loadActivities(ids: ids)
        let overrides = try latestOverrides(activityIds: ids, watermark: ewm)
        let map = try effectiveMap(watermark: mwm)

        var resolved: [Int64: ResolvedClient] = [:]
        var neededClients: Set<Int64> = []
        for id in ids {
            let client = overrides[id] ?? records[id].flatMap { $0.projectId.flatMap { map[$0] } } ?? ResolvedClient(clientId: nil, billable: true)
            resolved[id] = client
            if let cid = client.clientId { neededClients.insert(cid) }
        }
        let names = try clientNames(ids: Array(neededClients))

        var details: [Int64: ActivityDetail] = [:]
        for id in ids {
            guard let record = records[id]?.record, let client = resolved[id] else { continue }
            details[id] = ActivityDetail(record: record, client: client, clientName: client.clientId.flatMap { names[$0] })
        }
        return details
    }

    private func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    private func loadActivities(ids: [Int64]) throws -> [Int64: (record: ActivityRecord, projectId: Int64?)] {
        let stmt = try db.prepare("\(Self.activitySelect) WHERE a.id IN (\(placeholders(ids.count)))")
        try stmt.bind(ids.map { .int($0) })
        var result: [Int64: (ActivityRecord, Int64?)] = [:]
        while try stmt.step() {
            let record = readActivityRow(stmt)
            let projectId: Int64? = stmt.columnIsNull(6) ? nil : stmt.columnInt64(6)
            result[record.id] = (record, projectId)
        }
        return result
    }

    private func latestOverrides(activityIds ids: [Int64], watermark: Int64) throws -> [Int64: ResolvedClient] {
        let stmt = try db.prepare("""
            SELECT activity_id, payload FROM (
              SELECT activity_id, payload,
                     ROW_NUMBER() OVER (PARTITION BY activity_id ORDER BY id DESC) rn
              FROM events
              WHERE kind = 'activity_override' AND id <= ? AND activity_id IN (\(placeholders(ids.count)))
            ) WHERE rn = 1
            """)
        try stmt.bind([.int(watermark)] + ids.map { .int($0) })
        var result: [Int64: ResolvedClient] = [:]
        while try stmt.step() {
            let activityId = stmt.columnInt64(0)
            if let text = stmt.columnText(1), let override = parseOverride(text) {
                result[activityId] = ResolvedClient(clientId: override.clientId, billable: override.billable ?? true)
            }
        }
        return result
    }

    private func effectiveMap(watermark: Int64) throws -> [Int64: ResolvedClient] {
        let stmt = try db.prepare("""
            SELECT project_id, client_id, billable FROM (
              SELECT project_id, client_id, billable,
                     ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY id DESC) rn
              FROM project_client_map WHERE id <= ?
            ) WHERE rn = 1
            """)
        try stmt.bind([.int(watermark)])
        var result: [Int64: ResolvedClient] = [:]
        while try stmt.step() {
            let cb = readClientBillable(stmt, clientAt: 1, billableAt: 2)
            result[stmt.columnInt64(0)] = ResolvedClient(clientId: cb.clientId, billable: cb.billable)
        }
        return result
    }

    private func clientNames(ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let stmt = try db.prepare("SELECT id, name FROM clients WHERE id IN (\(placeholders(ids.count)))")
        try stmt.bind(ids.map { .int($0) })
        var result: [Int64: String] = [:]
        while try stmt.step() { result[stmt.columnInt64(0)] = stmt.columnText(1) ?? "" }
        return result
    }
}
