import Foundation

/// API list prices in USD per million tokens, used only to estimate what local session usage
/// *would have cost* at direct API rates ("what this would cost on the API," never actual money
/// spent -- subscription usage isn't billed per token). Ported from
/// github.com/superset-sh/superset's own maintained pricing table
/// (`packages/host-service/src/trpc/router/usage/history/pricing.ts`), the grounded source for
/// both these rates and the exact model-name strings TokenWatch's own local session scanners
/// encounter (`claude-sonnet-5`, `gpt-5-codex`, ...). This table goes stale as vendors change
/// prices -- `pricingTableUpdatedOn` is surfaced in the UI so an estimate is never presented as
/// more current than it actually is.
public enum ModelPricing {
    public static let pricingTableUpdatedOn = "2026-09-11"

    struct Rate {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double?
    }

    /// Cache-read price as a share of the input rate, for models without their own explicit
    /// cache-read rate.
    private static let cacheReadMultiplier = 0.1
    /// Cache-write (ephemeral 5-minute breakpoint) price as a multiple of the input rate.
    private static let cacheWriteMultiplier = 1.25

    private static let claudeRates: [String: Rate] = [
        "claude-opus-5": Rate(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: nil),
        "claude-opus-4-8": Rate(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: nil),
        "claude-opus-4-7": Rate(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: nil),
        "claude-opus-4-6": Rate(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: nil),
        "claude-opus-4-5": Rate(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: nil),
        "claude-opus-4": Rate(inputPerMillion: 15, outputPerMillion: 75, cacheReadPerMillion: nil),
        "claude-sonnet-5": Rate(inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: nil),
        "claude-sonnet-4": Rate(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: nil),
        "claude-haiku-4-5": Rate(inputPerMillion: 1, outputPerMillion: 5, cacheReadPerMillion: nil),
        "claude-3-5-haiku": Rate(inputPerMillion: 0.8, outputPerMillion: 4, cacheReadPerMillion: nil),
    ]

    private static let codexRates: [String: Rate] = [
        "gpt-5.3-codex": Rate(inputPerMillion: 1.75, outputPerMillion: 14, cacheReadPerMillion: nil),
        "gpt-5.3": Rate(inputPerMillion: 1.75, outputPerMillion: 14, cacheReadPerMillion: nil),
        "gpt-5-codex": Rate(inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: nil),
        "gpt-5": Rate(inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: nil),
        "gpt-4.1": Rate(inputPerMillion: 2, outputPerMillion: 8, cacheReadPerMillion: nil),
        "gpt-4o": Rate(inputPerMillion: 2.5, outputPerMillion: 10, cacheReadPerMillion: nil),
    ]

    private static func table(for provider: ProviderID) -> [String: Rate] {
        switch provider {
        case .claude: return claudeRates
        case .codex: return codexRates
        default: return [:]
        }
    }

    /// Longest-prefix match against the model id (lowercased); also tries the segment after a
    /// vendor-qualifying slash (`anthropic/claude-sonnet-4`), matching how multi-model harnesses
    /// -- including the one behind `OmpSessionScanner` -- qualify ids. Falls back to the
    /// provider's cheapest known rate when nothing matches (flagged `approximate`), since an
    /// unpriced $0 fallback would understate cost more than a rough estimate does.
    static func rate(provider: ProviderID, model: String) -> (rate: Rate, approximate: Bool) {
        let table = Self.table(for: provider)
        guard !table.isEmpty else { return (Rate(inputPerMillion: 0, outputPerMillion: 0, cacheReadPerMillion: nil), true) }

        let normalized = model.lowercased()
        var candidates = [normalized]
        if let slashIndex = normalized.lastIndex(of: "/") {
            let afterSlash = normalized.index(after: slashIndex)
            if afterSlash < normalized.endIndex {
                candidates.append(String(normalized[afterSlash...]))
            }
        }

        var best: (prefix: String, rate: Rate)?
        for candidate in candidates {
            for (prefix, rate) in table where candidate.hasPrefix(prefix) {
                if best == nil || prefix.count > best!.prefix.count {
                    best = (prefix, rate)
                }
            }
        }
        if let best { return (best.rate, false) }

        let cheapest = table.values.min { ($0.inputPerMillion + $0.outputPerMillion) < ($1.inputPerMillion + $1.outputPerMillion) }
            ?? Rate(inputPerMillion: 0, outputPerMillion: 0, cacheReadPerMillion: nil)
        return (cheapest, true)
    }

    /// Estimated USD cost for one turn's token counts at API list rates.
    static func costUSD(provider: ProviderID, model: String, inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, outputTokens: Int) -> Double {
        let (rate, _) = rate(provider: provider, model: model)
        let cacheReadRate = rate.cacheReadPerMillion ?? rate.inputPerMillion * cacheReadMultiplier
        return (Double(inputTokens) / 1_000_000) * rate.inputPerMillion
            + (Double(outputTokens) / 1_000_000) * rate.outputPerMillion
            + (Double(cacheReadTokens) / 1_000_000) * cacheReadRate
            + (Double(cacheWriteTokens) / 1_000_000) * rate.inputPerMillion * cacheWriteMultiplier
    }
}
