import XCTest
@testable import TokenWatchCore

@MainActor
final class AppearanceStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testDefaultsWhenNoFileExists() {
        let store = AppearanceStore(directory: tempDir())
        XCTAssertEqual(store.theme, .system)
        XCTAssertEqual(store.density, .regular)
        XCTAssertEqual(store.timeFormat, .auto)
        XCTAssertFalse(store.reduceAnimations)
        XCTAssertFalse(store.increaseTransparency)
    }

    func testChangesPersistAcrossInstancesOnDisk() {
        let dir = tempDir()
        let first = AppearanceStore(directory: dir)
        first.theme = .dark
        first.density = .compact
        first.timeFormat = .twentyFourHour
        first.reduceAnimations = true
        first.increaseTransparency = true

        let second = AppearanceStore(directory: dir)
        XCTAssertEqual(second.theme, .dark)
        XCTAssertEqual(second.density, .compact)
        XCTAssertEqual(second.timeFormat, .twentyFourHour)
        XCTAssertTrue(second.reduceAnimations)
        XCTAssertTrue(second.increaseTransparency)
    }
}
