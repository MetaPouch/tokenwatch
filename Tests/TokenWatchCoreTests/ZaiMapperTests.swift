import XCTest
@testable import TokenWatchCore

final class ZaiMapperTests: XCTestCase {
    func testMapsPrimaryAndSecondaryTokenLimits() throws {
        let json = """
        {
          "success": true,
          "code": 200,
          "data": {
            "planName": "Lite",
            "limits": [
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 40, "usage": 1000, "currentValue": null, "remaining": 600, "nextResetTime": 1700003600000},
              {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 10, "usage": 100000, "currentValue": null, "remaining": 90000, "nextResetTime": 1700100000000},
              {"type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 5, "usage": null, "currentValue": null, "remaining": null, "nextResetTime": null}
            ]
          }
        }
        """
        let response = try JSONDecoder().decode(ZaiQuotaResponse.self, from: Data(json.utf8))
        let (lines, plan) = try ZaiMapper.map(response)

        XCTAssertEqual(plan, "Lite")
        XCTAssertEqual(lines.count, 2)

        guard case let .progress(id: primaryID, _, primaryUsed, primaryLimit, _, primaryReset, primaryPeriod) = lines[0] else {
            return XCTFail("expected primary progress line")
        }
        XCTAssertEqual(primaryID, "primary")
        XCTAssertEqual(primaryUsed, 40, accuracy: 0.01)
        XCTAssertEqual(primaryLimit, 100)
        XCTAssertEqual(primaryPeriod, 5 * 60 * 60_000)
        XCTAssertNotNil(primaryReset)

        guard case let .progress(id: secondaryID, _, secondaryUsed, _, _, _, _) = lines[1] else {
            return XCTFail("expected secondary progress line")
        }
        XCTAssertEqual(secondaryID, "secondary")
        XCTAssertEqual(secondaryUsed, 10, accuracy: 0.01)
    }

    func testThrowsOnUnsuccessfulResponse() {
        let json = """
        {"success": false, "code": 401, "msg": "invalid token"}
        """
        XCTAssertThrowsError(try {
            let response = try JSONDecoder().decode(ZaiQuotaResponse.self, from: Data(json.utf8))
            _ = try ZaiMapper.map(response)
        }())
    }

    func testRecomputesPercentFromUsageAndRemaining() throws {
        let json = """
        {
          "success": true,
          "code": 200,
          "data": {
            "limits": [
              {"type": "CREDIT_LIMIT", "unit": 1, "number": 30, "percentage": 0, "usage": 200, "currentValue": null, "remaining": 50, "nextResetTime": null}
            ]
          }
        }
        """
        let response = try JSONDecoder().decode(ZaiQuotaResponse.self, from: Data(json.utf8))
        let (lines, _) = try ZaiMapper.map(response)

        guard case let .progress(_, label, used, _, _, _, _) = lines[0] else {
            return XCTFail("expected progress line")
        }
        XCTAssertEqual(label, "Credit quota")
        XCTAssertEqual(used, 75, accuracy: 0.01)
    }
}
