import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

struct SQLiteError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal wrapper over the system SQLite C API.
final class Database {
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw SQLiteError(message: "open \(path): \(msg)")
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(message: "\(msg) in: \(sql.prefix(80))")
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: "\(String(cString: sqlite3_errmsg(handle))) in: \(sql.prefix(80))")
        }
        return Statement(stmt)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}

final class Statement {
    private let stmt: OpaquePointer
    init(_ stmt: OpaquePointer) { self.stmt = stmt }
    deinit { sqlite3_finalize(stmt) }

    @discardableResult func bind(_ index: Int32, _ value: Int64?) -> Statement {
        if let value { sqlite3_bind_int64(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
        return self
    }
    @discardableResult func bind(_ index: Int32, _ value: Double?) -> Statement {
        if let value, value.isFinite { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
        return self
    }
    @discardableResult func bind(_ index: Int32, _ value: String?) -> Statement {
        if let value { sqlite3_bind_text(stmt, index, value, -1, transient) } else { sqlite3_bind_null(stmt, index) }
        return self
    }

    /// Advances to the next row; false when done.
    func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }
    /// Runs a statement that returns no rows, then resets it for reuse.
    func run() { _ = sqlite3_step(stmt); sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
    func reset() { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }

    func int(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
    func intOrNil(_ col: Int32) -> Int64? { sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, col) }
    func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
    func doubleOrNil(_ col: Int32) -> Double? { sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col) }
    func text(_ col: Int32) -> String { sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? "" }
    func textOrNil(_ col: Int32) -> String? { sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : text(col) }
}
