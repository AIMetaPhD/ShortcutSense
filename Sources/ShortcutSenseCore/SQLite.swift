import CSQLite
import Foundation

public enum SQLiteError: Error, CustomStringConvertible, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case execFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let m): return "sqlite open failed: \(m)"
        case .prepareFailed(let m): return "sqlite prepare failed: \(m)"
        case .stepFailed(let m): return "sqlite step failed: \(m)"
        case .bindFailed(let m): return "sqlite bind failed: \(m)"
        case .execFailed(let m): return "sqlite exec failed: \(m)"
        }
    }
}

/// Minimal typed wrapper over system SQLite. Deliberately small: ShortcutSense
/// only needs prepared statements, integer/text binding and transactions.
final class Database {
    private(set) var handle: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError.openFailed(message)
        }
        self.handle = db
        // Observed on a real Mac: `pragma busy_timeout` reported 0 even though this
        // call was present, because the pragma is per-connection and the value is
        // only applied when the call succeeds. Verify it rather than assume.
        let busyStatus = sqlite3_busy_timeout(db, 5_000)
        if busyStatus != SQLITE_OK {
            throw SQLiteError.openFailed("could not set busy_timeout (status \(busyStatus))")
        }
    }

    deinit { close() }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if status != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "status \(status)"
            sqlite3_free(errorMessage)
            throw SQLiteError.execFailed(message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(stmt: stmt, db: self)
    }

    /// Runs `body` inside a transaction, rolling back on any thrown error.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Number of rows changed by the most recent INSERT/UPDATE/DELETE.
    var changes: Int32 { sqlite3_changes(handle) }

    func scalarInt(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int64 {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        guard try statement.step() else { return 0 }
        return statement.int(at: 0)
    }
}

enum SQLiteValue {
    case int(Int64)
    case text(String)
    case null

    static func int(_ value: Int) -> SQLiteValue { .int(Int64(value)) }
    static func bool(_ value: Bool) -> SQLiteValue { .int(value ? 1 : 0) }
}

final class Statement {
    private let stmt: OpaquePointer
    private unowned let db: Database

    init(stmt: OpaquePointer, db: Database) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .int(let number):
                status = sqlite3_bind_int64(stmt, index, number)
            case .text(let string):
                status = sqlite3_bind_text(stmt, index, string, -1, SQLITE_TRANSIENT)
            case .null:
                status = sqlite3_bind_null(stmt, index)
            }
            if status != SQLITE_OK {
                throw SQLiteError.bindFailed("index \(index) status \(status)")
            }
        }
    }

    /// Returns `true` when a row is available, `false` when the statement is done.
    func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw SQLiteError.stepFailed(String(cString: sqlite3_errmsg(db.handle)))
        }
    }

    /// Resets the statement so it can be re-executed with fresh bindings.
    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func int(at index: Int32) -> Int64 { sqlite3_column_int64(stmt, index) }

    func string(at index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    func optionalInt(at index: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, index)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
