import XCTest
@testable import TokenWatchCore

final class GrokMapperTests: XCTestCase {
    func testUsesCreditUsagePercentWhenPresent() throws {
        let json = """
        {"config": {"creditUsagePercent": 42, "currentPeriod": {"end": "2026-07-01T00:00:00Z"}, "subscriptionTier": "SuperGrok"}}
        """
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: Data(json.utf8))
        let (lines, plan) = GrokMapper.map(response)

        XCTAssertEqual(plan, "SuperGrok")
        XCTAssertEqual(lines.count, 1)
        guard case let .progress(_, _, used, limit, _, resetsAt, _) = lines[0] else {
            return XCTFail("expected progress line")
        }
        XCTAssertEqual(used, 42)
        XCTAssertEqual(limit, 100)
        XCTAssertNotNil(resetsAt)
    }

    func testFallsBackToOnDemandRatio() throws {
        let json = """
        {"config": {"billingPeriodEnd": "2026-07-01T00:00:00Z"}, "onDemandUsed": {"val": 25}, "onDemandCap": {"val": 100}}
        """
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: Data(json.utf8))
        let (lines, _) = GrokMapper.map(response)

        guard case let .progress(_, _, used, _, _, _, _) = lines[0] else {
            return XCTFail("expected progress line")
        }
        XCTAssertEqual(used, 25)
    }

    func testEmptyWhenNoUsageSignal() throws {
        let json = "{\"config\": {}}"
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: Data(json.utf8))
        let (lines, _) = GrokMapper.map(response)
        XCTAssertTrue(lines.isEmpty)
    }
}
