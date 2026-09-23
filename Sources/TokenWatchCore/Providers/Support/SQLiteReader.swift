import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Minimal read-only SQLite reader for VS Code-style `ItemTable(key TEXT, value BLOB)` global
/// state databases (Cursor.app, and any future Electron-app auth store shaped the same way).
enum SQLiteReader {
    /// Returns the raw `value` BLOB for the first row matching `key` in `ItemTable`, or `nil` if
    /// the database can't be opened or no matching row exists.
    ///
    /// These databases use WAL mode. A plain read-only open of a WAL database fails whenever its
    /// `-shm` file is absent -- which is whenever the owning app isn't running, since it deletes
    /// `-wal`/`-shm` on quit -- because a read-only connection can't create it. So when the plain
    /// open can't read, this retries with `immutable=1`, which skips WAL/locking entirely; that's
    /// only safe because the plain open succeeds whenever the app is running and writing.
    static func readItemTableValue(databasePath: String, key: String) -> Data? {
        if let value = query(databasePath, flags: SQLITE_OPEN_READONLY, key: key) {
            return value
        }
        let immutableURI = URL(fileURLWithPath: databasePath).absoluteString + "?immutable=1"
        return query(immutableURI, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, key: key)
    }

    private static func query(_ filename: String, flags: Int32, key: String) -> Data? {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }

        guard sqlite3_open_v2(filename, &db, flags, nil) == SQLITE_OK else {
            return nil
        }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { if statement != nil { sqlite3_finalize(statement) } }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        guard let blob = sqlite3_column_blob(statement, 0) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, 0))
        return Data(bytes: blob, count: length)
    }
}
