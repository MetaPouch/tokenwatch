import XCTest
@testable import TokenWatchCore

final class CursorMapperTests: XCTestCase {
    func testMapsPlanAndOnDemandUsage() throws {
        let json = """
        {
          "billingCycleStart": "2026-09-01T00:00:00Z",
          "billingCycleEnd": "2026-10-01T00:00:00Z",
          "membershipType": "pro",
          "individualUsage": {
            "plan": {"used": 1500, "limit": 2000},
            "onDemand": {"used": 300, "limit": 1000}
          }
        }
        """
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: Data(json.utf8))
        let lines = CursorMapper.map(summary, userInfo: nil)

        XCTAssertEqual(lines.count, 2)
        guard case let .progress(id: planID, _, planUsed, planLimit, format, resetsAt, _) = lines[0] else {
            return XCTFail("expected plan progress line")
        }
        XCTAssertEqual(planID, "plan")
        XCTAssertEqual(planUsed, 15.0)
        XCTAssertEqual(planLimit, 20.0)
        XCTAssertEqual(format, .dollars)
        XCTAssertNotNil(resetsAt)

        guard case let .progress(id: onDemandID, _, onDemandUsed, onDemandLimit, _, _, _) = lines[1] else {
            return XCTFail("expected on-demand progress line")
        }
        XCTAssertEqual(onDemandID, "onDemand")
        XCTAssertEqual(onDemandUsed, 3.0)
        XCTAssertEqual(onDemandLimit, 10.0)
    }

    func testUnlimitedOnDemandBecomesValuesLine() throws {
        let json = """
        {
          "billingCycleStart": null, "billingCycleEnd": null, "membershipType": "pro",
          "individualUsage": {"plan": {"used": 0, "limit": 0}, "onDemand": {"used": 450, "limit": null}}
        }
        """
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: Data(json.utf8))
        let lines = CursorMapper.map(summary, userInfo: nil)

        XCTAssertEqual(lines.count, 1)
        guard case let .values(_, _, values) = lines[0] else {
            return XCTFail("expected values line for unlimited on-demand")
        }
        XCTAssertEqual(values.first?.number, 4.5)
    }
}
