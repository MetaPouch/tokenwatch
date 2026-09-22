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

    func testMapsSevenDaySonnetWindow() throws {
        let json = """
        {
          "five_hour": {"utilization": 14.0, "resets_at": null},
          "seven_day": {"utilization": 8.0, "resets_at": null},
          "seven_day_sonnet": {"utilization": 42.0, "resets_at": "2026-09-24T09:00:00Z"}
        }
        """
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        let lines = ClaudeMapper.map(response)
        XCTAssertEqual(lines.count, 3)
        guard case let .progress(id, label, used, _, _, resetsAt, _) = lines[2] else {
            return XCTFail("expected seven_day_sonnet progress line")
        }
        XCTAssertEqual(id, "weekly_sonnet")
        XCTAssertEqual(label, "Weekly · Sonnet")
        XCTAssertEqual(used, 42.0)
        XCTAssertNotNil(resetsAt)
    }

    func testMapsPerModelWeeklyScopedLimits() throws {
        let json = """
        {
          "five_hour": {"utilization": 14.0, "resets_at": null},
          "seven_day": {"utilization": 8.0, "resets_at": null},
          "limits": [
            {"kind": "weekly_scoped", "percent": 55.0, "resets_at": "2026-09-24T09:00:00Z", "scope": {"model": {"display_name": "Opus"}}},
            {"kind": "weekly_scoped", "percent": 12.0, "resets_at": null, "scope": {"model": {"display_name": "Haiku"}}}
          ]
        }
        """
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        let lines = ClaudeMapper.map(response)
        XCTAssertEqual(lines.count, 4)
        guard case let .progress(id, label, used, _, _, _, _) = lines[2] else {
            return XCTFail("expected Opus weekly_scoped line")
        }
        XCTAssertEqual(id, "weekly_scoped:Opus")
        XCTAssertEqual(label, "Weekly · Opus")
        XCTAssertEqual(used, 55.0)
        guard case let .progress(id2, label2, _, _, _, _, _) = lines[3] else {
            return XCTFail("expected Haiku weekly_scoped line")
        }
        XCTAssertEqual(id2, "weekly_scoped:Haiku")
        XCTAssertEqual(label2, "Weekly · Haiku")
    }

    func testIgnoresNonWeeklyScopedLimitsAndMissingModelName() throws {
        let json = """
        {
          "five_hour": {"utilization": 14.0, "resets_at": null},
          "seven_day": {"utilization": 8.0, "resets_at": null},
          "limits": [
            {"kind": "other_kind", "percent": 90.0, "scope": {"model": {"display_name": "Opus"}}},
            {"kind": "weekly_scoped", "percent": 90.0, "scope": {}}
          ]
        }
        """
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        let lines = ClaudeMapper.map(response)
        XCTAssertEqual(lines.count, 2)
    }

    func testSkipsDuplicateWeeklyScopedLabelIfAlreadyPresent() throws {
        // A limits[] entry whose composed label collides with seven_day_sonnet's own label is
        // skipped rather than shown twice.
        let json = """
        {
          "five_hour": {"utilization": 14.0, "resets_at": null},
          "seven_day": {"utilization": 8.0, "resets_at": null},
          "seven_day_sonnet": {"utilization": 40.0, "resets_at": null},
          "limits": [
            {"kind": "weekly_scoped", "percent": 99.0, "scope": {"model": {"display_name": "Sonnet"}}}
          ]
        }
        """
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        let lines = ClaudeMapper.map(response)
        XCTAssertEqual(lines.count, 3)
    }
}
