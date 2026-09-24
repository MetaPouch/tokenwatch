import XCTest
@testable import TokenWatchCore

final class SpendAggregatorTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // fixed instant

    private func day(offsetFromNow days: Int, cost: Double, tokens: Int = 0) -> UsageDay {
        let date = calendar.date(byAdding: .day, value: days, to: now)!
        return UsageDay(id: "\(days)", date: date, inputTokens: tokens, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0, estimatedCostUSD: cost, hasApproximateRate: false)
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

    private func dayWithModels(offsetFromNow days: Int, models: [(name: String, cost: Double, tokens: Int)]) -> UsageDay {
        let date = calendar.date(byAdding: .day, value: days, to: now)!
        let breakdown = models.map { ModelSpend(id: $0.name, costUSD: $0.cost, inputTokens: $0.tokens, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0) }
        let totalCost = models.reduce(0) { $0 + $1.cost }
        let totalTokens = models.reduce(0) { $0 + $1.tokens }
        return UsageDay(id: "\(days)", date: date, inputTokens: totalTokens, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0, estimatedCostUSD: totalCost, hasApproximateRate: false, modelBreakdown: breakdown)
    }

    func testModelBreakdownMergesSameModelAcrossDays() {
        let days = [
            dayWithModels(offsetFromNow: 0, models: [("claude-sonnet-5", 10, 1000)]),
            dayWithModels(offsetFromNow: -1, models: [("claude-sonnet-5", 5, 500)]),
        ]
        let breakdown = SpendAggregator.modelBreakdown(for: .thirtyDays, days: days, calendar: calendar, now: now)
        XCTAssertEqual(breakdown.count, 1)
        XCTAssertEqual(breakdown.first?.costUSD ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(breakdown.first?.tokens, 1500)
    }

    func testModelBreakdownSortsLargestFirst() {
        // 20/25 = 80% and 5/25 = 20% share -- both well above the 5%-fold threshold.
        let days = [dayWithModels(offsetFromNow: 0, models: [("small-model", 5, 100), ("big-model", 20, 2000)])]
        let breakdown = SpendAggregator.modelBreakdown(for: .today, days: days, calendar: calendar, now: now)
        XCTAssertEqual(breakdown.map(\.id), ["big-model", "small-model"])
    }

    func testModelBreakdownFoldsLongTailIntoOther() {
        // 6 models: 5 clearly above 5% share, one below -> the small one folds into "Other".
        let models: [(String, Double, Int)] = [
            ("m1", 40, 100), ("m2", 30, 100), ("m3", 15, 100), ("m4", 8, 100), ("m5", 5, 100), ("m6", 2, 100),
        ]
        let days = [dayWithModels(offsetFromNow: 0, models: models)]
        let breakdown = SpendAggregator.modelBreakdown(for: .today, days: days, calendar: calendar, now: now)
        XCTAssertEqual(breakdown.last?.id, "Other")
        XCTAssertEqual(breakdown.last?.costUSD ?? -1, 2, accuracy: 0.001)
    }

    func testModelBreakdownEmptyWhenNoActivity() {
        XCTAssertTrue(SpendAggregator.modelBreakdown(for: .today, days: [], calendar: calendar, now: now).isEmpty)
    }

    /// The leaderboard uploads per-model rows, so each model's disjoint buckets must add back up to
    /// the day's own totals -- not just the combined token count the hover list shows.
    func testAccumulatorPerModelBucketsSumToDayTotals() {
        var accumulator = UsageDayAccumulator(days: 1, now: now, calendar: calendar)
        accumulator.add(timestamp: now, model: "opus", input: 10, cacheRead: 200, cacheWrite: 30, output: 40, costUSD: 1.5, approximate: false)
        accumulator.add(timestamp: now, model: "opus", input: 1, cacheRead: 2, cacheWrite: 3, output: 4, costUSD: 0.5, approximate: false)
        accumulator.add(timestamp: now, model: "mystery", input: 7, cacheRead: 0, cacheWrite: 0, output: 9, costUSD: 0.1, approximate: true)
        guard let day = accumulator.build().last else { return XCTFail("no day built") }

        let opus = day.modelBreakdown.first { $0.id == "opus" }
        XCTAssertEqual([opus?.inputTokens, opus?.cacheReadTokens, opus?.cacheWriteTokens, opus?.outputTokens], [11, 202, 33, 44])
        XCTAssertEqual(opus?.hasApproximateRate, false)
        XCTAssertEqual(day.modelBreakdown.first { $0.id == "mystery" }?.hasApproximateRate, true)
        XCTAssertEqual(day.modelBreakdown.reduce(0) { $0 + $1.inputTokens }, day.inputTokens)
        XCTAssertEqual(day.modelBreakdown.reduce(0) { $0 + $1.cacheReadTokens }, day.cacheReadTokens)
        XCTAssertEqual(day.modelBreakdown.reduce(0) { $0 + $1.cacheWriteTokens }, day.cacheWriteTokens)
        XCTAssertEqual(day.modelBreakdown.reduce(0) { $0 + $1.outputTokens }, day.outputTokens)
        XCTAssertEqual(day.modelBreakdown.reduce(0) { $0 + $1.costUSD }, day.estimatedCostUSD, accuracy: 1e-9)
    }

    func testModelBreakdownMergeKeepsBucketsAndApproximateFlag() {
        let date = calendar.startOfDay(for: now)
        let spend = { (input: Int, output: Int, approximate: Bool) in
            ModelSpend(id: "m", costUSD: 1, inputTokens: input, cacheReadTokens: 5, cacheWriteTokens: 0, outputTokens: output, hasApproximateRate: approximate)
        }
        let days = [
            UsageDay(id: "a", date: date, inputTokens: 1, cacheReadTokens: 5, cacheWriteTokens: 0, outputTokens: 2, estimatedCostUSD: 1, hasApproximateRate: false, modelBreakdown: [spend(1, 2, false)]),
            UsageDay(id: "b", date: date, inputTokens: 3, cacheReadTokens: 5, cacheWriteTokens: 0, outputTokens: 4, estimatedCostUSD: 1, hasApproximateRate: true, modelBreakdown: [spend(3, 4, true)]),
        ]
        let merged = SpendAggregator.modelBreakdown(for: .thirtyDays, days: days, calendar: calendar, now: now)
        XCTAssertEqual(merged, [ModelSpend(id: "m", costUSD: 2, inputTokens: 4, cacheReadTokens: 10, cacheWriteTokens: 0, outputTokens: 6, hasApproximateRate: true)])
    }
}
