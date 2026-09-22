import XCTest
@testable import TokenWatchCore

@MainActor
final class MeterDisplayStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testDefaultsWhenNoFileExists() {
        let store = MeterDisplayStore(directory: tempDir())
        XCTAssertEqual(store.readingMode, .used)
        XCTAssertEqual(store.resetDisplayMode, .countdown)
        XCTAssertFalse(store.alwaysShowPacing)
        XCTAssertTrue(store.showTotalSpend)
    }

    func testTogglesPersistAcrossInstancesOnDisk() {
        let dir = tempDir()
        let first = MeterDisplayStore(directory: dir)
        first.toggleReadingMode()
        first.toggleResetDisplayMode()
        first.alwaysShowPacing = true
        first.showTotalSpend = false

        let second = MeterDisplayStore(directory: dir)
        XCTAssertEqual(second.readingMode, .left)
        XCTAssertEqual(second.resetDisplayMode, .exact)
        XCTAssertTrue(second.alwaysShowPacing)
        XCTAssertFalse(second.showTotalSpend)
    }

    func testShowTotalSpendDefaultsTrueWhenMissingFromAnOlderSavedFile() {
        // showTotalSpend shipped after display.json did -- an existing user's file predates the
        // key. Decoding it must default the new field to true, not fail the whole decode (which
        // would silently reset every other already-saved preference too).
        let dir = tempDir()
        let legacyJSON = """
        {"reading":"left","reset":"exact","alwaysShowPacing":true}
        """
        try? legacyJSON.data(using: .utf8)!.write(to: dir.appendingPathComponent("display.json"))

        let store = MeterDisplayStore(directory: dir)
        XCTAssertEqual(store.readingMode, .left)
        XCTAssertEqual(store.resetDisplayMode, .exact)
        XCTAssertTrue(store.alwaysShowPacing)
        XCTAssertTrue(store.showTotalSpend)
    }
}
