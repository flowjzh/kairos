import CSQLite
import Foundation
import KairosCore

/// The single writer and sole holder of the SQLite handle. An actor: all
/// access is serialized, satisfying the single-writer constraint (docs/03).
/// The daemon, idle sampler, and config window all route through this.
public actor Store {
    private let db: SQLiteConnection
    private var changeContinuation: AsyncStream<Void>.Continuation?

    /// The live-state read window (ADR 37): `loadGlobalEvents(since:)` loads only
    /// the last `liveWindow` seconds, so its cost is independent of total table
    /// size. 30 d — large enough that a focus/afk/pause open longer than this is
    /// pathological (the machine slept/restarted).
    public static let liveWindow: Double = 30 * 86_400

    public init(path: String) throws {
        self.db = try SQLiteConnection(path: path)
        try self.db.migrate()
    }

    // MARK: Change signal (event-driven refresh)

    /// A stream that yields after every write, so the menu bar can refresh on
    /// change instead of polling. One active consumer (the daemon); a new call
    /// supersedes the previous stream.
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

    /// Record a source's human-facing display name (the plugin owns its label,
    /// M4p3). Upserts the source and sets `display_name`.
    public func setSourceDisplayName(slug: String, displayName: String) throws {
        let stmt = try db.prepare("INSERT INTO sources (slug, display_name) VALUES (?, ?) ON CONFLICT(slug) DO UPDATE SET display_name=excluded.display_name")
        try stmt.bind([.text(slug), .text(displayName)])
        _ = try stmt.step()
    }

    private func lookupSource(slug: String) throws -> Int64? {
        let stmt = try db.prepare("SELECT id FROM sources WHERE slug=?")
        try stmt.bind([.text(slug)])
        if try stmt.step() { return stmt.columnInt64(0) }
        return nil
    }

    // MARK: Events

    public func appendEvent(activityId: Int64?, kind: EventKind, ts: Double, payload: Data? = nil) throws -> Int64 {
        let stmt = try db.prepare("INSERT INTO events (ts, activity_id, kind, payload) VALUES (?, ?, ?, ?) RETURNING id")
        try stmt.bind([
            .double(ts),
            activityId.map { .int($0) } ?? .null,
            .int(Int64(kind.rawValue)),
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

    /// The kind of the most recent afk event, or nil if there is none. `.afkOn`
    /// means a span is open (dangling) — used at startup to reconcile a kill that
    /// left `afk_on` without its `afk_off`.
    public func lastAfkEventKind() throws -> EventKind? {
        let stmt = try db.prepare("SELECT kind FROM events WHERE kind IN (\(EventKind.afkOn.rawValue), \(EventKind.afkOff.rawValue)) ORDER BY id DESC LIMIT 1")
        guard try stmt.step() else { return nil }
        return EventKind(rawValue: Int(stmt.columnInt64(0)))
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

    /// Create-or-resume an activity (M4p3): idempotent on `(source, external_id)`.
    /// A matching row (e.g. an `archived` claude session resumed by the same
    /// `claude_sid`) is flipped back to `visible` and returned; a NULL
    /// `externalId` (menu/manual) always creates a new row. Writes **no event** —
    /// timing/placement is derived from `focus`/`blur`; `state` is just visibility.
    public func startActivity(source: String, externalId: String?, project: String?, title: String?, metadata: Data?) throws -> Int64 {
        let sourceId = try resolveSource(slug: source)
        let projectId = try project.map { try resolveProject(slug: $0) }
        if let externalId, let existing = try findActivity(source: source, externalId: externalId) {
            try setActivityState(activityId: existing, .visible)
            return existing
        }
        return try insertActivity(sourceId: sourceId, externalId: externalId, projectId: projectId, title: title, metadata: metadata)
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
        if try stmt.step() { let id = stmt.columnInt64(0); signalChange(); return id }
        throw StoreError.sqlite(message: "insert activity returned no row")
    }

    /// Set an activity's visibility (`visible`/`archived`), ADR 37. Mutable, not
    /// watermarked, never read by attribution — `activities.stop` archives an
    /// exited session; archiving hides any activity. Placement is derived from
    /// events, not this column.
    public func setActivityState(activityId: Int64, _ state: ActivityState) throws {
        let stmt = try db.prepare("UPDATE activities SET state=? WHERE id=?")
        try stmt.bind([.int(Int64(state.rawValue)), .int(activityId)])
        _ = try stmt.step()
        signalChange()
    }

    /// Enrich a wrapper-created `pty` shell into an agent activity (Design B race
    /// fallback, M4p3): re-point its source/external_id/project/title/metadata and
    /// mark it visible. Keeps the id, so focus events already on the shell stay.
    public func enrichActivity(activityId: Int64, source: String, externalId: String?, project: String?, title: String?, metadata: Data?) throws {
        let sourceId = try resolveSource(slug: source)
        let projectId = try project.map { try resolveProject(slug: $0) }
        let stmt = try db.prepare("UPDATE activities SET source_id=?, external_id=?, project_id=COALESCE(?, project_id), title=COALESCE(?, title), metadata=COALESCE(?, metadata), state=? WHERE id=?")
        try stmt.bind([
            .int(sourceId),
            externalId.map { .text($0) } ?? .null,
            projectId.map { .int($0) } ?? .null,
            title.map { .text($0) } ?? .null,
            try jsonTextValue(metadata),
            .int(Int64(ActivityState.visible.rawValue)),
            .int(activityId),
        ])
        _ = try stmt.step()
        signalChange()
    }

    /// Reconcile a wrapper-created shell with an agent's `activities.start`
    /// (Design B, M4p3). One place owns "which activity wins", returning its id:
    ///   1. a pre-existing `(source, external_id)` row (e.g. a resumed session) —
    ///      resume it, and retire the now-redundant shell if one was spawned;
    ///   2. else the shell, enriched in place into this agent activity (keeps its
    ///      id, so a launch `focus` already on it stays attributed here);
    ///   3. else a fresh activity (no shell, no prior row).
    /// `shellId` is the kid's current activity when it is a different source than
    /// `source` (a `pty` shell to adopt), else nil.
    ///
    /// Corner (rare): in case 1 the shell's launch-`focus` interval stays on the
    /// `pty` source — the append-only log forbids re-homing it — so a few seconds
    /// before a *resumed* session is recognised bill to `pty`, not the agent.
    public func adoptOrStart(shellId: Int64?, source: String, externalId: String?, project: String?, title: String?, metadata: Data?) throws -> Int64 {
        // A `shellId` is only an adoptable shell if it is a *different* source
        // (a `pty` shell an agent hook is now claiming); a same-source id is the
        // activity itself, handled by the resume/start branches below.
        let shell = try shellId.flatMap { id -> Int64? in
            try loadActivity(id: id).flatMap { $0.source != source ? id : nil }
        }
        if let externalId, let existing = try findActivity(source: source, externalId: externalId) {
            try setActivityState(activityId: existing, .visible)
            if let shell, shell != existing { try setActivityState(activityId: shell, .archived) }
            return existing
        }
        if let shell {
            try enrichActivity(activityId: shell, source: source, externalId: externalId, project: project, title: title, metadata: metadata)
            return shell
        }
        return try startActivity(source: source, externalId: externalId, project: project, title: title, metadata: metadata)
    }

    /// Append an activity-scoped event. Verifies the activity exists (else
    /// `notFound`); the event's source is the activity's, joined on read (ADR 38).
    /// Used for `focus`/`blur`/`activity_override` where the caller has only the id.
    public func appendActivityEvent(activityId: Int64, kind: EventKind, ts: Double, payload: Data? = nil) throws {
        let stmt = try db.prepare("SELECT 1 FROM activities WHERE id=?")
        try stmt.bind([.int(activityId)])
        guard try stmt.step() else { throw StoreError.notFound("activity \(activityId)") }
        _ = try appendEvent(activityId: activityId, kind: kind, ts: ts, payload: payload)
    }

    /// Is this activity's source `manual` (backdrop-eligible)? Gates auto-catch:
    /// a foreground (auto) blur falls back to a backdrop; a manual one does not.
    public func isActivityManual(activityId: Int64) throws -> Bool {
        let stmt = try db.prepare("SELECT s.manual FROM activities a JOIN sources s ON s.id = a.source_id WHERE a.id=?")
        try stmt.bind([.int(activityId)])
        return try stmt.step() ? stmt.columnInt64(0) != 0 : false
    }

    /// Ids of all manual-source activities (visible or archived). Feeds grace's
    /// `manualIds` gate so absorb/pending skip manuals — a manual's blur is an
    /// intentional stop, never a grace-eligible excursion.
    public func manualActivityIds() throws -> Set<Int64> {
        let stmt = try db.prepare("SELECT a.id FROM activities a JOIN sources s ON s.id = a.source_id WHERE s.manual = 1")
        var ids = Set<Int64>()
        while try stmt.step() { ids.insert(stmt.columnInt64(0)) }
        return ids
    }

    // MARK: Helpers

    /// The activity SELECT fragment. Column order is a contract for the two
    /// position-indexed readers below — `readActivityRow` (0-5, 7-8; it skips
    /// `project_id` at 6, which only `loadActivities` reads) and `loadActivities`
    /// (0-6). Reordering this SELECT silently corrupts both; update together.
    private static let activitySelect = """
        SELECT a.id, s.slug, a.external_id, p.slug, a.title, a.metadata, a.project_id, s.manual, s.display_name
        FROM activities a
        JOIN sources s ON s.id = a.source_id
        LEFT JOIN projects p ON p.id = a.project_id
        """

    /// The event SELECT fragment — column order is the contract for `readEventRow`.
    private static let eventSelect = "SELECT id, ts, activity_id, kind, payload FROM events"

    /// Comma-joined rawValues of the event kinds `GlobalState.reduce` reads,
    /// for the `WHERE kind IN (…)` of `loadGlobalEvents` (a literal, not rebuilt per call).
    private static let globalEventKinds = [EventKind.focus, .blur, .afkOn, .afkOff, .pauseOn, .pauseOff]
        .map { String($0.rawValue) }.joined(separator: ",")

    private func readActivityRow(_ stmt: SQLiteStatement) -> ActivityRecord {
        ActivityRecord(
            id: stmt.columnInt64(0),
            source: stmt.columnText(1) ?? "",
            externalId: stmt.columnText(2),
            project: stmt.columnText(3),
            title: stmt.columnText(4),
            metadata: stmt.columnUTF8Data(5),
            manual: stmt.columnInt64(7) != 0,
            displayName: stmt.columnText(8) ?? ""
        )
    }

    /// Hydrate one event from a `SELECT id, ts, activity_id, kind, payload` row;
    /// nil for an unknown kind (forward-compat with new event kinds a reader
    /// doesn't recognise).
    private func readEventRow(_ stmt: SQLiteStatement) -> Event? {
        guard let kind = EventKind(rawValue: Int(stmt.columnInt64(3))) else { return nil }
        return Event(
            id: stmt.columnInt64(0),
            ts: stmt.columnDouble(1),
            activityId: stmt.columnIsNull(2) ? nil : stmt.columnInt64(2),
            kind: kind,
            payload: stmt.columnUTF8Data(4)
        )
    }

    /// Run a `SELECT … FROM events` (the columns must match `readEventRow`) and
    /// collect the rows, skipping forward-compat unknown kinds.
    private func queryEvents(_ sql: String, _ values: [SQLValue] = []) throws -> [Event] {
        let stmt = try db.prepare(sql)
        try stmt.bind(values)
        var events: [Event] = []
        while try stmt.step() { if let e = readEventRow(stmt) { events.append(e) } }
        return events
    }

    /// Run a `\(activitySelect) …` query and collect the activity rows.
    private func queryActivities(_ sql: String) throws -> [ActivityRecord] {
        let stmt = try db.prepare(sql)
        var result: [ActivityRecord] = []
        while try stmt.step() { result.append(readActivityRow(stmt)) }
        return result
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

    /// Watermark-bounded load for snapshot reproduction / future external
    /// readers — no internal caller yet (snapshots are reserved, docs/03).
    public func loadEvents(upToWatermark wm: Int64? = nil, beforeTs: Double? = nil) throws -> [Event] {
        var sql = "\(Self.eventSelect)"
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let wm { clauses.append("id <= ?"); values.append(.int(wm)) }
        if let ts = beforeTs { clauses.append("ts <= ?"); values.append(.double(ts)) }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        return try queryEvents(sql + " ORDER BY id", values)
    }

    /// Only the events `GlobalState.reduce` consumes — `focus`/`blur` and the
    /// global afk/pause spans. `since` bounds the read to a recent window so the
    /// cost is independent of total table size (`idx_events_ts` range scan); the
    /// reducer's current-state answer is correct as long as no focus/afk/pause
    /// span is open from before `since` (a month-long open span is pathological —
    /// see ADR 37). Billing uses the full-range `loadEventsInRange`.
    public func loadGlobalEvents(since: Double) throws -> [Event] {
        // `ORDER BY ts` (not id) so `idx_events_ts` serves the `ts >= ?` range as an
        // indexed SEARCH rather than a full SCAN; the reducer re-sorts by (ts, id).
        try queryEvents("\(Self.eventSelect) WHERE kind IN (\(Self.globalEventKinds)) AND ts >= ? ORDER BY ts", [.double(since)])
    }

    /// All events with `ts <= to` (global and activity-scoped). Attribution
    /// clips to `[from, to]`, and an open focus/afk/pause span opened before
    /// `from` must still be seen, so the lower bound is not applied here.
    /// Over-inclusion is safe; at this volume (docs/03) loading is milliseconds.
    public func loadEventsInRange(from: Double, to: Double) throws -> [Event] {
        try queryEvents("\(Self.eventSelect) WHERE ts <= ? ORDER BY id", [.double(to)])
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

    /// Visible (non-archived) activities — the menu base. Placement into
    /// Ongoing/Upcoming/Recent is derived from the focus/blur log by
    /// `ActivityBuckets`, not stored (ADR 37). Manual activities sort above auto.
    public func visibleActivities() throws -> [ActivityRecord] {
        try queryActivities("\(Self.activitySelect) WHERE a.state != \(ActivityState.archived.rawValue) ORDER BY s.manual DESC, a.id")
    }

    /// Visible **manual** activities — the auto-catch backdrop candidates (a
    /// caller further filters to those still ongoing).
    public func visibleManualActivities() throws -> [ActivityRecord] {
        try queryActivities("\(Self.activitySelect) WHERE a.state != \(ActivityState.archived.rawValue) AND s.manual = 1 ORDER BY a.id")
    }

    // MARK: segments.get pipeline (store → attribution → resolved clients)

    /// Load range-relevant events, compute attributed segments, batch-resolve
    /// each distinct activity's record + client/billable in a handful of
    /// queries (not N+1), and optionally filter by project/client.
    public func attributedSegments(from: Double, to: Double, project: String? = nil, client: Int64? = nil) throws -> AttributedSegments {
        let events = try loadEventsInRange(from: from, to: to)
        // Absorb grace-eligible blurs before attribution (ADR 39): an auto
        // activity's brief blur-to-void + same-activity re-focus within grace
        // becomes one continuous span. Manuals are excluded via `manualIds`
        // (all manuals — billing attributes archived activities too).
        let manualIds = (try? manualActivityIds()) ?? []
        let view = Grace.absorbedView(events: events, grace: AppSettings.grace, manualIds: manualIds)
        let computed = Attribution.compute(events: view, from: from, to: to)
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
              WHERE kind = \(EventKind.activityOverride.rawValue) AND id <= ? AND activity_id IN (\(placeholders(ids.count)))
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
