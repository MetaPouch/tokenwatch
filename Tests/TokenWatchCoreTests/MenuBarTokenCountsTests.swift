import XCTest
@testable import TokenWatchCore

final class MenuBarTokenCountsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_790_200_000)

    private func day(at date: Date, input: Int, output: Int, read: Int, write: Int) -> UsageDay {
        UsageDay(id: "fixture", date: date, inputTokens: input, cacheReadTokens: read,
                 cacheWriteTokens: write, outputTokens: output, estimatedCostUSD: 0,
                 hasApproximateRate: false)
    }

    func testCombinesOnlyEnabledProvidersTodayWithoutDoubleCountingCache() throws {
        let today = day(at: now, input: 100, output: 20, read: 300, write: 40)
        let yesterday = day(at: now.addingTimeInterval(-86_400), input: 9_000, output: 9_000, read: 9_000, write: 9_000)
        let history: [SpendSource: [UsageDay]] = [
            .provider(.claude): [yesterday, today],
            .provider(.codex): [day(at: now, input: 10, output: 2, read: 30, write: 4)],
            .service(.devin): [today],
            .other: [today]
        ]
        let combined = try XCTUnwrap(MenuBarTokenCounts.today(daysBySource: history, enabledProviders: [.claude, .codex], now: now, calendar: calendar))
        XCTAssertEqual(combined.input, 110)
        XCTAssertEqual(combined.output, 22)
        XCTAssertEqual(combined.cacheRead, 330)
        XCTAssertEqual(combined.cacheWrite, 44)
        XCTAssertEqual(combined.cache, 374)
        XCTAssertEqual(combined.input + combined.output + combined.cache, 506)
        let claudeOnly = try XCTUnwrap(MenuBarTokenCounts.today(daysBySource: history, enabledProviders: [.claude], now: now, calendar: calendar))
        XCTAssertEqual(claudeOnly.input, 100)
        XCTAssertEqual(claudeOnly.output, 20)
        XCTAssertEqual(claudeOnly.cache, 340)
    }

    func testMidnightClearsOldTotalsBeforeAnotherScan() throws {
        let history: [SpendSource: [UsageDay]] = [.provider(.claude): [day(at: now, input: 10, output: 20, read: 30, write: 40)]]
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let counts = try XCTUnwrap(MenuBarTokenCounts.today(daysBySource: history, enabledProviders: [.claude], now: tomorrow, calendar: calendar))
        XCTAssertEqual(counts.input + counts.output + counts.cache, 0)
    }

    func testUnloadedAndDisabledHistoryDoNotBecomeZeroUsageClaims() {
        XCTAssertNil(MenuBarTokenCounts.today(daysBySource: [:], enabledProviders: [.claude], now: now, calendar: calendar))
        XCTAssertNil(MenuBarTokenCounts.today(daysBySource: [.provider(.claude): []], enabledProviders: [.codex], now: now, calendar: calendar))
        XCTAssertNotNil(MenuBarTokenCounts.today(daysBySource: [.provider(.claude): []], enabledProviders: [.claude], now: now, calendar: calendar))
    }
}
