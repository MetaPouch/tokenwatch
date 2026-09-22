import XCTest
@testable import TokenWatchCore

@MainActor
final class NotificationSettingsStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testAllTriggersOffByDefault() {
        let store = NotificationSettingsStore(directory: tempDir())
        XCTAssertFalse(store.almostOut)
        XCTAssertFalse(store.cuttingItClose)
        XCTAssertFalse(store.willRunOut)
        XCTAssertFalse(store.anyEnabled)
    }

    func testTogglesPersistAcrossInstances() {
        let dir = tempDir()
        let first = NotificationSettingsStore(directory: dir)
        first.almostOut = true

        let second = NotificationSettingsStore(directory: dir)
        XCTAssertTrue(second.almostOut)
        XCTAssertFalse(second.cuttingItClose)
        XCTAssertTrue(second.anyEnabled)
    }

    func testSettingsMirrorsTogglesForTheEvaluator() {
        let store = NotificationSettingsStore(directory: tempDir())
        store.cuttingItClose = true
        store.willRunOut = true
        let settings = store.settings
        XCTAssertFalse(settings.almostOut)
        XCTAssertTrue(settings.cuttingItClose)
        XCTAssertTrue(settings.willRunOut)
    }
}
