import XCTest
@testable import TokenWatchCore

final class ClaudeCacheTemperatureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNilActivityYieldsNoLine() {
        XCTAssertNil(ClaudeCacheTemperature.evaluate(activity: nil, now: now, ttlSeconds: 300))
    }

    func testWarmWithinTTLShowsHitRatioAndExpiry() {
        let activity = ClaudeSessionActivity(timestamp: now.addingTimeInterval(-120), inputTokens: 2, cacheReadTokens: 484_489, cacheCreationTokens: 1_460, sessionLabel: "my-project")
        let line = ClaudeCacheTemperature.evaluate(activity: activity, now: now, ttlSeconds: 300)

        guard case let .badge(id, text, tone) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(id, "cacheTemperature")
        XCTAssertEqual(tone, .neutral)
        XCTAssertTrue(text.contains("Cache warm"), text)
        XCTAssertTrue(text.contains("100% hit"), text) // 484489 / (484489+1460+2) rounds to 100%
        XCTAssertTrue(text.contains("my-project"), text)
    }

    func testWarmOmitsHitRatioWhenNoCacheActivity() {
        let activity = ClaudeSessionActivity(timestamp: now.addingTimeInterval(-10), inputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, sessionLabel: "my-project")
        let line = ClaudeCacheTemperature.evaluate(activity: activity, now: now, ttlSeconds: 300)

        guard case let .badge(_, text, tone) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(tone, .neutral)
        XCTAssertFalse(text.contains("hit"))
        XCTAssertTrue(text.contains("Cache warm"))
    }

    func testExactExpiryBoundaryIsAlreadyCold() {
        let activity = ClaudeSessionActivity(timestamp: now.addingTimeInterval(-300), inputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 0, sessionLabel: "my-project")
        let line = ClaudeCacheTemperature.evaluate(activity: activity, now: now, ttlSeconds: 300)

        guard case let .badge(_, _, tone) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(tone, .warning)
    }

    func testColdNamesReReadSizeAndFullPrice() {
        let activity = ClaudeSessionActivity(timestamp: now.addingTimeInterval(-600), inputTokens: 500, cacheReadTokens: 4_500, cacheCreationTokens: 0, sessionLabel: "my-project")
        let line = ClaudeCacheTemperature.evaluate(activity: activity, now: now, ttlSeconds: 300)

        guard case let .badge(_, text, tone) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(tone, .warning)
        XCTAssertTrue(text.contains("Cache cold"), text)
        XCTAssertTrue(text.contains("5k tok"), text) // 500 + 4500 = 5000 -> "5k"
        XCTAssertTrue(text.contains("full price"), text)
        XCTAssertTrue(text.contains("my-project"), text)
    }

    func testResolveTTLSecondsDefaultsAndClampsAndRejectsInvalid() {
        XCTAssertEqual(ClaudeCacheTemperature.resolveTTLSeconds(environment: [:]), 300)
        XCTAssertEqual(ClaudeCacheTemperature.resolveTTLSeconds(environment: ["TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS": "not-a-number"]), 300)
        XCTAssertEqual(ClaudeCacheTemperature.resolveTTLSeconds(environment: ["TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS": "3600"]), 3600)
        XCTAssertEqual(ClaudeCacheTemperature.resolveTTLSeconds(environment: ["TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS": "0"]), 5)
        XCTAssertEqual(ClaudeCacheTemperature.resolveTTLSeconds(environment: ["TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS": "-50"]), 5)
    }
}
