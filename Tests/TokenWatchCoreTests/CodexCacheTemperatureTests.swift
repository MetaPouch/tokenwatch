import XCTest
@testable import TokenWatchCore

final class CodexCacheTemperatureTests: XCTestCase {
    func testNilActivityYieldsNoLine() {
        XCTAssertNil(CodexCacheTemperature.evaluate(activity: nil))
    }

    func testWarmWhenCachedTokensPositiveShowsHitRatio() {
        let activity = CodexSessionActivity(filePath: "/tmp/fake.jsonl", timestamp: Date(), inputTokens: 18193, cachedInputTokens: 10624, sessionLabel: "my-project")
        let line = CodexCacheTemperature.evaluate(activity: activity)

        guard case let .badge(id, text, tone, icon, detail) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(id, "cacheTemperature")
        XCTAssertEqual(tone, .neutral)
        XCTAssertEqual(icon, "flame.fill")
        XCTAssertEqual(text, "my-project")
        XCTAssertEqual(detail, "58% hit last turn") // 10624 / 18193 rounds to 58%
        // Never claims a precise expiry -- unlike Claude, Codex's retention isn't locally knowable.
        XCTAssertFalse((detail ?? "").contains("expires"))
    }

    /// Defensive edge case: `cachedInputTokens > 0` but `inputTokens == 0` shouldn't divide by
    /// zero computing the hit ratio -- still reports warm, just without a percentage.
    func testWarmOmitsHitRatioWhenInputTokensIsZero() {
        let activity = CodexSessionActivity(filePath: "/tmp/fake.jsonl", timestamp: Date(), inputTokens: 0, cachedInputTokens: 5, sessionLabel: "my-project")
        guard case let .badge(_, _, tone, icon, detail) = CodexCacheTemperature.evaluate(activity: activity) else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(tone, .neutral)
        XCTAssertEqual(icon, "flame.fill")
        XCTAssertEqual(detail, "cache hit last turn")
    }

    func testColdWhenNoCachedTokensNamesReReadSize() {
        let activity = CodexSessionActivity(filePath: "/tmp/fake.jsonl", timestamp: Date(), inputTokens: 5_000, cachedInputTokens: 0, sessionLabel: "my-project")
        let line = CodexCacheTemperature.evaluate(activity: activity)

        guard case let .badge(_, text, tone, icon, detail) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(tone, .warning)
        XCTAssertEqual(icon, "snowflake")
        XCTAssertEqual(text, "my-project")
        XCTAssertEqual(detail, "no hit last turn · re-reads ~5.0K tok if cold")
    }

    func testCustomBadgeIDDistinguishesMultipleSessions() {
        let activity = CodexSessionActivity(filePath: "/tmp/other.jsonl", timestamp: Date(), inputTokens: 100, cachedInputTokens: 10, sessionLabel: "other-project")
        let line = CodexCacheTemperature.evaluate(activity: activity, badgeID: "cacheTemperature-other-0")

        guard case let .badge(id, _, _, _, _) = line else {
            return XCTFail("expected a badge line")
        }
        XCTAssertEqual(id, "cacheTemperature-other-0")
    }
}
