import XCTest
@testable import TokenWatchCore

final class ClaudeMapperTests: XCTestCase {
    /// Fixture captured from a live `GET /api/oauth/usage` response (accessToken/refreshToken
    /// redacted; unused fields trimmed).
    func testMapsSessionWeeklyAndExtraUsage() throws {
        let json = """
        {
          "five_hour": {"utilization": 14.0, "resets_at": "2026-09-18T20:10:00.691202+00:00"},
          "seven_day": {"utilization": 8.0, "resets_at": "2026-09-24T09:00:00.691226+00:00"},
          "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1250, "utilization": 25.0}
        }
        """
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        let lines = ClaudeMapper.map(response)

        XCTAssertEqual(lines.count, 3)
        guard case let .progress(id: sessionID, _, sessionUsed, sessionLimit, _, sessionReset, _) = lines[0] else {
            return XCTFail("expected session progress line")
        }
        XCTAssertEqual(sessionID, "session")
        XCTAssertEqual(sessionUsed, 14.0)
        XCTAssertEqual(sessionLimit, 100)
        XCTAssertNotNil(sessionReset)

        guard case let .progress(id: weeklyID, _, weeklyUsed, _, _, _, _) = lines[1] else {
            return XCTFail("expected weekly progress line")
        }
        XCTAssertEqual(weeklyID, "weekly")
        XCTAssertEqual(weeklyUsed, 8.0)

        guard case let .progress(id: extraID, _, extraUsed, extraLimit, format, _, _) = lines[2] else {
            return XCTFail("expected extra usage progress line")
        }
        XCTAssertEqual(extraID, "extraUsage")
        XCTAssertEqual(extraUsed, 12.5)
        XCTAssertEqual(extraLimit, 50)
        XCTAssertEqual(format, .dollars)
    }

    func testOmitsExtraUsageWhenDisabled() throws {
        let json = """
        {
          "five_hour": {"utilization": 14.0, "resets_at": null},
          "seven_day": {"utilization": 8.0, "resets_at": null},
          "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null}
        }
        """
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        let lines = ClaudeMapper.map(response)
        XCTAssertEqual(lines.count, 2)
    }
}
