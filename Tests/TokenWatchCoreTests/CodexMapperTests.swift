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
}
