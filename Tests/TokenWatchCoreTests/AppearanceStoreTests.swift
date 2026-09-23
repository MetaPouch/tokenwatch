import XCTest
@testable import TokenWatchCore

@MainActor
final class AppearanceStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
        first.menuBarValues = [.inputTokens, .cacheTokens]

        let second = AppearanceStore(directory: dir)
        XCTAssertEqual(second.theme, .dark)
        XCTAssertEqual(second.density, .compact)
        XCTAssertEqual(second.timeFormat, .twentyFourHour)
        XCTAssertTrue(second.reduceAnimations)
        XCTAssertTrue(second.increaseTransparency)
        XCTAssertEqual(second.iconStyle, .bars)
        XCTAssertTrue(second.hideFromScreenShare)
        XCTAssertEqual(second.menuBarValues, [.inputTokens, .cacheTokens])
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
        XCTAssertEqual(store.menuBarValues, Set(MenuBarValue.allCases))
    }

    func testLegacyHiddenCountsMigrateAndEmptySelectionSurvivesReload() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = """
        {"theme":"Dark","density":"Compact","timeFormat":"Auto","reduceAnimations":false,"increaseTransparency":false,"showMenuBarTokenCounts":false}
        """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("appearance.json"))
        let store = AppearanceStore(directory: dir)
        XCTAssertEqual(store.menuBarValues, [.limits])
        XCTAssertEqual(store.theme, .dark)
        store.menuBarValues = []
        XCTAssertEqual(AppearanceStore(directory: dir).menuBarValues, [])
    }

    func testExplicitSelectionOverridesLegacyAndRetainsKnownFutureFileChoices() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = """
        {"theme":"Dark","density":"Compact","timeFormat":"Auto","reduceAnimations":false,"increaseTransparency":false,"showMenuBarTokenCounts":true,"menuBarValues":["outputTokens","futureMetric"]}
        """
        try Data(saved.utf8).write(to: dir.appendingPathComponent("appearance.json"))
        let store = AppearanceStore(directory: dir)
        XCTAssertEqual(store.menuBarValues, [.outputTokens])
        XCTAssertEqual(store.theme, .dark)
        store.menuBarValues.insert(.cacheTokens)
        XCTAssertEqual(AppearanceStore(directory: dir).menuBarValues, [.outputTokens, .cacheTokens])
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
