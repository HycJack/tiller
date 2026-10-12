import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

/// A thin wrapper over the system SQLite. Not thread-safe: each owner uses its
/// database from one queue at a time, which is why it can be handed to one.
final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw SQLiteError(description: "\(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    /// Runs one or more statements that take no parameters.
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    /// Runs one statement, binding `values` to its `?` placeholders in order.
    func run(_ sql: String, _ values: [Any?] = []) throws {
        try withStatement(sql, values) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error() }
        }
    }

    /// Runs one statement once for each of `rows`, binding its values in
    /// order. The statement is prepared once, which counts for thousands.
    func runEach(_ sql: String, _ rows: [[Any?]]) throws {
        try withStatement(sql, []) { statement in
            for values in rows {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(values, to: statement)
                let result = sqlite3_step(statement)
                guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error() }
            }
        }
    }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ values: [Any?] = [], row: (Row) throws -> T) throws -> [T] {
        try withStatement(sql, values) { statement in
            var rows: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw error() }
                rows.append(try row(Row(statement: statement)))
            }
            return rows
        }
    }

    /// Runs `body` in a transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, _ values: [Any?], _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        return try body(statement)
    }

    private func bind(_ values: [Any?], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, index)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as Bool: sqlite3_bind_int(statement, index, value ? 1 : 0)
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            default: throw SQLiteError(description: "can't bind \(type(of: value))")
            }
        }
    }

    private func error() -> SQLiteError {
        SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
    }

    /// Tells SQLite to copy bound strings and blobs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// One result row. Columns are read by index.
    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

        func string(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        func data(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }
}
