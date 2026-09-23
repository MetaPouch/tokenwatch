import XCTest
import SQLite3
@testable import TokenWatchCore

final class SQLiteReaderTests: XCTestCase {
    /// Cursor's state DB is in WAL mode; after Cursor quits, its `-wal`/`-shm` files are gone and
    /// a plain read-only open can't read it. The sign-in must still be readable then.
    func testReadsWALDatabaseWhoseOwnerHasQuit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + " with space")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.vscdb").path

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'token');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db) // checkpoints everything into the main file
        // Cursor's bundled SQLite deletes -wal/-shm when it quits (macOS's own SQLite keeps them),
        // so remove them to reproduce "Cursor isn't running".
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }

        let value = SQLiteReader.readItemTableValue(databasePath: path, key: "cursorAuth/accessToken")
        XCTAssertEqual(value.flatMap { String(data: $0, encoding: .utf8) }, "token")
    }
}
