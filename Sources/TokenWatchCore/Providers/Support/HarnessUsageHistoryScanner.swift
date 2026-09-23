import Foundation

/// Daily usage the omp/pi harnesses logged for every model provider other than Claude and Codex
/// (which fold harness turns into their own scanners alongside their CLIs' logs): OpenRouter,
/// OpenAI API, Gemini, xAI, z.ai, Kimi, ... and `other` for providers TokenWatch has no card for.
/// Priced at the harness's own recorded cost, else at list rates (`ModelPricing.harnessCostUSD`).
public enum HarnessUsageHistoryScanner {
    public static func dailyUsage(days: Int, now: Date = Date(), calendar: Calendar = .current, roots: [String]? = nil) -> [SpendSource: [UsageDay]] {
        let cutoff = UsageDayAccumulator(days: days, now: now, calendar: calendar).cutoff
        var accumulators: [SpendSource: UsageDayAccumulator] = [:]
        for turn in HarnessUsageLog.turns(roots: roots ?? HarnessUsageLog.roots(), modifiedSince: cutoff)
            where turn.timestamp >= cutoff && turn.source != .provider(.claude) && turn.source != .provider(.codex) {
            let repriced = ModelPricing.harnessCostUSD(
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
