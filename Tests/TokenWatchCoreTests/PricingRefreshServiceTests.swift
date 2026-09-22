import XCTest
@testable import TokenWatchCore

final class PricingRefreshServiceTests: XCTestCase {
    func testParsesLiteLLMShapedEntries() {
        let json = """
        {
            "claude-sonnet-6": {
                "input_cost_per_token": 0.000002,
                "output_cost_per_token": 0.00001,
                "cache_read_input_token_cost": 0.0000002
            }
        }
        """.data(using: .utf8)!

        let rates = PricingRefreshService.parse(json)
        let rate = rates?["claude-sonnet-6"]
        XCTAssertEqual(rate?.inputPerMillion ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(rate?.outputPerMillion ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(rate?.cacheReadPerMillion ?? -1, 0.2, accuracy: 0.001)
    }

    func testLowercasesModelKeys() {
        let json = """
        { "Claude-Sonnet-6": { "input_cost_per_token": 0.000001, "output_cost_per_token": 0.000005 } }
        """.data(using: .utf8)!
        let rates = PricingRefreshService.parse(json)
        XCTAssertNotNil(rates?["claude-sonnet-6"])
        XCTAssertNil(rates?["Claude-Sonnet-6"])
    }

    func testSkipsEntriesMissingRequiredCostFields() {
        // A real LiteLLM file mixes real model entries with metadata-only entries (e.g.
        // "sample_spec") that have no cost fields at all -- those must be skipped, not crash
        // the parse or produce a bogus zero-cost rate.
        let json = """
        {
            "sample_spec": { "some_other_field": true },
            "claude-sonnet-6": { "input_cost_per_token": 0.000002, "output_cost_per_token": 0.00001 }
        }
        """.data(using: .utf8)!
        let rates = PricingRefreshService.parse(json)
        XCTAssertEqual(rates?.count, 1)
        XCTAssertNotNil(rates?["claude-sonnet-6"])
    }

    func testMissingCacheReadCostLeavesItNil() {
        let json = """
        { "gpt-6": { "input_cost_per_token": 0.000001, "output_cost_per_token": 0.000008 } }
        """.data(using: .utf8)!
        let rates = PricingRefreshService.parse(json)
        XCTAssertNil(rates?["gpt-6"]?.cacheReadPerMillion)
    }

    func testEmptyOrAllUnparseableInputReturnsNil() {
        XCTAssertNil(PricingRefreshService.parse("{}".data(using: .utf8)!))
        XCTAssertNil(PricingRefreshService.parse("not json".data(using: .utf8)!))
        XCTAssertNil(PricingRefreshService.parse("""
        { "sample_spec": { "some_other_field": true } }
        """.data(using: .utf8)!))
    }
}
