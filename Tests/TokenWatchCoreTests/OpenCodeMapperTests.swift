import XCTest
@testable import TokenWatchCore

final class OpenCodeMapperTests: XCTestCase {
    func testMapsRollingAndWeeklyUsage() throws {
        let json = """
        {"rollingUsage": {"usagePercent": 33.5, "resetInSec": 1800}, "weeklyUsage": {"usagePercent": 12.0, "resetInSec": 86400}}
        """
        let response = try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lines = OpenCodeMapper.map(response, now: now)

        XCTAssertEqual(lines.count, 2)
        guard case let .progress(id: rollingID, _, rollingUsed, rollingLimit, _, rollingReset, rollingPeriod) = lines[0] else {
            return XCTFail("expected rolling progress line")
        }
        XCTAssertEqual(rollingID, "rolling")
        XCTAssertEqual(rollingUsed, 33.5)
        XCTAssertEqual(rollingLimit, 100)
        XCTAssertEqual(rollingReset, now.addingTimeInterval(1800))
        XCTAssertEqual(rollingPeriod, 5 * 3600 * 1000)

        guard case let .progress(id: weeklyID, _, weeklyUsed, _, _, weeklyReset, _) = lines[1] else {
            return XCTFail("expected weekly progress line")
        }
        XCTAssertEqual(weeklyID, "weekly")
        XCTAssertEqual(weeklyUsed, 12.0)
        XCTAssertEqual(weeklyReset, now.addingTimeInterval(86400))
    }

    func testOmitsWeeklyLineWhenAbsent() throws {
        let json = """
        {"rollingUsage": {"usagePercent": 5.0, "resetInSec": 300}}
        """
        let response = try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(json.utf8))
        let lines = OpenCodeMapper.map(response)
        XCTAssertEqual(lines.count, 1)
    }
}
