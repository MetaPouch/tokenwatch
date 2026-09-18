import XCTest
@testable import TokenWatchCore

final class CopilotMapperTests: XCTestCase {
    func testPrefersPremiumInteractionsOverChat() throws {
        let json = """
        {
          "quota_snapshots": {"premium_interactions": {"percent_remaining": 70.0}, "chat": {"percent_remaining": 40.0}},
          "copilot_plan": "individual"
        }
        """
        let response = try JSONDecoder().decode(CopilotUserResponse.self, from: Data(json.utf8))
        let (lines, plan) = CopilotMapper.map(response)

        XCTAssertEqual(plan, "individual")
        XCTAssertEqual(lines.count, 1)
        guard case let .progress(_, label, used, limit, _, resetsAt, _) = lines[0] else {
            return XCTFail("expected progress line")
        }
        XCTAssertEqual(label, "Premium interactions")
        XCTAssertEqual(used, 30.0)
        XCTAssertEqual(limit, 100)
        XCTAssertNil(resetsAt)
    }

    func testFallsBackToChatWhenPremiumInteractionsAbsent() throws {
        let json = """
        {"quota_snapshots": {"chat": {"percent_remaining": 90.0}}}
        """
        let response = try JSONDecoder().decode(CopilotUserResponse.self, from: Data(json.utf8))
        let (lines, _) = CopilotMapper.map(response)

        guard case let .progress(_, _, used, _, _, _, _) = lines[0] else {
            return XCTFail("expected progress line")
        }
        XCTAssertEqual(used, 10.0)
    }

    func testEmptyWhenNoQuotaSnapshots() throws {
        let json = "{}"
        let response = try JSONDecoder().decode(CopilotUserResponse.self, from: Data(json.utf8))
        let (lines, _) = CopilotMapper.map(response)
        XCTAssertTrue(lines.isEmpty)
    }
}
