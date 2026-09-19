import Foundation

/// Cache-temperature: answers "will my next Claude Code message be a cheap cache hit, or a
/// full-price re-read?" from local session transcripts alone -- no extra network call.
///
/// Anthropic's prompt cache holds a conversation's prefix for a TTL after the last turn (5
/// minutes by default; Claude Code can extend individual cache breakpoints to 1 hour, so this
/// intentionally stays conservative and may call a session "cold" slightly before an extended
/// breakpoint would). While warm, a follow-up message only pays for the new tokens; once it
/// lapses, the next message re-reads the whole cached prefix at full input price. Ported from
/// the cache-temperature widget design in github.com/EricCrosson/dotfiles (an omp/pi-coding-agent
/// TUI extension) to a passive, point-in-time badge suited to a menu-bar dashboard.
enum ClaudeCacheTemperature {
    /// Anthropic's default ephemeral prompt-cache TTL.
    static let defaultTTLSeconds = 300
    static let minimumTTLSeconds = 5

    /// `TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS` overrides the TTL (e.g. to model a workflow that
    /// only ever uses 1-hour cache breakpoints); invalid or missing values fall back to the
    /// conservative 5-minute default.
    static func resolveTTLSeconds(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = environment["TOKENWATCH_CLAUDE_CACHE_TTL_SECONDS"], let parsed = Int(raw) else {
            return defaultTTLSeconds
        }
        return max(minimumTTLSeconds, parsed)
    }

    /// Builds the `.badge` line for the dashboard, or `nil` when there's no local session
    /// activity to evaluate (no Claude Code transcripts found -- not an error, just nothing to
    /// show).
    static func evaluate(activity: ClaudeSessionActivity?, now: Date = Date(), ttlSeconds: Int = defaultTTLSeconds) -> MetricLine? {
        guard let activity else { return nil }

        let expiresAt = activity.timestamp.addingTimeInterval(TimeInterval(ttlSeconds))
        let contextTokens = activity.inputTokens + activity.cacheReadTokens + activity.cacheCreationTokens

        if now < expiresAt {
            let hitSuffix = hitRatioText(activity).map { " · \($0) hit" } ?? ""
            let text = "Cache warm\(hitSuffix) · expires \(formatClock(expiresAt))"
            return .badge(id: "cacheTemperature", text: text, tone: .neutral)
        }

        let text = "Cache cold · next message re-reads ~\(formatTokenCount(contextTokens)) tok at full price"
        return .badge(id: "cacheTemperature", text: text, tone: .warning)
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

    private static func formatTokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return "\(Int((Double(tokens) / 1_000).rounded()))k"
        }
        return String(tokens)
    }
}
