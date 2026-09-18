import XCTest
@testable import TokenWatchCore

final class OpenAIMapperTests: XCTestCase {
    func testSumsSpendAcrossBucketsAndResults() throws {
        let todayJSON = """
        {"data": [{"results": [{"amount": {"value": 0.06, "currency": "usd"}}, {"amount": {"value": 0.04, "currency": "usd"}}]}]}
        """
        let weekJSON = """
        {"data": [
          {"results": [{"amount": {"value": 0.06}}]},
          {"results": [{"amount": {"value": 1.5}}]}
        ]}
        """
        let today = try JSONDecoder().decode(OpenAICostsResponse.self, from: Data(todayJSON.utf8))
        let week = try JSONDecoder().decode(OpenAICostsResponse.self, from: Data(weekJSON.utf8))

        XCTAssertEqual(OpenAIMapper.totalSpend(today), 0.10, accuracy: 0.0001)
        XCTAssertEqual(OpenAIMapper.totalSpend(week), 1.56, accuracy: 0.0001)

        let lines = OpenAIMapper.map(today: today, last7Days: week)
        XCTAssertEqual(lines.count, 1)
        guard case let .values(_, label, values) = lines[0] else {
            return XCTFail("expected values line")
        }
        XCTAssertEqual(label, "Spend")
        XCTAssertEqual(values.first(where: { $0.kind == "Today" })?.number ?? -1, 0.10, accuracy: 0.0001)
        XCTAssertEqual(values.first(where: { $0.kind == "Last 7 days" })?.number ?? -1, 1.56, accuracy: 0.0001)
    }

    func testEmptyDataYieldsZeroSpend() throws {
        let json = "{\"data\": []}"
        let response = try JSONDecoder().decode(OpenAICostsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(OpenAIMapper.totalSpend(response), 0)
    }
}
