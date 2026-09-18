import XCTest
@testable import TokenWatchCore

final class AntigravityMapperTests: XCTestCase {
    func testPrefersFiveHourBucketAsPrimary() throws {
        let json = """
        {"groups": [
          {"description": "Gemini", "buckets": [
            {"bucketId": "weekly", "displayName": "Weekly Limit", "remainingFraction": 0.95, "resetTime": "2026-07-06T19:00:00Z", "window": "7d"},
            {"bucketId": "5h", "displayName": "Five Hour Limit", "remainingFraction": 0.625, "resetTime": "2026-06-29T23:00:00Z", "window": "5h"}
          ]},
          {"description": "Claude and GPT", "buckets": [
            {"bucketId": "other", "displayName": "Other", "remainingFraction": 1.0, "disabled": true}
          ]}
        ]}
        """
        let response = try JSONDecoder().decode(AntigravityQuotaSummaryResponse.self, from: Data(json.utf8))
        let lines = try AntigravityMapper.map(response)

        XCTAssertEqual(lines.count, 2)
        guard case let .progress(id: primaryID, label: primaryLabel, primaryUsed, _, _, primaryReset, _) = lines[0] else {
            return XCTFail("expected primary progress line")
        }
        XCTAssertEqual(primaryID, "primary")
        XCTAssertEqual(primaryLabel, "Five Hour Limit")
        XCTAssertEqual(primaryUsed, 37.5, accuracy: 0.01)
        XCTAssertNotNil(primaryReset)

        guard case let .progress(id: secondaryID, label: secondaryLabel, secondaryUsed, _, _, _, _) = lines[1] else {
            return XCTFail("expected secondary progress line")
        }
        XCTAssertEqual(secondaryID, "secondary")
        XCTAssertEqual(secondaryLabel, "Weekly Limit")
        XCTAssertEqual(secondaryUsed, 5.0, accuracy: 0.01)
    }

    func testThrowsWhenNoBuckets() throws {
        let json = "{\"groups\": []}"
        let response = try JSONDecoder().decode(AntigravityQuotaSummaryResponse.self, from: Data(json.utf8))
        XCTAssertThrowsError(try AntigravityMapper.map(response))
    }
}
