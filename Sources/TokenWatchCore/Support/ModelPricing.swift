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
    public static let pricingTableUpdatedOn = "2026-09-23"

    struct Rate: Equatable {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double?
    }

    /// Cache-read price as a share of the input rate, for models without their own explicit
    /// cache-read rate.
    private static let cacheReadMultiplier = 0.1
    /// Cache-write price as a multiple of the input rate: 1.25x for a 5-minute cache entry, 2x
    /// for a 1-hour one (which current Claude Code writes almost exclusively).
    private static let cacheWriteMultiplier = 1.25
    private static let cacheWrite1hMultiplier = 2.0

    /// Claude rates. Fable 5.1 and Mythos 5.1 keep Fable 5's token price but cut cache reads to
    /// $0.25/M instead of the usual 10% of input (Superset's and LiteLLM's tables agree).
    private static let claudeRates: [String: Rate] = [
        "claude-fable-5-1": Rate(inputPerMillion: 10, outputPerMillion: 50, cacheReadPerMillion: 0.25),
        "claude-mythos-5-1": Rate(inputPerMillion: 10, outputPerMillion: 50, cacheReadPerMillion: 0.25),
        "claude-fable-5": Rate(inputPerMillion: 10, outputPerMillion: 50, cacheReadPerMillion: nil),
        "claude-mythos": Rate(inputPerMillion: 10, outputPerMillion: 50, cacheReadPerMillion: nil),
        "claude-opus-5-5": Rate(inputPerMillion: 4, outputPerMillion: 20, cacheReadPerMillion: 0.2),
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

    /// Rates for current models from LiteLLM's public price list (the same source
    /// `PricingRefreshService` refreshes from), so estimates are right offline and on first launch.
    private static let codexRates: [String: Rate] = [
        "gpt-6-astra": Rate(inputPerMillion: 10, outputPerMillion: 50, cacheReadPerMillion: 1),
        "gpt-6-sol": Rate(inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: nil),
        "gpt-6-luna": Rate(inputPerMillion: 0.1, outputPerMillion: 0.5, cacheReadPerMillion: nil),
        // The bare `gpt-5.6` id follows Sol.
        "gpt-5.6": Rate(inputPerMillion: 4, outputPerMillion: 20, cacheReadPerMillion: 0.4),
        "gpt-5.6-sol": Rate(inputPerMillion: 4, outputPerMillion: 20, cacheReadPerMillion: 0.4),
        "gpt-5.6-terra": Rate(inputPerMillion: 2, outputPerMillion: 12, cacheReadPerMillion: 0.2),
        "gpt-5.6-luna": Rate(inputPerMillion: 0.2, outputPerMillion: 1.2, cacheReadPerMillion: 0.02),
        "gpt-5.5": Rate(inputPerMillion: 5, outputPerMillion: 30, cacheReadPerMillion: 0.5),
        "gpt-5.4": Rate(inputPerMillion: 2.5, outputPerMillion: 15, cacheReadPerMillion: 0.25),
        "gpt-5.3-codex": Rate(inputPerMillion: 1.75, outputPerMillion: 14, cacheReadPerMillion: nil),
        "gpt-5.3": Rate(inputPerMillion: 1.75, outputPerMillion: 14, cacheReadPerMillion: nil),
        "gpt-5-codex": Rate(inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: nil),
        "gpt-5": Rate(inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: nil),
        "gpt-4.1": Rate(inputPerMillion: 2, outputPerMillion: 8, cacheReadPerMillion: nil),
        "gpt-4o": Rate(inputPerMillion: 2.5, outputPerMillion: 10, cacheReadPerMillion: nil),
    ]

    /// xAI and Google rates, for the harness turns routed to them (see `harnessCostUSD`) --
    /// from Superset's maintained table. Gemini's >200K long-context tier isn't modeled: harness
    /// turns carry their own cost almost always, so these are a rarely used fallback.
    private static let grokRates: [String: Rate] = [
        "grok-4.6": Rate(inputPerMillion: 2, outputPerMillion: 6, cacheReadPerMillion: nil),
        "grok-4.5": Rate(inputPerMillion: 2, outputPerMillion: 6, cacheReadPerMillion: nil),
        "grok-4-fast": Rate(inputPerMillion: 0.2, outputPerMillion: 0.5, cacheReadPerMillion: nil),
        "grok-4": Rate(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: nil),
        "grok-code": Rate(inputPerMillion: 0.2, outputPerMillion: 1.5, cacheReadPerMillion: nil),
        "grok-3-mini": Rate(inputPerMillion: 0.3, outputPerMillion: 0.5, cacheReadPerMillion: nil),
        "grok-3": Rate(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: nil),
    ]

    private static let geminiRates: [String: Rate] = [
        "gemini-3.1-pro": Rate(inputPerMillion: 2, outputPerMillion: 12, cacheReadPerMillion: nil),
        "gemini-3-flash": Rate(inputPerMillion: 0.5, outputPerMillion: 3, cacheReadPerMillion: nil),
        "gemini-2.5-pro": Rate(inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: nil),
        "gemini-2.5-flash": Rate(inputPerMillion: 0.3, outputPerMillion: 2.5, cacheReadPerMillion: nil),
    ]

    private static func table(for provider: ProviderID) -> [String: Rate] {
        switch provider {
        case .claude: return claudeRates
        case .codex: return codexRates
        case .grok: return grokRates
        case .gemini: return geminiRates
        default: return [:]
        }
    }

    /// A substring every live-fetched model id for this provider is expected to contain --
    /// guards `DynamicPricingCache.bestMatch` against matching an unrelated vendor's similarly
    /// prefixed model in the same flat price list.
    private static func familyHint(for provider: ProviderID) -> String {
        switch provider {
        case .claude: return "claude"
        case .codex: return "gpt"
        case .grok: return "grok"
        case .gemini: return "gemini"
        default: return ""
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
        // Harnesses spell Claude versions with a dot (`anthropic/claude-haiku-4.5`); Anthropic's
        // own ids never use one, so the dashed spelling is always the one to price.
        if provider == .claude {
            candidates += candidates.filter { $0.contains(".") }.map { $0.replacingOccurrences(of: ".", with: "-") }
        }

        // A live-fetched rate (refreshed roughly hourly, see PricingRefreshService) wins over
        // the static table when both would match -- it tracks real vendor pricing instead of
        // whatever was hardcoded when this app version shipped.
        if let dynamicRate = DynamicPricingCache.shared.bestMatch(candidates: candidates, familyHint: familyHint(for: provider)) {
            return (dynamicRate, false)
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

    /// Estimated USD cost for one turn's token counts at API list rates. `cacheWriteTokens` is the
    /// total written; `cacheWrite1hTokens` is the part of it written with a 1-hour TTL (0 when a
    /// log doesn't split writes by TTL, which then prices them all as 5-minute writes).
    static func costUSD(provider: ProviderID, model: String, inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, cacheWrite1hTokens: Int = 0, outputTokens: Int) -> Double {
        costUSD(rate: rate(provider: provider, model: model).rate, inputTokens: inputTokens, cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens, cacheWrite1hTokens: cacheWrite1hTokens, outputTokens: outputTokens)
    }

    private static func costUSD(rate: Rate, inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, cacheWrite1hTokens: Int, outputTokens: Int) -> Double {
        let cacheReadRate = rate.cacheReadPerMillion ?? rate.inputPerMillion * cacheReadMultiplier
        let write1h = min(max(cacheWrite1hTokens, 0), cacheWriteTokens)
        return (Double(inputTokens) / 1_000_000) * rate.inputPerMillion
            + (Double(outputTokens) / 1_000_000) * rate.outputPerMillion
            + (Double(cacheReadTokens) / 1_000_000) * cacheReadRate
            + (Double(cacheWriteTokens - write1h) / 1_000_000) * rate.inputPerMillion * cacheWriteMultiplier
            + (Double(write1h) / 1_000_000) * rate.inputPerMillion * cacheWrite1hMultiplier
    }

    /// Cost of a harness turn (omp, pi) served by a model provider TokenWatch may have no table
    /// for, from disjoint token buckets: the model is matched against every table (Claude, OpenAI,
    /// xAI, Google), else priced at the cheapest known rate and flagged approximate. Harness turns
    /// carry their own recorded cost almost always; this is the fallback when one doesn't.
    static func harnessCostUSD(model: String, inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, cacheWrite1hTokens: Int, outputTokens: Int) -> (cost: Double, approximate: Bool) {
        let families: [ProviderID] = [.claude, .codex, .grok, .gemini]
        var matched: Rate?
        for family in families {
            let candidate = rate(provider: family, model: model)
            if !candidate.approximate { matched = candidate.rate; break }
        }
        let allRates: [Rate] = families.flatMap { Array(table(for: $0).values) }
        let fallback = allRates.min { lhs, rhs in lhs.inputPerMillion + lhs.outputPerMillion < rhs.inputPerMillion + rhs.outputPerMillion }!
        let cost = costUSD(rate: matched ?? fallback, inputTokens: inputTokens, cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens, cacheWrite1hTokens: cacheWrite1hTokens, outputTokens: outputTokens)
        return (cost, matched == nil)
    }

    /// Codex/OpenAI request pricing, ported from OpenUsage's `CodexUsagePricing`. OpenAI's usage
    /// shape counts cached tokens *and cache writes* inside `inputTokens` (confirmed in
    /// `codex-rs`: `total_tokens` = input + output, `non_cached_input` = input - cached), so only
    /// the remainder is billed at the input rate; writes bill at 1.25x input. Two request-level
    /// rules apply on top of the base rate:
    /// - Long context: a request above 272K input tokens on a model with a long-context tier bills
    ///   entirely at 2x input / 2x cache read / 1.5x output.
    /// - Priority (Codex "fast" service tier): the whole request is multiplied, 2.5x for gpt-5.5
    ///   and 2x otherwise.
    static func codexCostUSD(model: String, inputTokens: Int, cachedInputTokens: Int, cacheWriteInputTokens: Int = 0, outputTokens: Int, priorityTier: Bool = false) -> (cost: Double, approximate: Bool) {
        let (rate, approximate) = rate(provider: .codex, model: model)
        let base = datedBaseModel(model.lowercased())
        let longContext = inputTokens > codexLongContextThreshold && hasCodexLongContextTier(base)
        let inputRate = rate.inputPerMillion * (longContext ? 2 : 1)
        let cacheReadRate = (rate.cacheReadPerMillion ?? rate.inputPerMillion * cacheReadMultiplier) * (longContext ? 2 : 1)
        let outputRate = rate.outputPerMillion * (longContext ? 1.5 : 1)
        let cached = min(max(cachedInputTokens, 0), inputTokens)
        let written = min(max(cacheWriteInputTokens, 0), inputTokens - cached)
        let cost = (Double(inputTokens - cached - written) / 1_000_000) * inputRate
            + (Double(cached) / 1_000_000) * cacheReadRate
            + (Double(written) / 1_000_000) * inputRate * cacheWriteMultiplier
            + (Double(outputTokens) / 1_000_000) * outputRate
        let multiplier = priorityTier ? (base.hasPrefix("gpt-5.5") ? 2.5 : 2) : 1
        return (cost * multiplier, approximate)
    }

    static let codexLongContextThreshold = 272_000

    /// Models whose API pricing has a long-context (>272K input) tier; `-pro` variants price
    /// differently and aren't covered.
    private static func hasCodexLongContextTier(_ base: String) -> Bool {
        guard !base.contains("-pro") else { return false }
        return ["gpt-5.4", "gpt-5.5", "gpt-5.6", "gpt-6-astra"]
            .contains { base == $0 || base.hasPrefix($0 + "-") }
    }

    /// Strips a trailing `-YYYY-MM-DD` or `-YYYYMMDD` snapshot suffix.
    static func datedBaseModel(_ model: String) -> String {
        for pattern in ["-dddd-dd-dd", "-dddddddd"] where model.count > pattern.count {
            let matches = zip(model.suffix(pattern.count), pattern).allSatisfy { character, token in
                token == "d" ? character.isNumber : character == token
            }
            if matches { return String(model.dropLast(pattern.count)) }
        }
        return model
    }
}
