import XCTest
@testable import TokenWatchCore

final class AmpMapperTests: XCTestCase {
    func testParsesFreeMeterAndIndividualCredits() {
        let text = """
        Signed in as dev@example.com
        Amp Free: $3.50/$10.00 remaining (replenishes +$0.42/hour)
        Individual credits: $27.10 remaining - https://ampcode.com/settings
        """
        let lines = AmpMapper.map(displayText: text)

        XCTAssertEqual(lines.count, 2)
        guard case let .progress(id: freeID, _, used, limit, format, _, _) = lines[0] else {
            return XCTFail("expected Amp Free progress line")
        }
        XCTAssertEqual(freeID, "ampFree")
        XCTAssertEqual(used, 6.5, accuracy: 0.001)
        XCTAssertEqual(limit, 10.0)
        XCTAssertEqual(format, .dollars)

        guard case let .values(_, _, values) = lines[1] else {
            return XCTFail("expected credits values line")
        }
        XCTAssertEqual(values.first?.number ?? -1, 27.10, accuracy: 0.001)
        XCTAssertEqual(values.first?.kind, "Individual")
    }

    func testParsesPaidTierWithOnlyIndividualCredits() {
        let text = "Signed in as dev@example.com\nIndividual credits: $5.00 remaining - https://ampcode.com/settings"
        let lines = AmpMapper.map(displayText: text)
        XCTAssertEqual(lines.count, 1)
        guard case .values = lines[0] else {
            return XCTFail("expected only a values line for paid-only tier")
        }
    }

    func testEmptyWhenTextUnrecognized() {
        let lines = AmpMapper.map(displayText: "unexpected format")
        XCTAssertTrue(lines.isEmpty)
    }
}
