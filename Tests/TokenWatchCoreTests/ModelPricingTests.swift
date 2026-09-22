import XCTest
@testable import TokenWatchCore

final class ModelPricingTests: XCTestCase {
    func testExactMatchForKnownClaudeModel() {
        let (rate, approximate) = ModelPricing.rate(provider: .claude, model: "claude-sonnet-5")
        XCTAssertEqual(rate.inputPerMillion, 2)
        XCTAssertEqual(rate.outputPerMillion, 10)
        XCTAssertFalse(approximate)
    }

    func testExactMatchForKnownCodexModel() {
        let (rate, approximate) = ModelPricing.rate(provider: .codex, model: "gpt-5-codex")
        XCTAssertEqual(rate.inputPerMillion, 1.25)
        XCTAssertEqual(rate.outputPerMillion, 10)
        XCTAssertFalse(approximate)
    }

    func testLongestPrefixMatchPrefersMoreSpecificModel() {
        // "gpt-5-codex" is a longer, more specific prefix match than the bare "gpt-5" entry.
        let (rate, _) = ModelPricing.rate(provider: .codex, model: "gpt-5-codex-20260101")
        XCTAssertEqual(rate.inputPerMillion, 1.25)
        XCTAssertEqual(rate.outputPerMillion, 10)
    }

    func testMatchesVendorQualifiedModelIdAfterSlash() {
        let (rate, approximate) = ModelPricing.rate(provider: .claude, model: "anthropic/claude-sonnet-5")
        XCTAssertEqual(rate.inputPerMillion, 2)
        XCTAssertFalse(approximate)
    }

    func testFallsBackToCheapestRateForUnknownModel() {
        let (rate, approximate) = ModelPricing.rate(provider: .claude, model: "some-future-model-9000")
        XCTAssertTrue(approximate)
        // The cheapest known Claude rate in the table is claude-3-5-haiku at 0.8/4.
        XCTAssertEqual(rate.inputPerMillion, 0.8)
    }

    func testUnsupportedProviderYieldsApproximateZeroRate() {
        let (rate, approximate) = ModelPricing.rate(provider: .openai, model: "gpt-4o")
        XCTAssertTrue(approximate)
        XCTAssertEqual(rate.inputPerMillion, 0)
    }

    func testCostUSDSumsInputOutputAndCacheComponents() {
        // claude-sonnet-5: input $2/M, output $10/M, cacheRead defaults to 0.1x input = $0.2/M,
        // cacheWrite = 1.25x input = $2.5/M.
        let cost = ModelPricing.costUSD(provider: .claude, model: "claude-sonnet-5", inputTokens: 1_000_000, cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000, outputTokens: 1_000_000)
        XCTAssertEqual(cost, 2 + 10 + 0.2 + 2.5, accuracy: 0.0001)
    }

    func testCostUSDIsZeroForZeroTokens() {
        let cost = ModelPricing.costUSD(provider: .claude, model: "claude-sonnet-5", inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0)
        XCTAssertEqual(cost, 0)
    }
}
