import XCTest
@testable import TokenWatchCore

final class MeterPaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAheadOfPaceWhenProjectedToFinishWithComfortableSpare() {
        // 20% used after 40% of the window elapsed -> projects to 50% at reset, well under 90%.
        let resetsAt = now.addingTimeInterval(60 * 60) // 60 min left
        let periodMs = 100 * 60 * 1000 // 100 min window -> 40 min elapsed
        let severity = MeterPace.severity(used: 20, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, now: now)
        XCTAssertEqual(severity.tone, .good)
        guard case let .ahead(spare) = severity else { return XCTFail("expected .ahead, got \(severity)") }
        XCTAssertEqual(spare, 0.5, accuracy: 0.01)
    }

    func testOnTrackWhenProjectedToLandInsideLastTenPercent() {
        // 40% used after 40% elapsed -> projects to exactly 100% at reset -> 0% spare -> behind,
        // not on-track. Use 36% used after 40% elapsed -> projects to 90% -> exactly the
        // ahead/onTrack boundary; nudge to 37% so it's unambiguously onTrack (projected 92.5%).
        let resetsAt = now.addingTimeInterval(60 * 60)
        let periodMs = 100 * 60 * 1000
        let severity = MeterPace.severity(used: 37, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, now: now)
        XCTAssertEqual(severity.tone, .caution)
        guard case let .onTrack(spare) = severity else { return XCTFail("expected .onTrack, got \(severity)") }
        XCTAssertGreaterThan(spare, 0)
        XCTAssertLessThan(spare, 0.10)
    }

    func testBehindPaceProjectsARunOutTimeBeforeReset() {
        // 60% used after 40% elapsed -> projects to 150% at reset -> already behind; should
        // compute a run-out ETA strictly before the reset time.
        let resetsAt = now.addingTimeInterval(60 * 60)
        let periodMs = 100 * 60 * 1000
        let severity = MeterPace.severity(used: 60, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, now: now)
        XCTAssertEqual(severity.tone, .urgent)
        guard case let .behind(runOutAt) = severity, let runOutAt else { return XCTFail("expected .behind with an ETA, got \(severity)") }
        XCTAssertLessThan(runOutAt, resetsAt)
        XCTAssertGreaterThan(runOutAt, now)
    }

    func testSpentWhenAtOrOverTheLimitRightNow() {
        let severity = MeterPace.severity(used: 100, limit: 100, resetsAt: now.addingTimeInterval(3600), periodDurationMs: 18_000_000, now: now)
        XCTAssertEqual(severity, .spent)
        XCTAssertEqual(severity.tone, .urgent)
        XCTAssertFalse(severity.isProjected)
    }

    func testFallsBackToLevelColoringWithNoResetWindow() {
        // A credit balance with no reset window can never be projected -- must fall back to
        // raw-level bands rather than crashing or reading as "ahead" by default.
        let severity = MeterPace.severity(used: 85, limit: 100, resetsAt: nil, periodDurationMs: nil, now: now)
        guard case let .level(usedFraction) = severity else { return XCTFail("expected .level, got \(severity)") }
        XCTAssertEqual(usedFraction, 0.85, accuracy: 0.001)
        XCTAssertEqual(severity.tone, .caution)
        XCTAssertFalse(severity.isProjected)
    }

    func testFallsBackToLevelColoringWhenWindowTooFreshToProject() {
        // Only 1% of the window has elapsed -- a linear extrapolation off a couple of minutes of
        // usage is noise, so this must not produce a wild .behind/.ahead projection.
        let periodMs = 18_000_000 // 5h window
        let resetsAt = now.addingTimeInterval(Double(periodMs) / 1000 * 0.99)
        let severity = MeterPace.severity(used: 5, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, now: now)
        XCTAssertFalse(severity.isProjected)
    }

    func testZeroUsedNeverProjects() {
        let severity = MeterPace.severity(used: 0, limit: 100, resetsAt: now.addingTimeInterval(3600), periodDurationMs: 18_000_000, now: now)
        XCTAssertFalse(severity.isProjected)
        XCTAssertEqual(severity.tone, .good)
    }

    func testTickFractionIsElapsedShareOfWindow() {
        let periodMs = 18_000_000 // 5h
        let resetsAt = now.addingTimeInterval(Double(periodMs) / 1000 * 0.25) // 25% left -> 75% elapsed
        let tick = MeterPace.tickFraction(resetsAt: resetsAt, periodDurationMs: periodMs, now: now)
        XCTAssertEqual(tick ?? -1, 0.75, accuracy: 0.001)
    }

    func testTickFractionNilWithoutAResetWindow() {
        XCTAssertNil(MeterPace.tickFraction(resetsAt: nil, periodDurationMs: nil, now: now))
    }
}
