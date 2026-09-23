import Foundation

/// Thread-safe, synchronously-readable cache of model pricing fetched at runtime, consulted by
/// `ModelPricing.rate(provider:model:)` before its own static, deliberately-goes-stale table.
/// Empty until `PricingRefreshService`'s first successful fetch (or a warm on-disk cache loads),
/// so pricing always works offline and on first launch -- this is a best-effort enhancement
/// layered on top of the static table, never a hard dependency for cost estimates to work at all.
final class DynamicPricingCache: @unchecked Sendable {
    static let shared = DynamicPricingCache()

    private let lock = NSLock()
    private var rates: [String: ModelPricing.Rate] = [:]
    /// Lazily-built, per-family-hint subset of `rates` (keys containing that hint), computed
    /// once per hint and reused instead of re-filtering the full live price list on every
    /// `bestMatch` call. `PricingRefreshService` populates `rates` from LiteLLM's public price
    /// list -- every model from every vendor, typically 1000+ entries -- and a 30-day local
    /// history scan calls `bestMatch` once per turn (thousands of calls). Re-running
    /// `.contains(familyHint)` across the full unfiltered table on every one of those calls
    /// measured as a genuine multi-minute hang (confirmed via `sample` on the running process,
    /// not a guess); this index turns it back into one filter pass per hint, not one per turn.
    /// Cleared whenever `rates` is replaced.
    private var ratesByFamilyHint: [String: [String: ModelPricing.Rate]] = [:]
    private(set) var lastUpdated: Date?

    /// Longest-prefix match, same rule as the static table's own lookup, restricted to keys
    /// containing `familyHint` (e.g. "claude", "gpt") so an unrelated vendor's similarly-named
    /// model in the same flat price list can't be mismatched onto the wrong provider.
    func bestMatch(candidates: [String], familyHint: String) -> ModelPricing.Rate? {
        guard !familyHint.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !rates.isEmpty else { return nil }

        let scoped: [String: ModelPricing.Rate]
        if let cached = ratesByFamilyHint[familyHint] {
            scoped = cached
        } else {
            scoped = rates.filter { $0.key.contains(familyHint) }
            ratesByFamilyHint[familyHint] = scoped
        }
        guard !scoped.isEmpty else { return nil }

        var best: (keyLength: Int, rate: ModelPricing.Rate)?
        for candidate in candidates {
            for (key, rate) in scoped where candidate.hasPrefix(key) {
                if best == nil || key.count > best!.keyLength {
                    best = (key.count, rate)
                }
            }
        }
        return best?.rate
    }

    func replace(_ newRates: [String: ModelPricing.Rate], updatedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        rates = newRates
        ratesByFamilyHint = [:]
        lastUpdated = updatedAt
    }
}
