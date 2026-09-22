import XCTest
@testable import TokenWatchCore

final class DynamicPricingCacheTests: XCTestCase {
    // Every test uses a fresh instance, never `.shared` -- the singleton is read by
    // `ModelPricing.rate` in other test files, and polluting it here would make those tests'
    // outcome depend on run order.

    func testEmptyCacheNeverMatches() {
        let cache = DynamicPricingCache()
        XCTAssertNil(cache.bestMatch(candidates: ["claude-sonnet-6"], familyHint: "claude"))
    }

    func testMatchesOnlyWithinTheRequestedFamily() {
        let cache = DynamicPricingCache()
        cache.replace([
            "claude-sonnet-6": ModelPricing.Rate(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: nil),
        ], updatedAt: Date())

        let claudeMatch = cache.bestMatch(candidates: ["claude-sonnet-6-20270101"], familyHint: "claude")
        XCTAssertEqual(claudeMatch?.inputPerMillion, 3)

        // The candidate string prefix-matches the stored key either way -- only the family
        // filter can be rejecting this lookup, proving the guard actually runs.
        let wrongFamilyMatch = cache.bestMatch(candidates: ["claude-sonnet-6-20270101"], familyHint: "gpt")
        XCTAssertNil(wrongFamilyMatch)
    }

    func testLongestKeyWinsOnAmbiguousPrefix() {
        let cache = DynamicPricingCache()
        cache.replace([
            "claude-opus": ModelPricing.Rate(inputPerMillion: 15, outputPerMillion: 75, cacheReadPerMillion: nil),
            "claude-opus-5": ModelPricing.Rate(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: nil),
        ], updatedAt: Date())

        let match = cache.bestMatch(candidates: ["claude-opus-5-20270101"], familyHint: "claude")
        XCTAssertEqual(match?.inputPerMillion, 5) // the more specific "claude-opus-5" prefix, not "claude-opus"
    }

    func testReplaceOverwritesPreviousRates() {
        let cache = DynamicPricingCache()
        cache.replace(["claude-x": ModelPricing.Rate(inputPerMillion: 1, outputPerMillion: 1, cacheReadPerMillion: nil)], updatedAt: Date())
        cache.replace(["claude-y": ModelPricing.Rate(inputPerMillion: 2, outputPerMillion: 2, cacheReadPerMillion: nil)], updatedAt: Date())
        XCTAssertNil(cache.bestMatch(candidates: ["claude-x-2027"], familyHint: "claude"))
        XCTAssertNotNil(cache.bestMatch(candidates: ["claude-y-2027"], familyHint: "claude"))
    }
}
