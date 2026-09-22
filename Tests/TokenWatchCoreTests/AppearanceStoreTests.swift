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
        XCTAssertEqual(store.iconStyle, .text)
        XCTAssertFalse(store.hideFromScreenShare)
    }

    func testChangesPersistAcrossInstancesOnDisk() {
        let dir = tempDir()
        let first = AppearanceStore(directory: dir)
        first.theme = .dark
        first.density = .compact
        first.timeFormat = .twentyFourHour
        first.reduceAnimations = true
        first.increaseTransparency = true
        first.iconStyle = .bars
        first.hideFromScreenShare = true

        let second = AppearanceStore(directory: dir)
        XCTAssertEqual(second.theme, .dark)
        XCTAssertEqual(second.density, .compact)
        XCTAssertEqual(second.timeFormat, .twentyFourHour)
        XCTAssertTrue(second.reduceAnimations)
        XCTAssertTrue(second.increaseTransparency)
        XCTAssertEqual(second.iconStyle, .bars)
        XCTAssertTrue(second.hideFromScreenShare)
    }

    func testIconStyleDefaultsToTextWhenMissingFromAnOlderSavedFile() {
        let dir = tempDir()
        let legacyJSON = """
        {"theme":"Dark","density":"Compact","timeFormat":"Auto","reduceAnimations":false,"increaseTransparency":false}
        """
        try? legacyJSON.data(using: .utf8)!.write(to: dir.appendingPathComponent("appearance.json"))
        let store = AppearanceStore(directory: dir)
        XCTAssertEqual(store.iconStyle, .text)
        XCTAssertEqual(store.theme, .dark)
        XCTAssertFalse(store.hideFromScreenShare)
    }

    func testHideFromScreenShareDefaultsToFalseWhenMissingFromAnOlderSavedFile() {
        let dir = tempDir()
        let legacyJSON = """
        {"theme":"Light","density":"Default","timeFormat":"Auto","reduceAnimations":false,"increaseTransparency":false,"iconStyle":"Bars"}
        """
        try? legacyJSON.data(using: .utf8)!.write(to: dir.appendingPathComponent("appearance.json"))
        let store = AppearanceStore(directory: dir)
        XCTAssertFalse(store.hideFromScreenShare)
        XCTAssertEqual(store.iconStyle, .bars)
    }
}
