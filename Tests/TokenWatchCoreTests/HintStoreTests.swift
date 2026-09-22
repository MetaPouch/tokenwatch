import XCTest
@testable import TokenWatchCore

@MainActor
final class HintStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suiteName = "HintStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testBothHintsVisibleByDefault() {
        let store = HintStore(defaults: freshDefaults())
        XCTAssertFalse(store.providerDetectionDismissed)
        XCTAssertFalse(store.customizeTipDismissed)
    }

    func testDismissingOneHintDoesNotAffectTheOther() {
        let store = HintStore(defaults: freshDefaults())
        store.dismissProviderDetection()
        XCTAssertTrue(store.providerDetectionDismissed)
        XCTAssertFalse(store.customizeTipDismissed)
    }

    func testDismissalPersistsAcrossInstancesOnTheSameDefaults() {
        let defaults = freshDefaults()
        let first = HintStore(defaults: defaults)
        first.dismissCustomizeTip()

        let second = HintStore(defaults: defaults)
        XCTAssertTrue(second.customizeTipDismissed)
        XCTAssertFalse(second.providerDetectionDismissed)
    }
}
