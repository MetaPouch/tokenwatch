import XCTest
@testable import TokenWatchCore

final class SpendAggregatorTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // fixed instant

    private func day(offsetFromNow days: Int, cost: Double, tokens: Int = 0) -> ClaudeUsageDay {
        let date = calendar.date(byAdding: .day, value: days, to: now)!
        return ClaudeUsageDay(id: "\(days)", date: date, inputTokens: tokens, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0, estimatedCostUSD: cost, hasApproximateRate: false)
    }

    func testTodayReadsTheSameCalendarDaysEntry() {
        let days = [day(offsetFromNow: 0, cost: 12.5), day(offsetFromNow: -1, cost: 3.0)]
        XCTAssertEqual(SpendAggregator.amount(for: .today, days: days, calendar: calendar, now: now), 12.5, accuracy: 0.001)
    }

    func testYesterdayReadsOneCalendarDayBack() {
        let days = [day(offsetFromNow: 0, cost: 12.5), day(offsetFromNow: -1, cost: 3.0)]
        XCTAssertEqual(SpendAggregator.amount(for: .yesterday, days: days, calendar: calendar, now: now), 3.0, accuracy: 0.001)
    }

    func testThirtyDaysSumsEveryEntryRegardlessOfDate() {
        let days = [day(offsetFromNow: 0, cost: 1), day(offsetFromNow: -5, cost: 2), day(offsetFromNow: -29, cost: 3)]
        XCTAssertEqual(SpendAggregator.amount(for: .thirtyDays, days: days, calendar: calendar, now: now), 6, accuracy: 0.001)
    }

    func testMissingDayReadsAsZeroNotCrashing() {
        XCTAssertEqual(SpendAggregator.amount(for: .today, days: [], calendar: calendar, now: now), 0)
        XCTAssertEqual(SpendAggregator.amount(for: .yesterday, days: [], calendar: calendar, now: now), 0)
    }

    func testTodayDoesNotMatchYesterdaysEntry() {
        // A day with only a "yesterday" bucket must not leak into "today"'s total.
        let days = [day(offsetFromNow: -1, cost: 9.0)]
        XCTAssertEqual(SpendAggregator.amount(for: .today, days: days, calendar: calendar, now: now), 0)
    }

    func testTokensSumsAcrossThirtyDays() {
        let days = [day(offsetFromNow: 0, cost: 1, tokens: 1000), day(offsetFromNow: -1, cost: 1, tokens: 2000)]
        XCTAssertEqual(SpendAggregator.tokens(for: .thirtyDays, days: days, calendar: calendar, now: now), 3000)
    }

    func testTokensForTodayReadsOnlyTodaysBucket() {
        let days = [day(offsetFromNow: 0, cost: 1, tokens: 1000), day(offsetFromNow: -1, cost: 1, tokens: 2000)]
        XCTAssertEqual(SpendAggregator.tokens(for: .today, days: days, calendar: calendar, now: now), 1000)
    }

    func testCostPerMillionTokensComputesBlendedRate() {
        // $2 for 2,000,000 tokens -> $1/MTok.
        let days = [day(offsetFromNow: 0, cost: 2, tokens: 2_000_000)]
        XCTAssertEqual(SpendAggregator.costPerMillionTokens(for: .today, days: days, calendar: calendar, now: now) ?? -1, 1, accuracy: 0.001)
    }

    func testCostPerMillionTokensNilWhenNoTokenVolume() {
        // Never a divide-by-zero crash or a fabricated rate when nothing was recorded.
        XCTAssertNil(SpendAggregator.costPerMillionTokens(for: .today, days: [], calendar: calendar, now: now))
        let zeroTokenDay = day(offsetFromNow: 0, cost: 5, tokens: 0)
        XCTAssertNil(SpendAggregator.costPerMillionTokens(for: .today, days: [zeroTokenDay], calendar: calendar, now: now))
    }
}
