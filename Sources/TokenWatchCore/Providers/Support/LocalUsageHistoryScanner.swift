import Foundation

/// Daily usage from every local agent log (`LocalUsageLogs`: omp/pi, OpenCode, the Copilot, Grok,
/// Antigravity and Devin CLIs, fx, Muse Code) for every provider other than Claude and Codex --
/// those scanners fold the turns billed through them in alongside their own CLIs' logs. `other`
/// collects providers TokenWatch has no card for. Priced at the agent's own recorded cost, else at
/// list rates (`ModelPricing.listCostUSD`).
public enum LocalUsageHistoryScanner {
    public static func dailyUsage(days: Int, now: Date = Date(), calendar: Calendar = .current, locations: LocalUsageLocations = .standard()) -> [SpendSource: [UsageDay]] {
        let cutoff = UsageDayAccumulator(days: days, now: now, calendar: calendar).cutoff
        var accumulators: [SpendSource: UsageDayAccumulator] = [:]
        for turn in LocalUsageLogs.turns(locations, modifiedSince: cutoff)
            where turn.source != .provider(.claude) && turn.source != .provider(.codex) {
            let repriced = ModelPricing.listCostUSD(
                model: turn.model, inputTokens: turn.input, cacheReadTokens: turn.cacheRead,
                cacheWriteTokens: turn.cacheWrite, cacheWrite1hTokens: turn.cacheWrite1h, outputTokens: turn.output
            )
            accumulators[turn.source, default: UsageDayAccumulator(days: days, now: now, calendar: calendar)].add(
                timestamp: turn.timestamp, model: turn.model,
                input: turn.input, cacheRead: turn.cacheRead, cacheWrite: turn.cacheWrite, output: turn.output,
                costUSD: turn.costUSD ?? repriced.cost, approximate: turn.costUSD == nil && repriced.approximate
            )
        }
        return accumulators.mapValues { $0.build() }
    }
}
