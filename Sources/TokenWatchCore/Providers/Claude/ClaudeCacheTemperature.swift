import Foundation

/// Cache-temperature: answers "will my next Claude Code message be a cheap cache hit, or a
/// full-price re-read?" from local session transcripts alone -- no extra network call.
///
/// Anthropic's prompt cache holds a conversation's prefix for a TTL after the last turn: 5
/// minutes, or 1 hour for cache entries written with the extended TTL -- which current Claude
/// Code and omp use for nearly every turn. Both log which TTL each turn's cache writes used, so
/// the TTL is read per session (see `ttlSeconds(fiveMinuteWrites:oneHourWrites:)`), falling back
/// to the conservative 5 minutes only when a log doesn't say. While warm, a follow-up message
/// only pays for the new tokens; once it lapses, the next message re-reads the whole cached
/// prefix at full input price. Ported from the cache-temperature widget design in
/// github.com/EricCrosson/dotfiles (an omp/pi-coding-agent TUI extension) to a passive,
/// point-in-time badge suited to a menu-bar dashboard.
enum ClaudeCacheTemperature {
    /// Anthropic's default ephemeral prompt-cache TTL, and the fallback when a log doesn't record one.
    static let defaultTTLSeconds = 300
    /// The extended ("1h") prompt-cache TTL.
    static let extendedTTLSeconds = 3600
    static let minimumTTLSeconds = 5

    /// `TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS` forces one TTL for every session, overriding what
    /// the logs say; `nil` (the normal case) when unset or invalid.
    static func resolveTTLSeconds(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        guard let raw = environment["TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS"], let parsed = Int(raw) else {
            return nil
        }
        return max(minimumTTLSeconds, parsed)
    }

    /// The TTL one turn's cache writes imply, or `nil` when it wrote nothing (a pure cache hit,
    /// which refreshes whatever TTL the entries were written with). A turn that wrote any
    /// 5-minute entries reads as 5 minutes even if it also wrote 1-hour ones: that part of the
    /// context expires first and gets re-read at full price.
    static func ttlSeconds(fiveMinuteWrites: Int, oneHourWrites: Int) -> Int? {
        if fiveMinuteWrites > 0 { return defaultTTLSeconds }
        if oneHourWrites > 0 { return extendedTTLSeconds }
        return nil
    }

    /// Builds the `.badge` line for the dashboard, or `nil` when there's no local session
    /// activity to evaluate (no Claude Code transcripts found -- not an error, just nothing to
    /// show). `badgeID` defaults to the id `ProviderSnapshot.cacheTemperatureTone` and the
    /// status item look for (the headline, most-recent session); pass a distinct id for
    /// additional concurrently-active sessions so they don't collide in `snapshot.lines`.
    /// `ttlSeconds` overrides the session's own logged TTL (see `resolveTTLSeconds`).
    ///
    /// Leads with the project name and a flame/snowflake icon -- the glanceable part -- and
    /// pushes hit ratio / expiry / re-read size into `detail`, a smaller secondary line, rather
    /// than one long sentence.
    static func evaluate(activity: ClaudeSessionActivity?, now: Date = Date(), ttlSeconds: Int? = nil, badgeID: String = "cacheTemperature") -> MetricLine? {
        guard let activity else { return nil }

        let ttl = ttlSeconds ?? activity.cacheTTLSeconds ?? defaultTTLSeconds
        let expiresAt = activity.timestamp.addingTimeInterval(TimeInterval(ttl))
        let contextTokens = activity.inputTokens + activity.cacheReadTokens + activity.cacheCreationTokens

        if now < expiresAt {
            let hitSuffix = hitRatioText(activity).map { "\($0) hit · " } ?? ""
            let detail = "\(hitSuffix)expires \(formatClock(expiresAt))"
            return .badge(id: badgeID, text: activity.sessionLabel, tone: .neutral, icon: "flame.fill", detail: detail)
        }

        let detail = "cold · re-reads ~\(TokenCountFormatter.compact(contextTokens)) tok"
        return .badge(id: badgeID, text: activity.sessionLabel, tone: .warning, icon: "snowflake", detail: detail)
    }

    private static func hitRatioText(_ activity: ClaudeSessionActivity) -> String? {
        let denominator = activity.cacheReadTokens + activity.cacheCreationTokens + activity.inputTokens
        guard denominator > 0 else { return nil }
        let percent = Double(activity.cacheReadTokens) / Double(denominator) * 100
        return "\(Int(percent.rounded()))%"
    }

    /// Local HH:mm -- minute precision only. Anthropic's shortest cache window (5 minutes) makes
    /// second-level precision noise, not signal.
    private static func formatClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

