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

    /// A real `PricingRefreshService` fetch populates thousands of entries (LiteLLM's public
    /// price list covers every model from every vendor), and a 30-day local-history scan calls
    /// `bestMatch` once per turn -- thousands of calls. Before the per-family-hint index, that
    /// combination measured as a genuine multi-minute hang in the real app (confirmed via
    /// `sample` on the running process): every call re-filtered the *entire* unscoped table with
    /// `.contains(familyHint)`. This reproduces that shape at a smaller but still realistic size
    /// and asserts it stays fast, so a future change can't silently reintroduce the same
    /// per-call full-table rescan.
    func testStaysFastWithALargeUnrelatedTableAndManyLookups() {
        let cache = DynamicPricingCache()
        var rates: [String: ModelPricing.Rate] = [:]
        for i in 0..<2000 {
            rates["some-other-vendor-model-\(i)"] = ModelPricing.Rate(inputPerMillion: 1, outputPerMillion: 1, cacheReadPerMillion: nil)
        }
        rates["claude-sonnet-6"] = ModelPricing.Rate(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: nil)
        cache.replace(rates, updatedAt: Date())

        let start = Date()
        for _ in 0..<3000 {
            let match = cache.bestMatch(candidates: ["claude-sonnet-6-20270101"], familyHint: "claude")
            XCTAssertEqual(match?.inputPerMillion, 3)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }
}
