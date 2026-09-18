import XCTest
@testable import TokenWatchCore

final class KimiMapperTests: XCTestCase {
    func testMapsWeeklyAndSessionWindows() throws {
        let json = """
        {
          "usage": {"limit": "2048", "used": "214", "remaining": "1834", "resetTime": "2026-01-09T15:23:13.716839300Z"},
          "limits": [{
            "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
            "detail": {"limit": "200", "used": "139", "remaining": "61", "resetTime": "2026-01-06T13:33:02.717479433Z"}
          }]
        }
        """
        let response = try JSONDecoder().decode(KimiUsagesResponse.self, from: Data(json.utf8))
        let lines = KimiMapper.map(response)

        XCTAssertEqual(lines.count, 2)
        guard case let .progress(id: weeklyID, _, weeklyUsed, weeklyLimit, _, weeklyReset, _) = lines[0] else {
            return XCTFail("expected weekly progress line")
        }
        XCTAssertEqual(weeklyID, "weekly")
        XCTAssertEqual(weeklyUsed, 214)
        XCTAssertEqual(weeklyLimit, 2048)
        XCTAssertNotNil(weeklyReset)

        guard case let .progress(id: sessionID, _, sessionUsed, sessionLimit, _, _, sessionPeriod) = lines[1] else {
            return XCTFail("expected session progress line")
        }
        XCTAssertEqual(sessionID, "session")
        XCTAssertEqual(sessionUsed, 139)
        XCTAssertEqual(sessionLimit, 200)
        XCTAssertEqual(sessionPeriod, 300 * 60_000)
    }

    func testOmitsSessionWindowWhenLimitsMissing() throws {
        let json = """
        {"usage": {"limit": "1024", "used": "10", "remaining": "1014", "resetTime": null}}
        """
        let response = try JSONDecoder().decode(KimiUsagesResponse.self, from: Data(json.utf8))
        let lines = KimiMapper.map(response)
        XCTAssertEqual(lines.count, 1)
    }
}
