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

    func testOneHourCacheWritesCostTwiceInputRate() {
        // 3M written, 2M of it with a 1-hour TTL: 1M x $2.5/M (5-minute) + 2M x $4/M (1-hour).
        let cost = ModelPricing.costUSD(provider: .claude, model: "claude-sonnet-5", inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 3_000_000, cacheWrite1hTokens: 2_000_000, outputTokens: 0)
        XCTAssertEqual(cost, 2.5 + 8, accuracy: 0.0001)
    }

    func testCostUSDIsZeroForZeroTokens() {
        let cost = ModelPricing.costUSD(provider: .claude, model: "claude-sonnet-5", inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0)
        XCTAssertEqual(cost, 0)
    }

    /// OpenRouter and harnesses spell Claude versions with a dot (`claude-haiku-4.5`); without
    /// normalizing, that prefix-matches nothing better than `claude-haiku-4` or falls back.
    func testDottedClaudeVersionPricesAsDashedId() {
        let (rate, approximate) = ModelPricing.rate(provider: .claude, model: "anthropic/claude-haiku-4.5")
        XCTAssertEqual(rate, ModelPricing.rate(provider: .claude, model: "claude-haiku-4-5").rate)
        XCTAssertEqual(rate.inputPerMillion, 1)
        XCTAssertFalse(approximate)
    }

    /// Newer point releases carry their own cache-read rate and must not fall through to the
    /// shorter family prefix (`claude-mythos-5-1` isn't `claude-mythos`'s 0.1x-input default).
    func testNewModelsResolveToTheirOwnRates() {
        XCTAssertEqual(ModelPricing.rate(provider: .claude, model: "claude-mythos-5-1").rate.cacheReadPerMillion, 0.25)
        XCTAssertEqual(ModelPricing.rate(provider: .claude, model: "claude-fable-5-1-20260601").rate.cacheReadPerMillion, 0.25)
        XCTAssertEqual(ModelPricing.rate(provider: .codex, model: "gpt-6-luna").rate.inputPerMillion, 0.1)
        XCTAssertEqual(ModelPricing.rate(provider: .codex, model: "gpt-5.6").rate, ModelPricing.rate(provider: .codex, model: "gpt-5.6-sol").rate)
    }

    /// Codex counts cache writes inside `input_tokens`, like cached reads. They're billed at 1.25x
    /// input, not at the plain input rate.
    func testCodexCacheWritesAreSplitOutOfInputAndPricedAtWriteRate() {
        // gpt-6-sol: $2/M input, so 1M plain + 1M written = $2 + $2.5.
        let withWrites = ModelPricing.codexCostUSD(model: "gpt-6-sol", inputTokens: 2_000_000, cachedInputTokens: 0, cacheWriteInputTokens: 1_000_000, outputTokens: 0)
        XCTAssertEqual(withWrites.cost, 2 + 2.5, accuracy: 1e-9)
    }
}
