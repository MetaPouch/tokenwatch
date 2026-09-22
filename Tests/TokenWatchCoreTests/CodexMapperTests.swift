import XCTest
@testable import TokenWatchCore

final class CodexMapperTests: XCTestCase {
    func testMapsPrimaryAndSecondaryWindows() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 21, "window_minutes": 300, "resets_at": "2026-06-29T16:09:04Z"},
            "secondary_window": {"used_percent": 8, "window_minutes": 10080, "reset_after_seconds": 200000}
          }
        }
        """
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lines = CodexMapper.map(response, now: now)

        XCTAssertEqual(lines.count, 2)
        guard case let .progress(id: sessionID, _, sessionUsed, _, _, sessionReset, sessionPeriod) = lines[0] else {
            return XCTFail("expected session progress line")
        }
        XCTAssertEqual(sessionID, "session")
        XCTAssertEqual(sessionUsed, 21)
        XCTAssertEqual(sessionPeriod, 300 * 60_000)
        XCTAssertNotNil(sessionReset)

        guard case let .progress(id: weeklyID, _, weeklyUsed, _, _, weeklyReset, _) = lines[1] else {
            return XCTFail("expected weekly progress line")
        }
        XCTAssertEqual(weeklyID, "weekly")
        XCTAssertEqual(weeklyUsed, 8)
        XCTAssertEqual(weeklyReset, now.addingTimeInterval(200000))
    }

    func testEmptyWhenNoRateLimit() throws {
        let json = "{}"
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let lines = CodexMapper.map(response)
        XCTAssertTrue(lines.isEmpty)
    }

    func testMapsAdditionalRateLimits() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 21, "window_minutes": 300, "resets_at": "2026-06-29T16:09:04Z"}
          },
          "additional_rate_limits": [
            {"limit_name": "gpt-5-codex-max", "rate_limit": {"primary_window": {"used_percent": 60, "window_minutes": 1440, "resets_at": "2026-06-30T00:00:00Z"}}},
            {"limit_name": "gpt-5.1", "rate_limit": {"primary_window": {"used_percent": 15, "window_minutes": 1440}}}
          ]
        }
        """
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let lines = CodexMapper.map(response)

        XCTAssertEqual(lines.count, 3)
        guard case let .progress(id, label, used, _, _, _, _) = lines[1] else {
            return XCTFail("expected first additional-limit line")
        }
        XCTAssertEqual(id, "additional:gpt-5-codex-max")
        XCTAssertEqual(label, "gpt-5-codex-max")
        XCTAssertEqual(used, 60)

        guard case let .progress(id2, label2, used2, _, _, _, _) = lines[2] else {
            return XCTFail("expected second additional-limit line")
        }
        XCTAssertEqual(id2, "additional:gpt-5.1")
        XCTAssertEqual(label2, "gpt-5.1")
        XCTAssertEqual(used2, 15)
    }

    func testSkipsAdditionalRateLimitWithoutUsablePrimaryWindow() throws {
        let json = """
        {
          "additional_rate_limits": [
            {"limit_name": "empty-limit", "rate_limit": {}}
          ]
        }
        """
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let lines = CodexMapper.map(response)
        XCTAssertTrue(lines.isEmpty)
    }

    func testAdditionalRateLimitFallsBackToOrdinalNameWhenMissing() throws {
        let json = """
        {
          "additional_rate_limits": [
            {"rate_limit": {"primary_window": {"used_percent": 5, "window_minutes": 60}}}
          ]
        }
        """
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let lines = CodexMapper.map(response)
        guard case let .progress(_, label, _, _, _, _, _) = lines[0] else {
            return XCTFail("expected a progress line")
        }
        XCTAssertEqual(label, "Limit 1")
    }
}
