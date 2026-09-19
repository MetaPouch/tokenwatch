import XCTest
@testable import TokenWatchCore

final class PreferredProviderSelectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNoEnabledProvidersYieldsNil() {
        XCTAssertNil(PreferredProviderSelector.select(enabledProviders: [], snapshots: [:], now: now))
    }

    func testPrefersMostRecentlyActiveProviderWithinWindow() {
        let snapshots: [ProviderID: ProviderSnapshot] = [
            .claude: ProviderSnapshot(provider: .claude, lastActivityAt: now.addingTimeInterval(-3600)),
            .cursor: ProviderSnapshot(provider: .cursor, lastActivityAt: now.addingTimeInterval(-60)),
        ]
        let selected = PreferredProviderSelector.select(enabledProviders: [.claude, .cursor], snapshots: snapshots, now: now)
        XCTAssertEqual(selected, .cursor)
    }

    func testIgnoresActivityOlderThanTwentyFourHours() {
        // claude's activity is stale (25h) and cursor has no signal at all. If the 24h cutoff
        // were broken, claude's timestamp would win via the recent-activity path; correct
        // behavior falls through to "first enabled provider", which is cursor here -- so this
        // only passes when the cutoff is actually enforced.
        let snapshots: [ProviderID: ProviderSnapshot] = [
            .claude: ProviderSnapshot(provider: .claude, lastActivityAt: now.addingTimeInterval(-25 * 3600)),
        ]
        XCTAssertEqual(PreferredProviderSelector.select(enabledProviders: [.cursor, .claude], snapshots: snapshots, now: now), .cursor)
    }

    func testFallsBackToClosestToLimitWhenNoRecentActivity() {
        let lowUsage = ProviderSnapshot(provider: .claude, lines: [.progress(id: "session", label: "Session", used: 10, limit: 100, format: .percent, resetsAt: nil, periodDurationMs: nil)])
        let highUsage = ProviderSnapshot(provider: .cursor, lines: [.progress(id: "usage", label: "Usage", used: 90, limit: 100, format: .percent, resetsAt: nil, periodDurationMs: nil)])
        let snapshots: [ProviderID: ProviderSnapshot] = [.claude: lowUsage, .cursor: highUsage]

        let selected = PreferredProviderSelector.select(enabledProviders: [.claude, .cursor], snapshots: snapshots, now: now)
        XCTAssertEqual(selected, .cursor)
    }

    func testFallsBackToFirstEnabledProviderWhenNoSignalAtAll() {
        let selected = PreferredProviderSelector.select(enabledProviders: [.grok, .amp], snapshots: [:], now: now)
        XCTAssertEqual(selected, .grok)
    }
}
