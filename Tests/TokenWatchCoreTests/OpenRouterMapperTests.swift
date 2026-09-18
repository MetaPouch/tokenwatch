import XCTest
@testable import TokenWatchCore

final class OpenRouterMapperTests: XCTestCase {
    func testMapsKeyLimitAndBalance() throws {
        let creditsJSON = """
        {"data": {"total_credits": 100.0, "total_usage": 37.5}}
        """
        let keyJSON = """
        {"data": {"limit": 50.0, "limit_remaining": 12.5, "usage": 37.5}}
        """
        let credits = try JSONDecoder().decode(OpenRouterCreditsResponse.self, from: Data(creditsJSON.utf8))
        let key = try JSONDecoder().decode(OpenRouterKeyResponse.self, from: Data(keyJSON.utf8))

        let lines = OpenRouterMapper.map(credits: credits, key: key)

        XCTAssertEqual(lines.count, 2)
        guard case let .progress(_, _, used, limit, format, _, _) = lines[0] else {
            return XCTFail("expected progress line")
        }
        XCTAssertEqual(used, 37.5)
        XCTAssertEqual(limit, 50.0)
        XCTAssertEqual(format, .dollars)

        guard case let .values(_, _, values) = lines[1] else {
            return XCTFail("expected values line")
        }
        XCTAssertEqual(values.first?.number, 62.5)
    }

    func testOmitsKeyLimitWhenUnset() throws {
        let creditsJSON = """
        {"data": {"total_credits": 10.0, "total_usage": 1.0}}
        """
        let keyJSON = """
        {"data": {"limit": null, "limit_remaining": null, "usage": null}}
        """
        let credits = try JSONDecoder().decode(OpenRouterCreditsResponse.self, from: Data(creditsJSON.utf8))
        let key = try JSONDecoder().decode(OpenRouterKeyResponse.self, from: Data(keyJSON.utf8))

        let lines = OpenRouterMapper.map(credits: credits, key: key)

        XCTAssertEqual(lines.count, 1)
        guard case .values = lines[0] else {
            return XCTFail("expected only a values line")
        }
    }
}
