import XCTest
@testable import TokenWatchCore

final class GeminiMapperTests: XCTestCase {
    func testMapsLowestProAndFlashQuota() throws {
        let json = """
        {"buckets": [
          {"remainingFraction": 0.8, "resetTime": "2026-09-19T00:00:00Z", "modelId": "gemini-2.5-pro"},
          {"remainingFraction": 0.5, "resetTime": "2026-09-19T00:00:00Z", "modelId": "gemini-2.5-pro-vision"},
          {"remainingFraction": 0.9, "resetTime": "2026-09-19T00:00:00Z", "modelId": "gemini-2.5-flash"}
        ]}
        """
        let response = try JSONDecoder().decode(GeminiQuotaResponse.self, from: Data(json.utf8))
        let lines = try GeminiMapper.map(response)

        XCTAssertEqual(lines.count, 2)
        guard case let .progress(id: proID, _, proUsed, _, _, proReset, _) = lines[0] else {
            return XCTFail("expected pro progress line")
        }
        XCTAssertEqual(proID, "pro")
        XCTAssertEqual(proUsed, 50, accuracy: 0.01)
        XCTAssertNotNil(proReset)

        guard case let .progress(id: flashID, _, flashUsed, _, _, _, _) = lines[1] else {
            return XCTFail("expected flash progress line")
        }
        XCTAssertEqual(flashID, "flash")
        XCTAssertEqual(flashUsed, 10, accuracy: 0.01)
    }

    func testThrowsOnEmptyBuckets() throws {
        let json = """
        {"buckets": []}
        """
        let response = try JSONDecoder().decode(GeminiQuotaResponse.self, from: Data(json.utf8))
        XCTAssertThrowsError(try GeminiMapper.map(response))
    }
}
