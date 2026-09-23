import XCTest
@testable import TokenWatchCore

final class LiveUsageActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_200_000)

    private func day(_ total: Int, timedOutput: Int = 0, duration: Double = 0, timestamp: Date? = nil, id: String = "today") -> UsageDay {
        UsageDay(id: id, date: now, inputTokens: total - timedOutput, cacheReadTokens: 0,
                 cacheWriteTokens: 0, outputTokens: timedOutput, estimatedCostUSD: 0,
                 hasApproximateRate: false, latestUsageAt: total > 0 ? (timestamp ?? now) : nil,
                 timedOutputTokens: timedOutput, timedDurationMs: duration)
    }

    func testRateUsesMatchedResponseDurationNotTimeBetweenSnapshots() {
        var activity = LiveUsageActivity()
        activity.observe(day(10_000, timedOutput: 1_000, duration: 10_000), now: now)
        XCTAssertFalse(activity.isActive(at: now), "Initial history is only a baseline")
        XCTAssertNil(activity.outputTokensPerSecond(at: now))
        let later = now.addingTimeInterval(60)
        activity.observe(day(13_000, timedOutput: 1_400, duration: 12_000, timestamp: later), now: later)
        XCTAssertTrue(activity.isActive(at: later))
        XCTAssertEqual(activity.outputTokensPerSecond(at: later), 200)
        XCTAssertFalse(activity.isActive(at: later.addingTimeInterval(8)))
        XCTAssertEqual(activity.outputTokensPerSecond(at: later.addingTimeInterval(8)), 200)
        XCTAssertNil(activity.outputTokensPerSecond(at: later.addingTimeInterval(180)))
    }

    func testRepeatedSnapshotDoesNotKeepActivityOrRateAlive() {
        var activity = LiveUsageActivity()
        activity.observe(day(0), now: now)
        let sample = day(100, timedOutput: 20, duration: 1_000)
        activity.observe(sample, now: now)
        activity.observe(sample, now: now.addingTimeInterval(9))
        XCTAssertFalse(activity.isActive(at: now.addingTimeInterval(9)))
        XCTAssertEqual(activity.lastObservedAt, now)
        activity.observe(sample, now: now.addingTimeInterval(180))
        XCTAssertNil(activity.outputTokensPerSecond(at: now.addingTimeInterval(180)))
    }

    func testUntimedUsageIsActiveWithoutReusingEarlierRate() {
        var activity = LiveUsageActivity()
        activity.observe(day(0), now: now)
        activity.observe(day(100, timedOutput: 20, duration: 1_000), now: now)
        let later = now.addingTimeInterval(2)
        activity.observe(day(200, timedOutput: 20, duration: 1_000, timestamp: later), now: later)
        XCTAssertTrue(activity.isActive(at: later))
        XCTAssertNil(activity.outputTokensPerSecond(at: later))
    }

    func testOldImportsAndFutureTimestampsCannotAppearLive() {
        var activity = LiveUsageActivity()
        activity.observe(day(0), now: now)
        activity.observe(day(100, timedOutput: 20, duration: 1_000, timestamp: now.addingTimeInterval(-300)), now: now)
        XCTAssertFalse(activity.isActive(at: now))
        XCTAssertNil(activity.outputTokensPerSecond(at: now))
        activity.observe(day(200, timedOutput: 40, duration: 2_000, timestamp: now.addingTimeInterval(300)), now: now)
        XCTAssertFalse(activity.isActive(at: now))
        XCTAssertNil(activity.outputTokensPerSecond(at: now))
    }
    func testImportedHistoryCannotReactivateARecentExistingRecord() {
        var activity = LiveUsageActivity()
        activity.observe(day(0), now: now)
        activity.observe(day(100, timedOutput: 20, duration: 1_000), now: now)
        let later = now.addingTimeInterval(9)
        // Old rows increase today's counters, but its newest recorded response has not changed.
        activity.observe(day(200, timedOutput: 40, duration: 1_100), now: later)
        XCTAssertFalse(activity.isActive(at: later))
        XCTAssertEqual(activity.outputTokensPerSecond(at: later), 20)
        XCTAssertEqual(activity.lastObservedAt, now)
    }


    func testCounterResetAndMidnightRebaselineWithoutRateSpike() {
        var activity = LiveUsageActivity()
        activity.observe(day(0), now: now)
        activity.observe(day(100, timedOutput: 20, duration: 1_000), now: now)
        activity.observe(day(10, timedOutput: 2, duration: 100), now: now)
        XCTAssertFalse(activity.isActive(at: now))
        XCTAssertNil(activity.outputTokensPerSecond(at: now))
        let later = now.addingTimeInterval(1)
        activity.observe(day(110, timedOutput: 22, duration: 1_100, timestamp: later), now: later)
        XCTAssertEqual(activity.outputTokensPerSecond(at: later), 20)
        activity.observe(day(300, timedOutput: 100, duration: 2_000, id: "next-day"), now: now)
        XCTAssertFalse(activity.isActive(at: now))
        XCTAssertNil(activity.outputTokensPerSecond(at: now))
    }
}
