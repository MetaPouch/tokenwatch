import XCTest
@testable import TokenWatchCore

final class ClaudeCacheTemperatureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Mirrors `ClaudeCacheTemperature`'s private `formatClock` -- local HH:mm -- so expected
    /// values are computed relative to whatever timezone the test happens to run in, rather than
    /// a literal that only matches one machine's local timezone.
    private func expectedClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    func testNilActivityYieldsNoLine() {
        XCTAssertNil(ClaudeCacheTemperature.evaluate(activity: nil, now: now, ttlSeconds: 300))
    }

    func testWarmWithinTTLShowsHitRatioAndExpiry() {
        let timestamp = now.addingTimeInterval(-120)
        let activity = ClaudeSessionActivity(filePath: "/tmp/fake.jsonl", timestamp: timestamp, inputTokens: 2, cacheReadTokens: 484_489, cacheCreationTokens: 1_460, sessionLabel: "my-project")
        let line = ClaudeCacheTemperature.evaluate(activity: activity, now: now, ttlSeconds: 300)

        guard case let .badge(id, text, tone, icon, detail) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(id, "cacheTemperature")
        XCTAssertEqual(tone, .neutral)
        XCTAssertEqual(icon, "flame.fill")
        XCTAssertEqual(text, "my-project")
        // 484489 / (484489+1460+2) rounds to 100% hit.
        XCTAssertEqual(detail, "100% hit · expires \(expectedClock(timestamp.addingTimeInterval(300)))")
    }

    func testWarmOmitsHitRatioWhenNoCacheActivity() {
        let activity = ClaudeSessionActivity(filePath: "/tmp/fake.jsonl", timestamp: now.addingTimeInterval(-10), inputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, sessionLabel: "my-project")
        let line = ClaudeCacheTemperature.evaluate(activity: activity, now: now, ttlSeconds: 300)

        guard case let .badge(_, _, tone, icon, detail) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(tone, .neutral)
        XCTAssertEqual(icon, "flame.fill")
        XCTAssertFalse((detail ?? "").contains("hit"), detail ?? "nil")
        XCTAssertTrue((detail ?? "").contains("expires"), detail ?? "nil")
    }

    func testExactExpiryBoundaryIsAlreadyCold() {
        let activity = ClaudeSessionActivity(filePath: "/tmp/fake.jsonl", timestamp: now.addingTimeInterval(-300), inputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 0, sessionLabel: "my-project")
        let line = ClaudeCacheTemperature.evaluate(activity: activity, now: now, ttlSeconds: 300)

        guard case let .badge(_, _, tone, icon, _) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(tone, .warning)
        XCTAssertEqual(icon, "snowflake")
    }

    func testColdNamesReReadSizeAndFullPrice() {
        let activity = ClaudeSessionActivity(filePath: "/tmp/fake.jsonl", timestamp: now.addingTimeInterval(-600), inputTokens: 500, cacheReadTokens: 4_500, cacheCreationTokens: 0, sessionLabel: "my-project")
        let line = ClaudeCacheTemperature.evaluate(activity: activity, now: now, ttlSeconds: 300)

        guard case let .badge(_, text, tone, icon, detail) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(tone, .warning)
        XCTAssertEqual(icon, "snowflake")
        XCTAssertEqual(text, "my-project")
        XCTAssertEqual(detail, "cold · re-reads ~5k tok") // 500 + 4500 = 5000 -> "5k"
    }

    func testResolveTTLSecondsDefaultsAndClampsAndRejectsInvalid() {
        XCTAssertEqual(ClaudeCacheTemperature.resolveTTLSeconds(environment: [:]), 300)
        XCTAssertEqual(ClaudeCacheTemperature.resolveTTLSeconds(environment: ["TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS": "not-a-number"]), 300)
        XCTAssertEqual(ClaudeCacheTemperature.resolveTTLSeconds(environment: ["TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS": "3600"]), 3600)
        XCTAssertEqual(ClaudeCacheTemperature.resolveTTLSeconds(environment: ["TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS": "0"]), 5)
        XCTAssertEqual(ClaudeCacheTemperature.resolveTTLSeconds(environment: ["TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS": "-50"]), 5)
    }

    func testCustomBadgeIDDistinguishesMultipleSessions() {
        let activity = ClaudeSessionActivity(filePath: "/tmp/other.jsonl", timestamp: now.addingTimeInterval(-30), inputTokens: 1, cacheReadTokens: 10, cacheCreationTokens: 0, sessionLabel: "other-project")
        let line = ClaudeCacheTemperature.evaluate(activity: activity, now: now, ttlSeconds: 300, badgeID: "cacheTemperature-other-0")

        guard case let .badge(id, _, _, _, _) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(id, "cacheTemperature-other-0")
    }
}
