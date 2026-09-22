import XCTest
@testable import TokenWatchCore

@MainActor
final class LayoutStoreTests: XCTestCase {
    private func makeStore() -> LayoutStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LayoutStore(directory: dir)
    }

    func testUnorderedEnabledProvidersFallBackToCanonicalOrder() {
        let store = makeStore()
        let ordered = store.orderedProviders(enabled: [.cursor, .claude])
        XCTAssertEqual(ordered, [.claude, .cursor]) // ProviderID.allCases order, claude first
    }

    func testMoveProviderReordersAmongEnabledOnly() {
        let store = makeStore()
        let enabled: Set<ProviderID> = [.claude, .codex, .cursor]
        store.moveProvider(.cursor, enabled: enabled, toIndex: 0)
        XCTAssertEqual(store.orderedProviders(enabled: enabled), [.cursor, .claude, .codex])
    }

    func testDisabledProviderKeepsItsCustomizationAfterReenabling() {
        let store = makeStore()
        store.setHidden(true, provider: .grok, metricID: "weekly")
        XCTAssertTrue(store.layout(for: .grok, metricID: "weekly").hidden)
        // Grok toggled off then back on (enablement lives elsewhere; LayoutStore only orders).
        _ = store.orderedProviders(enabled: [.claude])
        _ = store.orderedProviders(enabled: [.claude, .grok])
        XCTAssertTrue(store.layout(for: .grok, metricID: "weekly").hidden)
    }

    func testStarringCapsAtTwoPerProvider() {
        let store = makeStore()
        XCTAssertTrue(store.toggleStar(provider: .claude, metricID: "session"))
        XCTAssertTrue(store.toggleStar(provider: .claude, metricID: "weekly"))
        XCTAssertFalse(store.toggleStar(provider: .claude, metricID: "sonnet"))
        XCTAssertEqual(Set(store.starredMetricIDs(for: .claude)), ["session", "weekly"])
    }

    func testUnstarringFreesUpASlot() {
        let store = makeStore()
        _ = store.toggleStar(provider: .claude, metricID: "session")
        _ = store.toggleStar(provider: .claude, metricID: "weekly")
        _ = store.toggleStar(provider: .claude, metricID: "session") // unstar
        XCTAssertTrue(store.toggleStar(provider: .claude, metricID: "sonnet"))
        XCTAssertEqual(Set(store.starredMetricIDs(for: .claude)), ["weekly", "sonnet"])
    }

    func testStarCapIsPerProviderNotGlobal() {
        let store = makeStore()
        _ = store.toggleStar(provider: .claude, metricID: "session")
        _ = store.toggleStar(provider: .claude, metricID: "weekly")
        // A different provider's cap is independent.
        XCTAssertTrue(store.toggleStar(provider: .codex, metricID: "session"))
    }

    func testResetProviderOnlyClearsThatProvidersMetrics() {
        let store = makeStore()
        store.setHidden(true, provider: .claude, metricID: "session")
        store.setHidden(true, provider: .codex, metricID: "session")
        store.resetProvider(.claude)
        XCTAssertFalse(store.layout(for: .claude, metricID: "session").hidden)
        XCTAssertTrue(store.layout(for: .codex, metricID: "session").hidden)
    }

    func testResetAllClearsProviderOrderAndEveryMetric() {
        let store = makeStore()
        store.moveProvider(.codex, enabled: [.claude, .codex], toIndex: 0)
        store.setHidden(true, provider: .claude, metricID: "session")
        store.resetAll()
        XCTAssertEqual(store.orderedProviders(enabled: [.claude, .codex]), [.claude, .codex])
        XCTAssertFalse(store.layout(for: .claude, metricID: "session").hidden)
    }

    func testCustomizationPersistsAcrossStoreInstancesOnDisk() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = LayoutStore(directory: dir)
        first.setHidden(true, provider: .grok, metricID: "weekly")
        _ = first.toggleStar(provider: .grok, metricID: "weekly")
        first.moveProvider(.grok, enabled: [.claude, .grok], toIndex: 0)

        let second = LayoutStore(directory: dir)
        XCTAssertTrue(second.layout(for: .grok, metricID: "weekly").hidden)
        XCTAssertTrue(second.layout(for: .grok, metricID: "weekly").starred)
        XCTAssertEqual(second.orderedProviders(enabled: [.claude, .grok]), [.grok, .claude])
    }
}
