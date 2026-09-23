import Foundation

/// Codex cache-temperature: the same idea as `ClaudeCacheTemperature` -- answer "will my next
/// message be a cheap cache hit, or a full-price re-read?" from local rollout files alone -- but
/// deliberately not the same math, because OpenAI's cache expiry isn't the same shape as
/// Anthropic's.
///
/// Anthropic's ephemeral cache has one fixed, client-visible TTL (5 minutes, or an explicit 1h
/// breakpoint), so Claude's version can honestly compute and show an exact "expires HH:mm".
/// OpenAI's retention for the models Codex CLI actually uses is controlled server-side by the
/// org's `prompt_cache_retention` setting, which Codex CLI doesn't surface locally: `in_memory`
/// (roughly 5-10 minutes idle, up to 1 hour) for Zero-Data-Retention orgs, or `24h` extended
/// (roughly 30 minutes typical, up to 24 hours) otherwise -- and caching is also machine-local,
/// so routing variance can miss the cache independent of idle time. There is no single correct
/// countdown to show. Rather than fabricate one, this reports the one fact local files actually
/// contain: whether the *last* turn was itself a cache hit (`cached_input_tokens > 0`), with no
/// claimed expiry time.
enum CodexCacheTemperature {
    /// Builds the `.badge` line for the dashboard, or `nil` when there's no local rollout
    /// activity to evaluate (no Codex CLI transcripts found -- not an error, just nothing to
    /// show). `badgeID` defaults to the id `ProviderSnapshot.cacheTemperatureTone` and the status
    /// item look for (the headline, most-recent session); pass a distinct id for additional
    /// concurrently-active sessions so they don't collide in `snapshot.lines`.
    static func evaluate(activity: CodexSessionActivity?, badgeID: String = "cacheTemperature") -> MetricLine? {
        guard let activity else { return nil }

        if activity.cachedInputTokens > 0 {
            let hitSuffix = hitRatioText(activity).map { "\($0) hit last turn" } ?? "cache hit last turn"
            return .badge(id: badgeID, text: activity.sessionLabel, tone: .neutral, icon: "flame.fill", detail: hitSuffix)
        }

        let detail = "no hit last turn · re-reads ~\(TokenCountFormatter.compact(activity.inputTokens)) tok if cold"
        return .badge(id: badgeID, text: activity.sessionLabel, tone: .warning, icon: "snowflake", detail: detail)
    }

    private static func hitRatioText(_ activity: CodexSessionActivity) -> String? {
        guard activity.inputTokens > 0 else { return nil }
        let percent = Double(activity.cachedInputTokens) / Double(activity.inputTokens) * 100
        return "\(Int(percent.rounded()))%"
    }
}
