import Foundation

/// Claude usage via OAuth: session (5h) + weekly (7d) percent, plus extra usage spend when
/// enabled, plus a best-effort cache-temperature badge per locally active session (see
/// `ClaudeCacheTemperature`) -- the most recently touched session is the headline badge (id
/// `cacheTemperature`, also driving `lastActivityAt`/`lastActivityLabel`), any other sessions
/// touched within the last 5 hours each get their own additional badge so the dashboard can list
/// every session currently in play, not just the newest. Local activity is merged from two
/// sources: `ClaudeSessionScanner` (the real `claude` CLI's own transcripts) and
/// `OmpSessionScanner` (a coding-agent harness that calls the Anthropic API directly and never
/// runs the `claude` CLI, so it has its own separate transcript format -- see that scanner's doc
/// comment) -- without the second source, any Claude usage happening through such a harness is
/// invisible here even though the account-level Session/Weekly percent below already reflects it.
/// Credentials: freshest of the Claude CLI Keychain item, `~/.claude/.credentials.json`, and
/// `~/.config/claude/credentials.json` -- see `ClaudeAuthStore`. A locally lapsed credential
/// short-circuits before any network call (see `ClaudeCredentialLapse`), distinguishing "will
/// refresh itself" from "needs `/login` again" rather than treating every lapse as the same
/// generic error. Local `.jsonl` per-model cost scanning (Claude Tracker's per-model breakdown)
/// remains a stretch goal skipped in v1 -- see plan Phase 2 step 1.
public struct ClaudeProvider: ProviderRuntime {
    public static let id: ProviderID = .claude
    public static let displayName = "Claude"

    private let authStore: ClaudeAuthStore
    private let usageClient: ClaudeUsageClient

    public init(authStore: ClaudeAuthStore = ClaudeAuthStore()) {
        self.authStore = authStore
        self.usageClient = ClaudeUsageClient()
    }

    public func detect() -> ProviderDetection? {
        authStore.detect()
    }

    public func refresh() async -> ProviderSnapshot {
        guard let credential = authStore.resolvedCredential() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }

        switch ClaudeAuthStore.classifyLapse(credential) {
        case .stale:
            return .error(provider: Self.id, error: .credentialLapsed(
                selfHeals: true,
                detail: "Access token will refresh automatically next time you run the claude CLI directly (not through a harness/wrapper) -- no action needed."
            ))
        case .expired:
            return .error(provider: Self.id, error: .credentialLapsed(
                selfHeals: false,
                detail: "Sign-in expired. \(ProviderID.claude.credentialSourceHint)"
            ))
        case .live:
            break
        }

        do {
            let response = try await usageClient.fetchUsage(accessToken: credential.accessToken)
            var lines = ClaudeMapper.map(response)
            let ttlSeconds = ClaudeCacheTemperature.resolveTTLSeconds() // nil: each session's own logged TTL
            let activity = Self.mostRecentActivity()
            if let cacheLine = ClaudeCacheTemperature.evaluate(activity: activity, ttlSeconds: ttlSeconds) {
                lines.append(cacheLine)
            }

            let otherActiveSessions = Self.allActiveSessions(excludingFilePath: activity?.filePath)
            for (index, session) in otherActiveSessions.enumerated() {
                if let line = ClaudeCacheTemperature.evaluate(activity: session, ttlSeconds: ttlSeconds, badgeID: "cacheTemperature-other-\(index)") {
                    lines.append(line)
                }
            }

            return ProviderSnapshot(provider: Self.id, plan: credential.subscriptionType, lines: lines, fetchedAt: Date(), lastActivityAt: activity?.timestamp, lastActivityLabel: activity?.sessionLabel)
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }

    /// The single most recently touched session across both local-activity sources.
    private static func mostRecentActivity() -> ClaudeSessionActivity? {
        let candidates = [ClaudeSessionScanner.mostRecentActivity(), OmpSessionScanner.mostRecentActivity()].compactMap { $0 }
        return candidates.max { $0.timestamp < $1.timestamp }
    }

    /// Every other session touched within the active window, from both sources combined, newest
    /// first, excluding whichever file is already shown as the headline.
    private static func allActiveSessions(excludingFilePath headlineFilePath: String?) -> [ClaudeSessionActivity] {
        let combined = ClaudeSessionScanner.allRecentActivity() + OmpSessionScanner.allRecentActivity()
        return combined.filter { $0.filePath != headlineFilePath }.sorted { $0.timestamp > $1.timestamp }
    }
}
