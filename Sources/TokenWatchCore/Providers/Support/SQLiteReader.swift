import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Minimal read-only SQLite access for other apps' databases: VS Code-style `ItemTable` global
/// state (Cursor.app) and coding agents' session stores (OpenCode, Copilot CLI, Devin CLI). The
/// owning app may hold the database open and be writing to it at the same time.
enum SQLiteReader {
    enum Binding {
        case text(String)
        case integer(Int64)
    }

    /// Returns the raw `value` BLOB for the first row matching `key` in `ItemTable`, or `nil` if
    /// the database can't be opened or no matching row exists.
    static func readItemTableValue(databasePath: String, key: String) -> Data? {
        let rows = rows(databasePath: databasePath, sql: "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", bindings: [.text(key)]) { statement -> Data? in
            guard let blob = sqlite3_column_blob(statement, 0) else { return nil }
            return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
        }
        return rows?.first
    }

    /// Every row `sql` returns, mapped by `row` (rows it maps to `nil` are dropped), or `nil` if
    /// the database can't be opened or the query fails (a missing table included).
    ///
    /// These databases use WAL mode. A plain read-only open of a WAL database fails whenever its
    /// `-shm` file is absent -- which is whenever the owning app isn't running, since it deletes
    /// `-wal`/`-shm` on quit -- because a read-only connection can't create it. So when the plain
    /// open can't read, this retries with `immutable=1`, which skips WAL/locking entirely; that's
    /// only safe because the plain open succeeds whenever the app is running and writing.
    static func rows<Row>(databasePath: String, sql: String, bindings: [Binding] = [], row: (OpaquePointer) -> Row?) -> [Row]? {
        if let rows = run(databasePath, flags: SQLITE_OPEN_READONLY, sql: sql, bindings: bindings, row: row) {
            return rows
        }
        let immutableURI = URL(fileURLWithPath: databasePath).absoluteString + "?immutable=1"
        return run(immutableURI, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, sql: sql, bindings: bindings, row: row)
    }

    /// A column's value as text (SQLite converts numbers), or `nil` when it's NULL.
    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    /// A column's integer value, or `nil` when it's NULL.
    static func integer(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    private static func run<Row>(_ filename: String, flags: Int32, sql: String, bindings: [Binding], row: (OpaquePointer) -> Row?) -> [Row]? {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        guard sqlite3_open_v2(filename, &db, flags, nil) == SQLITE_OK else { return nil }

        var statement: OpaquePointer?
        defer { if statement != nil { sqlite3_finalize(statement) } }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            switch binding {
            case let .text(value): sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            case let .integer(value): sqlite3_bind_int64(statement, Int32(index + 1), value)
            }
        }

        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let mapped = row(statement) { rows.append(mapped) }
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }
}
