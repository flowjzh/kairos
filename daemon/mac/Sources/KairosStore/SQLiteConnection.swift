import CSQLite
import Foundation

/// A bound value for a prepared statement.
enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// A thin wrapper over a sqlite3 connection. Non-Sendable; owned and
/// accessed solely from within the `Store` actor, which serializes all use.
final class SQLiteConnection {
    private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open(path, &handle)
        if rc != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open failed"
            if handle != nil { sqlite3_close(handle) }
            throw StoreError.sqlite(message: msg)
        }
        guard let db = handle else { throw StoreError.sqlite(message: "sqlite3_open returned nil") }
        self.db = db
        // WAL is a no-op on :memory: dbs (single connection); harmless otherwise.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close(db) }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(db)) }

    /// Rows modified by the most recent INSERT/UPDATE/DELETE on this connection.
    var changes: Int32 { sqlite3_changes(db) }

    @discardableResult
    func exec(_ sql: String) throws -> Self {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw StoreError.sqlite(message: lastErrorMessage)
        }
        return self
    }

    /// Prepare a fresh statement. Each call returns a new statement finalized
    /// when it goes out of scope — which commits its (autocommit) transaction.
    /// A shared statement cache is deliberately NOT used: our `INSERT …
    /// RETURNING` writes step once to read the id and return without reaching
    /// `SQLITE_DONE`, so a retained/cached statement would leave the write's
    /// transaction uncommitted (nothing reaches the WAL) and its open cursor
    /// would block checkpoints. Re-parsing is negligible at this volume.
    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(sql, on: db)
    }

    /// First column of the first row as Int64, or 0 if no row.
    func scalarInt(_ sql: String) throws -> Int64 {
        let stmt = try prepare(sql)
        if try stmt.step() {
            return stmt.columnInt64(0)
        }
        return 0
    }

    func migrate() throws {
        try exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL, applied_at REAL NOT NULL);")
        let current = try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_version;")
        if current < 1 {
            try exec(Schema.v1)
            try exec("INSERT INTO schema_version (version, applied_at) VALUES (1, \(Date().timeIntervalSince1970));")
        }
        if current < 2 {
            // Collapse activities.state to a visibility flag (ADR 37): the old
            // active(0)/stopped(1)/archived(2) → visible(0)/archived(1). A stopped
            // *manual* becomes visible (it shows in Recent, derived from its blur);
            // a stopped *auto* (exited session) and archived rows become archived.
            try exec("""
                UPDATE activities SET state = CASE
                    WHEN state = 2 OR (state = 1 AND source_id IN (SELECT id FROM sources WHERE manual = 0)) THEN 1
                    ELSE 0
                END;
                """)
            try exec("INSERT INTO schema_version (version, applied_at) VALUES (2, \(Date().timeIntervalSince1970));")
        }
    }
}

/// A prepared statement. Bind, step, read columns. Finalized on deinit.
final class SQLiteStatement {
    private let stmt: OpaquePointer
    private let db: OpaquePointer

    init(_ sql: String, on db: OpaquePointer) throws {
        self.db = db
        var s: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &s, nil) != SQLITE_OK {
            throw StoreError.sqlite(message: String(cString: sqlite3_errmsg(db)))
        }
        guard let stmt = s else { throw StoreError.sqlite(message: "prepare returned nil") }
        self.stmt = stmt
    }

    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    func bind(_ values: [SQLValue]) throws -> Self {
        sqlite3_reset(stmt)
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .null:
                sqlite3_bind_null(stmt, idx)
            case .int(let n):
                sqlite3_bind_int64(stmt, idx, n)
            case .double(let d):
                sqlite3_bind_double(stmt, idx, d)
            case .text(let s):
                try s.withCString { cstr in
                    if sqlite3_bind_text(stmt, idx, cstr, -1, kairos_sqlite_transient()) != SQLITE_OK {
                        throw StoreError.sqlite(message: String(cString: sqlite3_errmsg(db)))
                    }
                }
            case .blob(let data):
                _ = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                    sqlite3_bind_blob(stmt, idx, bytes.baseAddress, Int32(bytes.count), kairos_sqlite_transient())
                }
            }
        }
        return self
    }

    /// Returns true for a row (SQLITE_ROW), false when done (SQLITE_DONE).
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw StoreError.sqlite(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    func columnInt64(_ index: Int32) -> Int64 { sqlite3_column_int64(stmt, index) }
    func columnDouble(_ index: Int32) -> Double { sqlite3_column_double(stmt, index) }
    func columnText(_ index: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }
    /// A TEXT column decoded as UTF-8 `Data` (for JSON payload/metadata columns).
    func columnUTF8Data(_ index: Int32) -> Data? {
        columnText(index).flatMap { $0.data(using: .utf8) }
    }
    func columnBlob(_ index: Int32) -> Data? {
        let count = sqlite3_column_bytes(stmt, index)
        guard count > 0, let pointer = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: pointer, count: Int(count))
    }
    func columnIsNull(_ index: Int32) -> Bool {
        sqlite3_column_type(stmt, index) == SQLITE_NULL
    }
}
